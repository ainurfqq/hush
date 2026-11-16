import SwiftUI
import AppKit
import AVFoundation

// MARK: - welcome guide (first run, re-openable from Settings)

final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()
    @Published var step = 0
    let steps = ["Welcome", "Permissions", "AI", "Prompter", "How to use"]
}

/// Records 10 seconds of call + mic so macOS asks for permissions before the first real meeting.
final class PermissionTest: ObservableObject {
    static let shared = PermissionTest()
    @Published var running = false
    @Published var secondsLeft = 0
    @Published var micPeak: Float = 0
    @Published var sysPeak: Float = 0
    @Published var done = false
    @Published var error: String?
    private var rec: Recorder?

    var heardMic: Bool { micPeak > 0.01 }
    var heardCall: Bool { sysPeak > 0.005 }

    func run() {
        guard !running else { return }
        error = nil; done = false; micPeak = 0; sysPeak = 0
        MicCapture.requestAccess { ok in
            guard ok else { self.error = "Microphone access is off. Turn on Hush in System Settings → Privacy & Security → Microphone."; return }
            do {
                let r = try Recorder(mode: .call, title: "Hush setup test")
                r.onLevels = { [weak self] m, s in DispatchQueue.main.async { self?.micPeak = max(self?.micPeak ?? 0, m); self?.sysPeak = max(self?.sysPeak ?? 0, s) } }
                try r.start(warmASR: false)
                self.rec = r; self.running = true; self.secondsLeft = 10
                self.tick()
            } catch { self.error = "\(error)" }
        }
    }

    private func tick() {
        guard running else { return }
        if secondsLeft <= 0 { finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.secondsLeft -= 1; self.tick() }
    }

    private func finish() {
        if let m = rec?.stop() { try? Store.delete(m.id) }     // a test, not a meeting
        rec = nil; running = false; done = true
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) var dismissWindow
    @ObservedObject var ob = OnboardingState.shared
    @ObservedObject var setup = SetupState.shared
    @ObservedObject var perm = PermissionTest.shared

    var body: some View {
        VStack(spacing: 0) {
            // progress
            HStack(spacing: 8) {
                ForEach(Array(ob.steps.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 6) {
                        Circle().fill(i <= ob.step ? Theme.indigo : Theme.line).frame(width: 8, height: 8)
                        Text(name).font(.system(size: 12, weight: i == ob.step ? .semibold : .regular)).foregroundStyle(i == ob.step ? Theme.ink : Theme.ink3)
                    }
                    if i < ob.steps.count - 1 { Rectangle().fill(Theme.line).frame(height: 1).frame(maxWidth: 24) }
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch ob.step {
                    case 0: welcome
                    case 1: permissions
                    case 2: aiChoice
                    case 3: prompter
                    default: howTo
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.line)
            HStack {
                if ob.step > 0 { Button("Back") { ob.step -= 1 }.buttonStyle(OutlineButton()) }
                Spacer()
                if ob.step < ob.steps.count - 1 {
                    Button("Skip setup") { finish() }.buttonStyle(LinkStyle(color: Theme.ink3)).font(.system(size: 12)).padding(.trailing, 8)
                    Button(ob.step == 0 ? "Get started" : "Next") { ob.step += 1 }.buttonStyle(FilledButton(bg: Theme.indigo))
                } else {
                    Button("Start using Hush") { finish() }.buttonStyle(FilledButton(bg: Theme.ink))
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 14)
        }
        .frame(width: 640, height: 720)
        .background(Theme.panel).tint(Theme.indigo)
        .onAppear { setup.refresh(); AIChoices.shared.refresh() }
    }

    func finish() { model.config.setupDone = true; model.saveConfig(); ob.step = 0; dismissWindow(id: "setup") }

    func title(_ a: String, _ b: String) -> some View { (Text(a).font(Theme.serif(36)) + Text(b).font(Theme.serif(36, italic: true))) }
    func lead(_ s: String) -> some View { Text(s).font(.system(size: 14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }

    // 1
    @ViewBuilder var welcome: some View {
        HushGlyph.onLight.frame(width: 56, height: 50)
        title("Meet ", "Hush")
        lead("Your quiet meeting assistant. It takes notes of online and in-room meetings, without joining the call.")
        VStack(spacing: 10) {
            feature("waveform", "Listens quietly", "No bot joins your Zoom, Meet or Teams. Hush hears your Mac's sound and your mic.")
            feature("text.bubble", "Writes the notes", "Who said what, in Indonesian and English. Then a summary, decisions and tasks with names and dates.")
            feature("sparkles", "Helps you answer", "When someone asks you a question, a private prompter suggests an answer. It is hidden from screen sharing.")
        }
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.ok)
            Text("Audio and notes stay on this Mac. Nothing is uploaded unless you choose an online AI.").font(.system(size: 12)).foregroundStyle(Theme.ok)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.okSoft, in: RoundedRectangle(cornerRadius: 10))
    }

    func feature(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.indigo).frame(width: 34, height: 34).background(Theme.indigoSoft, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.system(size: 14, weight: .semibold))
                Text(d).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    // 2
    @ViewBuilder var permissions: some View {
        title("Let Hush ", "listen")
        lead("macOS asks once for two permissions. Do it now, so nothing pops up during your first real meeting.")
        card(done: setup.engines, title: "Speech engine and models", detail: setup.downloading ? setup.downloadLine : setup.enginesDetail) {
            if !setup.engines { Button(setup.downloading ? "Downloading…" : "Download (about 800 MB)") { setup.downloadModels() }
                .buttonStyle(FilledButton(bg: Theme.indigo)).disabled(setup.downloading) }
        }
        card(done: AVCaptureDeviceAuthorized(), title: "Microphone", detail: "For your side of the call, or the whole room.") {
            if !AVCaptureDeviceAuthorized() { Button("Allow") { MicCapture.requestAccess { _ in setup.refresh(); perm.objectWillChange.send() } }.buttonStyle(FilledButton(bg: Theme.indigo)) }
        }
        card(done: perm.done && perm.heardCall, title: "Call audio + a 10-second test",
             detail: perm.running ? "Recording… \(perm.secondsLeft) s. Play any video with sound and say a few words."
                : perm.done ? testResult : "Click Test, then play any video with sound and say something. If macOS asks for \"System Audio Recording\", click Allow.") {
            if !perm.running { Button(perm.done ? "Test again" : "Test 10 seconds") { perm.run() }.buttonStyle(FilledButton(bg: Theme.indigo)) }
        }
        if let e = perm.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.rec) }
    }

    var testResult: String {
        switch (perm.heardMic, perm.heardCall) {
        case (true, true): return "Heard your mic ✓ and the call audio ✓. You are ready."
        case (true, false): return "Heard your mic ✓, but no call audio. Did a video play? If macOS showed a prompt, allow it and test again. Or turn on Hush under System Settings → Privacy & Security → Screen & System Audio Recording."
        case (false, true): return "Heard the call audio ✓, but not your mic. Check the input in System Settings → Sound."
        default: return "Heard nothing. Play a video with sound and speak, then test again."
        }
    }

    func card<B: View>(done: Bool, title: String, detail: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(done ? Theme.ok : Theme.ink3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            button()
        }
        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    // 3
    @ViewBuilder var aiChoice: some View {
        title("Choose your ", "AI")
        lead("AI writes the summary and the prompter answers. It is optional: transcripts, speakers, tasks and search work without it.")
        AIChoiceCards()
    }

    // 4
    @ViewBuilder var prompter: some View {
        title("Your private ", "prompter")
        lead("When someone asks you a question during a recording, Hush shows a suggested answer only you can see.")
        HStack(spacing: 10) {
            styleCard("notch", "Notch bar", "Grows out of the top of the screen while recording. Opens by itself when you are asked.")
            styleCard("panel", "Floating panel", "A small window you can move anywhere, for example next to your camera.")
        }
        card(done: model.config.lastHiddenCheck.hasPrefix("hidden"), title: "Hidden from screen sharing",
             detail: model.hiddenCheck ?? "A 3-second check that the prompter does not show when you share your screen.") {
            Button(model.needsScreenPermission ? "Open Settings" : "Run check") {
                model.needsScreenPermission ? model.openScreenRecordingSettings() : model.checkPrompterHidden()
            }.buttonStyle(FilledButton(bg: Theme.indigo))
        }
        card(done: !model.config.contextFile.isEmpty, title: "Your prepared answers",
             detail: model.config.contextFile.isEmpty ? "A short file with facts about you and answers you want ready. The prompter uses it with or without AI."
                                                       : "Using \((model.config.contextFile as NSString).lastPathComponent). Edit it any time.") {
            Button(model.config.contextFile.isEmpty ? "Create my answers file" : "Open file") { AnswersTemplate.createAndOpen(model) }.buttonStyle(OutlineButton())
        }
    }

    func styleCard(_ tag: String, _ t: String, _ d: String) -> some View {
        let on = model.config.prompterStyle == tag
        return Button { model.config.prompterStyle = tag; model.saveConfig() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(t).font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Theme.indigo : Theme.ink3) }
                Text(d).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(on ? Theme.indigoSoft : Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.indigo : Theme.line, lineWidth: on ? 2 : 1))
        }.buttonStyle(RowStyle(radius: 12))
    }

    // 5
    @ViewBuilder var howTo: some View {
        title("How to ", "use Hush")
        VStack(spacing: 10) {
            tip("1", "Start", "Click the Hush icon in the menu bar → Start recording. Or press ⌃⌥R anywhere.")
            tip("2", "During the meeting", "The live window shows the transcript. Lost focus? Click What did I miss?. Write your own points in My notes.")
            tip("3", "When you are asked", "The answer appears in the \(model.config.prompterStyle == "notch" ? "notch bar" : "prompter"). Wrong question? Pick another one. ⌃⌥H shows or hides it.")
            tip("4", "After the meeting", "Click Stop. In about two minutes the notes are ready: summary, tasks with names and dates, the full transcript.")
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you record people").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.rgb(0x6B4205))
            Text("Tell them you are taking notes. Hush has a message ready to paste in the chat.").font(.system(size: 13)).foregroundStyle(Theme.rgb(0x4D3A1F))
            Button("Copy consent message") { model.copyConsent() }.buttonStyle(LinkStyle()).font(.system(size: 13))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rgb(0xFFF7EB), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rgb(0xF3DDB6)))
    }

    func tip(_ n: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(Theme.serif(26)).foregroundStyle(Theme.indigo).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.system(size: 14, weight: .semibold))
                Text(d).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}

// MARK: - AI choice cards (used in onboarding and Settings)

final class AIChoices: ObservableObject {
    static let shared = AIChoices()
    @Published var claude = false
    @Published var codex = false
    @Published var ollama = false
    func refresh() {
        DispatchQueue.global().async {
            let c = Shell.which("claude") != nil, x = Shell.which("codex") != nil
            let o = Shell.which("ollama") != nil || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            DispatchQueue.main.async { self.claude = c; self.codex = x; self.ollama = o }
        }
    }
}

struct AIChoiceCards: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ai = AIChoices.shared

    var body: some View {
        VStack(spacing: 10) {
            choice(.claudeCLI, "Claude Code", found: ai.claude, badge: "Best quality",
                   pros: "Strong summaries and answers, uses your Claude login.", cons: "Needs a Claude subscription. Text goes to Anthropic.") {
                model.config.provider = .claudeCLI; model.saveConfig()
            }
            choice(.codexCLI, "Free ChatGPT account (Codex)", found: ai.codex, badge: "Free",
                   pros: "Works with a free OpenAI account. Good summaries (tested).", cons: "Text goes to OpenAI. Free usage limits are not published.") {
                model.openWindowAction?("codex")
            }
            choice(.openAICompatible, "Free on this Mac (Ollama)", found: ai.ollama, badge: "Fully private",
                   pros: "Nothing leaves your Mac, no account.", cons: "Weaker; slow on 8 GB Macs. About 2–5 GB download.") {
                model.openWindowAction?("ollama")
            }
            choice(.none, "Without AI", found: true, badge: nil,
                   pros: "Transcripts, speakers, tasks and search still work. The prompter shows your prepared answers.", cons: "No written summary or new answers.") {
                model.config.provider = .none; model.saveConfig()
            }
        }
        .onAppear { ai.refresh() }
    }

    func choice(_ kind: ProviderKind, _ title: String, found: Bool, badge: String?, pros: String, cons: String, action: @escaping () -> Void) -> some View {
        let on = model.config.provider == kind
        return Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 18)).foregroundStyle(on ? Theme.indigo : Theme.ink3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        if let badge { Pill(text: badge, fg: Theme.indigo, bg: Theme.indigoSoft) }
                        if found && kind != .none { Pill(text: "Found on this Mac", fg: Theme.ok, bg: Theme.okSoft) }
                    }
                    Text("+ " + pros).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    Text("– " + cons).font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                    if (kind == .codexCLI || kind == .openAICompatible) && !on {
                        Text("Opens a short setup guide →").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.indigo)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.indigoSoft : Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.indigo : Theme.line, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(RowStyle(radius: 12))
    }
}

// MARK: - Codex guide

final class CodexGuideState: ObservableObject {
    static let shared = CodexGuideState()
    @Published var installed = false
    @Published var loggedIn = false
    @Published var loginRunning = false
    @Published var testResult = ""
    var hasNpm: Bool { Shell.which("npm") != nil }
    var hasBrew: Bool { Shell.which("brew") != nil }

    func refresh() {
        DispatchQueue.global().async {
            let exe = Shell.which("codex")
            var li = false
            if let exe, let r = try? Shell.run(exe, ["login", "status"], timeout: 15) { li = (r.stdout + r.stderr).lowercased().contains("logged in") }
            DispatchQueue.main.async { self.installed = exe != nil; self.loggedIn = li }
        }
    }

    /// `codex login` opens the browser and waits for the sign-in; we poll its status.
    func login() {
        guard let exe = Shell.which("codex"), !loginRunning else { return }
        loginRunning = true
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["login"]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        p.terminationHandler = { _ in DispatchQueue.main.async { self.loginRunning = false; self.refresh() } }
        do { try p.run() } catch { loginRunning = false }
    }
}

struct CodexGuideView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st = CodexGuideState.shared
    var inUse: Bool { model.config.provider == .codexCLI }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Free AI with ").font(Theme.serif(34)) + Text("ChatGPT").font(Theme.serif(34, italic: true)))
            Text("Hush can use OpenAI's Codex with a free ChatGPT account. No API key: Hush uses the Codex login on this Mac. Transcript text goes to OpenAI when Hush summarizes or answers.")
                .font(.system(size: 14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            step(1, st.installed, "Install Codex", st.installed ? "Installed." : "A small free command-line tool from OpenAI. Run one of these in Terminal:") {
                if !st.installed {
                    if st.hasNpm { copyButton("npm i -g @openai/codex") }
                    if st.hasBrew { copyButton("brew install --cask codex") }
                }
            }
            step(2, st.loggedIn, "Sign in with your ChatGPT account", st.loggedIn ? "Signed in." : st.loginRunning ? "Finish signing in in your browser…" : "Opens your browser. A free account is fine.") {
                if st.installed && !st.loggedIn { Button(st.loginRunning ? "Waiting…" : "Sign in") { st.login() }.buttonStyle(FilledButton(bg: Theme.indigo)).disabled(st.loginRunning) }
            }
            step(3, inUse && st.testResult.hasPrefix("Works"), "Use it in Hush", st.testResult.isEmpty ? "Switches Hush's AI to Codex and runs a short test." : st.testResult) {
                if st.loggedIn { Button("Use Codex") { use() }.buttonStyle(FilledButton(bg: Theme.ink)) }
            }
            Text("Free accounts can use the gpt-6-luna model; Hush switches to it by itself if your plan refuses another model. OpenAI does not publish the Free plan's limits.")
                .font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Check again") { st.refresh() }.buttonStyle(OutlineButton()) }
        }
        .padding(32).frame(width: 580).background(Theme.panel).tint(Theme.indigo)
        .onAppear { st.refresh() }
    }

    func copyButton(_ cmd: String) -> some View {
        Button("Copy: \(cmd)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) }.buttonStyle(OutlineButton())
    }

    func use() {
        model.config.provider = .codexCLI; model.saveConfig()
        st.testResult = "Testing…"
        let cfg = model.config
        DispatchQueue.global().async {
            let t0 = Date(); let r: String
            if let p = AI.provider(cfg) {
                do { let a = try p.complete(system: "Reply with one short sentence.", user: "Say hello in Indonesian.", fast: true)
                     r = String(format: "Works: answered in %.1f s (“%@”).", Date().timeIntervalSince(t0), String(a.prefix(60))) }
                catch { r = "Test failed: \(error)" }
            } else { r = "No provider." }
            DispatchQueue.main.async { st.testResult = r }
        }
    }

    func step<B: View>(_ n: Int, _ done: Bool, _ title: String, _ detail: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Theme.ok : Theme.chip).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) { buttons() }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}

// MARK: - answers file template

enum AnswersTemplate {
    static let text = """
    # My prepared answers for Hush

    Hush's prompter searches this file when someone asks you a question, with or without AI.
    Write short answers under each heading. Delete what you don't need. Indonesian or English are both fine.

    # About me
    Name, role, company. What I do in one or two sentences.

    # My experience
    The 2-3 results I am proud of, with numbers if possible.

    # Strengths
    What I do best, with one example.

    # Weaknesses
    One honest weakness and what I do about it.

    # Why this role / why us
    Why I want this, in two sentences.

    # Our product or service
    What it is, who it is for, the main benefit.

    # Price and budget
    Prices, packages, what is included.

    # Timeline
    How long things usually take, and the next steps.

    # How we measure success
    The numbers we report and how often.

    # Questions I want to ask
    Questions I can ask at the end of a meeting or interview.
    """

    /// Creates ~/Documents/Hush/My answers.md (if missing), selects it in Settings, opens it in the default editor.
    static func createAndOpen(_ model: AppModel) {
        if !model.config.contextFile.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: (model.config.contextFile as NSString).expandingTildeInPath)); return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Hush")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("My answers.md")
        if !FileManager.default.fileExists(atPath: f.path) { try? text.write(to: f, atomically: true, encoding: .utf8) }
        model.config.contextFile = f.path; model.saveConfig()
        NSWorkspace.shared.open(f)
    }
}
