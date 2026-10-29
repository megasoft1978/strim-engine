import SwiftUI
import AppKit
@testable import StrimApp
import StrimAppCore
import StrimAPI

/// `List` (sidebar, job list) is an NSOutlineView that draws no rows without a window, so the windowless tests compose
/// the same real row views (`ProjectRow`, `ThreadRow`, `JobRow`, `SelectedRowBackground`) in plain stacks, and the
/// detail pane the way `MainWindow` does. Window chrome (title bar, toolbar) is not rendered.


struct SidebarStandIn: View {
    @ObservedObject var model: AppModel
    var section: AppSection
    /// Fixed clock for the thread rows' relative times.
    let now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AppSection.sidebar) { s in
                Label(s.title, systemImage: s.icon)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).padding(.horizontal, 10)
                    .background(SelectedRowBackground(selected: section == s, hoverable: false))
            }
            ProjectsHeader(model: model, section: .constant(section)).padding(.horizontal, 10)
            ForEach(model.sidebarProjects) { p in
                ProjectRow(project: p, missing: model.folderMissing(p.id), open: true, granted: model.folderAccessRoot(p) != nil)
                    .padding(.horizontal, 10)
                let (visible, _) = Sidebar.visible(model.threads(in: p.id), selected: model.selectedThreadID, showAll: false)
                ForEach(visible) { t in
                    let selected = section == .chat && model.selectedThreadID == t.id
                    ThreadRow(thread: t, badge: model.threadBadge(t.id), selected: selected, now: now,
                              renaming: .constant(nil), renameText: .constant(""), commit: { _ in })
                        .padding(.leading, 26).padding(.trailing, 10)
                        .background(SelectedRowBackground(selected: selected, hoverable: false))
                }
            }
            if model.projects.isEmpty {
                Text("No projects yet").font(.system(size: 12)).foregroundStyle(Strim.C.tertiary).frame(height: 26).padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .environmentObject(ProjectsFlow())
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Strim.C.surface)
    }
}

struct JobListStandIn: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let view = model.jobListView
        VStack(spacing: 0) {
            ForEach(view.shown) { j in
                JobRow(job: j).padding(.horizontal, 14)
                    .background(SelectedRowBackground(selected: model.selectedJob?.id == j.id, hoverable: false))
            }
            Spacer(minLength: 0)
            if let footer = model.jobListFooter {
                HStack { Text(footer.countText).font(.system(size: 11)).foregroundStyle(Strim.C.tertiary); Spacer() }
                    .padding(.horizontal, 14).frame(height: 28)
                    .overlay(alignment: .top) { Rectangle().fill(Strim.C.hairline).frame(height: 1) }
            }
        }
        .background(Strim.C.bg)
    }
}

/// The window as `MainWindow` lays it out (sidebar column + detail), minus title bar and toolbar.
struct WindowStandIn<Detail: View>: View {
    @ObservedObject var model: AppModel
    var section: AppSection
    let width: CGFloat, height: CGFloat
    var sidebarOpen = false
    var now: Double
    /// Receives the detail column's width (it decides the layout class).
    @ViewBuilder var detail: (CGFloat) -> Detail

    private var firstRun: Bool { model.modelDownloadState.isBlockingFirstRun }
    private var sidebarShown: Bool {
        !firstRun && !SidebarVisibilityPolicy.collapsed(windowWidth: width, currentlyCollapsed: false, userPinned: false) || (sidebarOpen && !firstRun)
    }
    private var sidebarWidth: CGFloat { sidebarShown ? PaneWidths.sidebarSnapshot : 0 }
    private var detailWidth: CGFloat { width - sidebarWidth }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                SidebarStandIn(model: model, section: section, now: now).frame(width: sidebarWidth)
                Rectangle().fill(Strim.C.hairline).frame(width: 1)
            }
            detail(detailWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Strim.C.bg)
                .environment(\.layoutClass, LayoutClass.of(width: detailWidth))
        }
        .frame(width: width, height: height)
        .background(Strim.C.bg)
        .tint(Strim.C.accent)
        .foregroundStyle(Strim.C.text)
    }
}

/// Jobs section as `JobsView` lays it out: list + detail when wide, one column when compact.
struct JobsStandIn: View {
    @ObservedObject var model: AppModel
    let detailWidth: CGFloat
    var body: some View {
        if LayoutClass.of(width: detailWidth) == .compact {
            if model.selectedJob == nil { JobListStandIn(model: model) } else { JobDetailView(model: model) }
        } else {
            HStack(spacing: 0) {
                JobListStandIn(model: model).frame(width: PaneWidths.jobListIdeal)
                Rectangle().fill(Strim.C.hairline).frame(width: 1)
                JobDetailView(model: model)
            }
        }
    }
}
