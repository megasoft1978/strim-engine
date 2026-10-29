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
