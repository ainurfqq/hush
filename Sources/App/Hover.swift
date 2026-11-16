import SwiftUI
import AppKit

/// Hover state holder (`@State` is a macro this toolchain cannot expand; `@StateObject` works).
final class HoverBox: ObservableObject { @Published var on = false }

/// Respects System Settings → Accessibility → Display → Reduce motion: color changes stay, movement goes.
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
let hoverAnim = Animation.easeOut(duration: 0.14)

/// Tracks hover and shows the pointing-hand cursor over clickable things. Keeps push/pop balanced.
struct HoverTracker: ViewModifier {
    @ObservedObject var box: HoverBox
    var cursor = true
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { on in
                guard on != box.on else { return }
                if ProcessInfo.processInfo.environment["HUSH_DEBUG_HOVER"] == "1" { Log.write("hover \(on)") }
                box.on = on
                if cursor { on ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
            .onDisappear { if box.on { box.on = false; if cursor { NSCursor.pop() } } }
            .animation(hoverAnim, value: box.on)
    }
}

extension View {
    func tracksHover(_ box: HoverBox, cursor: Bool = true) -> some View { modifier(HoverTracker(box: box, cursor: cursor)) }
}

// MARK: buttons

struct FilledButton: ButtonStyle {
    var bg: Color
    func makeBody(configuration: Configuration) -> some View { FilledBody(c: configuration, bg: bg) }
}

private struct FilledBody: View {
    let c: ButtonStyleConfiguration
    let bg: Color
    @StateObject var h = HoverBox()
    @Environment(\.isEnabled) var enabled
    var body: some View {
        let hot = h.on && enabled
        c.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(bg)
                    .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hot && !c.isPressed ? 0.10 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(c.isPressed ? 0.12 : 0)))
                    .shadow(color: bg.opacity(hot ? 0.32 : 0), radius: hot ? 8 : 0, y: hot ? 3 : 0)
            )
            .scaleEffect(c.isPressed && !reduceMotion ? 0.97 : 1)
            .offset(y: hot && !c.isPressed && !reduceMotion ? -1 : 0)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.09), value: c.isPressed)
            .tracksHover(h, cursor: enabled)
    }
}

struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { OutlineBody(c: configuration) }
}

private struct OutlineBody: View {
    let c: ButtonStyleConfiguration
    @StateObject var h = HoverBox()
    @Environment(\.isEnabled) var enabled
    var body: some View {
        c.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(c.isPressed ? Theme.chip : (h.on ? Theme.rgb(0xFAF7F1) : .white)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(h.on ? Theme.ink3.opacity(0.55) : Theme.line))
            .scaleEffect(c.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.09), value: c.isPressed)
            .tracksHover(h, cursor: enabled)
    }
}

/// Text link: indigo, underline on hover, darker while pressed.
struct LinkStyle: ButtonStyle {
    var color: Color = Theme.indigo
    func makeBody(configuration: Configuration) -> some View { LinkBody(c: configuration, color: color) }
}

private struct LinkBody: View {
    let c: ButtonStyleConfiguration
    let color: Color
    @StateObject var h = HoverBox()
    var body: some View {
        c.label.foregroundStyle(color.opacity(c.isPressed ? 0.6 : 1))
            .underline(h.on, color: color.opacity(0.6))
            .tracksHover(h)
    }
}

/// List rows (meetings, recent): soft background on hover, stronger when selected.
struct RowStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View { RowBody(c: configuration, selected: selected, radius: radius) }
}

private struct RowBody: View {
    let c: ButtonStyleConfiguration
    let selected: Bool
    let radius: CGFloat
    @StateObject var h = HoverBox()
    var body: some View {
        c.label
            .background(RoundedRectangle(cornerRadius: radius).fill(
                selected ? Theme.rgb(0xE9E5DC) : c.isPressed ? Theme.rgb(0xE9E5DC) : h.on ? Theme.rgb(0xF0ECE4) : .clear))
            .tracksHover(h)
    }
}

/// Tabs: label darkens and the underline previews on hover.
struct TabStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { TabBody(c: configuration, selected: selected) }
}

private struct TabBody: View {
    let c: ButtonStyleConfiguration
    let selected: Bool
    @StateObject var h = HoverBox()
    var body: some View {
        VStack(spacing: 8) {
            c.label.foregroundStyle(selected || h.on ? Theme.ink : Theme.ink2)
            Rectangle().fill(selected ? Theme.indigo : (h.on ? Theme.line : .clear)).frame(height: 2)
        }
        .fixedSize()
        .tracksHover(h)
    }
}

/// Small clickable chips (speaker pills, prompter question chips): lift + brighten on hover.
struct ChipStyle: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View { ChipBody(c: configuration, dark: dark) }
}

private struct ChipBody: View {
    let c: ButtonStyleConfiguration
    let dark: Bool
    @StateObject var h = HoverBox()
    var body: some View {
        c.label
            .brightness(h.on ? (dark ? 0.12 : -0.04) : 0)
            .scaleEffect(c.isPressed && !reduceMotion ? 0.96 : (h.on && !reduceMotion ? 1.03 : 1))
            .animation(.easeOut(duration: 0.09), value: c.isPressed)
            .tracksHover(h)
    }
}
