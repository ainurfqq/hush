import Foundation

/// Names and special words passed to whisper as its starting prompt, so it spells them the way the user does
/// (Granola does the same with Deepgram "keyterms"). Sources: Settings → Vocabulary, and capitalised names in the
/// prompter notes file. Kept short: whisper reads at most ~224 prompt tokens, and a long prompt can leak into the text.
public enum Keyterms {
    static let maxChars = 400
    public static let lead = "Nama dan istilah:"

    public static func prompt(_ c: Config) -> String {
        var notes = ""
        if !c.contextFile.isEmpty {
            notes = (try? String(contentsOfFile: (c.contextFile as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
        }
        return build(vocabulary: c.vocabulary, notes: String(notes.prefix(6000)))
    }

    public static func build(vocabulary: String, notes: String) -> String {
        var out: [String] = [], seen = Set<String>(), length = 0
        func add(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 2, t.count <= 40, seen.insert(t.lowercased()).inserted, length + t.count + 2 <= maxChars else { return }
            out.append(t); length += t.count + 2
        }
        vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).forEach { add(String($0)) }
        names(in: notes).forEach(add)
        return out.isEmpty ? "" : lead + " " + out.joined(separator: ", ") + "."
    }

    /// Capitalised words and runs of them ("Meta Business Suite"), acronyms and words with digits.
    /// A capital that only starts a sentence ("Kita", "The") is skipped when it is a common word.
    static func names(in text: String) -> [String] {
        var found: [String] = [], run: [String] = []
        func flush() { if !run.isEmpty { found.append(run.joined(separator: " ")); run = [] } }
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let looksLikeName = word.first?.isUppercase == true || (word.contains { $0.isNumber } && word.contains { $0.isLetter })
            if looksLikeName && !common.contains(word.lowercased()) && word.count >= 2 { run.append(word) } else { flush() }
            if token.last.map({ ",.;:!?)".contains($0) }) == true { flush() }
        }
        flush()
        return found
    }

    static let common: Set<String> = [
        "the", "a", "an", "i", "we", "you", "he", "she", "they", "it", "my", "our", "your", "this", "that", "these", "those",
        "and", "but", "or", "so", "if", "in", "on", "at", "for", "to", "of", "with", "from", "by", "as", "is", "are", "was",
        "what", "why", "how", "when", "where", "who", "which", "yes", "no", "not", "do", "did", "can", "will", "would",
        "q", "a:", "q:", "note", "notes", "example", "tip", "key", "results", "result", "questions", "question", "answer",
        "saya", "aku", "kami", "kita", "kamu", "anda", "dia", "mereka", "ini", "itu", "dan", "atau", "tapi", "jadi", "kalau",
        "untuk", "dari", "dengan", "di", "ke", "yang", "ada", "tidak", "bisa", "akan", "sudah", "belum", "apa", "kenapa",
        "bagaimana", "siapa", "kapan", "dimana", "pertama", "kedua", "ketiga", "contoh", "catatan", "pertanyaan", "jawaban",
        "senin", "selasa", "rabu", "kamis", "jumat", "sabtu", "minggu", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday",
    ]
}
