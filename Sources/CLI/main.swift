import Foundation

// `hush` command-line tool: process audio, read meetings, run the MCP server. No audio capture here
// (capture lives in Hush.app), so MCP clients never get attributed microphone or system-audio access.

let usage = """
hush \(MCPServer.version): local meeting notes

USAGE
  hush process <audio-file> [--title T] [--no-summary]   import + transcribe + summarize a recording
  hush reprocess <meeting-id>                             run the pipeline again on a stored meeting
  hush summarize <meeting-id|latest>                      (re)write the summary with the configured AI
  hush list                                               list meetings
  hush show <meeting-id|latest> [--transcript|--summary|--json]
  hush search <words>
  hush ask "<question>" [--meeting <id>]                  draft a prompter answer from a meeting's context
  hush mcp                                                run the MCP server on stdio (for Claude Code etc.)
  hush doctor                                             check engines, models and AI provider
  hush config [get | set <key> <value>]                   e.g. hush config set provider claude-cli
  hush key <openai|anthropic> <value>                     store an API key in the macOS Keychain ("" deletes)
  hush setup                                              download engines + models (pinned SHA-256)

DATA  \(Paths.base.path)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }
func option(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("hush: \(msg)\n".utf8)); exit(1) }
func resolve(_ id: String) -> Meeting {
    if id == "latest" { guard let m = Store.all().first else { fail("no meetings yet") }; return m }
    do { return try Store.load(id) } catch { fail("no meeting \(id)") }
}
func progress(_ s: String, _ f: Double) { FileHandle.standardError.write(Data("  [\(Int(f * 100))%] \(s)\n".utf8)) }

func summarize(_ m: inout Meeting) {
    let p = AI.provider()
    FileHandle.standardError.write(Data("  summarizing with \(p?.name ?? "local rules")…\n".utf8))
    do {
        let (s, title) = try Summarizer.summarize(m, provider: p)
        m.summary = s
        if let title, m.source == "import" || m.title.hasPrefix("Meeting ") { m.title = title }
        try Store.save(m)
    } catch { fail("\(error)") }
}

guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

switch cmd {
case "process":
    let title = option("--title"); let noSummary = flag("--no-summary")
    guard let path = args.first else { fail("process needs an audio file") }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("file not found: \(path)") }
    let t0 = Date()
    do {
        let m0 = try Pipeline.importFile(url, title: title)
        FileHandle.standardError.write(Data("  meeting \(m0.id)\n".utf8))
        var m = try Pipeline.process(m0.id, progress: progress)
        if !noSummary { summarize(&m) }
        WhisperServer.shared.stop()
        print(Store.folder(m.id).path)
        FileHandle.standardError.write(Data(String(format: "  done in %.1f s: %d segments, %d speakers\n", Date().timeIntervalSince(t0), m.segments.count, m.speakers.count).utf8))
    } catch { WhisperServer.shared.stop(); fail("\(error)") }

case "reprocess":
    guard let id = args.first else { fail("reprocess needs a meeting id") }
    do { var m = try Pipeline.process(resolve(id).id, progress: progress); summarize(&m); WhisperServer.shared.stop(); print(Store.folder(m.id).path) }
    catch { WhisperServer.shared.stop(); fail("\(error)") }

case "summarize":
    var m = resolve(args.first ?? "latest")
    summarize(&m)
    print(Markdown.summary(m))

case "list":
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    for m in Store.all() {
        print("\(m.id)\t\(f.string(from: m.createdAt))\t\(formatTime(m.duration))\t\(m.status.rawValue)\t\(m.title)")
    }

case "show":
    let m = resolve(args.first(where: { !$0.hasPrefix("--") }) ?? "latest")
    if flag("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(m), as: UTF8.self))
    } else if flag("--transcript") { print(Markdown.transcript(m)) }
    else if flag("--summary") { print(Markdown.summary(m)) }
    else { print(Markdown.export(m)) }

case "search":
    let q = args.joined(separator: " ")
    for r in Store.search(q) { print("## \(r.meeting.title) (\(r.meeting.id))"); r.hits.prefix(10).forEach { print("  \($0)") } }

case "ask":
    let mid = option("--meeting")
    guard let q = args.first else { fail("ask needs a question") }
    let c = Config.load()
    guard let p = AI.provider(c, forPrompter: true) else { fail("no AI provider set (hush config set provider claude-cli)") }
    let recent = mid.map { Summarizer.transcriptText(resolve($0)) } ?? ""
    let ctx = c.contextFile.isEmpty ? "" : ((try? String(contentsOfFile: (c.contextFile as NSString).expandingTildeInPath, encoding: .utf8)) ?? "")
    let t0 = Date()
    do {
        let a = try p.complete(system: Answerer.system(userName: c.userName), user: Answerer.prompt(question: q, recent: recent, context: ctx), fast: true)
        print(a)
        FileHandle.standardError.write(Data(String(format: "  (%@, %.1f s)\n", p.name, Date().timeIntervalSince(t0)).utf8))
    } catch { fail("\(error)") }

case "mcp":
    MCPServer().serve()

case "doctor":
    let c = Config.load()
    var ok = true
    for (name, good, detail) in Engines.check(c) { print("\(good ? "ok  " : "MISS") \(name)  \(detail)"); ok = ok && good }
    print("AI   provider: \(c.provider.label)\(c.model.isEmpty ? "" : " (\(c.model))")")
    switch c.provider {
    case .claudeCLI:
        print("     claude: \(Shell.which("claude", override: c.claudePath) ?? "NOT FOUND")")
        print("     CLAUDE_CONFIG_DIR: \(c.claudeConfigDir.isEmpty ? (Shell.loginShellVar("CLAUDE_CONFIG_DIR") ?? "(default ~/.claude)") + " (from shell)" : c.claudeConfigDir)")
    case .codexCLI: print("     codex: \(Shell.which("codex", override: c.codexPath) ?? "NOT FOUND")")
    case .anthropic: print("     key in Keychain: \(Keychain.get("anthropic") != nil)")
    case .openAICompatible: print("     base URL: \(c.openAIBaseURL)  key set: \(Keychain.get("openai") != nil)")
    case .none: break
    }
    print("DATA \(Paths.base.path)\nMEET \(Paths.meetings.path)")
    exit(ok ? 0 : 2)

case "config":
    var c = Config.load()
    if args.first == "set", args.count >= 3 {
        let k = args[1], v = args[2]
        switch k {
        case "provider": guard let p = ProviderKind(rawValue: v) else { fail("provider: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))") }; c.provider = p
        case "prompterProvider": if v.isEmpty || v == "same" { c.prompterProvider = nil } else { guard let p = ProviderKind(rawValue: v) else { fail("bad provider") }; c.prompterProvider = p }
        case "model": c.model = v
        case "prompterModel": c.prompterModel = v
        case "openAIBaseURL": c.openAIBaseURL = v
        case "claudePath": c.claudePath = v
        case "codexPath": c.codexPath = v
        case "claudeConfigDir": c.claudeConfigDir = v
        case "codexHome": c.codexHome = v
        case "asrModel": c.asrModel = v
        case "language": c.language = v
        case "storageDir": c.storageDir = v.isEmpty ? nil : v
        case "contextFile": c.contextFile = v
        case "userName": c.userName = v
        case "prompterOpacity": c.prompterOpacity = Double(v) ?? c.prompterOpacity
        default: fail("unknown key \(k)")
        }
        do { try c.save() } catch { fail("\(error)") }
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! enc.encode(c), as: UTF8.self))

case "key":
    guard args.count >= 2, ["openai", "anthropic"].contains(args[0]) else { fail("usage: hush key <openai|anthropic> <value>") }
    Keychain.set(args[0], args[1])
    print(args[1].isEmpty ? "deleted \(args[0]) key" : "stored \(args[0]) key in Keychain (service app.airo.hush)")

case "setup":
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidates = [exe.deletingLastPathComponent().appendingPathComponent("../Resources/fetch-engines.sh").standardized.path,
                      exe.deletingLastPathComponent().appendingPathComponent("../../scripts/fetch-engines.sh").standardized.path]
    guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { fail("fetch-engines.sh not found") }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script]
    try? p.run(); p.waitUntilExit(); exit(p.terminationStatus)

case "help", "-h", "--help": print(usage)
case "version", "--version": print(MCPServer.version)
default: fail("unknown command \(cmd)\n\n\(usage)")
}
