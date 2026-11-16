import SwiftUI
import AppKit

// MARK: menu bar

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRecording {
                HStack {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("Recording \(model.recordingMode == .call ? "call" : "room") · \(formatTime(model.elapsed))").font(.headline)
                }
                LevelRow(label: "Mic (you)", level: model.micLevel)
                if model.recordingMode == .call { LevelRow(label: "Call audio", level: model.sysLevel) }
                if model.silentWarning {
                    Label("Hush hears nothing for 30 s. Check the mic and the call audio.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                if let last = model.liveLines.last {
                    Text("\(last.who == "me" ? "You" : "Them"): \(last.text)").font(.caption).lineLimit(3).foregroundStyle(.secondary)
                }
                Button("Stop and make notes") { model.stopRecording() }.keyboardShortcut(.defaultAction)
            } else {
                Text("Hush").font(.headline)
                Button("Record online meeting (mic + call audio)") { model.startRecording(mode: .call) }
                Button("Record in-room meeting (mic only)") { model.startRecording(mode: .room) }
                Button("Import audio file…") { model.importAudio() }
            }
            Divider()
            Button(model.prompterVisible ? "Hide prompter  ⌃⌥H" : "Show prompter  ⌃⌥H") { model.togglePrompter() }
            Button("Check prompter is hidden from screen capture") { model.checkPrompterHidden() }
            if let h = model.hiddenCheck { Text(h).font(.caption).foregroundStyle(h.hasPrefix("Hidden") ? .green : .orange).lineLimit(4) }
            Button("Copy consent message") { model.copyConsent() }
            Button("Open Hush") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
            Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
            if let e = model.lastError {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(4)
                Button("Dismiss") { model.lastError = nil }.font(.caption)
            }
            Divider()
            Button("Quit Hush") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct LevelRow: View {
    let label: String; let level: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 80, alignment: .leading)
            ProgressView(value: Double(min(1, level * 8))).tint(level > 0.01 ? .green : .gray)
        }
    }
}

// MARK: library

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var filtered: [Meeting] {
        model.libQuery.isEmpty ? model.meetings : Store.search(model.libQuery, in: model.meetings).map(\.meeting)
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, id: \.id, selection: $model.libSelection) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).lineLimit(1)
                    HStack {
                        Text(m.createdAt, style: .date); Text(formatTime(m.duration))
                        if let b = model.busy[m.id] { Text(b).foregroundStyle(.orange) }
                        else if m.status != .ready { Text(m.status.rawValue).foregroundStyle(.secondary) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $model.libQuery, prompt: "Search meetings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem { Button { model.importAudio() } label: { Label("Import", systemImage: "square.and.arrow.down") } }
                ToolbarItem { Button { model.toggleRecording() } label: { Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.circle.fill" : "record.circle") } }
            }
        } detail: {
            if model.isRecording && model.libSelection == nil { LiveView() }
            else if let id = model.libSelection, let m = model.meetings.first(where: { $0.id == id }) { MeetingDetail(st: model.detailState(m)).id(m.id) }
            else { Text(model.meetings.isEmpty ? "No meetings yet. Record one from the menu bar, or import an audio file." : "Pick a meeting.")
                .foregroundStyle(.secondary) }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { model.reload() }
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            List(model.liveLines) { l in
                HStack(alignment: .top) {
                    Text(l.who == "me" ? "You" : "Them").bold().frame(width: 44, alignment: .leading)
                    Text(l.text).textSelection(.enabled)
                }.id(l.id)
            }
            .onChange(of: model.liveLines.count) { _ in if let last = model.liveLines.last { proxy.scrollTo(last.id) } }
        }
        .navigationTitle("Live · \(formatTime(model.elapsed))")
    }
}

final class DetailState: ObservableObject {
    @Published var meeting: Meeting
    @Published var tab = 0
    init(_ m: Meeting) { meeting = m }
}

struct MeetingDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: DetailState
    var meeting: Meeting { st.meeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Title", text: $st.meeting.title, onCommit: { model.save(meeting) }).font(.title2).textFieldStyle(.plain)
                Spacer()
                if let b = model.busy[meeting.id] { ProgressView().controlSize(.small); Text(b).font(.caption) }
                Menu {
                    Button("Transcribe again") { model.process(meeting.id) }
                    Button("Summarize again with \(model.config.provider.label)") { model.summarize(meeting.id) }
                    Button("Export Markdown…") { model.export(meeting) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.folder(meeting.id)]) }
                    Divider()
                    Button("Delete meeting", role: .destructive) { model.delete(meeting.id) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 40)
            }.padding()
            Picker("", selection: $st.tab) { Text("Summary").tag(0); Text("Transcript").tag(1); Text("Action items").tag(2); Text("Speakers").tag(3) }
                .pickerStyle(.segmented).padding(.horizontal)
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch st.tab {
                    case 0: summaryTab
                    case 1: transcriptTab
                    case 2: actionsTab
                    default: speakersTab
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.meetings) { ms in if let fresh = ms.first(where: { $0.id == st.meeting.id }) { st.meeting = fresh } }
    }

    @ViewBuilder var summaryTab: some View {
        if let s = meeting.summary {
            Text(s.summary).textSelection(.enabled)
            if !s.decisions.isEmpty {
                Text("Decisions").font(.headline).padding(.top, 6)
                ForEach(s.decisions, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
            if !s.openQuestions.isEmpty {
                Text("Open questions").font(.headline).padding(.top, 6)
                ForEach(s.openQuestions, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
            Text("By \(s.provider)").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        } else if meeting.segments.isEmpty {
            Text(meeting.status == .failed ? "Processing failed: \(meeting.error ?? "")" : "Not transcribed yet.").foregroundStyle(.secondary)
            Button("Transcribe now") { model.process(meeting.id) }
        } else {
            Button("Summarize with \(model.config.provider.label)") { model.summarize(meeting.id) }
        }
    }

    @ViewBuilder var transcriptTab: some View {
        ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, s in
            HStack(alignment: .top, spacing: 10) {
                Text(formatTime(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                Text(meeting.displayName(s.speaker)).bold().frame(width: 90, alignment: .leading)
                Text(s.text).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder var actionsTab: some View {
        let items = meeting.summary?.actionItems ?? []
        if items.isEmpty { Text("No action items found.").foregroundStyle(.secondary) }
        ForEach(Array(items.enumerated()), id: \.offset) { i, a in
            Toggle(isOn: Binding(get: { a.done }, set: { v in st.meeting.summary?.actionItems[i].done = v; model.save(st.meeting) })) {
                VStack(alignment: .leading) {
                    Text(a.task)
                    Text("\(a.owner ?? "Unassigned")\(a.due.map { " · due \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder var speakersTab: some View {
        Text("Give speakers real names. Transcript, summary export and MCP use these names.").foregroundStyle(.secondary)
        ForEach(meeting.speakers, id: \.self) { spk in
            HStack {
                Text(spk == "me" ? "Me" : spk.replacingOccurrences(of: "spk", with: "Speaker ")).frame(width: 90, alignment: .leading)
                TextField("Name", text: Binding(get: { meeting.speakerNames[spk] ?? "" }, set: { st.meeting.speakerNames[spk] = $0 }),
                          onCommit: { model.save(meeting) })
                Text("\(meeting.segments.filter { $0.speaker == spk }.count) turns").font(.caption).foregroundStyle(.secondary)
            }
        }
        Button("Save names") { model.save(meeting) }
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var apiKey: String { model.settingsKey }

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $model.config.provider) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Model (empty = default)", text: $model.config.model)
                TextField("Faster model for the prompter (optional)", text: $model.config.prompterModel)
                if model.config.provider == .openAICompatible {
                    TextField("Base URL", text: $model.config.openAIBaseURL)
                }
                if model.config.provider == .claudeCLI { TextField("claude path (empty = auto)", text: $model.config.claudePath) }
                if model.config.provider == .codexCLI { TextField("codex path (empty = auto)", text: $model.config.codexPath) }
                if model.config.provider == .openAICompatible || model.config.provider == .anthropic {
                    SecureField("API key (stored in Keychain)", text: $model.settingsKey)
                    Button("Save key") { Keychain.set(model.config.provider == .anthropic ? "anthropic" : "openai", apiKey); model.settingsKey = ""; model.settingsTest = "Key saved to Keychain." }
                }
                HStack {
                    Button("Test") { test() }
                    Text(model.settingsTest).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("Only transcript text you summarize or ask about is sent to this provider. Audio never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Prompter") {
                Picker("Prompter AI", selection: $model.config.prompterProvider) {
                    Text("Same as summaries").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases.filter { $0 != .none }, id: \.self) { Text($0.label).tag(ProviderKind?.some($0)) }
                }
                Text("Tip: a local Ollama model answers in about 2 s; Claude Code CLI in about 5-7 s but writes better answers.").font(.caption).foregroundStyle(.secondary)
                Toggle("Answer questions from others automatically", isOn: $model.config.prompterAutoAnswer)
                Slider(value: Binding(get: { model.config.prompterOpacity }, set: { model.setOpacity($0) }), in: 0.3...1) { Text("Opacity") }
                TextField("Your name", text: $model.config.userName)
                HStack {
                    TextField("Context notes file (CV, product facts…)", text: $model.config.contextFile)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.plainText, .text]
                        if p.runModal() == .OK, let u = p.url { model.config.contextFile = u.path }
                    }
                }
                Text("⌃⌥H show/hide · ⌃⌥A answer last question · ⌃⌥R start/stop recording").font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription (on this Mac)") {
                Picker("Model", selection: $model.config.asrModel) {
                    Text("Large v3 turbo (best, 574 MB)").tag("ggml-large-v3-turbo-q5_0.bin")
                    Text("Small (faster, 190 MB; run `hush setup` with HUSH_SMALL_MODEL=1)").tag("ggml-small-q5_1.bin")
                }
                Picker("Language", selection: $model.config.language) {
                    Text("Auto (Indonesian + English mix)").tag("auto"); Text("Indonesian").tag("id"); Text("English").tag("en")
                }
                Text("Meetings are stored in \(Paths.meetings.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Consent") {
                Text(AppModel.consentMessage).font(.callout)
                Button("Copy consent message") { model.copyConsent() }
                Text("You are responsible for telling people they are being recorded and for following the rules of each meeting, interview or exam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Save") { model.saveConfig() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .onDisappear { model.saveConfig() }
    }

    func test() {
        model.saveConfig()
        model.settingsTest = "Testing…"
        let cfg = model.config
        DispatchQueue.global().async {
            let r: String
            if let p = AI.provider(cfg) {
                let t0 = Date()
                do { let a = try p.complete(system: "Reply with one short sentence.", user: "Say hello in Indonesian.", fast: true)
                     r = String(format: "OK in %.1f s: %@", Date().timeIntervalSince(t0), a) }
                catch { r = "Failed: \(error)" }
            } else { r = "No provider: summaries use local rules." }
            DispatchQueue.main.async { model.settingsTest = r }
        }
    }
}
