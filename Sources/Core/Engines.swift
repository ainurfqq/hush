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
    public static var whisperServer: String? { Shell.which("whisper-server") }

    /// Human-readable readiness report (used by `hush doctor` and the app's setup panel).
    public static func check(_ c: Config = .load()) -> [(String, Bool, String)] {
        let fm = FileManager.default
        return [
            ("whisper-server (brew install whisper-cpp)", whisperServer != nil, whisperServer ?? "not found"),
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

    public func ensureRunning(config: Config = .load(), live: Bool = false) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let model = Engines.asrModel(config, live: live).path
        if let p = process, p.isRunning, modelPath == model { return port }
        process?.terminate()
        guard let exe = Engines.whisperServer else { throw HushError.missing("whisper-server. Install with: brew install whisper-cpp") }
        guard FileManager.default.fileExists(atPath: model) else { throw HushError.missing("ASR model at \(model). Run: hush setup") }
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
    static var pidFile: URL { Paths.base.appendingPathComponent("whisper-server.pid") }

    /// Kills a watchdog left by an earlier Hush process (its trap then stops the server).
    static func killStale() {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != getpid() else { return }
        kill(pid, SIGTERM)
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

public struct TranscriptPiece { public var text: String; public var language: String?; public var noSpeech: Double; public var avgLogprob: Double }

public enum Transcriber {
    /// Transcribes one short WAV file (≤ ~30 s) with per-call language detection.
    public static func transcribe(_ wav: URL, language: String = "auto", config: Config = .load(), live: Bool = false) throws -> TranscriptPiece {
        let port = try WhisperServer.shared.ensureRunning(config: config, live: live)
        var form = MultipartForm()
        form.addFile("file", filename: "a.wav", mime: "audio/wav", data: try Data(contentsOf: wav))
        form.addField("response_format", "verbose_json")
        form.addField("language", language)
        form.addField("temperature", "0")
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
        let text = cleanText((j["text"] as? String) ?? "")
        let lang = (j["detected_language"] as? String) ?? (j["language"] as? String)
        return TranscriptPiece(text: text, language: language == "auto" ? lang.map(langCode) : language, noSpeech: noSpeech, avgLogprob: avgLogprob)
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
        guard FileManager.default.isExecutableFile(atPath: exe) else { throw HushError.missing("sherpa-onnx diarizer. Run: hush setup") }
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
