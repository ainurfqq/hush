import AppKit
// Renders Hush's app icon (dark tile + symbol from the Figma master) into an .iconset, then run iconutil.
// Usage: swift tools/make_icon.swift <out.iconset>
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func color(_ h: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a) }
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)          // y down, like the SVG
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824 px tile inside 1024 canvas, corner ~185
    let inset: CGFloat = 100 * s, tile = 824 * s
    color(0x1E1E22).setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: tile, height: tile), xRadius: 185 * s, yRadius: 185 * s).fill()
    // symbol: 600-unit design space mapped into the tile
    let k = tile / 600
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        let r = NSRect(x: inset + x * k, y: inset + y * k, width: w * k, height: h * k)
        return NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2, yRadius: min(r.width, r.height) / 2)
    }
    NSColor.white.setFill(); rr(164, 213, 42, 172).fill(); rr(247, 159, 43, 280).fill(); rr(330, 235, 43, 126).fill()
    color(0x858CE8, 0.6).setFill(); rr(143, 276, 165, 42).fill()
    color(0x858CEE).setFill(); NSBezierPath(ovalIn: NSRect(x: inset + (430 - 23) * k, y: inset + (298 - 23) * k, width: 46 * k, height: 46 * k)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(pt * scale).write(to: out.appendingPathComponent(name))
}
print("ok")
