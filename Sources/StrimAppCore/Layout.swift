import CoreGraphics

/// Width class of the detail column. Views reflow at these breakpoints.
public enum LayoutClass: Sendable, Equatable {
    case compact, regular, wide

    public static let compactBelow: CGFloat = 760
    public static let wideFrom: CGFloat = 1200

    public static func of(width: CGFloat) -> LayoutClass {
        width < compactBelow ? .compact : (width >= wideFrom ? .wide : .regular)
    }
}

/// Auto-collapse of the sidebar by window width, with hysteresis so it does not flap while dragging an edge.
/// Collapses once the window narrows below `collapseBelow`, restores once it widens past `restoreAbove`, and does
/// nothing after the user toggled the sidebar by hand.
public enum SidebarVisibilityPolicy {
    public static let collapseBelow: CGFloat = 820
    public static let restoreAbove: CGFloat = 880

    /// Returns whether the sidebar should be collapsed.
    public static func collapsed(windowWidth: CGFloat, currentlyCollapsed: Bool, userPinned: Bool) -> Bool {
        if userPinned { return currentlyCollapsed }
        if windowWidth < collapseBelow { return true }
        if windowWidth > restoreAbove { return false }
        return currentlyCollapsed
    }
}

/// How the toolbar's Start/Stop control is shown at a given window width.
public enum ToolbarStartStopStyle: Sendable, Equatable {
    case labeled, iconOnly, inMenu

    public static let inMenuBelow: CGFloat = 700

    public static func of(windowWidth: CGFloat, layout: LayoutClass) -> ToolbarStartStopStyle {
        if windowWidth < inMenuBelow { return .inMenu }
        return layout == .compact ? .iconOnly : .labeled
    }
}

/// Pane widths shared by the real views (`MainWindow`, `JobsView`) and the snapshot stand-ins
/// (`Tests/StrimAppSnapshotTests/StandIns.swift`), so the goldens cannot drift from the layout they describe.
public enum PaneWidths {
    /// Sidebar column (`MainWindow`): min / ideal / max.
    public static let sidebarMin: CGFloat = 180
    public static let sidebarIdeal: CGFloat = 200
    public static let sidebarMax: CGFloat = 240
    /// Sidebar width the windowless snapshot stand-in is composed at. Must lie within the column range.
    public static let sidebarSnapshot: CGFloat = 220

    /// Jobs list column (`JobsView`): min / ideal / max.
    public static let jobListMin: CGFloat = 240
    public static let jobListIdeal: CGFloat = 300
    public static let jobListMax: CGFloat = 420
}
