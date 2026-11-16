import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(AppDelegate.model)
        } label: {
            MenuBarIcon().environmentObject(AppDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Hush", id: "library") { LibraryView().environmentObject(AppDelegate.model) }
        Window("Hush Live", id: "live") { LiveWindow().environmentObject(AppDelegate.model) }
            .defaultSize(width: 640, height: 780)
        Window("Set up Hush", id: "setup") { SetupView().environmentObject(AppDelegate.model) }
            .windowResizability(.contentSize)
        Window("Hush Settings", id: "settings") { SettingsView().environmentObject(AppDelegate.model) }
            .windowResizability(.contentSize)
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Image(nsImage: MenuBarGlyph.image(recording: model.isRecording))
            .onAppear {
                model.openWindowAction = { id in openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
                if !model.config.setupDone && !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.openWindowAction?("setup") }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        Theme.registerFonts()
        NSApp.setActivationPolicy(.accessory)
        let m = Self.model
        let mods = controlKey | optionKey
        Hotkeys.shared.register(keyCode: kVK_ANSI_H, modifiers: mods) { m.togglePrompter() }
        Hotkeys.shared.register(keyCode: kVK_ANSI_A, modifiers: mods) { m.answerLastQuestion() }
        Hotkeys.shared.register(keyCode: kVK_ANSI_R, modifiers: mods) { m.toggleRecording() }
        recoverInterrupted()
        TestHooks.run(Self.model, CommandLine.arguments)
    }

    func applicationWillTerminate(_ n: Notification) {
        if Self.model.isRecording { _ = Self.model.stopRecording() }
        WhisperServer.shared.stop()
    }

    /// A crash mid-recording leaves status .recording with valid WAVs (headers are rewritten on every write).
    private func recoverInterrupted() {
        for var m in Store.all() where m.status == .recording || m.status == .processing {
            m.status = .recorded; m.error = "Recovered after Hush quit during recording or processing."
            try? Store.save(m)
        }
        Self.model.reload()
    }
}

/// Command-line hooks for automated QA (only active when these flags are passed):
///   --show-prompter <seconds> "<text>"      show the prompter with text, then quit
///   --record <seconds> [call|room] [title]  record headlessly, process, quit
///   --simulate <wav> [seconds]              feed a WAV through the live path → prompter; logs answer latency
///   --verify-hidden                         run the prompter screen-capture self-test, exit 0 if hidden
enum TestHooks {
    static func run(_ m: AppModel, _ argv: [String]) {
        Log.echo = argv.contains("--verbose")
        if let i = argv.firstIndex(of: "--show-prompter"), i + 2 < argv.count {
            m.prompterQuestion = "Test question"; m.prompterAnswer = argv[i + 2]; m.prompterStatus = "QA"
            m.showPrompter()
            if let n = m.prompterWindowNumber { print("PROMPTER_WINDOW \(n)"); fflush(stdout) }
            quit(after: Double(argv[i + 1]) ?? 10)
        }
        if argv.contains("--demo") { demo(m); if argv.contains("--prompter") { m.showPrompter() } }
        if let i = argv.firstIndex(of: "--open"), i + 1 < argv.count {
            let id = argv[i + 1]
            if let j = argv.firstIndex(of: "--select"), j + 1 < argv.count { m.libSelection = argv[j + 1] }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { m.openWindowAction?(id) }
        }
        if argv.contains("--verify-hidden") {
            m.prompterQuestion = "Self-test"; m.prompterAnswer = "Hush prompter self-test: this text must not appear in screen captures."
            m.checkPrompterHidden { r in
                print("VERIFY_HIDDEN \(m.hiddenCheck ?? "no result")")
                fflush(stdout); exit(r?.hidden == true && r?.valid == true ? 0 : 1)
            }
        }
        if let i = argv.firstIndex(of: "--record"), i + 1 < argv.count {
            let secs = Double(argv[i + 1]) ?? 20
            let mode = Recorder.Mode(rawValue: argv.count > i + 2 ? argv[i + 2] : "call") ?? .call
            let title = argv.count > i + 3 ? argv[i + 3] : "QA live capture"
            m.startRecording(mode: mode, title: title)
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                for l in m.liveLines { print("LIVE \(String(format: "%.1f", l.t)) \(l.who): \(l.text)") }
                m.stopRecording()
                waitIdle(m)
            }
        }
        if let i = argv.firstIndex(of: "--simulate"), i + 1 < argv.count {
            let url = URL(fileURLWithPath: argv[i + 1])
            let secs = argv.count > i + 2 ? Double(argv[i + 2]) ?? 120 : 120
            var marks: [(String, Date)] = []
            NotificationCenter.default.addObserver(forName: .hushAnswerShown, object: nil, queue: .main) { n in
                print(String(format: "ANSWER %.2f s after question line | Q: %@ | A: %@", n.object as? Double ?? -1,
                             m.prompterQuestion ?? "", m.prompterAnswer.replacingOccurrences(of: "\n", with: " ")))
                fflush(stdout)
            }
            _ = marks
            m.simulate(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                for l in m.liveLines { print("LIVE \(String(format: "%.1f", l.t)) \(l.who): \(l.text)") }
                exit(0)
            }
            marks.append(("start", Date()))
        }
    }

    /// Fills the live state with sample lines so the live window and prompter can be screenshotted in QA.
    static func demo(_ m: AppModel) {
        m.liveTitle = "Campaign kickoff"
        for (who, t) in [("them", "Budget kita 45 juta per bulan, sekitar 60% untuk iklan berbayar."), ("them", "That split works for us."),
                         ("them", "How do you measure success?"), ("them", "What is your timeline for the first campaign?"),
                         ("me", "5 Januari masih realistis. Minggu depan kita finalisasi strategi.")] {
            m.addLiveForDemo(LiveLine(t: 0, who: who, text: t))
        }
        m.catchUp = ["Budget agreed: Rp45 juta a month, about 60% for ads.", "Daniel asked for the timeline. You said 5 January.", "New task: Rina sends the revised proposal by Fri 21 Nov."]
        m.prompterQuestion = "What is your timeline for the first campaign?"
        m.prompterAskedAt = Date().addingTimeInterval(-4)
        m.prompterAnswer = "Launch on 5 January is realistic. Strategy is final next week, content is ready by end of December."
        m.prompterStatus = "Answered in 5.0 s · claude-cli"
    }

    static func waitIdle(_ m: AppModel) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if m.busy.isEmpty {
                t.invalidate()
                if let latest = Store.all().first { print("MEETING \(Store.folder(latest.id).path)") }
                if let e = m.lastError { print("ERROR \(e)") }
                fflush(stdout); exit(0)
            }
        }
    }

    static func quit(after s: Double) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) } }
}
