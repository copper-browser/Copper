import SwiftUI

/// Fork (ui-flows r3): the one ground every modal stands on — the panels,
/// Settings and Move in (⌘K keeps its own dim). The page card steps back,
/// blurred and a little darker; the column beside it stays crisp, as Arc
/// leaves its sidebar. The whole window still takes the click, so nothing
/// under a panel is pressed by accident.
struct ModalBackdrop: View {
    /// Where the page card starts (the column's width), or 0 for the window.
    var column: CGFloat = 0
    let tap: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// The dim over the blur: light 12%, dark 30%.
    static func dim(dark: Bool) -> Double { dark ? 0.30 : 0.12 }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
            // shortcut: the system material's blur radius (~20 pt) is fixed; a
            // CABackdropLayer filter would set it exactly, if it ever matters.
            let shape = RoundedRectangle(cornerRadius: column > 0 ? SplitMetrics.corner : 0, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(Self.dim(dark: scheme == .dark)).clipShape(shape))
                .padding(column > 0
                         ? EdgeInsets(top: SplitMetrics.margin, leading: column, bottom: SplitMetrics.margin, trailing: SplitMetrics.margin)
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
    @ObservedObject private var presenter = FlowPresenter.shared

    var body: some View {
        if let number = presenter.hostNumber, Windows.window(of: browser)?.windowNumber == number {
            // A click on the window behind gives the keyboard back to Move in.
            ModalBackdrop(column: column) { presenter.refocus() }
                .transition(.opacity)
        }
    }
}
