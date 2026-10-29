import SwiftUI
import XCTest
@testable import StrimApp
import StrimAppCore

/// Proves the golden tolerance is tight enough to catch a one-word label change, and that the stand-in layout
/// constants stay inside the real column ranges.
@MainActor
final class GoldenCompareSelfTests: XCTestCase {
    private func label(_ text: String) -> GoldenCompare.Pixels? {
        let size = CGSize(width: 240, height: 40)
        let view = Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.black)
            .frame(width: size.width, height: size.height, alignment: .leading).padding(.leading, 12)
            .background(Color.white)
        guard let image = GoldenRender.render(view, size: size, dark: false) else { return nil }
        return GoldenCompare.pixels(image)
    }

    func testOneWordLabelChangeFailsCompare() throws {
        let golden = try XCTUnwrap(label("Model running"))
        let same = try XCTUnwrap(label("Model running"))
        let changed = try XCTUnwrap(label("Model stopped"))

        let (sameFraction, _) = GoldenCompare.differ(same, golden)
        XCTAssertLessThanOrEqual(sameFraction,GoldenCompare.maxDifferingFraction, "identical render must pass")

        let (fraction, _) = GoldenCompare.differ(changed, golden)
        XCTAssertGreaterThan(fraction, GoldenCompare.maxDifferingFraction,
                             "one-word label change differs in only \(fraction * 100)% of pixels; the compare would pass it")
        GoldenRender.assertNoWindows()
    }

    func testStandInWidthsAreWithinRealColumnRanges() {
        XCTAssertTrue((PaneWidths.sidebarMin...PaneWidths.sidebarMax).contains(PaneWidths.sidebarSnapshot),
                      "sidebar stand-in width \(PaneWidths.sidebarSnapshot) is outside the MainWindow column range")
        XCTAssertTrue((PaneWidths.jobListMin...PaneWidths.jobListMax).contains(PaneWidths.jobListIdeal),
                      "jobs stand-in width \(PaneWidths.jobListIdeal) is outside the JobsView column range")
    }

    func testPlatformRecordRoundTrips() {
        let p = GoldenCompare.Platform(macOSMajor: 27, scrollerStyle: 1)
        XCTAssertEqual(GoldenCompare.Platform(text: p.text), p)
        XCTAssertNil(GoldenCompare.Platform(text: "macos_major=27\n"), "a record without scroller_style must not parse")
    }
}
