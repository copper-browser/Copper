import SwiftUI

// The ground of a text field in Settings: the wash it always sat on and,
// while the keyboard is in it, a quiet ink edge — so Tab never lands
// somewhere you can't see. Plain-style fields draw no ring of their own.
//
// Same name and shape as the Settings shell's (SettingsControls.swift); when
// both are in one tree, keep one.

extension View {
    /// Goes where the field's `.background(Palette.wash, in: RoundedRectangle(…))`
    /// went, after its padding, so the edge follows the field's own outline.
    func settingsField(radius: CGFloat = 7, fill: Color = Palette.wash) -> some View {
        modifier(SettingsFieldGround(radius: radius, fill: fill))
    }

    /// Fork (uitype): an empty field's example, in muted ink and the
    /// proportional face — the system's own prompt is ~1.5:1, and a plain
    /// field ignores a prompt's colour. Goes on the field, before its padding.
    func fieldExample(_ text: String, when empty: Bool) -> some View {
        background(alignment: .leading) {
            if empty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// `settingsField()`: the wash, and the ink edge while focused.
struct SettingsFieldGround: ViewModifier {
    let radius: CGFloat
    let fill: Color
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .focused($focused)
            .background(fill, in: shape)
            .overlay {
                shape
                    .strokeBorder(Palette.accent, lineWidth: 1.5) // Fork (ui-system)
                    .opacity(focused ? 1 : 0)
                    .animation(Motion.quick, value: focused)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
