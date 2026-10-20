import AppKit
import SwiftUI

// The column bounces at its ends, the way Arc's and every native list does:
// scroll past the top or the bottom and the rows stretch away from the edge
// and spring back, whether or not there are enough of them to scroll.
//
// `.scrollBounceBehavior(.always, axes: .vertical)` asks for that, but
// whether SwiftUI carries it through to the NSScrollView underneath has
// varied by release, so the scroll view is also found and told directly:
// elastic up and down, never sideways — a sideways stretch would fight the
// space swipe (Swipes.swift), which owns that axis over the column. The
// column's fade (SideBar.fade) masks the scroll's frame, not its content, so
// rows pulled past an end still run out under the same soft edge.
struct SideScrollElasticity: NSViewRepresentable {
    /// Whose column this scroll is: every space visited this launch keeps
    /// its own (SpaceColumns).
    var space: UUID? = nil

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.space = space
        view.apply()
    }

    final class Probe: NSView {
        var space: UUID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The scroll view is put together around the content after the
            // content's views exist; a turn later it is there to be found.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.verticalScrollElasticity != .allowed { scroll.verticalScrollElasticity = .allowed }
            if scroll.horizontalScrollElasticity != .none { scroll.horizontalScrollElasticity = .none }
            if window == Links.window, let space { SideScrollElasticity.columns[space] = Held(scroll) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The first window's column for each space it keeps one for.
    private final class Held { weak var scroll: NSScrollView?; init(_ scroll: NSScrollView) { self.scroll = scroll } }
    @MainActor private static var columns: [UUID: Held] = [:]

    /// The first window's column for `space`, if it has one laid out.
    @MainActor static func column(for space: UUID) -> NSScrollView? { columns[space]?.scroll }

    /// The first window's column on screen: the bench's, and what a slide's
    /// outgoing preview is scrolled as.
    @MainActor static var column: NSScrollView? { column(for: Spaces.shared.current(in: Windows.main)) }

    // MARK: - the bench

    /// `spaces scroll`: the column's scroll view as it stands — how elastic
    /// each way, where it is scrolled to, how tall its rows are. (A scripted
    /// scroll was tried: wheel events made in-process reach neither a
    /// HostingScrollView handed them directly nor, posted to the app, a
    /// window that is behind another one, so the bounce itself is for
    /// fingers to check.)
    @MainActor static func script(_ arg: String) -> [String: Any] {
        guard let scroll = column else { return ["error": "no column"] }
        func name(_ e: NSScrollView.Elasticity) -> String { e == .allowed ? "allowed" : e == .none ? "none" : "automatic" }
        return ["y": Double(scroll.contentView.bounds.minY.rounded()),
                "visible": Double(scroll.contentView.bounds.height.rounded()),
                "document": Double((scroll.documentView?.frame.height ?? 0).rounded()),
                "vertical": name(scroll.verticalScrollElasticity), "horizontal": name(scroll.horizontalScrollElasticity)]
    }
}
