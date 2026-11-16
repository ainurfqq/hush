import Foundation

/// Turns recorded audio into a speaker-labelled transcript.
///
/// - Two channels (online call): mic.wav → "me"; system.wav → diarized into spk1..n.
/// - One channel (in-room or imported): audio.wav / mic.wav → diarized into spk1..n.
/// Each turn is transcribed on its own with language auto-detect (fixes code-switch translation, spikes.md §B).
public enum Pipeline {
    public typealias Progress = (String, Double) -> Void

    public static let maxTurn = 28.0

    public static func process(_ meetingID: String, config: Config = .load(), progress: Progress = { _, _ in }) throws -> Meeting {
        var m = try Store.load(meetingID)
        m.status = .processing; m.error = nil
        try Store.save(m)
        do {
            m = try run(m, config: config, progress: progress)
            m.status = .ready
            try Store.save(m)
            return m
        } catch {
            m.status = .failed; m.error = "\(error)"
            try? Store.save(m)
            throw error
        }
    }

    static func run(_ meeting: Meeting, config: Config, progress: Progress) throws -> Meeting {
        var m = meeting
        let dir = Store.folder(m.id)
        let fm = FileManager.default
        let mic = dir.appendingPathComponent("mic.wav"), sys = dir.appendingPathComponent("system.wav")
        let single = dir.appendingPathComponent("audio.wav")
        var turns: [(DiarTurn, URL, String)] = []   // turn, source file, speaker id

        let hasSys = fm.fileExists(atPath: sys.path) && WAV.duration(sys) > 1 && hasSignal(sys)
        let hasMic = fm.fileExists(atPath: mic.path) && WAV.duration(mic) > 1

        // Warm the ASR server while diarization runs (both are needed; this hides the ~5-10 s model load).
        DispatchQueue.global().async { _ = try? WhisperServer.shared.ensureRunning(config: config) }

        if hasSys {
            progress("Finding speakers in call audio", 0.05)
            let d = try Diarizer.run(sys)
            turns += relabel(d).map { ($0, sys, $0.label) }
            if hasMic && hasSignal(mic) {
                progress("Finding your speech in mic audio", 0.2)
                let me = try Diarizer.run(mic, speakers: 1)
                turns += me.map { ($0, mic, "me") }
            }
        } else {
            let src = fm.fileExists(atPath: single.path) ? single : mic
            guard fm.fileExists(atPath: src.path) else { throw HushError.badAudio("no audio in \(dir.path)") }
            progress("Finding speakers", 0.05)
            let d = try Diarizer.run(src)
            turns += relabel(d).map { ($0, src, $0.label) }
        }

        // Merge per source + speaker, then split long turns.
        var units: [(start: Double, end: Double, src: URL, spk: String)] = []
        for group in Dictionary(grouping: turns, by: { "\($0.1.path)|\($0.2)" }).values {
            let sorted = group.sorted { $0.0.start < $1.0.start }
            for (t, src, spk) in sorted {
                if var last = units.last, last.src == src, last.spk == spk,
                   t.start - last.end < 0.8, t.end - last.start <= maxTurn {
                    last.end = max(last.end, t.end); units[units.count - 1] = last
                } else {
                    units.append((t.start, t.end, src, spk))
                }
            }
        }
        units = units.flatMap { u -> [(start: Double, end: Double, src: URL, spk: String)] in
            var out: [(start: Double, end: Double, src: URL, spk: String)] = []
            var s = u.start
            while s < u.end { let e = min(u.end, s + maxTurn); out.append((s, e, u.src, u.spk)); s = e }
            return out
        }.filter { $0.end - $0.start >= 0.4 }.sorted { $0.start < $1.start }

        // Load audio once per source.
        var cache: [URL: [Float]] = [:]
        for u in units where cache[u.src] == nil { cache[u.src] = try WAV.read(u.src).samples }

        let tmp = fm.temporaryDirectory.appendingPathComponent("hush-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var segments: [Segment] = []
        var langState = SpeakerLanguages()
        let windows = ProcessInfo.processInfo.environment["HUSH_NO_BATCH"] == "1"
            ? units.indices.map { [$0] } : batch(units.map { ($0.src.path, $0.spk, $0.end - $0.start) })
        for (wi, w) in windows.enumerated() {
            progress("Transcribing \(wi + 1)/\(windows.count)", 0.25 + 0.7 * Double(wi) / Double(max(windows.count, 1)))
            // Window audio = the turns of one speaker, back to back with 0.6 s silence between them.
            var audio: [Float] = [], offsets: [Double] = []
            for (k, ui) in w.enumerated() {
                let u = units[ui], samples = cache[u.src]!
                let a = max(0, Int((u.start - 0.15) * 16000)), b = min(samples.count, Int((u.end + 0.15) * 16000))
                if k > 0 { audio += [Float](repeating: 0, count: Int(gap * 16000)) }
                offsets.append(Double(audio.count) / 16000)
                if b > a { audio += samples[a..<b] }
            }
            guard audio.count > 1600 else { continue }
            let f = tmp.appendingPathComponent("\(wi).wav")
            try WAV.write(audio[...], to: f)
            let piece = try transcribeTurn(f, speaker: units[w[0]].spk, langState: &langState, config: config)
            for (k, text) in split(piece, offsets: offsets, total: Double(audio.count) / 16000).enumerated() {
                let u = units[w[k]]
                if text.isEmpty || Transcriber.isLikelyHallucination(text, duration: u.end - u.start) || Transcriber.isRepetitive(text) { continue }
                segments.append(Segment(start: u.start, end: u.end, speaker: u.spk, text: text, language: piece.language))
            }
        }

        m.segments = dropEchoes(segments).sorted { $0.start < $1.start }
        m.duration = max(m.duration, [mic, sys, single].map { WAV.duration($0) }.max() ?? 0)
        progress("Done", 1)
        return m
    }

    static let gap = 0.6
    static let maxWindow = 28.0

    /// Groups turns (source, speaker, duration) into windows of one speaker from one file, ≤ 28 s of audio each,
    /// in time order. Fewer, fuller whisper calls: each call costs a fixed 30 s encoder pass no matter how short the audio.
    /// One speaker per window keeps one language per call, so the code-switch translation bug (spikes §B) cannot come back.
    public static func batch(_ turns: [(src: String, spk: String, dur: Double)]) -> [[Int]] {
        var open: [String: [Int]] = [:], openLen: [String: Double] = [:], out: [[Int]] = []
        for (i, t) in turns.enumerated() {
            let key = t.src + "|" + t.spk
            if let cur = open[key], openLen[key]! + gap + t.dur + 0.3 > maxWindow { out.append(cur); open[key] = nil; openLen[key] = nil }
            openLen[key, default: 0] += t.dur + 0.3 + (open[key] == nil ? 0 : gap)
            open[key, default: []].append(i)
        }
        out += open.values
        return out.sorted { $0[0] < $1[0] }
    }

    /// Gives each turn in a window its own words, by word mid-time. Falls back to the whole text for a 1-turn window.
    public static func split(_ p: TranscriptPiece, offsets: [Double], total: Double) -> [String] {
        if offsets.count == 1 { return [p.text] }
        var parts = [String](repeating: "", count: offsets.count)
        for w in p.words {
            let token = w.word
            if token.hasPrefix("[") || token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let mid = (w.start + w.end) / 2
            let k = (offsets.lastIndex { $0 <= mid + 0.05 }) ?? 0
            parts[k] += token
        }
        return parts.map { Transcriber.cleanText($0) }
    }

    /// Per-speaker language lock: language detection costs a second encoder pass (~1.7 s per call on M2),
    /// so once a speaker's first 3 turns agree, later turns name the language. A low-confidence result is
    /// retried with auto-detect, and a disagreeing speaker goes back to auto (code-switch safety).
    public struct SpeakerLanguages {
        var seen: [String: [String]] = [:]
        var locked: [String: String] = [:]
        public init() {}
        public func language(for spk: String, configured: String) -> String {
            configured != "auto" ? configured : (locked[spk] ?? "auto")
        }
        public mutating func record(_ spk: String, _ lang: String?) {
            guard let lang else { return }
            if let l = locked[spk], l != lang { locked[spk] = nil; seen[spk] = []; return }
            seen[spk, default: []].append(lang)
            let s = seen[spk]!
            if locked[spk] == nil, s.count >= 3, Set(s.suffix(3)).count == 1 { locked[spk] = lang }
        }
    }

    static func transcribeTurn(_ f: URL, speaker: String, langState: inout SpeakerLanguages, config: Config) throws -> TranscriptPiece {
        let lang = langState.language(for: speaker, configured: config.language)
        var piece = try Transcriber.transcribe(f, language: lang, config: config)
        if lang != "auto" && config.language == "auto" && piece.avgLogprob < -0.7 {
            let retry = try Transcriber.transcribe(f, language: "auto", config: config)
            if retry.language != lang { piece = retry }
        }
        if config.language == "auto" { langState.record(speaker, piece.language) }
        return piece
    }

    /// speaker_00 → spk1 in order of first appearance.
    public static func relabel(_ turns: [DiarTurn]) -> [DiarTurn] {
        var map: [String: String] = [:]
        return turns.sorted { $0.start < $1.start }.map { t in
            if map[t.label] == nil { map[t.label] = "spk\(map.count + 1)" }
            return DiarTurn(start: t.start, end: t.end, label: map[t.label]!)
        }
    }

    /// Drops "me" segments that are just the call audio leaking from speakers into the mic:
    /// they overlap a non-me segment in time and share most of its words.
    public static func dropEchoes(_ segs: [Segment]) -> [Segment] {
        let others = segs.filter { $0.speaker != "me" }
        return segs.filter { s in
            guard s.speaker == "me" else { return true }
            let w = words(s.text)
            guard !w.isEmpty else { return false }
            for o in others where o.start < s.end && s.start < o.end {
                let ow = words(o.text)
                let overlap = Double(w.intersection(ow).count) / Double(min(w.count, max(ow.count, 1)))
                if overlap > 0.5 { return false }
            }
            return true
        }
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    static func hasSignal(_ url: URL) -> Bool {
        guard let s = try? WAV.read(url).samples, !s.isEmpty else { return false }
        var peak: Float = 0
        for x in s where abs(x) > peak { peak = abs(x) }
        return peak > 0.01
    }

    /// Creates a meeting from any audio file (copy + convert to 16 kHz mono).
    public static func importFile(_ src: URL, title: String? = nil) throws -> Meeting {
        let t = title ?? src.deletingPathExtension().lastPathComponent
        let id = Store.newID(title: t)
        let dir = Store.folder(id)
        try Store.makePrivateDir(dir)
        let dst = dir.appendingPathComponent("audio.wav")
        try WAV.convert(src, to: dst)
        let m = Meeting(id: id, title: t, duration: WAV.duration(dst), source: "import", audioFiles: ["audio.wav"])
        _ = try Store.create(m)
        return m
    }
}
