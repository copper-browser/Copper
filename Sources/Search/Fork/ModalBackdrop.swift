import SwiftUI

/// Fork (ui-flows r3): the one ground every modal stands on — the panels,
/// Settings and Move in (⌘K keeps its own dim). The page card steps back,
/// a little darker; the column beside it stays crisp, as Arc
/// leaves its sidebar. The whole window still takes the click, so nothing
/// under a panel is pressed by accident.
struct ModalBackdrop: View {
    /// Where the page card starts (the column's width), or 0 for the window.
    var column: CGFloat = 0
    /// Fork (ardia layout): that column on the right.
    var right = false
    /// Fork (ardia layout): the page frame now, so a change under an open panel redraws.
    var pageFrame = SplitMetrics.frame
    let tap: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// The dim: light 14%, dark 30%.
    static func dim(dark: Bool) -> Double { dark ? 0.30 : 0.14 }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
            // Fork (polish r5): a flat dim, no blur — the material picked up a
            // page's hero colour and glowed it round the panel.
            let shape = RoundedRectangle(cornerRadius: column > 0 ? pageFrame.corner : 0, style: .continuous)
            shape.fill(Color.black.opacity(Self.dim(dark: scheme == .dark)))
                .padding(column > 0
                         ? EdgeInsets(top: pageFrame.margin, leading: right ? pageFrame.margin : column, bottom: pageFrame.margin, trailing: right ? column : pageFrame.margin)
                         : EdgeInsets())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

/// Move in's backdrop, in the window it is up over (Fork/Flow/FlowPresenter):
/// its own small view, so a move's every step doesn't redraw the window.
struct FlowBackdrop: View {
    let browser: Browser
    var column: CGFloat
    var right = false
    @ObservedObject private var presenter = FlowPresenter.shared

    var body: some View {
        if let number = presenter.hostNumber, Windows.window(of: browser)?.windowNumber == number {
            // A click on the window behind gives the keyboard back to Move in.
            ModalBackdrop(column: column, right: right) { presenter.refocus() }
                .transition(.opacity)
        }
    }
}
