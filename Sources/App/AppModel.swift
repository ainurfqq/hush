import AppKit
import SwiftUI

/// App-wide state: recording, live transcript, prompter, library.
final class AppModel: ObservableObject {
    @Published var config = Config.load()
    @Published var meetings: [Meeting] = Store.all()
    @Published var isRecording = false
    @Published var recordingMode: Recorder.Mode = .call
    @Published var liveLines: [LiveLine] = []
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var silentWarning = false
    @Published var busy: [String: String] = [:]          // meeting id → progress text
    @Published var prompterVisible = false
    @Published var prompterQuestion: String?
    @Published var prompterAnswer = ""
    @Published var prompterStatus = "Ready"
    @Published var lastError: String?
    @Published var elapsed: TimeInterval = 0
    @Published var libSelection: String?
    @Published var libQuery = ""
    @Published var settingsKey = ""
    @Published var settingsTest = ""

    private var recorder: Recorder?
    private var panel: PrompterPanel?
    private var feeder: FileFeeder?
    var simStart: Date?
    private var lastQuestionAt = Date.distantPast
    private var answering = false
    private var timer: Timer?
    private var lastSound = Date()
    let answerQ = DispatchQueue(label: "hush.answer")

    // MARK: recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording(mode: recordingMode) }

    func startRecording(mode: Recorder.Mode, title: String? = nil) {
        guard !isRecording else { return }
        MicCapture.requestAccess { ok in
            guard ok else { self.lastError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."; return }
            do {
                let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
                let r = try Recorder(mode: mode, title: title ?? "Meeting \(f.string(from: Date()))")
                r.onLine = { [weak self] line in DispatchQueue.main.async { self?.addLive(line) } }
                r.onLevels = { [weak self] m, s in DispatchQueue.main.async { self?.levels(m, s) } }
                try r.start()
                self.recorder = r; self.isRecording = true; self.recordingMode = mode
                self.liveLines = []; self.prompterAnswer = ""; self.prompterQuestion = nil
                self.lastSound = Date(); self.silentWarning = false
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                self.prompterStatus = "Listening"
                self.reload()
            } catch {
                self.lastError = "\(error)"
            }
        }
    }

    func stopRecording() {
        guard let r = recorder else { return }
        timer?.invalidate(); timer = nil
        isRecording = false; recorder = nil
        prompterStatus = "Processing last meeting"
        let m = r.stop()
        reload()
        if let m { process(m.id) }
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = Date().timeIntervalSince(r.started)
        silentWarning = Date().timeIntervalSince(lastSound) > 30
    }

    private func levels(_ m: Float, _ s: Float) {
        micLevel = m; sysLevel = s
        if max(m, s) > 0.01 { lastSound = Date() }
    }

    // MARK: live transcript + prompter

    func addLive(_ line: LiveLine) {
        liveLines.append(line)
        if let s0 = simStart { print(String(format: "LINE_AT %.2f (audio clock) chunk@%.1f: %@", Date().timeIntervalSince(s0), line.t, line.text)); fflush(stdout) }
        if liveLines.count > 400 { liveLines.removeFirst(100) }
        guard line.who != "me", config.prompterAutoAnswer, (config.prompterProvider ?? config.provider) != .none,
              let q = QuestionDetector.question(in: line.text) else { return }
        answer(q)
    }

    func answerLastQuestion() {
        guard let last = liveLines.last(where: { $0.who != "me" }) else { prompterStatus = "No question heard yet"; return }
        answer(QuestionDetector.question(in: last.text) ?? last.text)
    }

    func answer(_ question: String) {
        guard !answering, Date().timeIntervalSince(lastQuestionAt) > 2 else { return }
        guard let provider = AI.provider(config, forPrompter: true) else { prompterStatus = "Set an AI provider in Settings"; return }
        answering = true; lastQuestionAt = Date()
        prompterQuestion = question; prompterAnswer = ""; prompterStatus = "Drafting answer…"
        if !prompterVisible { showPrompter() }
        let recent = liveLines.suffix(40).map { "\($0.who == "me" ? (config.userName.isEmpty ? "Me" : config.userName) : "Them"): \($0.text)" }.joined(separator: "\n")
        let ctxPath = (config.contextFile as NSString).expandingTildeInPath
        let ctx = config.contextFile.isEmpty ? "" : ((try? String(contentsOfFile: ctxPath, encoding: .utf8)) ?? "")
        let sys = Answerer.system(userName: config.userName), user = Answerer.prompt(question: question, recent: recent, context: ctx)
        let t0 = Date()
        answerQ.async {
            let result = Result { try provider.complete(system: sys, user: user, fast: true) }
            DispatchQueue.main.async {
                self.answering = false
                let dt = Date().timeIntervalSince(t0)
                switch result {
                case .success(let a):
                    self.prompterAnswer = a
                    self.prompterStatus = String(format: "Answered in %.1f s · %@", dt, provider.name)
                    Log.write(String(format: "prompter answer %.2f s via %@", dt, provider.name))
                    NotificationCenter.default.post(name: .hushAnswerShown, object: dt)
                    if let s0 = self.simStart {
                        print(String(format: "ANSWER_SHOWN_AT %.2f (audio clock) | AI %.2f s | Q: %@", Date().timeIntervalSince(s0), dt, question)); fflush(stdout)
                    }
                case .failure(let e):
                    self.prompterStatus = "AI error"; self.prompterAnswer = "\(e)"
                }
            }
        }
    }

    func showPrompter() {
        if panel == nil { panel = PrompterPanel(model: self) }
        panel?.orderFrontRegardless(); prompterVisible = true
    }
    func hidePrompter() { panel?.orderOut(nil); prompterVisible = false }
    func togglePrompter() { prompterVisible ? hidePrompter() : showPrompter() }
    func setOpacity(_ v: Double) { config.prompterOpacity = v; panel?.alphaValue = CGFloat(v); try? config.save() }
    var prompterWindowNumber: Int? { panel?.windowNumber }

    @Published var hiddenCheck: String?
    /// Runs the self-test that proves (or disproves) the prompter is hidden from ScreenCaptureKit on this Mac.
    func checkPrompterHidden(_ done: ((PrompterCheck.Result?) -> Void)? = nil) {
        showPrompter()
        guard let p = panel else { return }
        hiddenCheck = "Checking… (the prompter blinks twice)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PrompterCheck.run(panel: p) { r, err in
                self.hiddenCheck = r?.summary ?? err
                Log.write("prompter hidden check: \(self.hiddenCheck ?? "")")
                done?(r)
            }
        }
    }

    func simulate(_ url: URL) {
        _ = try? WhisperServer.shared.ensureRunning(config: config)   // a real recording warms it at start, too
        let f = FileFeeder()
        f.onLine = { [weak self] l in DispatchQueue.main.async { self?.addLive(l) } }
        feeder = f; isRecording = true; prompterStatus = "Simulating from \(url.lastPathComponent)"; simStart = Date()
        f.run(url)
    }

    // MARK: library

    func reload() { meetings = Store.all() }

    func process(_ id: String) {
        busy[id] = "Starting…"
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var m = try Pipeline.process(id, config: cfg) { s, f in
                    DispatchQueue.main.async { self.busy[id] = "\(s) (\(Int(f * 100))%)" }
                }
                DispatchQueue.main.async { self.busy[id] = "Summarizing…" }
                let (s, title) = try Summarizer.summarize(m, provider: AI.provider(cfg))
                m.summary = s
                if let title, m.title.hasPrefix("Meeting ") || m.source == "import" { m.title = title }
                try Store.save(m)
            } catch {
                DispatchQueue.main.async { self.lastError = "\(error)" }
            }
            DispatchQueue.main.async {
                self.busy[id] = nil; self.reload()
                if !self.isRecording { self.prompterStatus = "Ready" }
            }
        }
    }

    func summarize(_ id: String) {
        guard var m = try? Store.load(id) else { return }
        busy[id] = "Summarizing…"
        let cfg = config
        DispatchQueue.global().async {
            do { let (s, _) = try Summarizer.summarize(m, provider: AI.provider(cfg)); m.summary = s; try Store.save(m) }
            catch { DispatchQueue.main.async { self.lastError = "\(error)" } }
            DispatchQueue.main.async { self.busy[id] = nil; self.reload() }
        }
    }

    func importAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        do { let m = try Pipeline.importFile(url); reload(); process(m.id) }
        catch { lastError = "\(error)" }
    }

    private var detailStates: [String: DetailState] = [:]
    func detailState(_ m: Meeting) -> DetailState {
        if let d = detailStates[m.id] { return d }
        let d = DetailState(m); detailStates[m.id] = d; return d
    }

    func save(_ m: Meeting) { try? Store.save(m); reload() }
    func delete(_ id: String) { try? Store.delete(id); reload() }

    func export(_ m: Meeting) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(m.id).md"
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        try? Markdown.export(m).write(to: url, atomically: true, encoding: .utf8)
    }

    func saveConfig() { try? config.save() }

    static let consentMessage = "Heads-up: I'm using Hush to take notes of this meeting. It transcribes locally on my Mac, and nothing is uploaded or shared. Tell me if you'd rather I didn't."
    func copyConsent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.consentMessage, forType: .string)
    }
}

extension Notification.Name { static let hushAnswerShown = Notification.Name("hushAnswerShown") }
