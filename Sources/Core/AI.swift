import Foundation
import Security

/// Anything that turns a prompt into text. Implementations never log prompts or keys.
public protocol AIProvider {
    var name: String { get }
    func complete(system: String, user: String, fast: Bool) throws -> String
    /// Like `complete`, but calls `onText` with the answer so far while it is written. Default: one call at the end.
    func stream(system: String, user: String, fast: Bool, onText: @escaping (String) -> Void) throws -> String
}

extension AIProvider {
    public func stream(system: String, user: String, fast: Bool, onText: @escaping (String) -> Void) throws -> String {
        let t = try complete(system: system, user: user, fast: fast); onText(t); return t
    }
}

public enum AI {
    /// Builds the provider the user picked. Returns nil for `.none`.
    public static func provider(_ c: Config = .load(), forPrompter: Bool = false) -> AIProvider? {
        guard let p = baseProvider(c, forPrompter: forPrompter) else { return nil }
        return c.maskSecrets ? RedactingProvider(inner: p) : p
    }

    static func baseProvider(_ c: Config, forPrompter: Bool) -> AIProvider? {
        let kind = forPrompter ? (c.prompterProvider ?? c.provider) : c.provider
        // When the prompter uses its own provider, `prompterModel` is that provider's model.
        let split = forPrompter && c.prompterProvider != nil && c.prompterProvider != c.provider
        var c = c
        if split { c.model = c.prompterModel; c.prompterModel = "" }
        switch kind {
        case .none: return nil
        case .claudeCLI:
            var p = ClaudeCLIProvider(path: c.claudePath, model: c.model, fastModel: c.prompterModel)
            p.configDir = c.claudeConfigDir.isEmpty ? (Shell.loginShellVar("CLAUDE_CONFIG_DIR") ?? "") : (c.claudeConfigDir as NSString).expandingTildeInPath
            return p
        case .codexCLI:
            var p = CodexCLIProvider(path: c.codexPath, model: c.model)
            p.home = c.codexHome.isEmpty ? (Shell.loginShellVar("CODEX_HOME") ?? "") : (c.codexHome as NSString).expandingTildeInPath
            return p
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: c.openAIBaseURL, model: c.model.isEmpty ? "llama3.2" : c.model,
                                            fastModel: c.prompterModel, apiKey: Keychain.get("openai"))
        case .gemini:
            var p = OpenAICompatibleProvider(baseURL: Gemini.baseURL, model: c.model.isEmpty ? Gemini.defaultModel : c.model,
                                             fastModel: c.prompterModel.isEmpty ? Gemini.fastModel : c.prompterModel, apiKey: Keychain.get("gemini"))
            p.fallbackModels = [Gemini.fastModel]
            return p
        case .anthropic:
            return AnthropicProvider(apiKey: Keychain.get("anthropic") ?? "", model: c.model, fastModel: c.prompterModel)
        }
    }
}

// MARK: - Claude Code CLI

public struct ClaudeCLIProvider: AIProvider {
    public var path: String, model: String, fastModel: String
    /// CLAUDE_CONFIG_DIR for the child process; empty = Claude's default (~/.claude).
    public var configDir: String = ""
    public var name: String { "claude-cli" }
    public init(path: String = "", model: String = "", fastModel: String = "") { self.path = path; self.model = model; self.fastModel = fastModel }

    /// Arguments for a one-shot, tool-less, non-persistent call. Prompt goes on stdin.
    public func arguments(system: String, fast: Bool) -> [String] {
        // Meeting text is untrusted (anyone in the call can say anything): no tools, no MCP servers, no session.
        var a = ["-p", "--output-format", "text", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--system-prompt", system]
        let m = fast && !fastModel.isEmpty ? fastModel : (fast && model.isEmpty ? "haiku" : model)
        if !m.isEmpty { a += ["--model", m] }
        return a
    }

    public func complete(system: String, user: String, fast: Bool) throws -> String {
        guard let exe = Shell.which("claude", override: path) else { throw HushError.missing("claude CLI (install Claude Code, or set its path in Settings)") }
        // Run from a neutral folder so project CLAUDE.md files are not pulled into the prompt.
        let r = try Shell.run(exe, arguments(system: system, fast: fast), stdin: user, timeout: fast ? 60 : 300,
                              env: configDir.isEmpty ? nil : ["CLAUDE_CONFIG_DIR": configDir],
                              cwd: FileManager.default.temporaryDirectory.path)
        guard r.status == 0 else {
            // claude prints some failures (e.g. an expired login) on stdout, not stderr.
            let msg = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "no message"
            throw HushError.provider("claude exit \(r.status): \(msg.suffix(300))")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the answer (stream-json with partial messages) so the prompter can show the first words early.
    public func stream(system: String, user: String, fast: Bool, onText: @escaping (String) -> Void) throws -> String {
        guard let exe = Shell.which("claude", override: path) else { throw HushError.missing("claude CLI (install Claude Code, or set its path in Settings)") }
        var args = arguments(system: system, fast: fast)
        if let i = args.firstIndex(of: "--output-format"), i + 1 < args.count { args[i + 1] = "stream-json" }
        args += ["--verbose", "--include-partial-messages"]
        var soFar = "", final: String?, failure: String?
        let r = try Shell.run(exe, args, stdin: user, timeout: fast ? 60 : 300,
                              env: configDir.isEmpty ? nil : ["CLAUDE_CONFIG_DIR": configDir],
                              cwd: FileManager.default.temporaryDirectory.path) { line in
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            if j["type"] as? String == "stream_event", let ev = j["event"] as? [String: Any],
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                soFar += t; onText(soFar)
            } else if j["type"] as? String == "result" {
                if j["is_error"] as? Bool == true { failure = (j["result"] as? String) ?? "unknown error" } else { final = j["result"] as? String }
            }
        }
        if r.status != 0 || failure != nil {
            let msg = [failure ?? "", r.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "no message"
            throw HushError.provider("claude exit \(r.status): \(msg.suffix(300))")
        }
        return (final ?? soFar).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Codex CLI

public struct CodexCLIProvider: AIProvider {
    public var path: String, model: String
    /// CODEX_HOME for the child process (where `codex login` keeps its login); empty = ~/.codex.
    public var home: String = ""
    public var name: String { "codex-cli" }
    public init(path: String = "", model: String = "") { self.path = path; self.model = model }

    /// Model every ChatGPT plan can use in the Codex CLI, Free included (tested 2026-11-16 with a Free account).
    public static let chatGPTFallbackModel = "gpt-6-luna"

    public func arguments(model override: String? = nil) -> [String] {
        var a = ["exec", "--skip-git-repo-check", "--sandbox", "read-only"]
        let m = override ?? model
        if !m.isEmpty { a += ["--model", m] }
        a.append("-")   // read prompt from stdin
        return a
    }

    public func complete(system: String, user: String, fast: Bool) throws -> String {
        guard let exe = Shell.which("codex", override: path) else { throw HushError.missing("codex CLI (npm i -g @openai/codex, or set its path in Settings)") }
        func run(_ m: String?) throws -> ShellResult {
            try Shell.run(exe, arguments(model: m), stdin: "\(system)\n\n\(user)", timeout: fast ? 90 : 300,
                          env: home.isEmpty ? nil : ["CODEX_HOME": home], cwd: FileManager.default.temporaryDirectory.path)
        }
        var r = try run(nil)
        // A ChatGPT login (e.g. the Free plan) rejects some models; retry once with the model every plan has.
        if r.status != 0, (r.stderr + r.stdout).contains("not supported when using Codex with a ChatGPT account"),
           model != Self.chatGPTFallbackModel {
            Log.write("codex: model not allowed for this ChatGPT plan, retrying with \(Self.chatGPTFallbackModel)")
            r = try run(Self.chatGPTFallbackModel)
        }
        guard r.status == 0 else {
            let msg = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "no message"
            throw HushError.provider("codex exit \(r.status): \(msg.suffix(300)). If it says you are not logged in, run: codex login")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Google's Gemini API through its OpenAI-compatible endpoint (https://ai.google.dev/gemini-api/docs/openai).
public enum Gemini {
    public static let baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    public static let defaultModel = "gemini-flash-latest"
    /// Used for live answers (about 1 s to the first word in a 2026-11-22 test) and when the main model is busy.
    public static let fastModel = "gemini-flash-lite-latest"
    public static let keyPage = "https://aistudio.google.com/apikey"
}

// MARK: - OpenAI-compatible (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Gemini…)

public struct OpenAICompatibleProvider: AIProvider {
    public var baseURL: String, model: String, fastModel: String, apiKey: String?
    /// Tried in order when the server is busy (HTTP 429/5xx) or slow. Each try then gets a shorter timeout.
    public var fallbackModels: [String] = []
    public var name: String { "openai-compatible:\(model)" }
    public init(baseURL: String, model: String, fastModel: String = "", apiKey: String? = nil) {
        self.baseURL = baseURL; self.model = model; self.fastModel = fastModel; self.apiKey = apiKey
    }

    func models(fast: Bool) -> [String] {
        let first = fast && !fastModel.isEmpty ? fastModel : model
        return [first] + fallbackModels.filter { $0 != first }
    }

    static func busy(_ status: Int) -> Bool { status == 429 || status >= 500 }

    /// "HTTP 503: This model is currently experiencing high demand…" instead of the raw JSON.
    static func errorText(_ status: Int, _ body: Data) -> String {
        let j = try? JSONSerialization.jsonObject(with: body)
        let obj = (j as? [[String: Any]])?.first ?? (j as? [String: Any])
        let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: body.prefix(300), as: UTF8.self)
        return "HTTP \(status): \(msg)"
    }

    public func request(system: String, user: String, fast: Bool, stream: Bool = false, model chosen: String? = nil) throws -> URLRequest {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw HushError.provider("bad base URL \(baseURL)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = fallbackModels.isEmpty ? (fast ? 60 : 300) : (fast ? 15 : 120)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": chosen ?? models(fast: fast)[0],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": stream,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func complete(system: String, user: String, fast: Bool) throws -> String {
        try withFallback(fast: fast) { m in
            let (data, status) = try HTTP.send(try request(system: system, user: user, fast: fast, model: m))
            guard status == 200 else { throw Attempt(error: HushError.provider(Self.errorText(status, data)), retryable: Self.busy(status)) }
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = j["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String else { throw HushError.provider("unexpected response shape") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Server-sent events ("data: {…}" lines with choices[0].delta.content), so the prompter shows the first words early.
    public func stream(system: String, user: String, fast: Bool, onText: @escaping (String) -> Void) throws -> String {
        try withFallback(fast: fast) { m in
            var soFar = ""
            let (body, status) = try HTTP.streamLines(try request(system: system, user: user, fast: fast, stream: true, model: m)) { line in
                guard line.hasPrefix("data:") else { return }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let j = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let delta = (j["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                      let t = delta["content"] as? String, !t.isEmpty else { return }
                soFar += t; onText(soFar)
            }
            guard status == 200 else { throw Attempt(error: HushError.provider(Self.errorText(status, body)), retryable: Self.busy(status)) }
            guard !soFar.isEmpty else { throw Attempt(error: HushError.provider("empty streamed reply"), retryable: true) }
            return soFar.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A failed try; `retryable` means the next fallback model may work (busy server, timeout, empty reply).
    struct Attempt: Error { let error: Error; let retryable: Bool }

    func withFallback(fast: Bool, _ run: (String) throws -> String) throws -> String {
        let list = models(fast: fast)
        for (i, m) in list.enumerated() {
            let last = i == list.count - 1
            do { return try run(m) }
            catch let a as Attempt { if !a.retryable || last { throw a.error } }
            catch let e as URLError { if last { throw e } }
            Log.write("AI: \(m) busy or slow, trying \(list[i + 1])")
        }
        throw HushError.provider("no model")
    }
}

// MARK: - Anthropic Messages API (raw HTTP; Swift has no official SDK)

public struct AnthropicProvider: AIProvider {
    public var apiKey: String, model: String, fastModel: String
    public var endpoint = "https://api.anthropic.com/v1/messages"
    public var name: String { "anthropic:\(resolvedModel(fast: false))" }
    public init(apiKey: String, model: String = "", fastModel: String = "") { self.apiKey = apiKey; self.model = model; self.fastModel = fastModel }

    public func resolvedModel(fast: Bool) -> String {
        if fast && !fastModel.isEmpty { return fastModel }
        return model.isEmpty ? "claude-opus-5-5" : model
    }

    public func request(system: String, user: String, fast: Bool) throws -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"; req.timeoutInterval = fast ? 60 : 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let model = resolvedModel(fast: fast)
        // Server-side refusal fallback exists only for these families (Haiku has none).
        let fallbackOK = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5-5"].contains { model.hasPrefix($0) }
        if fallbackOK { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": fast ? 1024 : 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            // Short answers want speed; summaries are a single extraction pass.
            "output_config": ["effort": fast ? "low" : "medium"],
        ]
        if fallbackOK { body["fallbacks"] = "default" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public static func parse(_ data: Data) throws -> String {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HushError.provider("bad JSON") }
        if let err = j["error"] as? [String: Any] { throw HushError.provider("\(err["type"] ?? ""): \(err["message"] ?? "")") }
        if (j["stop_reason"] as? String) == "refusal" { throw HushError.provider("the model declined this request") }
        let blocks = (j["content"] as? [[String: Any]]) ?? []
        return blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func complete(system: String, user: String, fast: Bool) throws -> String {
        guard !apiKey.isEmpty else { throw HushError.missing("Anthropic API key (Settings → AI)") }
        let (data, status) = try HTTP.send(try request(system: system, user: user, fast: fast))
        guard status == 200 else { throw HushError.provider("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))") }
        return try Self.parse(data)
    }
}

// MARK: - Keychain

public enum Keychain {
    static let service = "app.airo.hush"

    public static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ account: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["HUSH_\(account.uppercased())_KEY"], !env.isEmpty { return env }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
