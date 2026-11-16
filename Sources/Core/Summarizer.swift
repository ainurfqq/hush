import Foundation

public enum Summarizer {
    public static let system = """
    You turn meeting transcripts into notes. The transcript may mix Indonesian and English. \
    Write the summary in the main language of the meeting. Use only facts said in the transcript; never invent \
    owners, dates or numbers. If a due date is relative ("hari Jumat", "by Wednesday"), keep the words as said. \
    Reply with ONLY one JSON object, no markdown fences, with exactly these keys:
    {"title": "short meeting title", "summary": "3-6 sentences", "decisions": ["..."], \
    "action_items": [{"owner": "name or null", "task": "...", "due": "as said, or null"}], "open_questions": ["..."]}
    """

    public static func transcriptText(_ m: Meeting, limit: Int = 120_000) -> String {
        var s = m.segments.map { "[\(formatTime($0.start))] \(m.displayName($0.speaker)): \($0.text)" }.joined(separator: "\n")
        if s.count > limit { s = String(s.prefix(limit)) + "\n[transcript truncated]" }
        return s
    }

    /// AI summary when a provider is set, otherwise (or on failure, if `fallback`) local rules.
    public static func summarize(_ m: Meeting, provider: AIProvider?, fallback: Bool = true) throws -> (MeetingSummary, String?) {
        if let p = provider {
            do {
                let prompt = "Meeting: \(m.title)\nSpeakers: \(m.speakers.map(m.displayName).joined(separator: ", "))\n\nTranscript:\n\(transcriptText(m))"
                let raw = try p.complete(system: system, user: prompt, fast: false)
                if var s = parse(raw, provider: p.name) {
                    s.actionItems = s.actionItems.filter { !$0.task.isEmpty }
                    return (s, parseTitle(raw))
                }
                throw HushError.provider("could not read JSON from the model reply")
            } catch {
                if !fallback { throw error }
                Log.write("summary via \(p.name) failed, using local rules: \(error)")
                var s = Rules.summarize(m)
                s.provider = "local rules (AI failed: \(error))"
                return (s, nil)
            }
        }
        return (Rules.summarize(m), nil)
    }

    static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw[a...b].utf8))) as? [String: Any]
    }

    public static func parse(_ raw: String, provider: String) -> MeetingSummary? {
        guard let j = jsonObject(raw) else { return nil }
        func strs(_ k: String) -> [String] { (j[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
        let items: [ActionItem] = ((j["action_items"] as? [[String: Any]]) ?? []).map {
            ActionItem(owner: nonEmpty($0["owner"] as? String), task: ($0["task"] as? String) ?? "", due: nonEmpty($0["due"] as? String))
        }
        return MeetingSummary(summary: (j["summary"] as? String) ?? "", decisions: strs("decisions"), actionItems: items,
                              openQuestions: strs("open_questions"), provider: provider)
    }

    static func parseTitle(_ raw: String) -> String? { nonEmpty(jsonObject(raw)?["title"] as? String) }
    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "null" else { return nil }
        return s
    }
}

/// Offline action-item extraction for when no AI is configured. Deliberately simple and conservative.
public enum Rules {
    static let commitCues = ["saya akan", "aku akan", "kami akan", "kita akan", "akan kirim", "akan bikin", "akan siapkan",
                             "i will", "i'll", "we will", "we'll", "will share", "will send", "will give", "akan "]
    static let dueCues = ["paling lambat", "sebelum", "by ", "hari ", "tanggal ", "minggu depan", "next week", "besok", "tomorrow",
                          "senin", "selasa", "rabu", "kamis", "jumat", "sabtu", "minggu", "monday", "tuesday", "wednesday",
                          "thursday", "friday", "saturday", "sunday", "today", "hari ini"]
    static let decisionCues = ["setuju", "kita catat sebagai keputusan", "let us agree", "let's agree", "we will go with",
                               "agreed", "keputusan", "deal", "sepakat", "that split works"]

    public static func actionItems(_ m: Meeting) -> [ActionItem] {
        var out: [ActionItem] = []
        for s in m.segments {
            for sentence in sentences(s.text) {
                let l = sentence.lowercased()
                guard commitCues.contains(where: { l.contains($0) }) else { continue }
                // A named third person ("Sari akan …", "our IT team will …") owns the task, else the speaker.
                var owner = m.displayName(s.speaker)
                let tokens = sentence.split(separator: " ").map(String.init)
                if let i = tokens.firstIndex(where: { $0.lowercased() == "akan" || $0.lowercased() == "will" }), i >= 1 {
                    let subj = tokens[max(0, i - 3)..<i].joined(separator: " ")
                    let sl = subj.lowercased()
                    let lastWord = tokens[i - 1].lowercased().trimmingCharacters(in: .punctuationCharacters)
                    if !["saya", "aku", "kami", "kita", "i", "we"].contains(lastWord),
                       let first = tokens[max(0, i - 3)..<i].last(where: { $0.first?.isUppercase == true }) {
                        owner = first.trimmingCharacters(in: .punctuationCharacters)
                        if sl.contains("team") || sl.contains("tim") { owner = subj.trimmingCharacters(in: .punctuationCharacters) }
                    }
                }
                let due = dueCues.compactMap { cue -> String? in
                    guard let r = l.range(of: cue) else { return nil }
                    let tail = sentence[r.lowerBound...]
                    return String(tail.prefix(40)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                }.first
                out.append(ActionItem(owner: owner, task: sentence.trimmingCharacters(in: .whitespaces), due: due))
            }
        }
        return out
    }

    public static func decisions(_ m: Meeting) -> [String] {
        m.segments.flatMap { s in sentences(s.text).filter { sent in decisionCues.contains { sent.lowercased().contains($0) } } }
    }

    public static func summarize(_ m: Meeting) -> MeetingSummary {
        let langs = Dictionary(grouping: m.segments.compactMap(\.language), by: { $0 }).mapValues(\.count)
        let who = m.speakers.map(m.displayName).joined(separator: ", ")
        let text = "\(formatTime(m.duration)) meeting with \(who). \(m.segments.count) turns" +
            (langs.isEmpty ? "." : ", languages: " + langs.sorted { $0.value > $1.value }.map(\.key).joined(separator: ", ") + ".") +
            " Set an AI provider in Settings for a written summary."
        return MeetingSummary(summary: text, decisions: decisions(m), actionItems: actionItems(m), openQuestions: [], provider: "local rules")
    }

    static func sentences(_ t: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in t {
            cur.append(ch)
            if ".?!".contains(ch) { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out
    }
}

/// Spots a question aimed at the user in a live line of transcript (Indonesian or English).
public enum QuestionDetector {
    static let enStarts = ["what", "how", "why", "when", "who", "which", "where", "can you", "could you", "would you",
                           "do you", "does", "did you", "is there", "are you", "have you", "tell me", "walk me through", "describe"]
    static let idCues = ["apa ", "apakah", "bagaimana", "gimana", "kenapa", "mengapa", "kapan", "siapa", "berapa",
                         "bisakah", "bisa jelaskan", "bisa ceritakan", "di mana", "dimana", "boleh tahu", "coba jelaskan", "ceritakan"]

    /// Returns the question sentence, or nil.
    public static func question(in text: String) -> String? {
        let parts = Rules.sentences(text)
        for s in parts.reversed() {
            let l = s.lowercased().trimmingCharacters(in: .whitespaces)
            if l.count < 8 { continue }
            if l.hasSuffix("?") { return s }
            if enStarts.contains(where: { l.hasPrefix($0 + " ") || l.hasPrefix($0 + ",") }) { return s }
            if idCues.contains(where: { l.hasPrefix($0) || l.contains(" " + $0) }) && !l.hasSuffix(".") { return s }
            if idCues.contains(where: { l.hasPrefix($0) }) { return s }
        }
        return nil
    }
}

/// Short answers for the prompter.
public enum Answerer {
    public static func system(userName: String) -> String {
        """
        You are a discreet meeting prompter for \(userName.isEmpty ? "the user" : userName). Someone in the meeting just asked \
        a question. Draft what the user could say next. Rules: answer in the language of the question; at most 60 words; \
        start with the direct answer; then 1-3 short bullet points the user can glance at; use facts from the context and \
        transcript only, and if the answer is not in them, give a safe, honest way to respond (for example, offer to follow up). \
        No preamble, no markdown headers.
        """
    }

    public static func prompt(question: String, recent: String, context: String) -> String {
        var p = ""
        if !context.isEmpty { p += "About the user (their notes):\n\(context.prefix(6000))\n\n" }
        p += "Recent transcript:\n\(recent.suffix(6000))\n\nQuestion to answer now:\n\(question)"
        return p
    }
}
