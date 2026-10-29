// Placeholder artwork generator (no external deps). Usage:
//   swift tools/gen-images.swift icon <out.png>          1024x1024 app icon placeholder
//   swift tools/gen-images.swift background <out.png>    660x400 DMG background (flat colour, arrow, caption)
// The owner replaces icon/icon-1024.png with the real icon; this script is only used to seed it.
import AppKit

func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    return rep.representation(using: .png, properties: [:])!
}
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, center: CGPoint) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: a)
    let sz = str.size()
    str.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
}

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: gen-images.swift icon|background out.png\n".utf8)); exit(2) }
var data: Data
switch args[1] {
case "icon":
    data = render(1024, 1024) { c in
        // macOS icon grid: 824x824 rounded square centred in 1024.
        let r = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: r, cornerWidth: 184, cornerHeight: 184, transform: nil)
        c.addPath(path); c.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 0.13, green: 0.16, blue: 0.30, alpha: 1), CGColor(red: 0.36, green: 0.30, blue: 0.85, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        text("S", 560, .heavy, .white, center: CGPoint(x: 512, y: 512))
    }
case "background":
    data = render(660, 400) { c in
        c.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 660, height: 400))
        text("Drag Strim to Applications", 22, .semibold, NSColor(white: 0.25, alpha: 1), center: CGPoint(x: 330, y: 340))
        text("\u{2192}", 90, .regular, NSColor(white: 0.55, alpha: 1), center: CGPoint(x: 330, y: 190))
    }
default:
    FileHandle.standardError.write(Data("unknown mode\n".utf8)); exit(2)
}
try data.write(to: URL(fileURLWithPath: args[2]))
