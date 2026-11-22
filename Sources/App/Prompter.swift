import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The floating answer panel. `sharingType = .none` keeps it out of standard macOS screen capture
/// (verified on macOS 27.2 for screencapture, ScreenCaptureKit and CGWindowList: run-1/spikes.md §D).
/// Meeting apps can use their own capture paths, so the UI never promises "undetectable".
final class PrompterPanel: NSPanel {
    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                   styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        // QA control only: HUSH_QA_CAPTURABLE=1 makes the panel capturable, to prove it is on screen in tests.
        sharingType = ProcessInfo.processInfo.environment["HUSH_QA_CAPTURABLE"] == "1" ? .readOnly : .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = NSHostingView(rootView: PrompterView().environmentObject(model))
        alphaValue = CGFloat(model.config.prompterOpacity)
        setFrameAutosaveName("HushPrompter")
        if frame.origin == .zero, let s = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: s.midX - 230, y: s.maxY - 280))
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PrompterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(model.isRecording ? Color(red: 1, green: 0.42, blue: 0.44) : Color.gray).frame(width: 8, height: 8)
                Text(header).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                Spacer()
                if model.config.lastHiddenCheck.hasPrefix("hidden") {
                    Text("Hidden ✓").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.61, green: 0.89, blue: 0.71))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color(red: 0.18, green: 0.62, blue: 0.36).opacity(0.25), in: Capsule())
                }
            }
            if let q = model.prompterQuestion {
                Text("“\(q)”").font(.system(size: 14).italic()).foregroundStyle(Color.white.opacity(0.82)).lineLimit(3)
            }
            ScrollView(showsIndicators: false) {
                Text(model.prompterAnswer.isEmpty ? "When someone asks you a question, a suggested answer appears here." : model.prompterAnswer)
                    .font(.system(size: model.prompterAnswer.isEmpty ? 15 : 19, weight: model.prompterAnswer.isEmpty ? .regular : .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(model.prompterAnswer.isEmpty ? Color.white.opacity(0.6) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 110, maxHeight: .infinity)
          }
          .overlay(WindowDragArea())          // header, question and answer: drag the panel from here
          .layoutPriority(1)
            let others = model.recentQuestions.compactMap(\.question).filter { $0 != model.prompterQuestion }.suffix(2)
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WRONG QUESTION? PICK ONE").font(.system(size: 10, weight: .semibold)).kerning(0.5).foregroundStyle(Color.white.opacity(0.6))
                    HStack(spacing: 6) {
                        ForEach(Array(others), id: \.self) { q in
                            Button { model.answer(q) } label: {
                                Text("“\(q)”").font(.system(size: 12)).lineLimit(1).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.white.opacity(0.08), in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.18)))
                            }.buttonStyle(ChipStyle(dark: true)).help("Answer this question instead")
                        }
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1), alignment: .top)
            }
            HStack(spacing: 10) {
                Text(model.prompterStatus).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                Spacer()
                Button { model.answerLastQuestion() } label: {
                    Text("Again ⌃⌥A").font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(ChipStyle(dark: true)).help("Answer the last question from others now")
                Slider(value: Binding(get: { model.config.prompterOpacity }, set: { model.setOpacity($0) }), in: 0.3...1)
                    .frame(width: 64).controlSize(.mini).help("Opacity")
            }
        }
        .padding(16).padding(.top, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.night.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    var header: String {
        guard model.prompterQuestion != nil, let t = model.prompterAskedAt else { return model.isRecording ? "Listening for questions" : "Prompter" }
        return "They asked · \(ago(t))"
    }
}

/// Lets the user drag the prompter from anywhere that is not a button or slider. SwiftUI text and scroll views
/// swallow the click, so `isMovableByWindowBackground` alone only worked on the thin title strip.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        /// The layer sits on top of the answer; hand the scroll wheel to the scroll view underneath.
        override func scrollWheel(with event: NSEvent) {
            isHidden = true
            let under = window?.contentView?.hitTest(event.locationInWindow)
            isHidden = false
            (under ?? superview)?.scrollWheel(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
        /// The panel never becomes active, so without this the first click is used up and the drag never starts.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// An open hand over the panel shows that it can be dragged (works while the panel is not active).
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// System-wide hotkeys through Carbon (no Accessibility permission needed).
final class Hotkeys {
    static let shared = Hotkeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { Hotkeys.shared.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x48555348), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
