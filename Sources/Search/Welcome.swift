import SwiftUI
import AppKit

/// The first time. Four short pages over the window, in the app's own
/// language: what this is, what to bring over, how to hold it, and whether
/// links from other apps should come here. Nothing is asked twice, and every
/// page can be skipped.
struct WelcomePanel: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var page = 0
    @State private var forward = true

    // The default browser.
    @State private var isDefault = Links.isDefault
    @State private var asked = false

    private let pages = 4
    @Environment(\.colorScheme) private var scheme

    /// Fork (ui-flows r3): one column on one card, Arc's onboarding size
    /// (~560 pt wide), every page left-aligned and every heading in the same
    /// place — on the Home space's own ground.
    /// Fork (uiflows r4): the card hugs its page (no blank half), never
    /// shorter than `least` (332 pt with its padding). Its top stays put
    /// (`top`) so the headings don't move; a taller page grows it downward.
    static let column: CGFloat = 560
    static let least: CGFloat = 260

    /// Where the card's top sits: a `least` card's middle 40% down the window.
    static func top(in height: CGFloat) -> CGFloat { max(height * 0.4 - (least / 2 + 36), 24) }

    var body: some View {
        GeometryReader { room in
            ZStack {
                ThemeBackdrop(theme: tint.theme, dark: tint.night)
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        switch page {
                        case 0: welcome
                        case 1: bring
                        case 2: hold
                        default: links
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                        removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                    ))
                    Spacer(minLength: 32)
                    foot
                }
                .frame(width: Self.column)
                .frame(minHeight: Self.least)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .padding(36)
                // Fork (uiflows r4): the shadow is the card's shape's alone —
                // on the whole card every word and icon cast its own (a grey haze).
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Palette.ground)
                        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
                }
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .padding(.top, Self.top(in: room.size.height))
                .frame(width: room.size.width, height: room.size.height, alignment: .top)
            }
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
    }

    // MARK: - the pages

    private var welcome: some View {
        HStack(alignment: .top, spacing: 28) { // Fork (polish r5): the column it is about, beside the words
            VStack(alignment: .leading, spacing: 22) {
                CopperIcon(size: 64)
                heading(Fork.name, "A browser that works for you. Spaces, an agent at your side, and the engine already in your Mac.")
            }
            SpacesThumb(tint: tint)
        }
    }

    private var tint: SpaceTint { SpaceTint(space: Spaces.shared.space(in: browser), dark: scheme == .dark) }

    /// Fork (ui-flows): Move in's own pills and sheet, not a second importer
    /// with its own list of browsers (Fork/StartCard.swift `MoveFrom`).
    private var bring: some View {
        HStack(alignment: .top, spacing: 28) { bringWords; SpacesThumb(tint: tint) } // Fork (polish r5)
    }

    private var bringWords: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring things over.", "Tabs, bookmarks, history, passwords and sign-ins from \(MoveFrom.names). Nothing in the other browser changes.")
            if MoveFrom.found.isEmpty {
                Text("No other browser found on this Mac — nothing to bring.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            } else {
                MoveFromPills(browser: browser, via: .welcome)
            }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Two ways to hold it.", "Titles across the top, or down the side. The highlight follows the tab you pick either way, and you can change your mind with ⇧⌘S.")
            HStack(spacing: 12) {
                Way(title: "Tab strip", sidebar: false, chosen: !prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = false }
                }
                Way(title: "Sidebar", sidebar: true, chosen: prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = true }
                }
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Links from other apps.", "A click in Mail, in Slack, in a PDF — macOS sends it to whichever browser is the default. It can be this one.")
            HStack(spacing: 12) {
                if isDefault {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                        Text("Copper is the default browser")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                } else {
                    Big("Make Copper the default") { // Fork (ui-flows): one primary per page, Continue's
                        asked = true
                        Links.becomeDefault { _ in isDefault = Links.isDefault }
                    }
                    if asked, !isDefault {
                        Text("macOS asks in its own dialog")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .animation(Motion.settle, value: isDefault)

            VStack(alignment: .leading, spacing: 8) {
                Text("Three things worth knowing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, 6)
                Key("⌘T", "A new tab. Type a place, or words to search.")
                Key("⌘K", "Every open tab, by name.")
                Key("⌘,", "Settings, including passwords and updates.")
            }
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    // Fork (uichrome): solid muted (0.8 of it drew 2.2:1 on dark),
                    // the page you are on a longer ink capsule, not a shade apart.
                    Capsule()
                        .fill(i == page ? Palette.ink : Palette.muted) // Fork (ui-flows): ≥3:1, faint was 1.5:1
                        .frame(width: i == page ? 14 : 6, height: 6)
                }
            }
            Spacer()
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            if page < pages - 1 {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Big(page < pages - 1 ? "Continue" : "Start browsing", filled: true) {
                if page < pages - 1 { forward = true; page += 1 } else { finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - doing

    private func finish() {
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
    }

    private func heading(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .semibold)) // Fork (ui-flows r3): Arc's onboarding sizes
                .foregroundStyle(Palette.ink)
            Text(line)
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - pieces

    private struct Big: View {
        let title: String
        var filled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(filled ? Palette.onAccent : Palette.ink) // Fork (ui-system)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.accent : (hovering ? Palette.hover : Palette.wash), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    /// One of the two ways, as a small drawing of the window.
    /// Fork (polish r5): a small picture of the Spaces column — what Copper
    /// is, shown, beside the first two pages' words (they were text alone).
    /// Drawn, not a screenshot: it wears this space's own colours.
    private struct SpacesThumb: View {
        let tint: SpaceTint
        static let widths: [CGFloat] = [52, 64, 44, 58]
        static let hues: [Double] = [0.12, 0.42, 0.62]

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(tint.faint).frame(width: 5, height: 5) } }
                    .padding(.bottom, 2)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.square).frame(height: 14)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.square).frame(height: 18) }
                }
                ForEach(0..<4, id: \.self) { i in // four rows: five overflowed the 176 pt card at its top
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(i == 1 ? tint.dot : tint.faint).frame(width: 7, height: 7)
                        RoundedRectangle(cornerRadius: 2).fill(tint.faint.opacity(0.7)).frame(width: SpacesThumb.widths[i], height: 5)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background { if i == 1 { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.pill).shadow(color: tint.lift, radius: 2, y: 1) } }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint.dot).frame(width: 11, height: 11)
                    ForEach(SpacesThumb.hues, id: \.self) { hue in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(hue: hue, saturation: 0.35, brightness: tint.dark ? 0.6 : 0.75)).frame(width: 11, height: 11)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: 132, height: 176)
            .background(tint.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .accessibilityHidden(true)
        }
    }

    private struct Way: View {
        let title: String
        let sidebar: Bool
        let chosen: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground)
                        if sidebar {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                        .padding(.bottom, 4)
                                    ForEach(0..<4, id: \.self) { i in
                                        RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(height: 8)
                                    }
                                }
                                .padding(8)
                                .frame(width: 62)
                                Rectangle().fill(Palette.hairline).frame(width: 1)
                                Spacer()
                            }
                        } else {
                            HStack(spacing: 3) {
                                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                    .padding(.trailing, 6)
                                ForEach(0..<4, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(width: 30, height: 8)
                                }
                            }
                            .padding(8)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    Text(title)
                        .font(.system(size: 13, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chosen ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chosen ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.settle, value: chosen)
        }
    }

    private struct Key: View {
        let keys: String
        let what: String
        init(_ keys: String, _ what: String) { self.keys = keys; self.what = what }
        var body: some View {
            HStack(spacing: 10) {
                Text(keys)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(minWidth: 44)
                Text(what).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }
}
