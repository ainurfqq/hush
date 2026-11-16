import SwiftUI
import AppKit

/// "Use free AI on this Mac": a 4-step guide to Ollama with live status for each step.
/// Model picks come from ollama.com/library/qwen2.5 (checked 2026-11-16): 3b = 1.9 GB (Qwen license), 7b = 4.7 GB (Apache 2.0).
final class OllamaGuideState: ObservableObject {
    static let shared = OllamaGuideState()
    @Published var installed = false
    @Published var running = false
    @Published var models: [String] = []
    @Published var pulling = false
    @Published var pullLine = ""
    @Published var testResult = ""

    let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    var recommended: (tag: String, size: String, note: String) {
        ramGB >= 16 ? ("qwen2.5:7b", "4.7 GB", "Good for summaries and live answers on your \(ramGB) GB Mac.")
                    : ("qwen2.5:3b", "1.9 GB", "Your Mac has \(ramGB) GB of memory. This small model is fine for summaries after the meeting. For live answers Hush keeps using your notes file, because a local AI next to live speech-to-text is too slow on \(ramGB) GB.")
    }
    var ollamaPath: String? { Shell.which("ollama") ?? (FileManager.default.fileExists(atPath: "/Applications/Ollama.app/Contents/Resources/ollama") ? "/Applications/Ollama.app/Contents/Resources/ollama" : nil) }
    var hasModel: Bool { models.contains { $0.hasPrefix(recommended.tag) } }

    func refresh() {
        DispatchQueue.global().async {
            let inst = self.ollamaPath != nil || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!); req.timeoutInterval = 1.5
            var run = false, names: [String] = []
            if let (d, s) = try? HTTP.send(req), s == 200 {
                run = true
                names = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            }
            DispatchQueue.main.async { self.installed = inst; self.running = run; self.models = names }
        }
    }

    func start() {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
        } else if let exe = ollamaPath {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["serve"]
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null"); p.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? p.run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }

    func pull() {
        guard let exe = ollamaPath, !pulling else { return }
        pulling = true; pullLine = "Starting download…"
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["pull", recommended.tag]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            // ollama redraws its progress line with \r; keep the newest readable part
            let last = s.components(separatedBy: CharacterSet(charactersIn: "\r\n")).map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }?.replacingOccurrences(of: "\u{1B}[?25l", with: "").replacingOccurrences(of: "\u{1B}[?25h", with: "")
            if let last { DispatchQueue.main.async { self.pullLine = String(last.suffix(90)) } }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.pulling = false
                self.pullLine = proc.terminationStatus == 0 ? "Downloaded \(self.recommended.tag)." : "Download failed (exit \(proc.terminationStatus)). Check the internet connection and try again."
                self.refresh()
            }
        }
        do { try p.run() } catch { pulling = false; pullLine = "Could not start ollama: \(error.localizedDescription)" }
    }
}

struct OllamaGuideView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st = OllamaGuideState.shared

    var inUse: Bool { model.config.provider == .openAICompatible && model.config.openAIBaseURL.contains("11434") && model.config.model.hasPrefix(st.recommended.tag) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Free AI ").font(Theme.serif(36)) + Text("on this Mac").font(Theme.serif(36, italic: true)))
            Text("Ollama runs an AI model on your Mac. No account, no subscription, nothing leaves the Mac. Hush uses it for summaries, and on Macs with 16 GB or more also for live answers.")
                .font(.system(size: 14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)

            step(1, done: st.installed, title: "Install Ollama", detail: st.installed ? "Installed." : "Free download from ollama.com (about 200 MB).") {
                if !st.installed {
                    Button("Download Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }.buttonStyle(FilledButton(bg: Theme.indigo))
                    if Shell.which("brew") != nil {
                        Button("Copy: brew install ollama") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install ollama", forType: .string) }
                            .buttonStyle(OutlineButton())
                    }
                }
            }
            step(2, done: st.running, title: "Start Ollama", detail: st.running ? "Running." : "It runs in the background after you open it once.") {
                if st.installed && !st.running { Button("Start Ollama") { st.start() }.buttonStyle(FilledButton(bg: Theme.indigo)) }
            }
            step(3, done: st.hasModel, title: "Download a model: \(st.recommended.tag) (\(st.recommended.size))", detail: st.pulling || !st.pullLine.isEmpty ? st.pullLine : st.recommended.note) {
                if st.running && !st.hasModel {
                    Button(st.pulling ? "Downloading…" : "Download") { st.pull() }.buttonStyle(FilledButton(bg: Theme.indigo)).disabled(st.pulling)
                }
            }
            step(4, done: inUse, title: "Use it in Hush", detail: inUse ? (st.testResult.isEmpty ? "Hush uses Ollama now." : st.testResult) : "Switches Hush's AI to Ollama and runs a short test.") {
                if st.hasModel && !inUse {
                    Button("Use Ollama") { useOllama() }.buttonStyle(FilledButton(bg: Theme.ink))
                }
            }

            Text("Want better answers? Claude Code or an API key gives stronger summaries. You can switch any time in Settings → AI provider.")
                .font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Check again") { st.refresh() }.buttonStyle(OutlineButton()) }
        }
        .padding(32).frame(width: 580).background(Theme.panel).tint(Theme.indigo)
        .onAppear { st.refresh() }
    }

    func useOllama() {
        model.config.provider = .openAICompatible
        model.config.openAIBaseURL = "http://127.0.0.1:11434/v1"
        model.config.model = st.recommended.tag
        // On small Macs keep live answers on the notes file (no local AI next to live speech-to-text).
        model.config.prompterProvider = st.ramGB >= 16 ? nil : ProviderKind.none
        model.saveConfig()
        st.testResult = "Testing…"
        let cfg = model.config
        DispatchQueue.global().async {
            let t0 = Date()
            let r: String
            if let p = AI.provider(cfg) {
                do { let a = try p.complete(system: "Reply with one short sentence.", user: "Say hello in Indonesian.", fast: false)
                     r = String(format: "Works: answered in %.1f s (“%@”).", Date().timeIntervalSince(t0), String(a.prefix(60))) }
                catch { r = "Test failed: \(error)" }
            } else { r = "No provider." }
            DispatchQueue.main.async { st.testResult = r }
        }
    }

    func step<B: View>(_ n: Int, done: Bool, title: String, detail: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Theme.ok : Theme.chip).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}
