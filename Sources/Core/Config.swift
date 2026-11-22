import Foundation

/// Where Hush keeps things. Everything is local. `HUSH_HOME` overrides the base (used by tests).
public enum Paths {
    public static var base: URL {
        if let h = ProcessInfo.processInfo.environment["HUSH_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hush")
    }
    public static var configFile: URL { base.appendingPathComponent("config.json") }
    public static var models: URL { base.appendingPathComponent("models") }
    public static var engines: URL { base.appendingPathComponent("engines") }
    public static var logs: URL { base.appendingPathComponent("logs") }
    public static var meetings: URL {
        let c = Config.load()
        if let d = c.storageDir, !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath) }
        return base.appendingPathComponent("meetings")
    }
}

public enum ProviderKind: String, Codable, CaseIterable {
    case none, claudeCLI = "claude-cli", codexCLI = "codex-cli", openAICompatible = "openai-compatible", anthropic, gemini

    public var label: String {
        switch self {
        case .none: return "None (local rules only)"
        case .claudeCLI: return "Claude Code CLI"
        case .codexCLI: return "Codex CLI"
        case .openAICompatible: return "OpenAI-compatible (OpenAI, Ollama, LM Studio, OpenRouter)"
        case .anthropic: return "Anthropic API"
        case .gemini: return "Google Gemini API (free key from AI Studio)"
        }
    }
}

/// Non-secret settings. API keys live in the Keychain (see Keychain.swift).
public struct Config: Codable, Equatable {
    public var provider: ProviderKind = .claudeCLI
    /// Optional different provider for the live prompter (e.g. a fast local Ollama model). nil = same as `provider`.
    public var prompterProvider: ProviderKind? = nil
    /// Model name for the provider. Empty = provider default.
    public var model: String = ""
    /// Faster model used by the live prompter. Empty = same as `model`.
    public var prompterModel: String = ""
    public var openAIBaseURL: String = "http://127.0.0.1:11434/v1"
    public var claudePath: String = ""
    public var codexPath: String = ""
    /// Claude Code settings folder (CLAUDE_CONFIG_DIR). Empty = read it from the login shell, else Claude's default.
    public var claudeConfigDir: String = ""
    /// Codex state folder (CODEX_HOME, holds the `codex login`). Empty = login shell, else ~/.codex.
    public var codexHome: String = ""
    /// whisper model file name inside `models/`.
    public var asrModel: String = "ggml-large-v3-turbo-q5_0.bin"
    /// Faster model for live captions + prompter. The big model still makes the final transcript after the meeting.
    public var liveAsrModel: String = "ggml-small-q5_1.bin"
    /// "auto", "id", "en", …
    public var language: String = "auto"
    /// With "auto": the languages spoken in meetings. A guess outside this list is transcribed again in the last listed language heard.
    public var languages: [String] = ["id", "en"]
    public var storageDir: String? = nil
    public var prompterOpacity: Double = 0.85
    public var prompterAutoAnswer: Bool = true
    /// "notch" = the notch bar while recording; "panel" = the floating prompter window.
    public var prompterStyle: String = "notch"
    /// Plain-text file with the user's background (CV, product notes) for the prompter.
    public var contextFile: String = ""
    /// Names and special words for the speech engine to spell right (comma or line separated).
    public var vocabulary: String = ""
    public var userName: String = ""
    public var keepAudio: Bool = true
    public var acknowledgedAINotice: Bool = false
    public var acknowledgedConsent: Bool = false
    public var setupDone: Bool = false
    /// Mask passwords, keys, card/ID numbers before text goes to an AI provider.
    public var maskSecrets: Bool = true
    public var lastHiddenCheck: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case provider, prompterProvider, model, prompterModel, openAIBaseURL, claudePath, codexPath, claudeConfigDir, codexHome, asrModel, liveAsrModel, language, languages, storageDir,
             prompterOpacity, prompterAutoAnswer, prompterStyle, contextFile, vocabulary, userName, keepAudio, acknowledgedAINotice, acknowledgedConsent, setupDone, maskSecrets, lastHiddenCheck
    }
    /// Tolerant decoding: unknown or missing keys fall back to defaults, so old config files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        provider = (try? c.decode(ProviderKind.self, forKey: .provider)) ?? d.provider
        prompterProvider = try? c.decode(ProviderKind.self, forKey: .prompterProvider)
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        prompterModel = (try? c.decode(String.self, forKey: .prompterModel)) ?? d.prompterModel
        openAIBaseURL = (try? c.decode(String.self, forKey: .openAIBaseURL)) ?? d.openAIBaseURL
        claudePath = (try? c.decode(String.self, forKey: .claudePath)) ?? d.claudePath
        codexPath = (try? c.decode(String.self, forKey: .codexPath)) ?? d.codexPath
        claudeConfigDir = (try? c.decode(String.self, forKey: .claudeConfigDir)) ?? d.claudeConfigDir
        codexHome = (try? c.decode(String.self, forKey: .codexHome)) ?? d.codexHome
        asrModel = (try? c.decode(String.self, forKey: .asrModel)) ?? d.asrModel
        liveAsrModel = (try? c.decode(String.self, forKey: .liveAsrModel)) ?? d.liveAsrModel
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        languages = (try? c.decode([String].self, forKey: .languages)) ?? d.languages
        storageDir = try? c.decode(String.self, forKey: .storageDir)
        prompterOpacity = (try? c.decode(Double.self, forKey: .prompterOpacity)) ?? d.prompterOpacity
        prompterAutoAnswer = (try? c.decode(Bool.self, forKey: .prompterAutoAnswer)) ?? d.prompterAutoAnswer
        prompterStyle = (try? c.decode(String.self, forKey: .prompterStyle)) ?? d.prompterStyle
        contextFile = (try? c.decode(String.self, forKey: .contextFile)) ?? d.contextFile
        vocabulary = (try? c.decode(String.self, forKey: .vocabulary)) ?? d.vocabulary
        userName = (try? c.decode(String.self, forKey: .userName)) ?? d.userName
        keepAudio = (try? c.decode(Bool.self, forKey: .keepAudio)) ?? d.keepAudio
        acknowledgedAINotice = (try? c.decode(Bool.self, forKey: .acknowledgedAINotice)) ?? d.acknowledgedAINotice
        acknowledgedConsent = (try? c.decode(Bool.self, forKey: .acknowledgedConsent)) ?? d.acknowledgedConsent
        setupDone = (try? c.decode(Bool.self, forKey: .setupDone)) ?? d.setupDone
        maskSecrets = (try? c.decode(Bool.self, forKey: .maskSecrets)) ?? d.maskSecrets
        lastHiddenCheck = (try? c.decode(String.self, forKey: .lastHiddenCheck)) ?? d.lastHiddenCheck
    }

    public static let defaults = Config()

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.configFile, options: .atomic)
    }
}
