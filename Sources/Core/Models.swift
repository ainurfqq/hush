import Foundation

/// One spoken turn in a meeting.
public struct Segment: Codable, Equatable {
    public var start: Double
    public var end: Double
    /// Raw speaker id: "me", "spk1", "spk2", …
    public var speaker: String
    public var text: String
    public var language: String?

    public init(start: Double, end: Double, speaker: String, text: String, language: String? = nil) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text; self.language = language
    }
    public var duration: Double { end - start }
}

public struct ActionItem: Codable, Equatable, Hashable {
    public var owner: String?
    public var task: String
    public var due: String?
    public var done: Bool

    public init(owner: String? = nil, task: String, due: String? = nil, done: Bool = false) {
        self.owner = owner; self.task = task; self.due = due; self.done = done
    }

    enum CodingKeys: String, CodingKey { case owner, task, due, done }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        task = try c.decode(String.self, forKey: .task)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

public struct MeetingSummary: Codable, Equatable {
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    /// Which provider produced it, e.g. "claude-cli", "rules".
    public var provider: String
    public var createdAt: Date

    public init(summary: String, decisions: [String], actionItems: [ActionItem], openQuestions: [String], provider: String, createdAt: Date = Date()) {
        self.summary = summary; self.decisions = decisions; self.actionItems = actionItems
        self.openQuestions = openQuestions; self.provider = provider; self.createdAt = createdAt
    }
}

public enum MeetingStatus: String, Codable { case recording, recorded, processing, ready, failed }

public struct Meeting: Codable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var duration: Double
    /// "live" (mic + system), "mic" (in-room), "import" (file)
    public var source: String
    public var audioFiles: [String]
    /// Display names for raw speaker ids, e.g. ["spk1": "Daniel"].
    public var speakerNames: [String: String]
    public var segments: [Segment]
    public var summary: MeetingSummary?
    public var status: MeetingStatus
    public var error: String?

    public init(id: String, title: String, createdAt: Date = Date(), duration: Double = 0, source: String,
                audioFiles: [String], speakerNames: [String: String] = [:], segments: [Segment] = [],
                summary: MeetingSummary? = nil, status: MeetingStatus = .recorded, error: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.duration = duration; self.source = source
        self.audioFiles = audioFiles; self.speakerNames = speakerNames; self.segments = segments
        self.summary = summary; self.status = status; self.error = error
    }

    public func displayName(_ speaker: String) -> String {
        if let n = speakerNames[speaker], !n.isEmpty { return n }
        if speaker == "me" { return "Me" }
        if speaker.hasPrefix("spk"), let n = Int(speaker.dropFirst(3)) { return "Speaker \(n)" }
        return speaker
    }

    public var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }
}

public enum HushError: Error, CustomStringConvertible {
    case missing(String)
    case engine(String)
    case provider(String)
    case badAudio(String)

    public var description: String {
        switch self {
        case .missing(let s): return "Missing: \(s)"
        case .engine(let s): return "Engine error: \(s)"
        case .provider(let s): return "AI provider error: \(s)"
        case .badAudio(let s): return "Audio error: \(s)"
        }
    }
}

public func formatTime(_ t: Double) -> String {
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
