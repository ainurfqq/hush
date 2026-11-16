import Foundation

/// One live line shown while recording.
struct LiveLine: Identifiable, Equatable {
    let id = UUID()
    var t: Double
    var who: String   // "me" or "them"
    var text: String
}

/// Records a meeting. Call mode = mic + system audio; room mode = mic only.
/// Audio goes to disk continuously (crash-safe); speech chunks go to the live transcriber.
final class Recorder {
    enum Mode: String { case call, room }

    let meetingID: String
    let mode: Mode
    private let tap = SystemAudioTap()
    private let mic = MicCapture()
    private var micWriter: WAVStreamWriter?, sysWriter: WAVStreamWriter?
    private var micDS: Downsampler?, sysDS: Downsampler?
    private var micChunker = Chunker(), sysChunker = Chunker()
    private let q = DispatchQueue(label: "hush.recorder")
    private let asrQ = DispatchQueue(label: "hush.live-asr")
    private(set) var started = Date()

    var onLine: ((LiveLine) -> Void)?
    var onLevels: ((Float, Float) -> Void)?   // mic, system (RMS of last buffer)
    private var micLevel: Float = 0, sysLevel: Float = 0

    init(mode: Mode, title: String) throws {
        self.mode = mode
        meetingID = Store.newID(title: title)
        let files = mode == .call ? ["mic.wav", "system.wav"] : ["mic.wav"]
        _ = try Store.create(Meeting(id: meetingID, title: title, source: mode == .call ? "live" : "mic", audioFiles: files, status: .recording))
    }

    func start(echoCancel: Bool = true) throws {
        let dir = Store.folder(meetingID)
        micWriter = try WAVStreamWriter(url: dir.appendingPathComponent("mic.wav"))
        mic.echoCancel = echoCancel && mode == .call && ProcessInfo.processInfo.environment["HUSH_NO_AEC"] != "1"
        mic.onSamples = { [weak self] s in self?.q.async { self?.ingest(s, system: false) } }
        try mic.start()
        micDS = Downsampler(inRate: mic.sampleRate)
        if mode == .call {
            sysWriter = try WAVStreamWriter(url: dir.appendingPathComponent("system.wav"))
            tap.onSamples = { [weak self] s in self?.q.async { self?.ingest(s, system: true) } }
            do { try tap.start(); sysDS = Downsampler(inRate: tap.sampleRate) }
            catch { mic.stop(); throw error }
        }
        started = Date()
        DispatchQueue.global().async { _ = try? WhisperServer.shared.ensureRunning(live: true) }
    }

    private func ingest(_ s: [Float], system: Bool) {
        if system {
            guard var ds = sysDS else { return }
            let x = ds.process(s); sysDS = ds
            sysWriter?.append(x); sysLevel = WAV.rms(x[...])
            for (t, chunk) in sysChunker.push(x) { transcribe(chunk, at: t, who: "them") }
        } else {
            guard var ds = micDS else { return }
            let x = ds.process(s); micDS = ds
            micWriter?.append(x); micLevel = WAV.rms(x[...])
            for (t, chunk) in micChunker.push(x) { transcribe(chunk, at: t, who: "me") }
        }
        onLevels?(micLevel, sysLevel)
    }

    // MARK: live ASR scheduling
    // One ASR call at a time. Call audio ("them") goes first: that is where questions come from.
    // When behind, waiting chunks of the same channel are joined into one call instead of dropped.
    // Mic chunks are context only: kept to the newest 3 and skipped when quiet.
    private var waiting: [(t: Double, who: String, samples: [Float])] = []
    private var asrBusy = false

    private func transcribe(_ chunk: [Float], at t: Double, who: String) {
        let gate: Float = who == "me" ? 0.015 : 0.006       // the mic hears room noise; be stricter
        guard WAV.rms(chunk[...]) > gate else { return }
        waiting.append((t, who, chunk))
        let mine = waiting.filter { $0.who == "me" }
        if mine.count > 3, let oldest = waiting.firstIndex(where: { $0.who == "me" }) {
            waiting.remove(at: oldest); Log.write("live ASR busy: skipped an old mic chunk")
        }
        pump()
    }

    /// Runs on `q`.
    private func pump() {
        guard !asrBusy, !waiting.isEmpty else { return }
        let who = waiting.contains { $0.who == "them" } ? "them" : "me"
        var t0 = -1.0, joined: [Float] = []
        let gap = [Float](repeating: 0, count: 4800)       // 0.3 s between joined chunks
        while let i = waiting.firstIndex(where: { $0.who == who }), Double(joined.count + waiting[i].samples.count) / 16000 <= 25 || joined.isEmpty {
            let c = waiting.remove(at: i)
            if t0 < 0 { t0 = c.t } else { joined += gap }
            joined += c.samples
        }
        if joined.count > 9 * 16000 { Log.write(String(format: "live ASR caught up: joined %.1f s of %@ audio", Double(joined.count) / 16000, who)) }
        asrBusy = true
        let start = t0, audio = joined
        asrQ.async { [weak self] in
            defer { self?.q.async { self?.asrBusy = false; self?.pump() } }
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("hush-live-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: f) }
            do {
                try WAV.write(audio[...], to: f)
                let p = try Transcriber.transcribe(f, live: true)
                let dur = Double(audio.count) / 16000
                guard !p.text.isEmpty, p.noSpeech < 0.8, !Transcriber.isLikelyHallucination(p.text, duration: dur),
                      !Transcriber.isRepetitive(p.text) else { return }
                self?.onLine?(LiveLine(t: start, who: who, text: p.text))
            } catch { Log.write("live ASR: \(error)") }
        }
    }

    /// Appends one line to the meeting's live log (live.md): what Hush heard and what the prompter did.
    func liveLog(_ text: String) {
        let url = Store.folder(meetingID).appendingPathComponent("live.md")
        let line = "[\(formatTime(Date().timeIntervalSince(started)))] \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(("# Live log\n\n" + line).utf8).write(to: url) }
    }

    /// Stops capture and returns the stored meeting (status .recorded).
    func stop() -> Meeting? {
        mic.stop(); tap.stop()
        q.sync {}
        micWriter?.close(); sysWriter?.close()
        guard var m = try? Store.load(meetingID) else { return nil }
        m.duration = Date().timeIntervalSince(started)
        m.status = .recorded
        try? Store.save(m)
        return m
    }
}

/// Feeds a WAV file through the same live path (chunker → async ASR queue → question detector) in real time.
/// Used by `Hush --simulate <file>` for repeatable prompter tests without a live call.
final class FileFeeder {
    var onLine: ((LiveLine) -> Void)?
    private var stopped = false
    private let asrQ = DispatchQueue(label: "hush.sim-asr")
    func run(_ url: URL, who: String = "them") {
        DispatchQueue.global().async { [self] in
            guard let s = try? WAV.read(url).samples else { return }
            var ch = Chunker(); var i = 0; let block = 1600   // 100 ms blocks, like a live tap
            let t0 = Date()
            while i < s.count && !stopped {
                let end = min(s.count, i + block)
                for (t, chunk) in ch.push(Array(s[i..<end])) {
                    asrQ.async { [self] in
                        do {
                            let f = FileManager.default.temporaryDirectory.appendingPathComponent("hush-sim-\(UUID().uuidString).wav")
                            try WAV.write(chunk[...], to: f); defer { try? FileManager.default.removeItem(at: f) }
                            let p = try Transcriber.transcribe(f, live: true)
                            if !p.text.isEmpty { onLine?(LiveLine(t: t, who: who, text: p.text)) }
                        } catch { Log.write("simulate: \(error)") }
                    }
                }
                i = end
                let due = Double(i) / 16000, now = Date().timeIntervalSince(t0)
                if due > now { usleep(UInt32((due - now) * 1_000_000)) }
            }
        }
    }
    func stop() { stopped = true }
}
