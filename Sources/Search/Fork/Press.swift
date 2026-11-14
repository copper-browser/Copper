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
            .animation(still ? nil : Motion.quick, value: down)
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
struct FadingTitle: View {
    let text: Text

    var body: some View {
        ViewThatFits(in: .horizontal) {
            text.lineLimit(1)
            text.lineLimit(1)
                .fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                    }
                }
        }
    }
}
