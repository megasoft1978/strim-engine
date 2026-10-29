import Foundation
import Testing
@testable import StrimAppCore

@Suite struct LayoutTests {
    @Test func testLayoutClassBoundaries() {
        #expect(LayoutClass.of(width: 0) == .compact)
        #expect(LayoutClass.of(width: 759) == .compact)
        #expect(LayoutClass.of(width: 760) == .regular)
        #expect(LayoutClass.of(width: 1199) == .regular)
        #expect(LayoutClass.of(width: 1200) == .wide)
        #expect(LayoutClass.of(width: 3000) == .wide)
    }

    @Test func testSidebarCollapsesBelow820AndRestoresAbove880() {
        typealias P = SidebarVisibilityPolicy
        #expect(P.collapsed(windowWidth: 819, currentlyCollapsed: false, userPinned: false))
        // Hysteresis band keeps whatever state it has.
        #expect(!(P.collapsed(windowWidth: 820, currentlyCollapsed: false, userPinned: false)))
        #expect(!(P.collapsed(windowWidth: 850, currentlyCollapsed: false, userPinned: false)))
        #expect(P.collapsed(windowWidth: 850, currentlyCollapsed: true, userPinned: false))
        #expect(P.collapsed(windowWidth: 880, currentlyCollapsed: true, userPinned: false))
        #expect(!(P.collapsed(windowWidth: 881, currentlyCollapsed: true, userPinned: false)))
    }

    @Test func testSidebarNeverChangesAfterUserToggle() {
        typealias P = SidebarVisibilityPolicy
        #expect(!(P.collapsed(windowWidth: 600, currentlyCollapsed: false, userPinned: true)))
        #expect(P.collapsed(windowWidth: 1400, currentlyCollapsed: true, userPinned: true))
    }

    @Test func testSidebarDragSequenceDoesNotFlap() {
        typealias P = SidebarVisibilityPolicy
        var collapsed = false
        var changes = 0
        for w in stride(from: 1000, through: 700, by: -10).map(CGFloat.init) + stride(from: 700, through: 1000, by: 10).map(CGFloat.init) {
            let n = P.collapsed(windowWidth: w, currentlyCollapsed: collapsed, userPinned: false)
            if n != collapsed { changes += 1 }
            collapsed = n
        }
        #expect(changes == 2)
        #expect(!(collapsed))
    }

    @Test func testToolbarStartStopStyle() {
        #expect(ToolbarStartStopStyle.of(windowWidth: 699, layout: .compact) == .inMenu)
        #expect(ToolbarStartStopStyle.of(windowWidth: 700, layout: .compact) == .iconOnly)
        #expect(ToolbarStartStopStyle.of(windowWidth: 1040, layout: .regular) == .labeled)
        #expect(ToolbarStartStopStyle.of(windowWidth: 1500, layout: .wide) == .labeled)
    }
}
