import AppKit
import SwiftUI
import Combine

/// The notch bar: one black shape that grows out of the MacBook notch while Hush records.
/// Collapsed = "ears" (time left, sound meter right). Hover = controls. Question = the prompter answer.
/// Hidden from standard screen capture like the floating prompter (sharingType = .none).
final class NotchState: ObservableObject {
    enum Mode { case collapsed, hover, question }
    @Published var mode: Mode = .collapsed { didSet { if mode != .collapsed { lastOpen = mode } } }
    /// The open content stays laid out while the shape closes over it (drawer effect).
    @Published var lastOpen: Mode = .hover
    @Published var contentHeight: CGFloat = 0
    @Published var pinned = false
    var hovering = false
    /// Size of the black shape (reported by the view); the rest of the window lets clicks through.
    var shapeSize = CGSize(width: 300, height: 32)
}

enum NotchGeometry {
    /// The screen with a notch, else the main screen.
    static var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0] }
    /// Height of the menu bar strip the bar sits in.
    static var barHeight: CGFloat {
        let s = screen
        return s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : max(24, s.frame.maxY - s.visibleFrame.maxY)
    }
    /// Width and center of the physical notch (0 width when there is none).
    static var notch: (width: CGFloat, centerX: CGFloat) {
        let s = screen
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, r.minX > l.maxX {
            return (r.minX - l.maxX, (l.maxX + r.minX) / 2)
        }
        return (0, s.frame.midX)
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 32), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        sharingType = ProcessInfo.processInfo.environment["HUSH_QA_CAPTURABLE"] == "1" ? .readOnly : .none
        // No .stationary: that kept the bar on top of Mission Control's Spaces strip, in the way when switching desktops.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { NotchController.current?.collapse(force: true) }   // Esc
}

final class NotchController {
    static weak var current: NotchController?
    let state = NotchState()
    private let panel = NotchPanel()
    private let host: NSHostingView<AnyView>
    private var bag: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        host = NSHostingView(rootView: AnyView(NotchView().environmentObject(model).environmentObject(state)))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        panel.ignoresMouseEvents = false
        NotchController.current = self
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.relayout() }.store(in: &bag)
    }

    private var mouseTimer: Timer?

    func show() {
        state.mode = .collapsed; relayout(); panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true
        mouseTimer?.invalidate()
        // 30 times a second: accept the mouse only over the black shape, pass it through everywhere else.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateMousePassThrough() }
    }
    func hide() {
        collapseWork?.cancel(); mouseTimer?.invalidate(); mouseTimer = nil
        panel.orderOut(nil); state.mode = .collapsed; state.pinned = false
    }

    private func updateMousePassThrough() {
        let f = panel.frame, s = state.shapeSize
        let shape = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height).insetBy(dx: -4, dy: -4)
        let inside = shape.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
    var isVisible: Bool { panel.isVisible }

    /// The window has ONE fixed size (big enough for the open states) and never resizes: resizing a window while
    /// SwiftUI animates its content looked jumpy, and made macOS report hover exit/enter (open/close flicker).
    /// Only the black shape inside animates. The clear area around it lets clicks pass through.
    static let canvas = NSSize(width: 560, height: 300)
    func relayout() {
        let (_, cx) = NotchGeometry.notch
        let top = NotchGeometry.screen.frame.maxY
        let w = Self.canvas.width, h = Self.canvas.height
        panel.setFrame(NSRect(x: (cx - w / 2).rounded(), y: top - h, width: w, height: h), display: false)
    }

    private var hoverWork: DispatchWorkItem?
    func hoverChanged(_ on: Bool) {
        state.hovering = on
        if on {
            collapseWork?.cancel()
            // Open only if the pointer rests on the bar: passing through the top edge (menu bar, Spaces) leaves it closed.
            if state.mode == .collapsed {
                hoverWork?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.state.hovering, self.state.mode == .collapsed else { return }
                    self.state.mode = .hover
                }
                hoverWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        } else if state.mode == .hover || (state.mode == .question && !state.pinned && autoCloseDue) {
            schedule(after: 0.45)
        }
    }

    private var questionShownAt = Date.distantPast
    private var autoCloseDue: Bool { Date().timeIntervalSince(questionShownAt) > 20 }

    func showQuestion() {
        if !panel.isVisible { show() }          // show() places the bar at the notch first (else it opens at 0,0)
        state.mode = .question
        questionShownAt = Date()
        schedule(after: 20)
    }

    func toggleQuestion() { state.mode == .question ? collapse(force: true) : showQuestion() }

    func collapse(force: Bool = false) {
        guard force || (!state.pinned && !state.hovering) else { return }
        guard state.mode != .collapsed else { return }
        if force { state.pinned = false }
        state.mode = .collapsed
    }

    private func schedule(after s: Double) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    func focusForKeys() { panel.makeKey() }
}

// MARK: view

struct NotchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var st: NotchState

    var notchW: CGFloat { NotchGeometry.notch.width }
    var barH: CGFloat { NotchGeometry.barHeight }
    var collapsedWidth: CGFloat { (notchW > 0 ? notchW : 120) + 2 * 92 }
    func openWidth(_ m: NotchState.Mode) -> CGFloat { m == .question ? max(notchW + 120, 480) : max(notchW + 120, 460) }
    var isOpen: Bool { st.mode != .collapsed }
    var shown: NotchState.Mode { isOpen ? st.mode : st.lastOpen }

    var body: some View {
        let w = isOpen ? openWidth(st.mode) : collapsedWidth
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 1, green: 0.35, blue: 0.37)).frame(width: 8, height: 8)
                    Text(formatTime(model.elapsed)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                }
                .frame(width: 92, alignment: .center)
                Spacer(minLength: notchW > 0 ? notchW : 120)
                meter.frame(width: 92)
            }
            .frame(width: w, height: barH)

            // Always laid out at its open width; the shape's height reveals or hides it like a drawer.
            Group { if shown == .question { questionContent } else { hoverContent } }
                .frame(width: openWidth(shown))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.onAppear { st.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, v in st.contentHeight = v }
                })
                .opacity(isOpen ? 1 : 0)
                .animation(isOpen ? .easeOut(duration: 0.2).delay(0.06) : .easeIn(duration: 0.1), value: isOpen)
        }
        .frame(width: w, height: barH + (isOpen ? st.contentHeight : 0), alignment: .top)
        .clipped()
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: isOpen ? 22 : 14,
                                                      bottomTrailing: isOpen ? 22 : 14, topTrailing: 0))
                .fill(Color(red: 0.043, green: 0.043, blue: 0.051))
        )
        .contentShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0)))
        .onHover { NotchController.current?.hoverChanged($0) }
        .background(GeometryReader { g in
            Color.clear.onAppear { st.shapeSize = g.size }.onChange(of: g.size) { _, v in st.shapeSize = v }
        })
        .frame(width: NotchController.canvas.width, height: NotchController.canvas.height, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.86), value: st.mode)
        .environment(\.colorScheme, .dark)
    }

    var meter: some View {
        let lvl = CGFloat(min(1, max(model.sysLevel, model.micLevel) * 10))
        let heights: [CGFloat] = [0.4, 0.8, 0.6, 1.0, 0.5]
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(Color(red: 0.61, green: 0.89, blue: 0.71))
                    .frame(width: 3, height: max(3, 14 * heights[i] * max(0.2, lvl)))
            }
        }
        .accessibilityLabel("Sound level")
    }

    var hoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(model.liveTitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer()
            }
            if let l = model.liveLines.last {
                (Text(l.who == "me" ? "You  " : l.who == "room" ? "Room  " : "Them  ").bold().foregroundColor(Color(red: 0.95, green: 0.76, blue: 0.55))
                 + Text(l.text).foregroundColor(.white.opacity(0.85)))
                    .font(.system(size: 13)).lineLimit(2)
            } else {
                Text("Listening…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 8) {
                Button { model.openWindowAction?("live"); model.whatDidIMiss() } label: { Text("What did I miss?").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(FilledButton(bg: Theme.indigo))
                Button { NotchController.current?.showQuestion() } label: { Text("Prompter").frame(minHeight: 30) }.buttonStyle(NotchOutline())
                Button { LiveTab.shared.index = 0; model.openWindowAction?("live") } label: { Text("Notes").frame(minHeight: 30) }.buttonStyle(NotchOutline())
                Button { model.stopRecording() } label: { Text("■ Stop").frame(minHeight: 30) }.buttonStyle(FilledButton(bg: Color(white: 0.22)))
            }
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
    }

    var questionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.prompterAskedAt.map { "They asked · " + ago($0) } ?? "Prompter").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                if model.config.lastHiddenCheck.hasPrefix("hidden") {
                    Text("Hidden ✓").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.61, green: 0.89, blue: 0.71))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color(red: 0.18, green: 0.62, blue: 0.36).opacity(0.25), in: Capsule())
                }
            }
            if let q = model.prompterQuestion {
                Text("“\(q)”").font(.system(size: 14).italic()).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
            Text(model.prompterAnswer.isEmpty ? (model.prompterStatus.hasPrefix("Drafting") ? "Drafting an answer…" : "No question yet. Answers appear here when someone asks you.")
                                              : model.prompterAnswer)
                .font(.system(size: model.prompterAnswer.isEmpty ? 14 : 18, weight: model.prompterAnswer.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.prompterAnswer.isEmpty ? .white.opacity(0.6) : .white)
                .lineSpacing(2).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(model.prompterStatus).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer()
                if let other = model.recentQuestions.compactMap(\.question).last(where: { $0 != model.prompterQuestion }) {
                    Button("Wrong question?") { model.answer(other) }.buttonStyle(NotchChip()).help("Answer “\(other)” instead")
                }
                Button(st.pinned ? "Pinned" : "Pin") { st.pinned.toggle() }.buttonStyle(NotchChip(on: st.pinned))
                Button("Hide") { NotchController.current?.collapse(force: true) }.buttonStyle(NotchChip()).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
            .overlay(Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1), alignment: .top)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
    }
}

struct NotchOutline: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { NotchOutlineBody(c: configuration) }
}
private struct NotchOutlineBody: View {
    let c: ButtonStyleConfiguration
    @StateObject var h = HoverBox()
    var body: some View {
        c.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(c.isPressed ? 0.16 : (h.on ? 0.10 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.18)))
            .tracksHover(h)
    }
}

struct NotchChip: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View { NotchChipBody(c: configuration, on: on) }
}
private struct NotchChipBody: View {
    let c: ButtonStyleConfiguration
    let on: Bool
    @StateObject var h = HoverBox()
    var body: some View {
        c.label.font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(on ? 0.22 : (c.isPressed ? 0.18 : (h.on ? 0.14 : 0.08)))))
            .overlay(Capsule().stroke(Color.white.opacity(0.16)))
            .tracksHover(h)
    }
}
