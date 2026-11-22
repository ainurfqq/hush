import SwiftUI
import AppKit

/// "Free Google Gemini": get a free key in Google AI Studio, paste it, switch Hush to Gemini and run a short test.
final class GeminiGuideState: ObservableObject {
    static let shared = GeminiGuideState()
    @Published var key = ""
    @Published var hasKey = false   // read in refresh(), off the main thread: a Keychain prompt must not block launch
    func refresh() { DispatchQueue.global().async { let h = Keychain.get("gemini") != nil; DispatchQueue.main.async { self.hasKey = h } } }
    @Published var testResult = ""
}

struct GeminiGuideView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st = GeminiGuideState.shared
    var inUse: Bool { model.config.provider == .gemini }

    static let privacyNote = "Free tier: Google may use the text Hush sends (meeting transcripts, your notes file) to improve its products. A paid Gemini key does not. Audio never leaves your Mac. For fully private AI, use Ollama."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Free AI with ").font(Theme.serif(34)) + Text("Gemini").font(Theme.serif(34, italic: true)))
            Text("Google gives a free API key in AI Studio. Hush uses it for summaries and live answers. Answers stream in, so the prompter shows the first words quickly.")
                .font(.system(size: 14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.ink2)
                Text(Self.privacyNote).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))

            step(1, st.hasKey, "Get a free API key", st.hasKey ? "Key saved in the macOS Keychain." : "Sign in with a Google account, click “Create API key”, then copy it.") {
                if !st.hasKey { Button("Open Google AI Studio") { NSWorkspace.shared.open(URL(string: Gemini.keyPage)!) }.buttonStyle(FilledButton(bg: Theme.indigo)) }
            }
            step(2, st.hasKey, "Paste the key", "Hush keeps it in the macOS Keychain, never in a file.") {
                HStack {
                    SecureField("API key", text: $st.key).textFieldStyle(.roundedBorder).frame(width: 300)
                    Button("Save key") { Keychain.set("gemini", st.key.trimmingCharacters(in: .whitespacesAndNewlines)); st.key = ""; st.hasKey = Keychain.get("gemini") != nil }
                        .buttonStyle(OutlineButton()).disabled(st.key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            step(3, inUse && st.testResult.hasPrefix("Works"), "Use it in Hush", st.testResult.isEmpty ? "Switches Hush's AI to Gemini (\(Gemini.defaultModel)) and runs a short test." : st.testResult) {
                if st.hasKey { Button("Use Gemini") { use() }.buttonStyle(FilledButton(bg: Theme.ink)) }
            }
            Text("Google shows your free limits in AI Studio. When a limit is reached, Hush falls back to your notes file for live answers.")
                .font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(32).frame(width: 580).background(Theme.panel).tint(Theme.indigo)
        .onAppear { st.refresh() }
    }

    func use() {
        model.config.provider = .gemini
        model.config.model = Gemini.defaultModel
        model.config.prompterProvider = nil; model.config.prompterModel = ""
        model.saveConfig()
        st.testResult = "Testing…"
        let cfg = model.config
        DispatchQueue.global().async {
            let t0 = Date(); let r: String
            if let p = AI.provider(cfg) {
                do { let a = try p.complete(system: "Reply with one short sentence.", user: "Say hello in Indonesian.", fast: true)
                     r = String(format: "Works: answered in %.1f s (“%@”).", Date().timeIntervalSince(t0), String(a.prefix(60))) }
                catch { r = "Test failed: \(error)" }
            } else { r = "No provider." }
            DispatchQueue.main.async { GeminiGuideState.shared.testResult = r }
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
