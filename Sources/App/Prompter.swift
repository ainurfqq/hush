import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The floating answer panel. `sharingType = .none` keeps it out of standard macOS screen capture
/// (verified on macOS 27.2 for screencapture, ScreenCaptureKit and CGWindowList: run-1/spikes.md §D).
/// Meeting apps can use their own capture paths, so the UI never promises "undetectable".
final class PrompterPanel: NSPanel {
    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(model.isRecording ? Color.red : Color.secondary).frame(width: 7, height: 7)
                Text(model.prompterStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { model.answerLastQuestion() } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.borderless).help("Answer the last question now (⌃⌥A)")
                Slider(value: Binding(get: { model.config.prompterOpacity }, set: { model.setOpacity($0) }), in: 0.3...1)
                    .frame(width: 70).controlSize(.mini).help("Opacity")
            }
            if let q = model.prompterQuestion {
                Text(q).font(.callout).italic().foregroundStyle(.secondary).lineLimit(3)
            }
            ScrollView {
                Text(model.prompterAnswer.isEmpty ? "Answers to questions from others appear here." : model.prompterAnswer)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.prompterAnswer.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Text("Hidden from standard macOS screen capture. Check your meeting app once (see README).")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .padding(.top, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
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
