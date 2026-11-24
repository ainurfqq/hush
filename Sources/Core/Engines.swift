import Foundation

/// Local engines Hush drives as subprocesses. Pinned versions + SHA-256 live in scripts/engines.lock.
public enum Engines {
    public static let sherpaDirName = "sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts"
    public static var sherpaDiarizer: URL { Paths.engines.appendingPathComponent("\(sherpaDirName)/bin/sherpa-onnx-offline-speaker-diarization") }
    public static var segmentationModel: URL { Paths.models.appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0/model.onnx") }
    public static var embeddingModel: URL { Paths.models.appendingPathComponent("3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx") }
    public static func asrModel(_ c: Config = .load(), live: Bool = false) -> URL {
        let liveURL = Paths.models.appendingPathComponent(c.liveAsrModel)
        if live, !c.liveAsrModel.isEmpty, FileManager.default.fileExists(atPath: liveURL.path) { return liveURL }
        return Paths.models.appendingPathComponent(c.asrModel)
    }
    /// The DMG build carries its own whisper-server next to the app binary; other builds use Homebrew's.
    public static var whisperServer: String? {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundled = exe.deletingLastPathComponent().appendingPathComponent("whisper-server").path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        return Shell.which("whisper-server")
    }

    /// Inside Hush.app (DMG build) there is no `hush` command on PATH, so point at the app's own button.
    public static var inApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    public static var setupHint: String { inApp ? "Open the Hush menu and click Finish the download." : "Run: hush setup" }

    /// Human-readable readiness report (used by `hush doctor` and the app's setup panel).
    public static func check(_ c: Config = .load()) -> [(String, Bool, String)] {
        let fm = FileManager.default
        return [
            ("whisper-server", whisperServer != nil, whisperServer ?? "not found"),
            ("ASR model \(c.asrModel)", fm.fileExists(atPath: asrModel(c).path), asrModel(c).path),
            ("sherpa-onnx diarizer", fm.isExecutableFile(atPath: sherpaDiarizer.path), sherpaDiarizer.path),
            ("segmentation model", fm.fileExists(atPath: segmentationModel.path), segmentationModel.path),
            ("speaker embedding model", fm.fileExists(atPath: embeddingModel.path), embeddingModel.path),
        ]
    }
}

/// Keeps one whisper-server process alive on 127.0.0.1 so the model loads once.
public final class WhisperServer {
    public static let shared = WhisperServer()
    private var process: Process?
    private(set) public var port: Int = 0
    private let lock = NSLock()
    private var modelPath = ""
    /// Set while a final transcript runs (Pipeline): the server must not be swapped for the live model.
    public var pinned = false

    public func ensureRunning(config: Config = .load(), live: Bool = false) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let model = Engines.asrModel(config, live: live).path
        if let p = process, p.isRunning, modelPath == model { return port }
        // Notes for the last meeting are being made: live captions share that model instead of killing it mid-request.
        if live, pinned, let p = process, p.isRunning { return port }
        process?.terminate()
        guard let exe = Engines.whisperServer else { throw HushError.missing("whisper-server. " + (Engines.inApp ? "Reinstall Hush from the download link." : "Install with: brew install whisper-cpp")) }
        guard FileManager.default.fileExists(atPath: model) else { throw HushError.missing("ASR model at \(model). \(Engines.setupHint)") }
        let port = Int.random(in: 18100...18999)
        Self.killStale()
        let p = Process()
        // Watchdog shell: the server dies when Hush dies (crash, exit(), kill), so no 600 MB orphans pile up.
        // Bound to loopback only. Threads: 4 is the measured sweet spot on M2 (spikes.md §B).
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.watchdog, exe, "-m", model, "--host", "127.0.0.1", "--port", String(port), "-l", "auto", "-t", "4"]
        let null = FileHandle(forWritingAtPath: "/dev/null")
        p.standardOutput = null; p.standardError = null
        try p.run()
        Log.write("whisper-server pid \(p.processIdentifier) port \(port)")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning { throw HushError.engine("whisper-server exited during start") }
            if Self.ping(port) { break }
            usleep(250_000)
        }
        guard Self.ping(port) else { p.terminate(); throw HushError.engine("whisper-server did not start in 90 s") }
        process = p; self.port = port; modelPath = model
        try? "\(p.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        return port
    }

    static let watchdog = "\"$0\" \"$@\" & c=$!; trap 'kill $c 2>/dev/null' EXIT TERM INT HUP; while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 1; done"
    /// One file per program (app and CLI), so running `hush-cli` never stops the app's server, or the other way round.
    static var pidFile: URL { Paths.base.appendingPathComponent("whisper-server-\(ProcessInfo.processInfo.processName).pid") }

    /// Kills a watchdog left by an earlier Hush process (its trap then stops the server).
    /// Only if that pid is still our watchdog: after a reboot the number can belong to any other app.
    static func killStale() {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != getpid() else { return }
        let cmd = (try? Shell.run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 5).stdout) ?? ""
        if cmd.contains("whisper-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate(); process = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    static func ping(_ port: Int) -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!); req.timeoutInterval = 1
        return (try? HTTP.send(req).1) != nil
    }

    deinit { process?.terminate() }
}

public struct TimedWord { public var start: Double; public var end: Double; public var word: String }
public struct TranscriptPiece {
    public var text: String; public var language: String?; public var noSpeech: Double; public var avgLogprob: Double
    public var words: [TimedWord] = []
}

public enum Transcriber {
    /// Transcribes one short WAV file (≤ ~30 s) with per-call language detection.
    public static func transcribe(_ wav: URL, language: String = "auto", config: Config = .load(), live: Bool = false) throws -> TranscriptPiece {
        let port = try WhisperServer.shared.ensureRunning(config: config, live: live)
        var form = MultipartForm()
        form.addFile("file", filename: "a.wav", mime: "audio/wav", data: try Data(contentsOf: wav))
        form.addField("response_format", "verbose_json")
        form.addField("language", language)
        form.addField("temperature", "0")
        // With a fixed language, skip whisper.cpp's extra language-probability pass (one more encoder run per call).
        if language != "auto" { form.addField("no_language_probabilities", "true") }
        let hint = Keyterms.prompt(config)
        if !hint.isEmpty { form.addField("prompt", hint) }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"; req.timeoutInterval = 300
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalBody
        let (data, status) = try HTTP.send(req)
        guard status == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HushError.engine("whisper-server HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let segs = (j["segments"] as? [[String: Any]]) ?? []
        let noSpeech = segs.compactMap { $0["no_speech_prob"] as? Double }.max() ?? 0
        let lps = segs.compactMap { $0["avg_logprob"] as? Double }
        let avgLogprob = lps.isEmpty ? 0 : lps.reduce(0, +) / Double(lps.count)
        var text = cleanText((j["text"] as? String) ?? "")
        if !hint.isEmpty, text.hasPrefix(Keyterms.lead) { text = "" }     // on silence whisper can echo its prompt
        let lang = (j["detected_language"] as? String) ?? (j["language"] as? String)
        let words: [TimedWord] = segs.flatMap { seg in
            ((seg["words"] as? [[String: Any]]) ?? []).compactMap { w in
                guard let t = w["word"] as? String, let a = w["start"] as? Double, let b = w["end"] as? Double else { return nil }
                return TimedWord(start: a, end: b, word: t)
            }
        }
        let piece = TranscriptPiece(text: text, language: language == "auto" ? lang.map(langCode) : language, noSpeech: noSpeech,
                                    avgLogprob: avgLogprob, words: words)
        // Auto mode with a language list: a guess outside the list (Greek, Korean… on short or noisy audio) is redone
        // in the last listed language heard, so the line keeps its words instead of turning into another script.
        if language == "auto", !config.languages.isEmpty, !text.isEmpty, let got = piece.language {
            if config.languages.contains(got) { lastListed.set(got) }
            else {
                let redo = lastListed.get(in: config.languages) ?? config.languages[0]
                Log.write("language guess \(got) not in \(config.languages.joined(separator: ",")); redoing as \(redo)")
                return try transcribe(wav, language: redo, config: config, live: live)
            }
        }
        return piece
    }

    /// The last language from the user's list that whisper detected (shared by live and final transcription).
    static let lastListed = LastLanguage()
    final class LastLanguage {
        private var value: String?; private let lock = NSLock()
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get(in list: [String]) -> String? { lock.lock(); defer { lock.unlock() }; return value.flatMap { list.contains($0) ? $0 : nil } }
    }

    public static func cleanText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper's well-known silence hallucinations.
        let junk = ["[BLANK_AUDIO]", "[Music]", "(music)", "[MUSIC]", "[ Silence ]", "[SILENCE]"]
        for j in junk { t = t.replacingOccurrences(of: j, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func langCode(_ s: String) -> String {
        let map = ["english": "en", "indonesian": "id", "malay": "ms", "javanese": "jw", "sundanese": "su"]
        return map[s.lowercased()] ?? s
    }

    /// Whisper on noise often loops one sentence ("I don't know what I'm talking about." ×10).
    public static func isRepetitive(_ text: String) -> Bool {
        let parts = text.lowercased().split(whereSeparator: { ".?!".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 3 else { return false }
        let most = Dictionary(grouping: parts, by: { $0 }).values.map(\.count).max() ?? 0
        return Double(most) / Double(parts.count) >= 0.6
    }

    /// Short silent-audio hallucinations whisper is known to emit.
    public static func isLikelyHallucination(_ text: String, duration: Double) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let known = ["thank you", "thanks for watching", "thank you for watching", "terima kasih telah menonton",
                     "terima kasih sudah menonton", "sampai jumpa di video berikutnya", "subscribe", "you"]
        return duration < 4 && known.contains(t)
    }
}

public struct DiarTurn: Equatable { public var start: Double; public var end: Double; public var label: String }

public enum Diarizer {
    /// Runs sherpa-onnx offline diarization. `speakers` > 0 forces that many clusters.
    public static func run(_ wav: URL, speakers: Int = 0, threshold: Double = 0.9) throws -> [DiarTurn] {
        let exe = Engines.sherpaDiarizer.path
        guard FileManager.default.isExecutableFile(atPath: exe) else { throw HushError.missing("sherpa-onnx diarizer. \(Engines.setupHint)") }
        var args = ["--segmentation.pyannote-model=\(Engines.segmentationModel.path)",
                    "--embedding.model=\(Engines.embeddingModel.path)",
                    "--segmentation.num-threads=4", "--embedding.num-threads=4"]
        if speakers > 0 { args.append("--clustering.num-clusters=\(speakers)") }
        else { args.append("--clustering.cluster-threshold=\(threshold)") }
        args.append(wav.path)
        let r = try Shell.run(exe, args, timeout: 3600)
        guard r.status == 0 else { throw HushError.engine("diarizer exit \(r.status): \(r.stderr.suffix(300))") }
        return parse(r.stdout)
    }

    /// Parses lines like "0.031 -- 11.017 speaker_00".
    public static func parse(_ out: String) -> [DiarTurn] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ")
            guard p.count >= 4, p[1] == "--", let s = Double(p[0]), let e = Double(p[2]) else { return nil }
            return DiarTurn(start: s, end: e, label: String(p[3]))
        }
    }
}

// MARK: - tiny HTTP helpers (sync, for engine + provider calls off the main thread)

public enum HTTP {
    public static func send(_ req: URLRequest) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?; var error: Error?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = req.timeoutInterval
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { d, r, e in
            if let e { error = e } else { result = (d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 0) }
            sem.signal()
        }.resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        if let error { throw error }
        return result!
    }

    /// Sends `req` and hands over each response line as it arrives (for streamed replies).
    /// Returns the whole body (useful for error messages) and the status code.
    public static func streamLines(_ req: URLRequest, onLine: @escaping (String) -> Void) throws -> (Data, Int) {
        let d = LineDelegate(onLine: onLine)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = req.timeoutInterval
        let session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
        session.dataTask(with: req).resume()
        d.done.wait()
        session.finishTasksAndInvalidate()
        if let e = d.error { throw e }
        return (d.body, d.status)
    }

    final class LineDelegate: NSObject, URLSessionDataDelegate {
        let onLine: (String) -> Void
        let done = DispatchSemaphore(value: 0)
        var body = Data(), buf = Data(), status = 0, error: Error?
        init(onLine: @escaping (String) -> Void) { self.onLine = onLine }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0; completionHandler(.allow)
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data); buf.append(data)
            while let nl = buf.firstIndex(of: 10) {
                onLine(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                buf.removeSubrange(buf.startIndex...nl)
            }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if !buf.isEmpty { onLine(String(decoding: buf, as: UTF8.self)); buf.removeAll() }
            error = e; done.signal()
        }
    }
}

public struct MultipartForm {
    let boundary = "hush-\(UUID().uuidString)"
    public private(set) var body = Data()
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    public init() {}
    public mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    public mutating func addFile(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n".utf8))
    }
    public var finalBody: Data { var b = body; b.append(Data("--\(boundary)--\r\n".utf8)); return b }
}
