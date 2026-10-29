import Foundation
import Testing
import StrimAppCore

@Suite struct LayoutSweepTests {
    @Test func widthSweepAndHysteresis() {
        var collapsed = false
        var transitions = 0
        let widths = Array(stride(from: 2000, through: 400, by: -20)) + Array(stride(from: 400, through: 2000, by: 20))
        for width in widths {
            let w = CGFloat(width)
            let layout = LayoutClass.of(width: w)
            #expect(layout == (w < 760 ? .compact : w < 1200 ? .regular : .wide))
            let next = SidebarVisibilityPolicy.collapsed(windowWidth: w, currentlyCollapsed: collapsed, userPinned: false)
            if next != collapsed { transitions += 1 }
            collapsed = next
            #expect(SidebarVisibilityPolicy.collapsed(windowWidth: w, currentlyCollapsed: false, userPinned: true) == false)
            #expect(SidebarVisibilityPolicy.collapsed(windowWidth: w, currentlyCollapsed: true, userPinned: true) == true)
        }
        #expect(transitions == 2 && !collapsed)
        #expect(SidebarVisibilityPolicy.collapsed(windowWidth: 820, currentlyCollapsed: false, userPinned: false) == false)
        #expect(SidebarVisibilityPolicy.collapsed(windowWidth: 880, currentlyCollapsed: true, userPinned: false) == true)
    }
}
