import SwiftUI

// The pieces every panel is made of, so that Settings, History, Downloads,
// Passwords and Bookmarks read as one kind of thing: the same plate, the
// same title with the cross beside it, the same hairline cards with a rule
// between lines, the same field for searching. Built once here; each panel
// only says what goes in it.

/// The plate: a rounded card with a title, a cross, whatever the panel is
/// about, and — when there is one — a foot below a hairline.
struct Plate<Content: View, Foot: View>: View {
    let title: String
    var width: CGFloat = 560
    /// Fork (ui-system): false while the panel is empty — a count of nought
    /// and a Clear with nothing to clear are not worth a rule and a row.
    var footed = true
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let foot: () -> Foot

    init(
        _ title: String,
        width: CGFloat = 560,
        footed: Bool = true,
        close: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder foot: @escaping () -> Foot
    ) {
        self.title = title
        self.width = width
        self.footed = footed
        self.close = close
        self.content = content
        self.foot = foot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Done   esc", act: close)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            content()
                .padding(.horizontal, 22)

            if Foot.self != EmptyView.self, footed {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                    .padding(.top, 18)
                foot()
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
            } else {
                Color.clear.frame(height: 20)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
    }
}

extension Plate where Foot == EmptyView {
    init(
        _ title: String,
        width: CGFloat = 560,
        close: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, width: width, close: close, content: content, foot: { EmptyView() })
    }
}

/// A group of lines in one hairline box.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsLook) private var settings // Fork (settings-revamp)

    var body: some View {
        let _ = SettingsPerf.tick("card") // Fork (settings-perf)
        VStack(spacing: 0) { content() }
            .background(SettingsMetrics.cardFill(settings)) // Fork (settings-revamp)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(SettingsMetrics.cardEdge(settings), lineWidth: 1) // Fork (settings-revamp)
            )
    }
}

/// The hairline between two lines of a card, inset like the text.
struct Rule: View {
    var inset: CGFloat? = nil // Fork (settings-revamp): nil = the line's own inset (14, or Settings' 16)
    @Environment(\.settingsLook) private var settings // Fork (settings-revamp)
    var body: some View {
        Rectangle().fill(SettingsMetrics.cardEdge(settings)).frame(height: 1).padding(.leading, inset ?? SettingsMetrics.lineInset(settings))
    }
}

/// One thing to set or do: what it is on the left, the control on the right.
struct Line<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    @Environment(\.settingsLook) private var settings // Fork (settings-revamp)

    init(_ title: String, _ detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        let _ = SettingsPerf.tick("line") // Fork (settings-perf)
        Group {
            if settings {
                // Fork (settings-revamp): in a narrow Settings window a wide
                // control (a segmented chooser, a key field) goes under its
                // text rather than squeezing it into a truncated sliver.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        words.frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                        control()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        words.frame(maxWidth: .infinity, alignment: .leading)
                        control()
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    words
                    Spacer(minLength: 8)
                    control()
                }
            }
        }
        .environment(\.controlLabel, title) // Fork (settings-a11y): the row's name for its switch or choices
        .padding(.horizontal, SettingsMetrics.lineInset(settings)) // Fork (settings-revamp)
        .padding(.vertical, SettingsMetrics.lineHeight(settings)) // Fork (settings-revamp)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
            if let detail {
                Text(detail)
                    .font(.system(size: SettingsMetrics.detailSize(settings))) // Fork (settings-revamp)
                    .foregroundStyle(SettingsMetrics.detailInk(settings)) // Fork (settings-revamp)
                    .lineLimit(settings ? nil : 3) // Fork (settings-revamp): Settings never cuts a sentence off
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small heading over a card, for when a panel has more than one.
struct Caption: View {
    let text: String
    @Environment(\.settingsLook) private var settings // Fork (settings-revamp)
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(SettingsMetrics.captionFont(settings)) // Fork (settings-revamp)
            .foregroundStyle(SettingsMetrics.captionInk(settings)) // Fork (settings-revamp)
            .padding(.leading, settings ? 16 : 2) // Fork (settings-revamp): over the row text
    }
}

/// The field for narrowing a list. The wash, the glass, the caret.
struct Hunt: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding
    @Environment(\.settingsLook) private var inSettings // Fork (settings-a11y)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true) // Fork (settings-a11y)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).foregroundStyle(Palette.muted) // Fork (ui-system): a prompt is words, ≥4.5:1
                        .accessibilityHidden(true) // Fork (settings-a11y): the field says it
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused(focus)
                    .accessibilityLabel(prompt) // Fork (settings-a11y)
            }
            .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search") // Fork (settings-a11y)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Fork (settings-a11y): in Settings, the quiet ink edge every field
        // there wears while the keyboard is in it (Fork/SettingsField.swift).
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.accent, lineWidth: 1.5) // Fork (ui-system)
                .opacity(inSettings && focus.wrappedValue ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Fork (ui-system): a panel's list as tall as what is in it, scrolling only
/// once the panel runs out of room (`sheet` holds a panel to 70% of the
/// window) — never a 400 pt box around one row.
struct Fitted<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var tall: CGFloat?

    var body: some View {
        ScrollView(showsIndicators: false) {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
        }
        .frame(maxHeight: tall)
    }
}

/// Fork (ui-system): what an empty panel says — a symbol, what it is, one
/// line of what fills it, and at most one thing to do about it.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let line: String
    @ViewBuilder let action: () -> Action

    init(_ symbol: String, _ title: String, _ line: String, @ViewBuilder action: @escaping () -> Action) {
        self.symbol = symbol
        self.title = title
        self.line = line
        self.action = action
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.muted)
                .frame(height: 34)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if Action.self != EmptyView.self {
                action().padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Action == EmptyView {
    init(_ symbol: String, _ title: String, _ line: String) {
        self.init(symbol, title, line) { EmptyView() }
    }
}

/// What a panel says when its list is empty.
struct Nothing: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
    }
}

/// A small text action inside a row — Show, Copy, Remove.
struct Quick: View {
    let title: String
    var tint: Color = Palette.ink
    let act: () -> Void
    @FocusState private var focused: Bool // Fork (settings-a11y)
    @Environment(\.isEnabled) private var enabled // Fork (settings-a11y)
    @Environment(\.settingsPageName) private var pageName // Fork (settings-a11y)

    init(_ title: String, tint: Color = Palette.ink, act: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.act = act
    }

    var body: some View {
        let _ = SettingsControlLedger.note("button", page: pageName, name: title, keyboard: enabled, disabled: !enabled, focused: focused) // Fork (settings-a11y)
        Button(action: act) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.wash, in: Capsule())
        }
        .buttonStyle(.plain)
        .settingsFocusRing($focused, shape: Capsule()) // Fork (settings-a11y): Settings' ring, not the system halo
    }
}
