import Foundation

/// Everything Hush can do with no AI provider: keyword retrieval over the user's notes file and over the
/// live transcript, plus extractive catch-ups. Instant, local, works on every Mac.
public enum Retrieval {
    static let stop: Set<String> = [
        // English
        "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "what", "how", "why", "when", "who",
        "which", "can", "could", "would", "will", "have", "has", "had", "does", "did", "about", "from", "into", "they", "them",
        "our", "out", "not", "but", "all", "any", "there", "their", "been", "also", "just", "like", "tell", "please", "some",
        // Indonesian
        "yang", "dan", "untuk", "dengan", "kita", "kami", "saya", "aku", "kamu", "anda", "ini", "itu", "ada", "apa", "akan",
        "bisa", "juga", "dari", "pada", "dalam", "tidak", "atau", "sudah", "belum", "lagi", "nanti", "bagaimana", "gimana",
        "kenapa", "mengapa", "kapan", "siapa", "berapa", "apakah", "tolong", "mau", "jadi", "kalau", "seperti", "sih", "dong", "nya",
    ]

    /// Small Indonesian ↔ English bridge for common meeting words, so an English question finds Indonesian notes.
    static let bridge: [String: String] = [
        "jadwal": "timeline", "anggaran": "budget", "harga": "price", "biaya": "cost", "target": "target", "pengalaman": "experience",
        "kelebihan": "strength", "kekuatan": "strength", "kelemahan": "weakness", "gaji": "salary", "tim": "team", "proyek": "project",
        "klien": "client", "pelanggan": "customer", "hasil": "result", "ukur": "measure", "mengukur": "measure", "sukses": "success",
        "keberhasilan": "success", "rencana": "plan", "strategi": "strategy", "produk": "product", "layanan": "service",
        "kenapa": "why", "alasan": "reason", "tantangan": "challenge", "masalah": "problem", "tujuan": "goal", "minggu": "week",
        "bulan": "month", "tahun": "year", "kampanye": "campaign", "proses": "process", "kerja": "work", "langkah": "step",
        "cara": "how", "rencanakan": "plan", "merencanakan": "plan", "perencanaan": "plan", "kontrak": "contract", "diskon": "discount", "garansi": "warranty", "kirim": "send",
    ]

    /// Lowercase, accent-folded word stems (first 6 letters), stop words removed, ID words bridged to EN.
    public static func terms(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) }
            .map { bridge[$0] ?? $0 }
            .map { w -> String in   // light English plural/verb endings: plans → plan, campaigns → campaign
                if w.count > 4 && w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
                if w.count > 4 && w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
                return w
            }
            .map { String($0.prefix(6)) }
    }

    /// Splits a notes file into answerable pieces: blank-line blocks; long blocks split by line.
    /// A heading or "Q:" line stays attached to the lines under it.
    public static func chunks(_ text: String) -> [String] {
        let blocks = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return blocks.flatMap { b -> [String] in
            guard b.count > 500 else { return [b] }
            let lines = b.split(separator: "\n").map(String.init)
            var out: [String] = [], head = ""
            for l in lines {
                if l.hasPrefix("#") || l.lowercased().hasPrefix("q:") { head = l; continue }
                out.append(head.isEmpty ? l : head + "\n" + l)
            }
            return out
        }
    }

    /// BM25 ranking of `docs` for `query`. Returns the best `k` with a positive score, best first.
    public static func best(_ query: String, in docs: [String], k: Int = 3) -> [String] {
        let q = Set(terms(query))
        guard !q.isEmpty, !docs.isEmpty else { return [] }
        let toks = docs.map(terms)
        let avg = Double(toks.map(\.count).reduce(0, +)) / Double(max(1, toks.count))
        var df: [String: Int] = [:]
        for t in toks { for w in Set(t) where q.contains(w) { df[w, default: 0] += 1 } }
        let n = Double(docs.count)
        let scored = toks.enumerated().map { (i, t) -> (Int, Double) in
            var tf: [String: Int] = [:]
            for w in t where q.contains(w) { tf[w, default: 0] += 1 }
            let score = tf.reduce(0.0) { acc, kv in
                let idf = log(1 + (n - Double(df[kv.key]!) + 0.5) / (Double(df[kv.key]!) + 0.5))
                let f = Double(kv.value)
                return acc + idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * Double(t.count) / max(avg, 1)))
            }
            return (i, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(k).map { docs[$0.0] }
    }

    /// Prompter without AI: the best matching pieces of the user's notes file.
    public static func notesAnswer(question: String, notes: String) -> String? {
        let hits = best(question, in: chunks(notes), k: 3)
        guard !hits.isEmpty else { return nil }
        return hits.map { "• " + $0.replacingOccurrences(of: "\n", with: " — ") }.joined(separator: "\n")
    }

    /// "What did I miss?" without AI: lines that carry numbers, decisions, tasks or questions.
    public static func catchUp(_ lines: [(who: String, text: String)], max: Int = 4) -> [String] {
        let cues = Rules.decisionCues + Rules.commitCues + ["?", "deadline", "budget", "harga", "target", "paling lambat"]
        let picked = lines.filter { l in
            let t = l.text.lowercased()
            return t.rangeOfCharacter(from: .decimalDigits) != nil || cues.contains { t.contains($0) }
        }
        return picked.suffix(max).map { "\($0.who): \($0.text)" }
    }
}

/// Masks secrets before text leaves the Mac for an AI provider (idea from Goldfish's privacy page).
/// Pattern-based, so it cannot catch everything; names and emails stay (they matter for notes).
public enum Redact {
    static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)\b(password|passwd|pwd|kata ?sandi|sandi|pin|otp|kode verifikasi)(?:\s*(?:nya|is|adalah|itu|yaitu|:|=|-))*\s*\S+"#, "$1 [hidden]"),
        (#"\b(sk-[A-Za-z0-9_\-]{16,}|sk-ant-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,})\b"#, "[key hidden]"),
        (#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#, "[IBAN hidden]"),
        (#"\b\d{16}\b"#, "[16-digit number hidden]"),                       // NIK / card without spaces
        (#"\b(?:\d{4}[ -]){3}\d{1,7}\b"#, "[card number hidden]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func mask(_ s: String) -> String {
        var out = s
        for (re, tpl) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tpl)
        }
        return out
    }
}

/// Wraps any provider so the user text is masked first.
public struct RedactingProvider: AIProvider {
    public let inner: AIProvider
    public var name: String { inner.name }
    public func complete(system: String, user: String, fast: Bool) throws -> String {
        try inner.complete(system: system, user: Redact.mask(user), fast: fast)
    }
    public func stream(system: String, user: String, fast: Bool, onText: @escaping (String) -> Void) throws -> String {
        try inner.stream(system: system, user: Redact.mask(user), fast: fast, onText: onText)
    }
}

/// Which AI is available on this Mac, for first-run setup.
public enum AIDetect {
    public struct Found { public var kind: ProviderKind; public var model: String; public var detail: String }

    public static func run() -> Found {
        if let c = Shell.which("claude") { return Found(kind: .claudeCLI, model: "", detail: "Claude Code found at \(c)") }
        if let c = Shell.which("codex") { return Found(kind: .codexCLI, model: "", detail: "Codex found at \(c)") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!); req.timeoutInterval = 1.5
        if let (data, status) = try? HTTP.send(req), status == 200,
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let first = (j["models"] as? [[String: Any]])?.first?["name"] as? String {
            return Found(kind: .openAICompatible, model: first, detail: "Ollama running with \(first)")
        }
        return Found(kind: .none, model: "", detail: "No AI found on this Mac")
    }
}
