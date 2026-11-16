import SwiftUI
import AppKit
import CoreText

/// Hush look: warm paper, ink, one indigo accent, red only for recording.
/// Titles in Instrument Serif (bundled, SIL OFL 1.1), everything else in the system sans.
enum Theme {
    static func rgb(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }
    static let paper = rgb(0xF4F1EA)       // window ground
    static let panel = rgb(0xFFFDF9)       // content panel
    static let line = rgb(0xE8E3D9)        // borders
    static let chip = rgb(0xEFECE5)        // segmented controls, chips
    static let ink = rgb(0x1E1E22)
    static let ink2 = rgb(0x4C483F)        // secondary text (7:1 on paper)
    static let ink3 = rgb(0x5F5B53)        // captions (5.6:1 on paper)
    static let indigo = rgb(0x4B4BC8)
    static let indigoSoft = rgb(0xF1F0FC)
    static let lilac = rgb(0x858CEE)
    static let rec = rgb(0xD93A3F)
    static let ok = rgb(0x1E6B3A)
    static let okSoft = rgb(0xE3F4E8)
    static let night = rgb(0x16161C)

    /// Registers the bundled serif once per process.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let name = italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular"
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, design: .serif)
    }
}

/// The Hush symbol: three bars, a glass crossbar over the first two, and a dot.
/// Geometry from the Figma master (viewBox 318 × 288).
struct HushGlyph: View {
    var bars: Color = Theme.ink
    var glass: Color = Theme.indigo
    var glassOpacity: Double = 0.42
    var dot: Color = Theme.indigo
    var dotScale: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 318, g.size.height / 288)
            ZStack(alignment: .topLeading) {
                bar(24, 58, 42, 172, s).fill(bars)
                bar(107, 4, 43, 280, s).fill(bars)
                bar(190, 80, 43, 126, s).fill(bars)
                bar(3, 121, 165, 42, s).fill(glass.opacity(glassOpacity))
                let r = 23 * dotScale
                Circle().fill(dot).frame(width: 2 * r * s, height: 2 * r * s).offset(x: (290 - r) * s, y: (143 - r) * s)
            }
            .frame(width: 318 * s, height: 288 * s)
        }
        .aspectRatio(318 / 288, contentMode: .fit)
        .accessibilityLabel("Hush")
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGFloat) -> some Shape {
        RoundedRectangle(cornerRadius: min(w, h) / 2 * s).path(in: CGRect(x: x * s, y: y * s, width: w * s, height: h * s))
    }
}

extension HushGlyph {
    static var onLight: HushGlyph { HushGlyph() }
    static var onDark: HushGlyph { HushGlyph(bars: .white, glass: Theme.rgb(0x858CE8), glassOpacity: 0.6, dot: Theme.lilac) }
}

/// Menu bar image: one-color template when idle, red dot while recording.
enum MenuBarGlyph {
    static func image(recording: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            let s = min(rect.width / 318, rect.height / 288)
            let ox = (rect.width - 318 * s) / 2, oy = (rect.height - 288 * s) / 2
            func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
                let r = NSRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
                return NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2, yRadius: min(r.width, r.height) / 2)
            }
            NSColor.black.setFill()
            rr(24, 58, 42, 172).fill(); rr(107, 4, 43, 280).fill(); rr(190, 80, 43, 126).fill()
            NSColor.black.withAlphaComponent(0.45).setFill(); rr(3, 121, 165, 42).fill()
            let r: CGFloat = recording ? 34 : 23
            (recording ? NSColor.systemRed : NSColor.black).setFill()
            NSBezierPath(ovalIn: NSRect(x: ox + (290 - r) * s, y: oy + (143 - r) * s, width: 2 * r * s, height: 2 * r * s)).fill()
            return true
        }
        img.isTemplate = !recording
        img.accessibilityDescription = recording ? "Hush, recording" : "Hush"
        return img
    }
}

/// Small rounded label.
struct Pill: View {
    let text: String
    var fg: Color = Theme.ink2
    var bg: Color = Theme.chip
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3).background(bg, in: Capsule())
    }
}

/// Warm content card used across windows.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
    }
}
