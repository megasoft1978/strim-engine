import AppKit
import XCTest

/// Golden PNG comparison. A pixel differs when any channel differs by more than `channelTolerance`; the image fails
/// when more than `maxDifferingFraction` of its pixels differ (or the size differs).
/// `STRIM_UPDATE_GOLDENS=1` (re)writes goldens; a missing golden fails otherwise.
/// `Tests/Goldens/PLATFORM` records the macOS major version and scroller style the goldens were drawn on; on a
/// different platform the compare tests skip (`platformSkipReason`) instead of failing on rasterization noise.
enum GoldenCompare {
    static let channelTolerance = 4
    static let maxDifferingFraction = 0.0005

    static let goldenDir: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Goldens", isDirectory: true)
    static let platformFile: URL = goldenDir.appendingPathComponent("PLATFORM")
    static var updating: Bool { ProcessInfo.processInfo.environment["STRIM_UPDATE_GOLDENS"] == "1" }

    struct Pixels { var w: Int; var h: Int; var data: [UInt8] }

    /// The rendering environment a golden depends on.
    struct Platform: Equatable {
        var macOSMajor: Int
        var scrollerStyle: Int

        static var current: Platform {
            pinScrollerStyle()
            return Platform(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                     scrollerStyle: NSScroller.preferredScrollerStyle.rawValue)
        }

        init(macOSMajor: Int, scrollerStyle: Int) { self.macOSMajor = macOSMajor; self.scrollerStyle = scrollerStyle }

        /// Parses `macos_major=N` / `scroller_style=N` lines; nil when either key is missing.
        init?(text: String) {
            var fields: [String: Int] = [:]
            for line in text.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, let v = Int(kv[1]) { fields[kv[0]] = v }
            }
            guard let major = fields["macos_major"], let style = fields["scroller_style"] else { return nil }
            self.init(macOSMajor: major, scrollerStyle: style)
        }

        var text: String { "macos_major=\(macOSMajor)\nscroller_style=\(scrollerStyle)\n" }
    }

    /// Pins the scroller style to overlay ("When scrolling") for this process. Under the Automatic setting AppKit flips
    /// the preferred style when the first render runs (device-dependent), so goldens would not repeat within one run.
    /// Called before every render and before reading the platform record. Uses the in-memory argument domain, so nothing
    /// is written to disk and the user's global preference is never touched.
    static func pinScrollerStyle() {
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard args["AppleShowScrollBars"] as? String != "WhenScrolling" else { return }
        args["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    /// Writes the current platform to `PLATFORM`. Only called while updating.
    @discardableResult
    static func recordPlatform() -> Bool {
        try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
        return (try? Platform.current.text.write(to: platformFile, atomically: true, encoding: .utf8)) != nil
    }

    /// Skip reason when the goldens were recorded on another macOS major version or scroller style. nil when they match,
    /// when updating, or when there is no record (then `check` fails, since a missing record is not a skip).
    static func platformSkipReason() -> String? {
        guard !updating, let text = try? String(contentsOf: platformFile, encoding: .utf8),
              let recorded = Platform(text: text) else { return nil }
        let now = Platform.current
        guard recorded != now else { return nil }
        return "goldens recorded on macOS \(recorded.macOSMajor) (scroller style \(recorded.scrollerStyle)); this host is macOS "
            + "\(now.macOSMajor) (scroller style \(now.scrollerStyle)); regenerate with STRIM_UPDATE_GOLDENS=1"
    }

    /// sRGB RGBA8, premultiplied, so decoded goldens and fresh renders compare in the same space.
    static func pixels(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(w: w, h: h, data: data)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func load(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.cgImage
    }

    /// Per-pixel comparison of two same-sized images: the fraction of pixels over `channelTolerance`, and a diff
    /// overlay (differing pixels red, matching pixels dimmed golden).
    static func differ(_ actual: Pixels, _ golden: Pixels) -> (fraction: Double, diff: [UInt8]) {
        var differing = 0
        var diff = [UInt8](repeating: 0, count: actual.data.count)
        for p in 0..<(actual.w * actual.h) {
            var worst = 0
            for c in 0..<4 { worst = max(worst, abs(Int(actual.data[p * 4 + c]) - Int(golden.data[p * 4 + c]))) }
            if worst > channelTolerance {
                differing += 1
                diff[p * 4] = 255; diff[p * 4 + 3] = 255
            } else {
                diff[p * 4] = golden.data[p * 4] / 3; diff[p * 4 + 1] = golden.data[p * 4 + 1] / 3
                diff[p * 4 + 2] = golden.data[p * 4 + 2] / 3; diff[p * 4 + 3] = 255
            }
        }
        return (Double(differing) / Double(actual.w * actual.h), diff)
    }

    /// Returns a failure message, or nil when the image matches (or the golden was written).
    static func check(_ image: CGImage, name: String) -> String? {
        let url = goldenDir.appendingPathComponent(name + ".png")
        guard let actual = pixels(image) else { return "\(name): cannot read rendered pixels" }
        if updating {
            try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
            guard let data = png(image), (try? data.write(to: url)) != nil else { return "\(name): cannot write golden" }
            return nil
        }
        guard FileManager.default.fileExists(atPath: platformFile.path) else {
            return "\(name): missing platform record \(platformFile.path) (run with STRIM_UPDATE_GOLDENS=1)"
        }
        guard let goldenImage = load(url), let golden = pixels(goldenImage) else {
            let path = writeFailure(name, actual: image, diff: nil)
            return "\(name): missing golden \(url.path) (run with STRIM_UPDATE_GOLDENS=1); actual: \(path)"
        }
        guard golden.w == actual.w, golden.h == actual.h else {
            return "\(name): size \(actual.w)x\(actual.h) differs from golden \(golden.w)x\(golden.h); actual: \(writeFailure(name, actual: image, diff: nil))"
        }
        if golden.data == actual.data { return nil }
        let (fraction, diffBytes) = differ(actual, golden)
        guard fraction > maxDifferingFraction else { return nil }
        var diff = diffBytes
        let diffImage = diff.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: actual.w, height: actual.h, bitsPerComponent: 8, bytesPerRow: actual.w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        let paths = writeFailure(name, actual: image, diff: diffImage)
        return String(format: "%@: %.3f%% pixels differ (limit %.3f%%); %@", name, fraction * 100, maxDifferingFraction * 100, paths)
    }

    @discardableResult
    static func writeFailure(_ name: String, actual: CGImage, diff: CGImage?) -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-snapshot-failures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = ""
        let a = dir.appendingPathComponent(name + "-actual.png")
        if let d = png(actual) { try? d.write(to: a); out += "actual \(a.path)" }
        if let diff {
            let d = dir.appendingPathComponent(name + "-diff.png")
            if let data = png(diff) { try? data.write(to: d); out += " diff \(d.path)" }
        }
        return out
    }
}
