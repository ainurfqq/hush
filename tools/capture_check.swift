import AppKit
import ScreenCaptureKit
// QA: find the on-screen window(s) of a process by name, then capture that screen region with
// ScreenCaptureKit (display filter) and save the PNG. Prints window bounds and sharing state.
// Usage: capture_check <owner-name> <out.png>
let owner = CommandLine.arguments[1], out = CommandLine.arguments[2]
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let wins = info.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 60 }
guard let w = wins.max(by: { (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) < (($1[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) }),
      let b = w[kCGWindowBounds as String] as? [String: Double] else { print("NO_WINDOW"); exit(2) }
let rect = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
print("WINDOW id=\(w[kCGWindowNumber as String]!) bounds=\(rect) onscreen=\(w[kCGWindowIsOnscreen as String] ?? "?") sharingState=\(w[kCGWindowSharingState as String] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?")")
let pad: CGFloat = 40
let crop = rect.insetBy(dx: -pad, dy: -pad)
print("REGION \(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))")
Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
    let scale = NSScreen.main!.backingScaleFactor
    let cfg = SCStreamConfiguration(); cfg.width = Int(CGFloat(display.width) * scale); cfg.height = Int(CGFloat(display.height) * scale)
    let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
    let r = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
    try NSBitmapImageRep(cgImage: img.cropping(to: r)!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("SAVED \(out)"); exit(0)
  } catch { print("ERR \(error)"); exit(1) }
}
RunLoop.main.run(until: Date().addingTimeInterval(15)); exit(3)
