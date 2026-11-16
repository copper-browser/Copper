import SwiftUI

// Fork (motion): one pressed state for everything you click in the chrome —
// tab rows, top tabs, pinned tiles, space chips, browser pills — so a press
// answers the same way wherever it lands: the thing gives a hair under the
// finger (98%) and darkens by a 6% wash of ink. Reduce Motion keeps the wash
// and drops the give.

/// The look of a press, for a Button (`Press`) or a tap target (`Pressable`).
struct PressLook: ViewModifier {
    let down: Bool
    var radius: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.ink.opacity(down ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(down && !still ? 0.98 : 1)
            // Fork (r7 motion): the press lands in the frame after the click, the
            // let-go eases out — eased in too, it crept in over 4 frames.
            .animation(still || down ? nil : Motion.quick, value: down)
    }
}

/// The house ButtonStyle: a plain button that shows it was pressed. A
/// capsule is a radius past half its height (RoundedRectangle clamps it).
struct Press: ButtonStyle {
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressLook(down: configuration.isPressed, radius: radius))
    }
}

/// The same press on a view that is a tap and a drag rather than a Button
/// (rows, pins, chips). A long press that never fires reads the button
/// state without taking the click from the tap or the pick-up from the drag:
/// it lets go after 4 pt of travel, before a drag (5 pt) starts.
struct Pressable: ViewModifier {
    var radius: CGFloat = 10
    @State private var down = false

    func body(content: Content) -> some View {
        content
            .modifier(PressLook(down: down, radius: radius))
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 4, perform: {}, onPressingChanged: { down = $0 })
    }
}

/// Fork (motion): a tab's title in the column or the strip. One that fits is
/// plain text; one that doesn't runs out under a 24 pt fade instead of an
/// ellipsis, as Arc's do. Only the overflowing ones pay for the mask (an
/// offscreen pass — see RowEndFade).
///
/// Fork (switch, hill-climb r4): one Text, measured once. It was a
/// ViewThatFits of two copies of the title, which built both — the faded
/// one's mask and gradient too — for every row a space switch brought in,
/// and measured the title twice. Now the line takes what its words need, up
/// to what it is offered (`TitleLine`, which keeps the words' width), and a
/// geometry reading that changes only when that flips puts the fade on.
struct FadingTitle: View {
    let text: Text
    @State private var line = TitleLine.Width()
    @State private var over = false

    var body: some View {
        TitleLine(width: line) { text.lineLimit(1) }
            .clipped()
            .modifier(TitleFade(on: over))
            .onGeometryChange(for: Bool.self) { $0.size.width + 0.5 < line.natural } action: { over = $0 }
    }
}

/// One line of text at its own width, or at what it is offered when that is
/// less — drawn whole from its leading edge either way, for a clip to cut.
/// Its words' width is kept in `width` for the title to read after layout.
struct TitleLine: Layout {
    final class Width { var natural: CGFloat = 0 }
    let width: Width

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let line = subviews.first else { return .zero }
        let ideal = line.sizeThatFits(.unspecified)
        width.natural = ideal.width
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// The title's last 24 pt fading out, only while it overflows.
private struct TitleFade: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 24)
                }
            }
        } else {
            content
        }
    }
}
