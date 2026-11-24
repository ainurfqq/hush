import AppKit
import SwiftUI
import Combine

/// App-wide state: recording, live transcript, prompter, library.
final class AppModel: ObservableObject {
    @Published var config = Config.load()
    @Published var meetings: [Meeting] = Store.all()
    @Published var isRecording = false
    /// Remembered across launches, so the mode on screen is the mode the last meeting used.
    @Published var recordingMode: Recorder.Mode = Recorder.Mode(rawValue: UserDefaults.standard.string(forKey: "recordingMode") ?? "") ?? .call {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode") }
    }
    @Published var liveLines: [LiveLine] = []
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var silentWarning = false
    @Published var callSilentWarning = false   // online call, mic hears you, but the call audio is silent (permission off?)
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
    // Live meeting window
    @Published var liveNotes = ""
    @Published var catchUp: [String] = []
    @Published var catchUpBusy = false
    @Published var askText = ""
    @Published var askAnswer: String?
    @Published var askBusy = false
    @Published var liveTitle = ""
    @Published var prompterAskedAt: Date?
    var recentQuestions: [LiveLine] { Array(liveLines.filter { $0.question != nil }.suffix(3)) }
    /// Set by a SwiftUI view that has `openWindow` in its environment.
    var openWindowAction: ((String) -> Void)?

    private var recorder: Recorder?
    private var panel: PrompterPanel?
    lazy var notch = NotchController(model: self)
    var notchStyle: Bool { config.prompterStyle == "notch" }
    private lazy var styleWatch: AnyCancellable = $config.map(\.prompterStyle).removeDuplicates().dropFirst()
        .receive(on: RunLoop.main).sink { [weak self] _ in self?.applyPrompterStyle() }

    /// The prompter style can change mid-meeting (Settings): move the answer to the notch bar or the panel right away.
    func applyPrompterStyle() {
        guard isRecording else { return }
        if notchStyle {
            let wasOpen = prompterVisible
            hidePrompter(); notch.show()
            if wasOpen && prompterQuestion != nil { notch.showQuestion() }
        } else {
            let wasOpen = notch.isVisible && notch.state.mode == .question
            notch.hide()
            if wasOpen || !prompterAnswer.isEmpty { showPrompter() }
        }
    }

    /// Shows the answer UI the user picked: the notch bar (while recording) or the floating prompter.
    func presentAnswer() {
        if notchStyle && isRecording { notch.showQuestion() } else if !prompterVisible { showPrompter() }
    }
    private var feeder: FileFeeder?
    var simStart: Date?
    private var lastQuestionAt = Date.distantPast
    private var answering = false
    private var timer: Timer?
    private var lastSound = Date()
    private var lastCallSound = Date()
    let answerQ = DispatchQueue(label: "hush.answer")
    static let pipelineQ = DispatchQueue(label: "hush.pipeline", qos: .userInitiated)

    // MARK: recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording(mode: recordingMode) }

    func startRecording(mode: Recorder.Mode, title: String? = nil) {
        guard !isRecording else { return }
        MicCapture.requestAccess { ok in
            guard ok else { self.lastError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."; return }
            var made: Recorder?
            do {
                let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
                let r = try Recorder(mode: mode, title: title ?? "Meeting \(f.string(from: Date()))")
                made = r
                r.onLine = { [weak self] line in DispatchQueue.main.async { self?.addLive(line) } }
                r.onLevels = { [weak self] m, s in DispatchQueue.main.async { self?.levels(m, s) } }
                try r.start()
                self.recorder = r; self.isRecording = true; self.recordingMode = mode
                self.liveLines = []; self.prompterAnswer = ""; self.prompterQuestion = nil
                self.liveNotes = ""; self.catchUp = []; self.askAnswer = nil; self.askText = ""
                self.liveTitle = (try? Store.load(r.meetingID).title) ?? "Meeting"
                self.openWindowAction?("live")
                if self.notchStyle { self.notch.show() }
                _ = self.styleWatch
                self.lastSound = Date(); self.silentWarning = false
                self.lastCallSound = Date(); self.callSilentWarning = false
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                self.prompterStatus = "Listening"
                self.reload()
            } catch {
                if let r = made { try? Store.delete(r.meetingID); self.reload() }   // no empty "recording" left in the Library
                Log.write("start recording failed: \(error)")
                self.lastError = "\(error)"
                self.openWindowAction?("library")
            }
        }
    }

    func stopRecording() {
        guard let r = recorder else { return }
        timer?.invalidate(); timer = nil
        isRecording = false; recorder = nil
        notch.hide(); hidePrompter()
        prompterStatus = "Processing last meeting"
        var m = r.stop()
        if var mm = m {
            if !liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { mm.userNotes = liveNotes }
            if !liveTitle.isEmpty { mm.title = liveTitle }
            try? Store.save(mm); m = mm
        }
        reload()
        if let m { libSelection = m.id; process(m.id) }
    }

    private func tick() {
        guard let r = recorder else { return }
        if r.writeFailed {
            stopRecording()
            lastError = "Your Mac's disk is full, so Hush stopped recording. The audio up to now is saved. Free some space, then open the meeting and click Transcribe."
            return
        }
        elapsed = Date().timeIntervalSince(r.started)
        silentWarning = Date().timeIntervalSince(lastSound) > 30
        callSilentWarning = recordingMode == .call && !silentWarning && elapsed > 45 && Date().timeIntervalSince(lastCallSound) > 45
    }

    private func levels(_ m: Float, _ s: Float) {
        micLevel = m; sysLevel = s
        if max(m, s) > 0.01 { lastSound = Date() }
        if s > 0.002 { lastCallSound = Date() }
    }

    // MARK: live transcript + prompter

    func addLive(_ incoming: LiveLine) {
        var line = incoming
        if line.who != "me" { line.question = QuestionDetector.question(in: line.text) }
        liveLines.append(line)
        if let s0 = simStart { print(String(format: "LINE_AT %.2f (audio clock) chunk@%.1f: %@", Date().timeIntervalSince(s0), line.t, line.text)); fflush(stdout) }
        if liveLines.count > 400 { liveLines.removeFirst(100) }
        recorder?.liveLog("\(line.who == "me" ? "Me" : line.who == "room" ? "Room" : "Them"): \(line.text)")
        guard line.who != "me", config.prompterAutoAnswer,
              (config.prompterProvider ?? config.provider) != .none || !notesText.isEmpty,
              var q = line.question else { return }
        // A short or cut-off question gets the line before it as context ("…for the launch. What do you think?").
        let others = liveLines.filter { $0.who != "me" }
        if q.split(separator: " ").count < 7, others.count >= 2 { q = others[others.count - 2].text + " " + q }
        answer(q)
    }

    /// QA only: add a line without triggering the AI.
    func addLiveForDemo(_ incoming: LiveLine) {
        var l = incoming
        if l.who != "me" { l.question = QuestionDetector.question(in: l.text) }
        liveLines.append(l)
    }

    func answerLastQuestion() {
        guard let last = liveLines.last(where: { $0.who != "me" }) else { prompterStatus = "No question heard yet"; return }
        answer(QuestionDetector.question(in: last.text) ?? last.text)
    }

    func answer(_ question: String) {
        guard !answering, Date().timeIntervalSince(lastQuestionAt) > 2 else { return }
        guard let provider = AI.provider(config, forPrompter: true) else { answerFromNotes(question, reason: nil); return }
        answering = true; lastQuestionAt = Date(); prompterAskedAt = liveLines.last(where: { $0.question != nil })?.heardAt ?? Date()
        recorder?.liveLog("QUESTION caught: \(question)")
        prompterQuestion = question; prompterAnswer = ""; prompterStatus = "Drafting answer…"
        presentAnswer()
        let recent = liveLines.suffix(40).map { "\($0.who == "me" ? (config.userName.isEmpty ? "Me" : config.userName) : "Them"): \($0.text)" }.joined(separator: "\n")
        let ctxPath = (config.contextFile as NSString).expandingTildeInPath
        let ctx = config.contextFile.isEmpty ? "" : ((try? String(contentsOfFile: ctxPath, encoding: .utf8)) ?? "")
        let sys = Answerer.system(userName: config.userName), user = Answerer.prompt(question: question, recent: recent, context: ctx)
        let t0 = Date()
        answerQ.async {
            var firstLogged = false
            let result = Result { try provider.stream(system: sys, user: user, fast: true) { soFar in
                DispatchQueue.main.async {
                    guard self.answering else { return }
                    if !firstLogged { firstLogged = true; Log.write(String(format: "prompter first words %.2f s via %@", Date().timeIntervalSince(t0), provider.name)) }
                    self.prompterAnswer = soFar; self.prompterStatus = "Answering…"
                }
            } }
            DispatchQueue.main.async {
                self.answering = false
                let dt = Date().timeIntervalSince(t0)
                switch result {
                case .success(let a):
                    self.prompterAnswer = a
                    self.prompterStatus = String(format: "Answered in %.1f s · %@", dt, provider.name)
                    Log.write(String(format: "prompter answer %.2f s via %@", dt, provider.name))
                    self.recorder?.liveLog(String(format: "ANSWER after %.1f s (%@): ", dt, provider.name) + a.replacingOccurrences(of: "\n", with: " / "))
                    NotificationCenter.default.post(name: .hushAnswerShown, object: dt)
                    if let s0 = self.simStart {
                        print(String(format: "ANSWER_SHOWN_AT %.2f (audio clock) | AI %.2f s | Q: %@", Date().timeIntervalSince(s0), dt, question)); fflush(stdout)
                    }
                case .failure(let e):
                    self.recorder?.liveLog("ANSWER failed: \(e)")
                    self.answerFromNotes(question, reason: "AI failed (\(String(describing: e).prefix(60))…)")
                }
            }
        }
    }

    /// The user's notes file (CV, prepared answers, product facts), read fresh each time.
    var notesText: String {
        guard !config.contextFile.isEmpty else { return "" }
        return (try? String(contentsOfFile: (config.contextFile as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
    }

    /// Notes mode: no AI needed. Shows the best matching pieces of the user's notes file.
    func answerFromNotes(_ question: String, reason: String?) {
        prompterQuestion = question; prompterAskedAt = Date()
        presentAnswer()
        let notes = notesText
        if notes.isEmpty {
            prompterAnswer = "No AI is set up, so Hush cannot write an answer. Add a notes file with prepared answers (Settings → Prompter → Context notes file) and Hush will show the matching points here."
            prompterStatus = reason ?? "No AI · notes mode"
        } else if let a = Retrieval.notesAnswer(question: question, notes: notes) {
            prompterAnswer = a
            prompterStatus = (reason.map { $0 + " · " } ?? "") + "From your notes · no AI"
        } else {
            prompterAnswer = "Nothing in your notes matches this question."
            prompterStatus = (reason.map { $0 + " · " } ?? "") + "Notes mode"
        }
        recorder?.liveLog("NOTES ANSWER: " + prompterAnswer.replacingOccurrences(of: "\n", with: " / "))
        if let s0 = simStart { print(String(format: "NOTES_ANSWER_AT %.2f | Q: %@ | A: %@", Date().timeIntervalSince(s0), question, prompterAnswer.replacingOccurrences(of: "\n", with: " / "))); fflush(stdout) }
    }

    private func liveTranscript(since: Date? = nil) -> String {
        let me = config.userName.isEmpty ? "Me" : config.userName
        return liveLines.filter { since == nil || $0.heardAt >= since! }
            .map { "\($0.who == "me" ? me : "Them"): \($0.text)" }.joined(separator: "\n")
    }

    /// "What did I miss?": bullets for the last 5 minutes.
    func whatDidIMiss() {
        guard !catchUpBusy else { return }
        guard let p = AI.provider(config, forPrompter: true) else {
            let cutoff = Date().addingTimeInterval(-300)
            let lines = liveLines.filter { $0.heardAt >= cutoff }.map { (who: $0.who == "me" ? "You" : "Them", text: $0.text) }
            let picked = Retrieval.catchUp(lines)
            catchUp = picked.isEmpty ? ["Nothing important was said in the last 5 minutes."] : picked + ["(Key lines, no AI. Set up an AI for a real summary.)"]
            return
        }
        let recent = liveTranscript(since: Date().addingTimeInterval(-300))
        guard !recent.isEmpty else { catchUp = ["Nothing was said in the last 5 minutes."]; return }
        catchUpBusy = true
        DispatchQueue.global().async {
            let r = Result { try p.complete(system: LiveHelp.catchUpSystem, user: recent, fast: true) }
            DispatchQueue.main.async {
                self.catchUpBusy = false
                switch r {
                case .success(let t):
                    self.catchUp = t.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespaces)) }.filter { !$0.isEmpty }
                    self.recorder?.liveLog("CATCH-UP: " + self.catchUp.joined(separator: " / "))
                case .failure(let e): self.catchUp = ["AI error: \(e)"]
                }
            }
        }
    }

    /// "Ask anything" about the meeting so far.
    func askLive() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askBusy else { return }
        guard let p = AI.provider(config, forPrompter: true) else {
            let hits = Retrieval.best(q, in: liveLines.map { ($0.who == "me" ? "You: " : "Them: ") + $0.text }, k: 3)
            askAnswer = hits.isEmpty ? "No line in this meeting matches that. (No AI: Hush searches the transcript by words.)"
                                     : hits.joined(separator: "\n") + "\n(Matching lines, no AI.)"
            return
        }
        askBusy = true; askAnswer = nil
        let t = liveTranscript()
        DispatchQueue.global().async {
            let r = Result { try p.complete(system: LiveHelp.askSystem, user: "Transcript so far:\n\(t.suffix(12000))\n\nQuestion: \(q)", fast: true) }
            DispatchQueue.main.async {
                self.askBusy = false
                switch r { case .success(let a): self.askAnswer = a; case .failure(let e): self.askAnswer = "AI error: \(e)" }
            }
        }
    }

    func showPrompter() {
        if panel == nil { panel = PrompterPanel(model: self) }
        panel?.orderFrontRegardless(); prompterVisible = true
    }
    func hidePrompter() { panel?.orderOut(nil); prompterVisible = false }
    func togglePrompter() {
        if notchStyle && isRecording { notch.toggleQuestion(); return }
        prompterVisible ? hidePrompter() : showPrompter()
    }
    func setOpacity(_ v: Double) { config.prompterOpacity = v; panel?.alphaValue = CGFloat(v); try? config.save() }
    var prompterWindowNumber: Int? { panel?.windowNumber }

    @Published var hiddenCheck: String?
    @Published var needsScreenPermission = false
    @Published var aiDetect: String?

    /// First run: pick the AI that is actually on this Mac (Claude Code, Codex, Ollama) or none.
    func detectAI() {
        DispatchQueue.global().async {
            let f = AIDetect.run()
            DispatchQueue.main.async {
                self.config.provider = f.kind
                if f.kind == .openAICompatible { self.config.model = f.model; self.config.openAIBaseURL = "http://127.0.0.1:11434/v1" }
                self.aiDetect = f.detail
                self.saveConfig()
                Log.write("AI detect: \(f.detail)")
            }
        }
    }
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    /// Runs the self-test that proves (or disproves) the prompter is hidden from ScreenCaptureKit on this Mac.
    func checkPrompterHidden(_ done: ((PrompterCheck.Result?) -> Void)? = nil) {
        showPrompter()
        guard let p = panel else { return }
        hiddenCheck = "Checking… (the prompter blinks twice)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PrompterCheck.run(panel: p) { r, err in
                if err == PrompterCheck.needsPermission {
                    self.hiddenCheck = "Hush needs Screen Recording permission for this check (only to take the test screenshots). Turn on Hush in System Settings, then run the check again."
                    self.needsScreenPermission = true
                } else {
                    self.hiddenCheck = r?.summary ?? err
                    self.needsScreenPermission = false
                }
                // QA runs (deliberately capturable panel) must never overwrite the user's saved result.
                if let r, r.valid, ProcessInfo.processInfo.environment["HUSH_QA_CAPTURABLE"] != "1" {
                    let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
                    self.config.lastHiddenCheck = (r.hidden ? "hidden" : "visible") + "|" + f.string(from: Date())
                    self.saveConfig()
                }
                Log.write("prompter hidden check: \(self.hiddenCheck ?? "")")
                done?(r)
            }
        }
    }

    func simulate(_ url: URL) {
        _ = try? WhisperServer.shared.ensureRunning(config: config, live: true)   // a real recording warms it at start, too
        let f = FileFeeder()
        f.onLine = { [weak self] l in DispatchQueue.main.async { self?.addLive(l) } }
        feeder = f; isRecording = true; prompterStatus = "Simulating from \(url.lastPathComponent)"; simStart = Date()
        f.run(url)
    }

    // MARK: library

    func reload() { meetings = Store.all() }

    func process(_ id: String) {
        guard busy[id] == nil else { return }   // one pipeline per meeting
        busy[id] = "Starting…"
        let cfg = config
        // One meeting at a time: two pipelines at once can run an 8 GB Mac out of memory.
        Self.pipelineQ.async {
            do {
                var m = try Pipeline.process(id, config: cfg) { s, f in
                    DispatchQueue.main.async { self.busy[id] = "\(s) (\(Int(f * 100))%)" }
                }
                DispatchQueue.main.async { self.busy[id] = "Summarizing…" }
                let (s, title) = try Summarizer.summarize(m, provider: AI.provider(cfg))
                // Re-read: names, notes or a title typed while the summary was written must not be lost.
                var cur = (try? Store.load(id)) ?? m
                cur.summary = s
                if let title, cur.title.hasPrefix("Meeting ") || cur.source == "import" { cur.title = title }
                try Store.save(cur)
            } catch {
                Log.write("process/summary failed for \(id): \(error)")
                DispatchQueue.main.async { self.lastError = "\(error)" }
            }
            DispatchQueue.main.async {
                self.busy[id] = nil; self.reload()
                if !self.isRecording {
                    self.prompterStatus = "Ready"
                    // Free ~600-800 MB between meetings; the next recording reloads it in a few seconds.
                    if self.busy.isEmpty { WhisperServer.shared.stop(); Log.write("speech model unloaded (idle)") }
                }
            }
        }
    }

    func summarize(_ id: String) {
        guard busy[id] == nil, let m = try? Store.load(id) else { return }
        busy[id] = "Summarizing…"
        let cfg = config
        DispatchQueue.global().async {
            do {
                let (s, _) = try Summarizer.summarize(m, provider: AI.provider(cfg))
                var cur = (try? Store.load(id)) ?? m; cur.summary = s; try Store.save(cur)
            }
            catch { Log.write("summary failed for \(id): \(error)"); DispatchQueue.main.async { self.lastError = "\(error)" } }
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
