import AppKit
import SwiftUI
import XCTest

/// Windowless rendering: an `NSHostingView` that is never put in a window, drawn with `cacheDisplay` into a
/// fixed 2x bitmap. No `NSWindow` is created and the app is never activated (asserted in `assertNoWindows`).
/// `ImageRenderer` was tried first: it renders pure SwiftUI but draws a "prohibited" placeholder for every
/// AppKit-backed view (ScrollView, TextField, Menu, List, NavigationSplitView, TabView).
@MainActor
enum GoldenRender {
    static let scale: CGFloat = 2

    /// `size == nil` renders at the view's fitting size.
    static func render<V: View>(_ view: V, size: CGSize?, dark: Bool) -> CGImage? {
        GoldenCompare.pinScrollerStyle()
        let scheme: ColorScheme = dark ? .dark : .light
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size ?? CGSize(width: 1000, height: 1000))
        host.layoutSubtreeIfNeeded()
        var frame = host.frame
        if size == nil {
            let fit = host.fittingSize
            frame = NSRect(origin: .zero, size: CGSize(width: ceil(fit.width), height: ceil(fit.height)))
            host.frame = frame
        }
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        guard frame.width > 0, frame.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale), pixelsHigh: Int(frame.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = frame.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    static func assertNoWindows(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSApp.windows.isEmpty, "snapshot rendering created a window", file: file, line: line)
        XCTAssertFalse(NSApp.isActive, "snapshot rendering activated the app", file: file, line: line)
    }
}
