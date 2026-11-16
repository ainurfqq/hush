import Foundation
import Network

// Tiny test runner (SwiftPM/XCTest are unavailable on a Command-Line-Tools-only Mac; see run-1/spikes.md §0).
// Run: scripts/test.sh

var passed = 0, failed: [String] = []
var current = ""
func expect(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond() { failed.append("\(current): \(msg) (line \(line))") }
}
func test(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failed.count
    do { try body() } catch { failed.append("\(name): threw \(error)") }
    if failed.count == before { passed += 1; print("  ok   \(name)") } else { print("  FAIL \(name)") }
}

// Isolated data folder for the whole run.
let home = FileManager.default.temporaryDirectory.appendingPathComponent("hush-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
setenv("HUSH_HOME", home.path, 1)
// (cleaned up at the end)

func sine(_ secs: Double, freq: Float = 440, amp: Float = 0.3, rate: Double = 16000) -> [Float] {
    (0..<Int(secs * rate)).map { amp * sin(2 * .pi * freq * Float($0) / Float(rate)) }
}

func sampleMeeting() -> Meeting {
    Meeting(id: "2026-11-16-000000-demo", title: "Demo kickoff", duration: 120, source: "import", audioFiles: ["audio.wav"],
            speakerNames: ["spk2": "Daniel"], segments: [
                Segment(start: 0, end: 5, speaker: "spk1", text: "Halo Daniel, terima kasih sudah join.", language: "id"),
                Segment(start: 5, end: 9, speaker: "spk2", text: "What is your timeline for the first campaign?", language: "en"),
                Segment(start: 9, end: 15, speaker: "spk1", text: "Saya akan kirim proposal revisi paling lambat hari Jumat. Sari akan bikin tiga draft konten untuk Senin depan.", language: "id"),
                Segment(start: 15, end: 19, speaker: "spk2", text: "I will share our brand guidelines by Wednesday. Let us agree on that as the first target.", language: "en"),
            ], status: .ready)
}

print("Hush unit tests")

// MARK: audio

test("WAV write/read round trip keeps samples") {
    let url = home.appendingPathComponent("rt.wav")
    let s = sine(1)
    try WAV.write(s[...], to: url)
    let (r, rate) = try WAV.read(url)
    expect(rate == 16000, "rate \(rate)")
    expect(r.count == s.count, "count \(r.count)")
    expect(zip(r, s).map { abs($0 - $1) }.max()! < 0.001, "values drift")
    expect(abs(WAV.duration(url) - 1.0) < 0.001, "duration \(WAV.duration(url))")
}

test("WAVStreamWriter header is valid after every append (crash-safe)") {
    let url = home.appendingPathComponent("stream.wav")
    let w = try WAVStreamWriter(url: url)
    w.append(sine(0.5)); expect((try? WAV.read(url).samples.count) == 8000, "after 1st append")
    w.append(sine(0.25)); expect((try? WAV.read(url).samples.count) == 12000, "after 2nd append")
    w.close()
}

test("Downsampler 48 kHz → 16 kHz keeps duration across uneven blocks") {
    var ds = Downsampler(inRate: 48000)
    var out: [Float] = []
    let src = sine(2, rate: 48000)
    var i = 0
    for n in [480, 512, 1000, 4096, 333] where i < src.count { out += ds.process(Array(src[i..<min(src.count, i + n)])); i += n }
    out += ds.process(Array(src[i...]))
    expect(abs(out.count - 32000) <= 3, "got \(out.count) samples")
    expect(WAV.rms(out[...]) > 0.18 && WAV.rms(out[...]) < 0.25, "440 Hz tone level kept: \(WAV.rms(out[...]))")
}

test("Chunker cuts at a pause and at the max length") {
    var c = Chunker()
    var chunks = c.push(sine(4) + [Float](repeating: 0, count: 8000))
    expect(chunks.count == 1, "one chunk at the pause, got \(chunks.count)")
    expect(chunks.first?.0 == 0, "starts at 0")
    chunks = c.push(sine(11))
    expect(!chunks.isEmpty && chunks.allSatisfy { Double($0.1.count) / 16000 <= 9.01 }, "long speech cut at ≤ 9 s: \(chunks.map { $0.1.count })")
    expect(c.consumed > 4, "time advances")
}

test("WAV.convert reads other formats (AIFF from `say`) to 16 kHz mono") {
    let aiff = home.appendingPathComponent("say.aiff"), wav = home.appendingPathComponent("say.wav")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-o", aiff.path, "Halo, ini tes."]
    try p.run(); p.waitUntilExit()
    try WAV.convert(aiff, to: wav)
    let (s, rate) = try WAV.read(wav)
    expect(rate == 16000 && s.count > 8000, "converted \(s.count) samples at \(rate)")
}

// MARK: engines + pipeline helpers

test("Diarizer.parse reads sherpa-onnx output") {
    let out = "OfflineSpeakerDiarizationConfig(...)\nStarted\n0.031 -- 11.017 speaker_00\n11.765 -- 22.103 speaker_01\nDuration : 335.6 s\n"
    let t = Diarizer.parse(out)
    expect(t == [DiarTurn(start: 0.031, end: 11.017, label: "speaker_00"), DiarTurn(start: 11.765, end: 22.103, label: "speaker_01")], "\(t)")
}

test("Pipeline.relabel numbers speakers by first appearance") {
    let r = Pipeline.relabel([DiarTurn(start: 5, end: 6, label: "speaker_00"), DiarTurn(start: 0, end: 1, label: "speaker_03"), DiarTurn(start: 7, end: 8, label: "speaker_03")])
    expect(r.map(\.label) == ["spk1", "spk2", "spk1"], "\(r.map(\.label))")
}

test("Pipeline.dropEchoes removes speaker leak into the mic, keeps real 'me' speech") {
    let segs = [Segment(start: 0, end: 5, speaker: "spk1", text: "What is your timeline for the first campaign"),
                Segment(start: 0.2, end: 5, speaker: "me", text: "what is your timeline for the first campaign"),
                Segment(start: 6, end: 9, speaker: "me", text: "We can launch on the fifth of January")]
    let kept = Pipeline.dropEchoes(segs)
    expect(kept.count == 2 && kept.last?.speaker == "me", "\(kept.map(\.text))")
}

test("Per-speaker language lock engages after 3 agreeing turns, releases on change") {
    var l = Pipeline.SpeakerLanguages()
    expect(l.language(for: "spk1", configured: "auto") == "auto", "starts auto")
    l.record("spk1", "id"); l.record("spk1", "id")
    expect(l.language(for: "spk1", configured: "auto") == "auto", "not yet locked")
    l.record("spk1", "id")
    expect(l.language(for: "spk1", configured: "auto") == "id", "locked")
    l.record("spk1", "en")
    expect(l.language(for: "spk1", configured: "auto") == "auto", "released on change")
    expect(l.language(for: "spk9", configured: "en") == "en", "explicit config wins")
}

test("Pipeline.batch groups one speaker's turns into ≤ 28 s windows, in time order") {
    let turns = [("a", "spk1", 10.0), ("a", "spk2", 5.0), ("a", "spk1", 10.0), ("a", "spk2", 5.0), ("a", "spk1", 10.0), ("b", "me", 3.0)]
    let w = Pipeline.batch(turns.map { (src: $0.0, spk: $0.1, dur: $0.2) })
    expect(w == [[0, 2], [1, 3], [4], [5]], "\(w)")
}

test("Pipeline.split gives each turn its words by time") {
    let p = TranscriptPiece(text: "Halo semua. Apa kabar?", language: "id", noSpeech: 0, avgLogprob: 0, words: [
        TimedWord(start: 0.1, end: 0.4, word: " Halo"), TimedWord(start: 0.4, end: 0.9, word: " semua."),
        TimedWord(start: 5.2, end: 5.5, word: " Apa"), TimedWord(start: 5.5, end: 5.9, word: " kabar?")])
    expect(Pipeline.split(p, offsets: [0, 5.0], total: 7) == ["Halo semua.", "Apa kabar?"], "\(Pipeline.split(p, offsets: [0, 5.0], total: 7))")
    expect(Pipeline.split(p, offsets: [0], total: 7) == ["Halo semua. Apa kabar?"], "single turn keeps whole text")
}

test("Notes mode finds the right prepared answer (EN question, ID notes) without AI") {
    let notes = """
    # Timeline
    Kampanye pertama launch 5 Januari. Strategi final minggu depan.

    # Anggaran
    Budget 45 juta per bulan, 60% untuk iklan.

    Q: Kenapa pilih agensi kami?
    Kami respon dalam 24 jam lewat grup WhatsApp.
    """
    let a = Retrieval.notesAnswer(question: "What is the budget per month?", notes: notes) ?? ""
    expect(a.contains("45 juta"), a)
    let b = Retrieval.notesAnswer(question: "What is your timeline?", notes: notes) ?? ""
    expect(b.hasPrefix("• # Timeline") || b.contains("5 Januari"), b)
    expect(Retrieval.notesAnswer(question: "Do you like football?", notes: notes) == nil, "no match → nil")
    let c = Retrieval.catchUp([("Them", "Nice weather."), ("Them", "Budget kita 45 juta."), ("You", "Saya akan kirim proposal.")])
    expect(c.count == 2, "\(c)")
}

test("Redact hides secrets but keeps names and ordinary numbers") {
    let s = Redact.mask("Rina: password nya Hush2026! dan kartu 4111 1111 1111 1111, NIK 3471012345678901, key sk-ant-abcdefghijklmnopqrstu. Budget 45 juta.")
    expect(!s.contains("Hush2026") && !s.contains("4111 1111") && !s.contains("3471012345678901") && !s.contains("sk-ant-abc"), s)
    expect(s.contains("Rina") && s.contains("45 juta"), s)
}

test("Transcriber.cleanText strips silence tokens and whitespace") {
    expect(Transcriber.cleanText("  Halo\n dunia [BLANK_AUDIO] ") == "Halo dunia", Transcriber.cleanText("  Halo\n dunia [BLANK_AUDIO] "))
    expect(Transcriber.isLikelyHallucination("Terima kasih telah menonton!", duration: 2), "known outro")
    expect(!Transcriber.isLikelyHallucination("Terima kasih telah menonton!", duration: 9), "long real speech kept")
}

test("Repetition filter catches whisper noise loops, keeps normal speech") {
    expect(Transcriber.isRepetitive("I don't know what I'm talking about. I don't know what I'm talking about. I don't know what I'm talking about."), "loop")
    expect(!Transcriber.isRepetitive("What is your timeline? We want to launch in January. Is that realistic?"), "normal speech")
}

test("MultipartForm is well formed") {
    var f = MultipartForm(); f.addField("language", "auto"); f.addFile("file", filename: "a.wav", mime: "audio/wav", data: Data([1, 2, 3]))
    let body = String(decoding: f.finalBody, as: UTF8.self)
    expect(body.contains("name=\"language\"\r\n\r\nauto\r\n") && body.hasSuffix("--\r\n") && f.contentType.contains("boundary="), body)
}

// MARK: notes

test("Rules extract action items with owners and due words (ID + EN)") {
    let items = Rules.actionItems(sampleMeeting())
    expect(items.contains { $0.owner == "Speaker 1" && $0.task.contains("proposal") && ($0.due ?? "").contains("paling lambat") }, "speaker owns 'saya akan': \(items)")
    expect(items.contains { $0.owner == "Sari" && $0.task.contains("draft") }, "named third person owns 'Sari akan': \(items)")
    expect(items.contains { $0.owner == "Daniel" && ($0.due ?? "").lowercased().contains("wednesday") }, "renamed speaker + EN due: \(items)")
    expect(Rules.decisions(sampleMeeting()).count == 1, "one decision cue")
}

test("QuestionDetector finds Indonesian and English questions, ignores statements") {
    expect(QuestionDetector.question(in: "That sounds good. What is your timeline for the first campaign?") == "What is your timeline for the first campaign?", "EN ?")
    expect(QuestionDetector.question(in: "Bagaimana cara tim kamu mengukur hasil campaign") != nil, "ID without ?")
    expect(QuestionDetector.question(in: "Can you walk me through your process.") != nil, "EN imperative-question")
    expect(QuestionDetector.question(in: "Kita pakai tiga metrik utama.") == nil, "statement")
    expect(QuestionDetector.question(in: "Oke.") == nil, "too short")
}

test("Summarizer.parse accepts fenced JSON and nulls") {
    let raw = "```json\n{\"title\":\"Kickoff\",\"summary\":\"S\",\"decisions\":[\"D\"],\"action_items\":[{\"owner\":null,\"task\":\"Kirim proposal\",\"due\":\"Jumat\"},{\"owner\":\"Sari\",\"task\":\"Draft\",\"due\":\"null\"}],\"open_questions\":[]}\n```"
    let s = Summarizer.parse(raw, provider: "t")
    expect(s?.summary == "S" && s?.decisions == ["D"], "fields")
    expect(s?.actionItems.first?.owner == nil && s?.actionItems.first?.due == "Jumat", "null owner")
    expect(s?.actionItems.last?.due == nil, "string 'null' due → nil")
    expect(Summarizer.parseTitle(raw) == "Kickoff", "title")
    expect(Summarizer.parse("no json here", provider: "t") == nil, "garbage → nil")
}

test("Summarizer falls back to local rules when the provider fails") {
    struct Broken: AIProvider { var name = "broken"; func complete(system: String, user: String, fast: Bool) throws -> String { throw HushError.provider("down") } }
    let (s, _) = try Summarizer.summarize(sampleMeeting(), provider: Broken())
    expect(s.provider.hasPrefix("local rules") && !s.actionItems.isEmpty, s.provider)
    expect((try? Summarizer.summarize(sampleMeeting(), provider: Broken(), fallback: false)) == nil, "no fallback → throws")
}

test("Store saves, loads, searches and writes Markdown") {
    let m = sampleMeeting()
    _ = try Store.create(m)
    var loaded = try Store.load(m.id)
    expect(loaded.segments == m.segments && loaded.speakerNames == m.speakerNames && loaded.title == m.title, "round trip")
    loaded.summary = Rules.summarize(loaded); try Store.save(loaded)
    let dir = Store.folder(m.id)
    let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
    expect(md.contains("**Daniel**") && md.contains("**Speaker 1**"), "names in transcript.md")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path), "summary.md")
    expect(Store.search("PROPOSAL").first?.hits.isEmpty == false, "case-insensitive search")
    expect(Store.search("zzz-nothing").isEmpty, "no false hits")
    expect((try? Store.load("../../etc")) == nil && !Store.isValidID("a/b") && !Store.isValidID("..") && Store.isValidID(m.id), "ids cannot escape the store")
    let perms = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
    expect(perms == 0o700, "meeting folder is private, got \(String(perms, radix: 8))")
    expect(Store.newID(title: "Rapat Tim / Q4!", date: Date(timeIntervalSince1970: 0)).hasSuffix("-rapat-tim-q4"), Store.newID(title: "Rapat Tim / Q4!"))
}

test("Config decodes old/partial files with defaults") {
    let c = try JSONDecoder().decode(Config.self, from: Data(#"{"provider":"anthropic","unknownKey":1}"#.utf8))
    expect(c.provider == .anthropic && c.asrModel == Config.defaults.asrModel && c.prompterProvider == nil, "\(c)")
    let bad = try JSONDecoder().decode(Config.self, from: Data(#"{"provider":"nope"}"#.utf8))
    expect(bad.provider == Config.defaults.provider, "bad enum → default")
}

// MARK: AI connectors

test("Claude CLI arguments: print mode, no tools, no session, fast → haiku") {
    let a = ClaudeCLIProvider().arguments(system: "SYS", fast: true)
    expect(a.starts(with: ["-p", "--output-format", "text", "--no-session-persistence", "--tools", "", "--strict-mcp-config"]), "\(a)")
    expect(a.contains("--system-prompt") && a.contains("SYS") && a.suffix(2) == ["--model", "haiku"], "\(a)")
    expect(!ClaudeCLIProvider(model: "opus").arguments(system: "S", fast: false).contains("haiku"), "explicit model kept")
}

test("CLI providers run a real executable with the prompt on stdin (fake claude / codex)") {
    let bin = home.appendingPathComponent("bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["claude", "codex"] {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/sh\nprintf 'ARGS:%s|' \"$*\"; cat\n".write(to: f, atomically: true, encoding: .utf8)
        chmod(f.path, 0o755)
    }
    let c = try ClaudeCLIProvider(path: bin.appendingPathComponent("claude").path).complete(system: "S", user: "halo dari stdin", fast: false)
    expect(c.contains("-p --output-format text") && c.hasSuffix("halo dari stdin"), c)
    let x = try CodexCLIProvider(path: bin.appendingPathComponent("codex").path).complete(system: "S", user: "pesan", fast: false)
    expect(x.contains("exec --skip-git-repo-check --sandbox read-only -") && x.hasSuffix("S\n\npesan"), x)
    expect((try? ClaudeCLIProvider(path: "/nonexistent/claude").complete(system: "", user: "", fast: true)) == nil, "missing binary throws")
}

/// Minimal HTTP mock server (Network framework) for the HTTP providers.
final class MockServer {
    let listener: NWListener
    var lastRequest = ""
    var reply: (String) -> (Int, String)
    init(reply: @escaping (String) -> (Int, String)) throws {
        self.reply = reply
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [unowned self] conn in
            conn.start(queue: .global())
            var buf = Data()
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, _ in
                    if let d { buf.append(d) }
                    let s = String(decoding: buf, as: UTF8.self)
                    if let h = s.range(of: "\r\n\r\n") {
                        let len = Int(s.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }?
                            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                        if buf.count - s[..<h.upperBound].utf8.count >= len {
                            self.lastRequest = s
                            let (code, body) = self.reply(s)
                            let resp = "HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                            return
                        }
                    }
                    if !done { read() }
                }
            }
            read()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }
    var port: Int { Int(listener.port!.rawValue) }
    deinit { listener.cancel() }
}

test("OpenAI-compatible provider: request shape + reply parsing against a mock server") {
    let srv = try MockServer { _ in (200, #"{"choices":[{"message":{"role":"assistant","content":" Jawaban singkat. "}}]}"#) }
    let p = OpenAICompatibleProvider(baseURL: "http://127.0.0.1:\(srv.port)/v1/", model: "big", fastModel: "small", apiKey: "sk-test")
    let out = try p.complete(system: "SYS", user: "Q", fast: true)
    expect(out == "Jawaban singkat.", out)
    expect(srv.lastRequest.hasPrefix("POST /v1/chat/completions"), String(srv.lastRequest.prefix(60)))
    expect(srv.lastRequest.lowercased().contains("authorization: bearer sk-test"), "bearer header")
    expect(srv.lastRequest.contains("\"model\":\"small\"") && srv.lastRequest.contains("\"role\":\"system\""), "fast model + system msg")
    let err = try MockServer { _ in (401, #"{"error":"bad key"}"#) }
    expect((try? OpenAICompatibleProvider(baseURL: "http://127.0.0.1:\(err.port)/v1", model: "m").complete(system: "", user: "", fast: false)) == nil, "HTTP 401 throws")
}

test("Anthropic provider: headers, body, text parsing, refusal handling (mock server)") {
    let srv = try MockServer { _ in (200, #"{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Halo "},{"type":"text","text":"Rina."}]}"#) }
    var p = AnthropicProvider(apiKey: "sk-ant-test")
    p.endpoint = "http://127.0.0.1:\(srv.port)/v1/messages"
    let joined = try p.complete(system: "SYS", user: "Q", fast: true); expect(joined == "Halo Rina.", "text blocks joined: \(joined)")
    let r = srv.lastRequest.lowercased()
    expect(r.contains("x-api-key: sk-ant-test") && r.contains("anthropic-version: 2026-10-21"), "auth + version headers")
    expect(r.contains("anthropic-beta: server-side-fallback-2026-07-01") && srv.lastRequest.contains("\"fallbacks\":\"default\""), "fallback on Opus 5.5")
    expect(srv.lastRequest.contains("\"model\":\"claude-opus-5-5\"") && srv.lastRequest.contains("\"effort\":\"low\""), "default model + low effort for prompter")
    expect(!srv.lastRequest.contains("temperature"), "no sampling params (400 on current API)")
    let haiku = try AnthropicProvider(apiKey: "k", model: "claude-haiku-5-5").request(system: "", user: "", fast: false)
    expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil && !String(decoding: haiku.httpBody!, as: UTF8.self).contains("fallbacks"), "no fallback for Haiku")
    expect((try? AnthropicProvider.parse(Data(#"{"stop_reason":"refusal","content":[]}"#.utf8))) == nil, "refusal throws")
    expect((try? AnthropicProvider(apiKey: "").complete(system: "", user: "", fast: true)) == nil, "missing key throws")
}

test("Keychain stores, reads and deletes a key; env override wins") {
    let acct = "test-\(UUID().uuidString.prefix(6))"
    Keychain.set(acct, "secret-1"); expect(Keychain.get(acct) == "secret-1", "stored")
    Keychain.set(acct, ""); expect(Keychain.get(acct) == nil, "deleted")
    setenv("HUSH_ENVTEST_KEY", "from-env", 1); expect(Keychain.get("envtest") == "from-env", "env override")
}

// MARK: MCP

test("MCP server: initialize, tools/list, tools/call, errors, notifications") {
    let s = MCPServer()
    func call(_ json: String) -> [String: Any]? {
        guard let d = s.handle(Data(json.utf8)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    let ini = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    let res = ini?["result"] as? [String: Any]
    expect(res?["protocolVersion"] as? String == "2025-06-18" && (res?["serverInfo"] as? [String: Any])?["name"] as? String == "hush", "\(String(describing: ini))")
    expect(call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "no reply to notification")
    let tools = ((call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    expect(tools == ["list_meetings", "get_transcript", "get_summary", "get_action_items", "search"], "\(String(describing: tools))")
    func text(_ r: [String: Any]?) -> String { (((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    expect(text(call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)).contains("2026-11-16-000000-demo"), "list")
    expect(text(call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_transcript","arguments":{"meeting_id":"latest"}}}"#)).contains("What is your timeline"), "transcript")
    expect(text(call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search","arguments":{"query":"brand guidelines"}}}"#)).contains("Daniel"), "search")
    expect(text(call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_action_items","arguments":{}}}"#)).contains("Sari"), "action items")
    let trav = call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_transcript","arguments":{"meeting_id":"../../../../etc"}}}"#)
    expect((trav?["result"] as? [String: Any])?["isError"] as? Bool == true, "path traversal id rejected")
    let missing = call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_summary","arguments":{"meeting_id":"nope"}}}"#)
    expect((missing?["result"] as? [String: Any])?["isError"] as? Bool == true, "missing meeting → isError")
    expect(((call(#"{"jsonrpc":"2.0","id":8,"method":"bogus"}"#)?["error"] as? [String: Any])?["code"] as? Int) == -32601, "unknown method")
    expect(((call("not json")?["error"] as? [String: Any])?["code"] as? Int) == -32700, "parse error")
}

print("\n\(passed) passed, \(failed.count) failed")
for f in failed { print("  ✗ \(f)") }
try? FileManager.default.removeItem(at: home)
exit(failed.isEmpty ? 0 : 1)
