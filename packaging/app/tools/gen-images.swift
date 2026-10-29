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
        // Full-bleed neutral field; macOS applies the app-icon squircle mask.
        c.setFillColor(CGColor(red: 20 / 255, green: 21 / 255, blue: 26 / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

        // Candidate A, matching StrimSite/Mark.swift: paired offset capsules form one flat S.
        let capsules = CGMutablePath()
        capsules.move(to: CGPoint(x: 47, y: 14))
        capsules.addLine(to: CGPoint(x: 27, y: 14))
        capsules.addCurve(to: CGPoint(x: 18, y: 23), control1: CGPoint(x: 22.0294, y: 14), control2: CGPoint(x: 18, y: 18.0294))
        capsules.addCurve(to: CGPoint(x: 27, y: 32), control1: CGPoint(x: 18, y: 27.9706), control2: CGPoint(x: 22.0294, y: 32))
        capsules.addLine(to: CGPoint(x: 34, y: 32))
        capsules.move(to: CGPoint(x: 30, y: 32))
        capsules.addLine(to: CGPoint(x: 37, y: 32))
        capsules.addCurve(to: CGPoint(x: 46, y: 41), control1: CGPoint(x: 41.9706, y: 32), control2: CGPoint(x: 46, y: 36.0294))
        capsules.addCurve(to: CGPoint(x: 37, y: 50), control1: CGPoint(x: 46, y: 45.9706), control2: CGPoint(x: 41.9706, y: 50))
        capsules.addLine(to: CGPoint(x: 17, y: 50))

        // Fit the 56-unit ink height (including the 10-unit stroke) to 60% of the 1024 grid.
        let scale = 614.4 / 56
        var fit = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                    tx: 512 - 32 * scale, ty: 512 + 32 * scale)
        guard let fitted = capsules.copy(using: &fit) else { return }
        c.setStrokeColor(CGColor(red: 124 / 255, green: 124 / 255, blue: 245 / 255, alpha: 1))
        c.setLineWidth(10 * scale)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.addPath(fitted)
        c.strokePath()
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
