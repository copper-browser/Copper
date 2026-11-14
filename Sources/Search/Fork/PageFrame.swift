import AppKit
import SwiftUI

// Fork (page-frame): the page as Arc lays it out in the sidebar layout — a
// card inset in the space's ground, not a window sawn in two at the column's
// edge.
//
// The space's ground (SpaceGround) runs under the whole window, the column
// draws none of its own, and the stage sits in it with a margin on the top,
// the right and the bottom, round corners, a hairline and a soft shadow: the
// split's cards (SplitMetrics), so one page and two read as the same thing.
// The top-tab layout has no space ground to sit in and keeps its full-bleed
// page.
//
// The page is a WKWebView, an AppKit layer that SwiftUI's `.clipShape` does
// not reach, so its corners are rounded on the stage's own layer instead
// (`StageView.round`), told how by the environment. Painting the corners back
// out in the colour behind (the split's old way) cannot match a picture or a
// gradient behind the card.

/// How the stage's corners are cut: the radius, and whether only the bottom
/// two (a split card, whose top is its own toolbar).
struct PageCorners: Equatable {
    var radius: CGFloat = 0
    var bottomOnly = false

    /// The same corners for the SwiftUI drawn over the page (the cover a
    /// waking tab shows, the error page), which `.clipShape` does reach.
    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: bottomOnly ? 0 : radius, bottomLeadingRadius: radius,
                               bottomTrailingRadius: radius, topTrailingRadius: bottomOnly ? 0 : radius,
                               style: .continuous)
    }
}

private struct PageCornersKey: EnvironmentKey {
    static let defaultValue = PageCorners()
}

extension EnvironmentValues {
    var pageCorners: PageCorners {
        get { self[PageCornersKey.self] }
        set { self[PageCornersKey.self] = newValue }
    }
}

extension StageView {
    /// Cuts the page's corners on the layer that holds it. Square (the
    /// default) costs nothing: no mask at all. Called on every update of the
    /// stage, so a layer already cut this way is left alone.
    func round(_ corners: PageCorners) {
        guard corners != cut else { return }
        cut = corners
        wantsLayer = true
        guard let layer else { return }
        let r = corners.radius
        layer.cornerRadius = r
        layer.cornerCurve = .continuous
        layer.masksToBounds = r > 0
        // A view's layer is not flipped: its min-Y corners are the bottom ones.
        layer.maskedCorners = corners.bottomOnly
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
}

/// The window's ground in the sidebar layout: the space's, the one surface
/// the column and the margin round the page both sit on.
struct WindowGround: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser) {
        self.browser = browser
        prefs = browser.prefs
    }

    var body: some View { SpaceGroundView(browser: browser, dark: scheme == .dark, span: prefs.sideWidth) }
}

/// One page as a card: rounded, hairlined, lifted off the ground.
struct PageCard: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Page(tab: tab)
            .environment(\.pageCorners, PageCorners(radius: SplitMetrics.corner))
            .background(PageCard.plate(lifted: true))
            .overlay { PageCard.edge }
    }

    /// The card's ground and the only thing carrying the shadow — on the
    /// subtree instead, the page inside loses its place (see SplitPane.swift).
    static func plate(lifted: Bool) -> some View {
        RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
            .fill(Palette.ground)
            .shadow(color: .black.opacity(lifted ? 0.14 : 0.09), radius: lifted ? 4 : 3, y: 1)
    }

    /// Half a point of edge, so a white page holds on a pale ground and a
    /// dark one on a dark ground.
    static var edge: some View {
        RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false)
    }
}

/// The agent's pane as a card beside the page card. An addon's pane is a web
/// view, which `.clipShape` does not round and whose frame it upsets (see
/// SplitPane.swift), so only the native pane is clipped; an addon's keeps
/// square corners inside the card's edge.
struct PaneCard: ViewModifier {
    let on: Bool
    @ObservedObject private var addons = AddonSync.shared

    func body(content: Content) -> some View {
        if on {
            let shape = RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
            Group {
                if addons.active(.agentSidebar) == nil { content.clipShape(shape) } else { content }
            }
            .background(PageCard.plate(lifted: false))
            .overlay { PageCard.edge }
        } else {
            content
        }
    }
}
