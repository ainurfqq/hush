import SwiftUI
import AppKit
import AVFoundation

// MARK: menu bar popover

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @ObservedObject var flash = MenuRowFlash.shared
    var copied: Bool { flash.on }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isRecording { recording } else { idle }
            if let e = model.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e).font(.caption).foregroundStyle(Theme.rec).lineLimit(4)
                    Button("Dismiss") { model.lastError = nil }.buttonStyle(LinkStyle()).font(.caption)
                }
            }
            Divider()
            VStack(spacing: 0) {
                MenuRow(icon: "doc.text", title: "Open notes", shortcut: "⌘O") { open("library") }
                    .keyboardShortcut("o", modifiers: .command)
                MenuRow(icon: "doc.on.clipboard", title: copied ? "Consent message copied" : "Copy consent message", shortcut: nil) {
                    model.copyConsent(); MenuRowFlash.shared.flash()
                }
                MenuRow(icon: "gearshape", title: "Settings…", shortcut: "⌘,") { open("settings") }
                    .keyboardShortcut(",", modifiers: .command)
                Divider().padding(.vertical, 4)
                MenuRow(icon: "power", title: "Quit Hush", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, -8)
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.panel)
        .tint(Theme.indigo)
        .onAppear { model.openWindowAction = { id in openWindow(id: id); NSApp.activate(ignoringOtherApps: true) } }
    }

    func open(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }

    @ViewBuilder var idle: some View {
        HStack(spacing: 10) {
            HushGlyph.onLight.frame(width: 30, height: 27)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hush").font(.system(size: 16, weight: .semibold)).kerning(-0.3)
                Text("Ready · AI: \(model.config.provider.label.components(separatedBy: " (").first ?? "")")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer()
            Pill(text: "On this Mac", fg: Theme.ok, bg: Theme.okSoft)
        }
        HStack(spacing: 4) {
            SegmentButton(title: "Online call", on: model.recordingMode == .call) { model.recordingMode = .call }
            SegmentButton(title: "In the room", on: model.recordingMode == .room) { model.recordingMode = .room }
        }
        .padding(3).background(Theme.chip, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain).accessibilityLabel("Recording mode")
        Text(model.recordingMode == .call ? "Hears your mic as \"Me\" and the call as everyone else. No bot joins."
                                          : "Uses the mic only and tells the voices in the room apart.")
            .font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        Button { model.startRecording(mode: model.recordingMode) } label: {
            HStack(spacing: 8) { Circle().fill(.white).frame(width: 10, height: 10); Text("Start recording"); Text("⌃⌥R").opacity(0.8).font(.system(size: 12)) }
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(FilledButton(bg: Theme.indigo))
        Button { model.importAudio() } label: { Text("Import an audio file…").frame(maxWidth: .infinity, minHeight: 36) }
            .buttonStyle(OutlineButton())
        Divider()
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Button { model.togglePrompter() } label: {
                    Text("Prompter ").font(.system(size: 13, weight: .semibold)) + Text(model.prompterVisible ? "on · ⌃⌥H" : "off · ⌃⌥H").font(.system(size: 13)).foregroundColor(Theme.ink3)
                }.buttonStyle(LinkStyle(color: Theme.ink))
                hiddenStatus
            }
            Spacer()
            Toggle("Auto-answer", isOn: Binding(get: { model.config.prompterAutoAnswer }, set: { model.config.prompterAutoAnswer = $0; model.saveConfig() }))
                .toggleStyle(.checkbox).font(.system(size: 12))
        }
        let recent = Array(model.meetings.filter { $0.status == .ready }.prefix(3))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.ink3)
                ForEach(recent, id: \.id) { m in
                    Button { model.libSelection = m.id; open("library") } label: {
                        HStack {
                            Text(m.title).font(Theme.serif(17)).lineLimit(1)
                            Spacer()
                            let n = m.summary?.actionItems.count ?? 0
                            Text(formatTime(m.duration) + (n > 0 ? " · \(n) task\(n == 1 ? "" : "s")" : "")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(RowStyle(radius: 6)).padding(.horizontal, -8)
                }
            }
        }
    }

    @ViewBuilder var hiddenStatus: some View {
        let parts = model.config.lastHiddenCheck.split(separator: "|").map(String.init)
        if model.needsScreenPermission {
            HStack(spacing: 6) {
                Text("Needs Screen Recording permission").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                Button("Open Settings") { model.openScreenRecordingSettings() }.buttonStyle(LinkStyle()).font(.system(size: 12))
            }
        } else if let h = model.hiddenCheck {
            Text(h).font(.system(size: 11)).foregroundStyle(h.hasPrefix("Hidden") ? Theme.ok : Theme.rec).lineLimit(3)
        } else if parts.count == 2 {
            HStack(spacing: 6) {
                Text(parts[0] == "hidden" ? "Hidden from screen capture · checked \(parts[1])" : "Last check (\(parts[1])): visible in screen capture")
                    .font(.system(size: 12)).foregroundStyle(parts[0] == "hidden" ? Theme.ok : Theme.rec)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") { model.checkPrompterHidden() }.buttonStyle(LinkStyle()).font(.system(size: 12))
            }
        } else {
            Button("Run screen-share check") { model.checkPrompterHidden() }.buttonStyle(LinkStyle()).font(.system(size: 12))
        }
    }

    @ViewBuilder var recording: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.rec).frame(width: 11, height: 11).overlay(Circle().stroke(Theme.rec.opacity(0.18), lineWidth: 6))
            Text("Recording").font(Theme.serif(22))
            Text(formatTime(model.elapsed)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.ink3)
            Spacer()
            Pill(text: model.recordingMode == .call ? "Online call" : "In the room")
        }
        VStack(alignment: .leading, spacing: 6) {
            LevelRow(label: "You", level: model.micLevel)
            if model.recordingMode == .call { LevelRow(label: "Call audio", level: model.sysLevel) }
            if model.silentWarning {
                Label("Hush hears nothing for 30 s. Check the mic and the call audio.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else {
                Text("Hearing you\(model.recordingMode == .call ? " and the call" : "")").font(.system(size: 12)).foregroundStyle(Theme.ok)
            }
        }
        if let q = model.recentQuestions.last, let qt = q.question {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Pill(text: "Question caught", fg: Theme.indigo, bg: Theme.indigoSoft); Text(ago(q.heardAt)).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
                Text("“\(qt)”").font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.indigoSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        Button { open("live") } label: { Text("Open live window").frame(maxWidth: .infinity, minHeight: 34) }.buttonStyle(OutlineButton())
        Button { model.stopRecording() } label: {
            HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10); Text("Stop and make notes") }
                .frame(maxWidth: .infinity, minHeight: 40)
        }.buttonStyle(FilledButton(bg: Theme.ink))
        Text("Notes in a few minutes, on this Mac").font(.system(size: 12)).foregroundStyle(Theme.ink3).frame(maxWidth: .infinity)
    }
}

struct SegmentButton: View {
    let title: String; let on: Bool; let action: () -> Void
    @StateObject var h = HoverBox()
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: on ? .semibold : .medium)).foregroundStyle(on ? Theme.ink : Theme.ink2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white : (h.on ? Color.white.opacity(0.5) : .clear))
                    .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1))
        }
        .buttonStyle(.plain).tracksHover(h).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Native-feeling menu row: icon, label, right-aligned shortcut, soft hover background.
struct MenuRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer()
                if let s = shortcut { Text(s).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle(radius: 6))
    }
}

/// Brief "copied" confirmation on the consent row.
final class MenuRowFlash: ObservableObject {
    static let shared = MenuRowFlash()
    @Published var on = false
    func flash() { on = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.on = false } }
}

func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    return s < 60 ? "\(max(1, s)) s ago" : "\(s / 60) min ago"
}

struct LevelRow: View {
    let label: String; let level: Float
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2).frame(width: 70, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(level > 0.01 ? Theme.ok : Theme.ink3).frame(width: g.size.width * CGFloat(min(1, level * 8)))
                }
            }.frame(height: 6)
        }
    }
}

// MARK: live meeting window

struct LiveWindow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab = LiveTab.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HushGlyph(dot: model.isRecording ? Theme.rec : Theme.indigo, dotScale: model.isRecording ? 1.35 : 1).frame(width: 24, height: 22)
                Text(model.isRecording ? "Recording" : "Not recording").font(.system(size: 14, weight: .semibold))
                if model.isRecording { Text(formatTime(model.elapsed)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.ink3) }
                Pill(text: model.recordingMode == .call ? "Online call" : "In the room")
                Spacer()
                Button(model.prompterVisible ? "Hide prompter ⌃⌥H" : "Show prompter ⌃⌥H") { model.togglePrompter() }.buttonStyle(OutlineButton()).frame(height: 30)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Meeting title", text: $model.liveTitle).textFieldStyle(.plain).font(Theme.serif(32))
                Text(model.recordingMode == .call ? "You and the call · notes stay on this Mac" : "Everyone in the room · notes stay on this Mac")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 24).padding(.top, 16).frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 22) {
                tabButton("My notes", 0); tabButton("Live transcript", 1)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 10)
            Divider().overlay(Theme.line)

            Group {
                if tab.index == 0 { notes } else { transcript }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.line)
            bottomBar
        }
        .background(Theme.panel)
        .tint(Theme.indigo)
        .frame(minWidth: 560, minHeight: 640)
    }

    func tabButton(_ title: String, _ i: Int) -> some View {
        Button { tab.index = i } label: {
            Text(title).font(.system(size: 14, weight: tab.index == i ? .semibold : .medium))
        }.buttonStyle(TabStyle(selected: tab.index == i))
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type what matters to you. The summary uses your notes as hints.").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            TextEditor(text: $model.liveNotes).font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }.padding(20)
    }

    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.liveLines.isEmpty {
                        Text(model.isRecording ? "Listening… lines appear a few seconds after people speak." : "Start a recording from the menu bar.")
                            .font(.system(size: 14)).foregroundStyle(Theme.ink3).padding(.top, 8)
                    }
                    ForEach(model.liveLines) { l in
                        HStack(alignment: .top, spacing: 12) {
                            Text(l.who == "me" ? "You" : "Them").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(l.who == "me" ? Theme.ink : Theme.rgb(0x7A3E06)).frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l.text).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let q = l.question {
                                    Text(q == model.prompterQuestion ? "Question · answer is on the prompter"
                                         : (model.config.prompterAutoAnswer ? "Question · pick it on the prompter for an answer" : "Question · press ⌃⌥A for an answer"))
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.indigo)
                                }
                            }
                        }
                        .padding(l.question != nil ? 10 : 0)
                        .background(l.question != nil ? Theme.indigoSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .id(l.id)
                    }
                    if model.catchUpBusy || !model.catchUp.isEmpty { catchUpCard.id("catchup") }
                    if model.askBusy || model.askAnswer != nil { askCard.id("ask") }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveLines.count) { _ in if let last = model.liveLines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            .onChange(of: model.catchUp) { _ in withAnimation { proxy.scrollTo("catchup", anchor: .bottom) } }
            .onChange(of: model.askAnswer) { _ in withAnimation { proxy.scrollTo("ask", anchor: .bottom) } }
        }
    }

    var catchUpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("What you ").font(Theme.serif(22)) + Text("missed").font(Theme.serif(22, italic: true))
                Text("last 5 minutes").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                Spacer()
                if !model.catchUpBusy { Button("Close") { model.catchUp = [] }.buttonStyle(LinkStyle()).font(.caption).tint(Theme.indigo) }
            }
            if model.catchUpBusy { ProgressView().controlSize(.small) }
            ForEach(model.catchUp, id: \.self) { b in
                HStack(alignment: .top, spacing: 8) { Text("•"); Text(b).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 14))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rgb(0xF7F6FE), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.rgb(0xE2DFF7)))
    }

    var askCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You asked").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
            if model.askBusy { ProgressView().controlSize(.small) }
            if let a = model.askAnswer { Text(a).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("Tell everyone you are taking notes.").foregroundStyle(Theme.ink3)
                Button("Copy consent message") { model.copyConsent() }.buttonStyle(LinkStyle()).tint(Theme.indigo)
            }.font(.system(size: 12))
            HStack(spacing: 8) {
                if model.isRecording {
                    Button { model.stopRecording() } label: {
                        HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9); Text("Stop") }
                            .padding(.horizontal, 16).frame(minHeight: 40)
                    }.buttonStyle(FilledButton(bg: Theme.ink))
                } else {
                    Button { model.startRecording(mode: model.recordingMode) } label: {
                        HStack(spacing: 8) { Circle().fill(.white).frame(width: 9, height: 9); Text("Record") }.padding(.horizontal, 16).frame(minHeight: 40)
                    }.buttonStyle(FilledButton(bg: Theme.indigo))
                }
                TextField("Ask anything about this meeting", text: $model.askText)
                    .textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 14).frame(minHeight: 40)
                    .background(Color.white, in: Capsule()).overlay(Capsule().stroke(Theme.line))
                    .onSubmit { model.askLive() }
                Button { model.whatDidIMiss(); tab.index = 1 } label: { Text("What did I miss?").padding(.horizontal, 14).frame(minHeight: 40) }
                    .buttonStyle(FilledButton(bg: Theme.indigo)).disabled(model.catchUpBusy)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

final class LiveTab: ObservableObject {
    static let shared = LiveTab()
    @Published var index = 1
}

// MARK: notes window

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var filtered: [Meeting] {
        model.libQuery.isEmpty ? model.meetings : Store.search(model.libQuery, in: model.meetings).map(\.meeting)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            PanelCard {
                Group {
                    if let id = model.libSelection, let m = model.meetings.first(where: { $0.id == id }) { MeetingDetail(st: model.detailState(m)).id(m.id) }
                    else {
                        VStack(spacing: 10) {
                            HushGlyph.onLight.frame(width: 64, height: 58).opacity(0.5)
                            Text(model.meetings.isEmpty ? "No meetings yet" : "Pick a meeting").font(Theme.serif(28))
                            Text("Record one from the menu bar, or import an audio file.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding([.top, .bottom, .trailing], 12)
        }
        .background(Theme.paper)
        .tint(Theme.indigo)
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { model.reload() }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HushGlyph.onLight.frame(width: 28, height: 25)
                Text("Hush").font(.system(size: 17, weight: .semibold)).kerning(-0.3)
                Spacer()
                Button { model.toggleRecording() } label: {
                    Text(model.isRecording ? "■ Stop" : "● Record").padding(.horizontal, 10).frame(minHeight: 30)
                }.buttonStyle(FilledButton(bg: model.isRecording ? Theme.ink : Theme.indigo))
            }
            TextField("Search words, people, tasks", text: $model.libQuery)
                .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10).frame(minHeight: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.0) { g in
                            Text(g.0.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.ink3).padding(.top, 8).padding(.horizontal, 8)
                            ForEach(g.1, id: \.id) { m in row(m).id(m.id) }
                        }
                    }
                }
                .onAppear { if let s = model.libSelection { proxy.scrollTo(s, anchor: .center) } }
                .onChange(of: model.libSelection) { s in if let s { withAnimation { proxy.scrollTo(s, anchor: .center) } } }
            }
            Spacer(minLength: 0)
            HStack {
                Button { model.importAudio() } label: { Label("Import audio", systemImage: "square.and.arrow.down") }.buttonStyle(LinkStyle(color: Theme.ink2))
                Spacer()
            }.font(.system(size: 12))
            let open = model.meetings.reduce(0) { $0 + ($1.summary?.actionItems.filter { !$0.done }.count ?? 0) }
            Text("Open tasks across meetings: \(open)").font(.system(size: 12)).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 18)
    }

    var groups: [(String, [Meeting])] {
        let cal = Calendar.current
        var out: [(String, [Meeting])] = []
        for m in filtered {
            let key = cal.isDateInToday(m.createdAt) ? "Today" : cal.isDateInYesterday(m.createdAt) ? "Yesterday" : {
                let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: m.createdAt) }()
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(m) } else { out.append((key, [m])) }
        }
        return out
    }

    func row(_ m: Meeting) -> some View {
        let selected = model.libSelection == m.id
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return Button { model.libSelection = m.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(Theme.serif(18)).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(f.string(from: m.createdAt)) · \(formatTime(m.duration)) · \(m.speakers.count) speaker\(m.speakers.count == 1 ? "" : "s")")
                    if let b = model.busy[m.id] { Text(b).foregroundStyle(.orange).lineLimit(1) }
                    else if m.status != .ready { Text(m.status.rawValue) }
                }.font(.system(size: 12)).foregroundStyle(Theme.ink3)
                if let b = model.busy[m.id], let pct = Double(b.split(separator: "(").last?.prefix(while: { $0.isNumber }) ?? "") {
                    ProgressView(value: pct / 100).tint(Theme.indigo)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(RowStyle(selected: selected))
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
    let tabs = ["Summary", "Transcript", "Tasks", "My notes", "Speakers"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    TextField("Title", text: $st.meeting.title, axis: .vertical)
                        .lineLimit(1...3).onSubmit { model.save(meeting) }
                        .textFieldStyle(.plain).font(Theme.serif(32))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let b = model.busy[meeting.id] { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(Theme.ink3) }
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Markdown.export(meeting), forType: .string)
                    }.buttonStyle(OutlineButton()).frame(height: 32)
                    Menu {
                        Button("Export Markdown…") { model.export(meeting) }
                        Button("Transcribe again") { model.process(meeting.id) }
                        Button("Summarize again with \(model.config.provider.label)") { model.summarize(meeting.id) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.folder(meeting.id)]) }
                        Divider()
                        Button("Delete meeting", role: .destructive) { model.delete(meeting.id) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 36)
                }
                Text(meta).font(.system(size: 13)).foregroundStyle(Theme.ink3)
                HStack(spacing: 8) {
                    Text("Speakers").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    ForEach(Array(meeting.speakers.enumerated()), id: \.offset) { i, spk in
                        Button { st.tab = 4 } label: {
                            Pill(text: "\(meeting.displayName(spk)) · \(meeting.segments.filter { $0.speaker == spk }.count) ✎",
                                 fg: [Theme.rgb(0x2B2B8A), Theme.rgb(0x7A3E06), Theme.ok, Theme.ink2][i % 4],
                                 bg: [Theme.rgb(0xE6E6FB), Theme.rgb(0xFCEBD9), Theme.okSoft, Theme.chip][i % 4])
                        }.buttonStyle(ChipStyle()).help("Rename speakers")
                    }
                }
                HStack(spacing: 22) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                        Button { st.tab = i } label: {
                            HStack(spacing: 6) {
                                Text(t).font(.system(size: 14, weight: st.tab == i ? .semibold : .medium))
                                if t == "Tasks", let n = meeting.summary?.actionItems.count, n > 0 { Pill(text: "\(n)") }
                            }
                        }.buttonStyle(TabStyle(selected: st.tab == i))
                    }
                }.padding(.top, 6)
            }
            .padding(.horizontal, 32).padding(.top, 24)
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch st.tab {
                    case 0: summaryTab
                    case 1: transcriptTab
                    case 2: actionsTab
                    case 3: notesTab
                    default: speakersTab
                    }
                }.padding(.horizontal, 32).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.meetings) { ms in if let fresh = ms.first(where: { $0.id == st.meeting.id }) { st.meeting = fresh } }
    }

    var meta: String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM · HH:mm"
        let langs = Set(meeting.segments.compactMap(\.language)).sorted().map { $0 == "id" ? "Indonesian" : $0 == "en" ? "English" : $0 }
        return "\(f.string(from: meeting.createdAt)) · \(formatTime(meeting.duration))" + (langs.isEmpty ? "" : " · " + langs.joined(separator: " + "))
            + (meeting.summary.map { " · summary by \($0.provider)" } ?? "")
    }

    func heading(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 12, weight: .bold)).kerning(0.5).foregroundStyle(Theme.ink2).padding(.top, 8)
    }

    @ViewBuilder var summaryTab: some View {
        if let s = meeting.summary {
            Text(s.summary).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
            if !s.decisions.isEmpty { heading("Decisions"); ForEach(s.decisions, id: \.self) { Text("• \($0)").font(.system(size: 14)).textSelection(.enabled) } }
            if !s.openQuestions.isEmpty { heading("Open questions"); ForEach(s.openQuestions, id: \.self) { Text("• \($0)").font(.system(size: 14)).textSelection(.enabled) } }
        } else if meeting.segments.isEmpty {
            Text(meeting.status == .failed ? "Processing failed: \(meeting.error ?? "")" : "Not transcribed yet.").foregroundStyle(Theme.ink3)
            Button("Transcribe now") { model.process(meeting.id) }.buttonStyle(OutlineButton()).frame(width: 160, height: 34)
        } else {
            Button("Summarize with \(model.config.provider.label)") { model.summarize(meeting.id) }.buttonStyle(OutlineButton()).frame(height: 34)
        }
    }

    @ViewBuilder var transcriptTab: some View {
        ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, s in
            HStack(alignment: .top, spacing: 12) {
                Text(formatTime(s.start)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink3).frame(width: 46, alignment: .leading)
                Text(meeting.displayName(s.speaker)).font(.system(size: 13, weight: .semibold)).frame(width: 90, alignment: .leading)
                Text(s.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder var actionsTab: some View {
        let items = meeting.summary?.actionItems ?? []
        if items.isEmpty { Text("No tasks found.").foregroundStyle(Theme.ink3) }
        ForEach(Array(items.enumerated()), id: \.offset) { i, a in
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(get: { a.done }, set: { v in st.meeting.summary?.actionItems[i].done = v; model.save(st.meeting) }))
                    .toggleStyle(.checkbox).labelsHidden()
                VStack(alignment: .leading, spacing: 6) {
                    Text(a.task).font(.system(size: 14)).strikethrough(a.done).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Pill(text: a.owner ?? "Unassigned", fg: Theme.rgb(0x2B2B8A), bg: Theme.rgb(0xE6E6FB))
                        if let d = a.due { Pill(text: d) }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .opacity(a.done ? 0.6 : 1)
        }
        if !items.isEmpty {
            Button("Copy tasks for WhatsApp") {
                let text = items.filter { !$0.done }.map { "• \($0.task) — \($0.owner ?? "?")\($0.due.map { ", \($0)" } ?? "")" }.joined(separator: "\n")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("*\(meeting.title)*\n" + text, forType: .string)
            }.buttonStyle(OutlineButton()).frame(width: 220, height: 34)
        }
    }

    @ViewBuilder var notesTab: some View {
        Text("Your own notes from this meeting. The summary uses them as hints.").font(.system(size: 12)).foregroundStyle(Theme.ink3)
        TextEditor(text: Binding(get: { st.meeting.userNotes ?? "" }, set: { st.meeting.userNotes = $0 }))
            .font(.system(size: 14)).scrollContentBackground(.hidden).frame(minHeight: 220).padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        SaveButton(title: "Save notes", outline: true) { model.save(st.meeting) }.frame(width: 120, height: 32)
    }

    @ViewBuilder var speakersTab: some View {
        Text("Give speakers real names. The transcript, export and MCP use these names.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
        ForEach(meeting.speakers, id: \.self) { spk in
            HStack {
                Text(spk == "me" ? "Me" : spk.replacingOccurrences(of: "spk", with: "Speaker ")).frame(width: 90, alignment: .leading)
                TextField("Name", text: Binding(get: { meeting.speakerNames[spk] ?? "" }, set: { st.meeting.speakerNames[spk] = $0 }),
                          onCommit: { model.save(meeting) })
                Text("\(meeting.segments.filter { $0.speaker == spk }.count) turns").font(.caption).foregroundStyle(Theme.ink3)
            }
        }
        SaveButton(title: "Save names", outline: true) { model.save(meeting) }.frame(width: 120, height: 32)
    }
}

// MARK: first run

final class SetupState: ObservableObject {
    static let shared = SetupState()
    @Published var engines = false
    @Published var enginesDetail = ""
    @Published var mic = false
    @Published var callAudioTried = false
    @Published var downloading = false
    @Published var downloadLine = ""

    /// Runs the bundled fetch-engines.sh (pinned SHA-256) and shows its newest line.
    func downloadModels() {
        guard !downloading, let script = Bundle.main.resourceURL?.appendingPathComponent("fetch-engines.sh").path else { return }
        downloading = true; downloadLine = "Starting…"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Shell.searchDirs.joined(separator: ":"); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if let last = s.components(separatedBy: CharacterSet(charactersIn: "\r\n")).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) {
                DispatchQueue.main.async { self.downloadLine = String(last.suffix(90)) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.downloading = false
                if proc.terminationStatus != 0 { self.downloadLine = "Download failed. Check the internet connection and try again." }
                self.refresh()
            }
        }
        do { try p.run() } catch { downloading = false; downloadLine = "Could not start the download: \(error.localizedDescription)" }
    }
    func refresh() {
        let checks = Engines.check()
        engines = checks.allSatisfy { $0.1 }
        enginesDetail = engines ? "whisper.cpp + speaker models · checked" : "Missing: " + checks.filter { !$0.1 }.map(\.0).joined(separator: ", ") + ". Run: hush setup"
        mic = AVCaptureDeviceAuthorized()
        callAudioTried = Store.all().contains { $0.source == "live" }
    }
}

func AVCaptureDeviceAuthorized() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }


// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var apiKey: String { model.settingsKey }

    var body: some View {
        Form {
            Section("AI") {
                AIChoiceCards()
                Button("Open the welcome guide again") { OnboardingState.shared.step = 0; model.openWindowAction?("setup") }.buttonStyle(LinkStyle())
            }
            Section("AI provider details") {
                Picker("Provider", selection: $model.config.provider) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Model", text: $model.config.model, prompt: Text("default"))
                TextField("Faster model for the prompter", text: $model.config.prompterModel, prompt: Text("optional, e.g. haiku"))
                if model.config.provider == .openAICompatible {
                    TextField("Base URL", text: $model.config.openAIBaseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                }
                if model.config.provider == .claudeCLI {
                    TextField("claude command", text: $model.config.claudePath, prompt: Text("found automatically"))
                    TextField("Claude settings folder", text: $model.config.claudeConfigDir, prompt: Text("from your shell (CLAUDE_CONFIG_DIR)"))
                }
                if model.config.provider == .codexCLI {
                    TextField("codex command", text: $model.config.codexPath, prompt: Text("found automatically"))
                    TextField("Codex folder", text: $model.config.codexHome, prompt: Text("~/.codex (CODEX_HOME)"))
                    Text("Uses your Codex login (run `codex login` once). Works with a free ChatGPT account using the gpt-6-luna model; Hush switches to it automatically if your plan does not allow the default model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if [.openAICompatible, .anthropic, .gemini].contains(model.config.provider) {
                    SecureField("API key", text: $model.settingsKey, prompt: Text("stored in the macOS Keychain"))
                    Button("Save key") {
                        Keychain.set(model.config.provider == .anthropic ? "anthropic" : model.config.provider == .gemini ? "gemini" : "openai", apiKey)
                        model.settingsKey = ""; model.settingsTest = "Key saved to Keychain."
                    }
                }
                if model.config.provider == .gemini {
                    Text(GeminiGuideView.privacyNote).font(.caption).foregroundStyle(.secondary)
                }
                Button("Set up free AI on this Mac (Ollama)…") { model.openWindowAction?("ollama") }.buttonStyle(LinkStyle())
                HStack {
                    Button("Test") { test() }.buttonStyle(OutlineButton())
                    Text(model.settingsTest).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Toggle("Hide passwords, keys and card/ID numbers before sending", isOn: $model.config.maskSecrets)
                Text("Only transcript text you summarize or ask about is sent to this provider. Audio never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Prompter") {
                Picker("Prompter style", selection: $model.config.prompterStyle) {
                    Text("Notch bar (while recording)").tag("notch")
                    Text("Floating panel").tag("panel")
                }
                Picker("Prompter AI", selection: $model.config.prompterProvider) {
                    Text("Same as summaries").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases.filter { $0 != .none }, id: \.self) { Text($0.label).tag(ProviderKind?.some($0)) }
                }
                Text("Tip: a local Ollama model answers in about 2 s; Claude Code CLI in about 5-7 s but writes better answers.").font(.caption).foregroundStyle(.secondary)
                Toggle("Answer questions from others automatically", isOn: $model.config.prompterAutoAnswer)
                Slider(value: Binding(get: { model.config.prompterOpacity }, set: { model.setOpacity($0) }), in: 0.3...1) { Text("Opacity") }
                TextField("Your name", text: $model.config.userName, prompt: Text("used in the prompter"))
                HStack {
                    TextField("Context notes file", text: $model.config.contextFile, prompt: Text("CV, product facts… (.txt)"))
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
                    Text("Small (faster, 190 MB)").tag("ggml-small-q5_1.bin")
                }
                Picker("Live model (captions + prompter)", selection: $model.config.liveAsrModel) {
                    Text("Small (fast, recommended on 8 GB Macs)").tag("ggml-small-q5_1.bin")
                    Text("Same as final transcript (slower, more accurate)").tag("")
                }
                Picker("Language", selection: $model.config.language) {
                    Text("Auto (mixed languages)").tag("auto"); Text("Indonesian").tag("id"); Text("English").tag("en")
                }
                if model.config.language == "auto" {
                    HStack(spacing: 14) {
                        Text("Languages in your meetings").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([("id", "Indonesian"), ("en", "English"), ("jw", "Javanese")], id: \.0) { code, name in
                            Toggle(name, isOn: Binding(
                                get: { model.config.languages.contains(code) },
                                set: { on in
                                    if on { if !model.config.languages.contains(code) { model.config.languages.append(code) } }
                                    else if model.config.languages.count > 1 { model.config.languages.removeAll { $0 == code } }
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text("Hush only keeps these languages. Lines it guesses as another language are transcribed again. Javanese is less accurate than Indonesian.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Meetings are stored in \(Paths.meetings.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Consent") {
                Text(AppModel.consentMessage).font(.callout)
                Button("Copy consent message") { model.copyConsent() }
                Text("You are responsible for telling people they are being recorded and for following the rules of each meeting, interview or exam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); SaveButton { model.saveConfig() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .tint(Theme.indigo)
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
