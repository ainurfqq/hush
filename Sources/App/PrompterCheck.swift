import AppKit
import ScreenCaptureKit

/// Self-test: "Is the prompter hidden from screen capture on THIS Mac?"
/// Captures the panel's screen area with ScreenCaptureKit (what Zoom/Meet/OBS use on modern macOS) in three states:
///   B1, B2: panel removed (background noise between two frames)
///   A:      panel shown as normal (sharingType .none)
///   C:      control, panel made capturable (.readOnly) — proves the check can see the panel at all
/// Hidden = diff(A, B) is within background noise AND diff(C, B) is clearly larger.
enum PrompterCheck {
    struct Result { var hidden: Bool; var valid: Bool; var noise: Double; var shown: Double; var control: Double
        var summary: String {
            guard valid else { return String(format: "Check inconclusive: the control capture did not differ from the background (%.1f). Try again on a still screen.", control) }
            return hidden ? String(format: "Hidden ✓  ScreenCaptureKit did not see the prompter (difference %.1f vs noise %.1f; control %.1f).", shown, noise, control)
                          : String(format: "VISIBLE ✗  ScreenCaptureKit captured the prompter (difference %.1f vs noise %.1f). Share a single window, not the whole screen.", shown, noise)
        }
    }

    static func run(panel: NSPanel, completion: @escaping (Result?, String?) -> Void) {
        guard let screen = panel.screen ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            completion(nil, "No screen found"); return
        }
        // Panel rect in top-left display coordinates (points).
        let f = panel.frame, sf = screen.frame
        let rect = CGRect(x: f.minX - sf.minX, y: sf.maxY - f.maxY, width: f.width, height: f.height)
        let original = panel.sharingType
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw HushError.engine("display not shareable") }
                func grab() async throws -> CGImage {
                    let cfg = SCStreamConfiguration()
                    cfg.sourceRect = rect; cfg.width = Int(rect.width * 2); cfg.height = Int(rect.height * 2)
                    cfg.showsCursor = false
                    return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
                }
                func onMain(_ b: @escaping () -> Void) async { await MainActor.run { b() }; try? await Task.sleep(nanoseconds: 350_000_000) }

                // B1 hidden · A shown (real setting) · C shown and made capturable (control) · B2 hidden again.
                await onMain { panel.orderOut(nil) }
                let b1 = try await grab()
                await onMain { panel.orderFrontRegardless() }
                let a = try await grab()
                await onMain { panel.sharingType = .readOnly }
                let c = try await grab()
                await onMain { panel.sharingType = original; panel.orderOut(nil) }
                let b2 = try await grab()
                await onMain { panel.orderFrontRegardless() }

                // The screen behind can change (a ticking clock, scrolling text), so do not compare A with a
                // single background frame. Ask instead: does A look like the background, or like the panel (C)?
                let noise = diff(b1, b2)
                let shown = min(diff(a, b1), diff(a, b2))
                let toPanel = diff(a, c)
                let control = min(diff(c, b1), diff(c, b2))
                let valid = control > noise + 4
                let hidden = shown * 2 < toPanel
                await MainActor.run { completion(Result(hidden: hidden, valid: valid, noise: noise, shown: shown, control: control), nil) }
            } catch {
                await MainActor.run { panel.sharingType = original; completion(nil, "\(error). Allow Hush under System Settings → Privacy & Security → Screen & System Audio Recording to run this check.") }
            }
        }
    }

    /// Mean absolute difference per channel (0–255) between two same-size images.
    static func diff(_ x: CGImage, _ y: CGImage) -> Double {
        let w = min(x.width, y.width), h = min(x.height, y.height)
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let p = pixels(x), q = pixels(y)
        var acc = 0
        for i in stride(from: 0, to: p.count, by: 4) {
            acc += abs(Int(p[i]) - Int(q[i])) + abs(Int(p[i + 1]) - Int(q[i + 1])) + abs(Int(p[i + 2]) - Int(q[i + 2]))
        }
        return Double(acc) / Double(w * h * 3)
    }
}
