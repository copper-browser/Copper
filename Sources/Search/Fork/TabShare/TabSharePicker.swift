import AppKit
import SwiftUI

// What to share, asked the way ⌘K asks things: one card a third of the way
// down the window, the page dimmed behind it, rows you can click or walk with
// the arrow keys. Tabs first — this window's space, then the others under
// their names — then a window or the whole screen, which hand over to macOS's
// own picker. Typing narrows the tabs. Return shares the highlighted row;
// Escape, a click outside or Cancel refuse, and the page hears NotAllowedError.
//
// The calling tab is left out (sharing a call into itself is a hall of
// mirrors), unless the page asked to be offered itself; then it comes first,
// marked "This tab".

/// App.swift's hook: the picker, in the window it belongs to.
struct SharePickerSlot: View {
    let browser: Browser
    @ObservedObject private var share = TabShare.shared

    var body: some View {
        ZStack {
            if let picking = share.picking, picking.browser == ObjectIdentifier(browser) {
                SharePicker(browser: browser, picking: picking)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: share.picking?.id)
    }
}

struct SharePicker: View {
    let browser: Browser
    let picking: TabShare.Picking
    @ObservedObject private var share = TabShare.shared
    @ObservedObject private var marks = Marks.ticker
    @State private var place = WindowRuler.Place()
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 520

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { share.choose(.cancel) }

            SharePickerCard(picking: picking, query: share.query, highlighted: share.highlighted,
                            rows: share.rows, tint: tint, scheme: scheme, stamp: marks.landed,
                            room: place.height > 0 ? place.height * 0.7 - 40 : 520) { share.choose($0) }
                .frame(width: SharePicker.width)
                .offset(x: -inset / 2, y: place.height > 0 ? place.height * 0.22 - place.top : 200)
        }
        .background(WindowRuler { place = $0 })
    }

    private var inset: CGFloat {
        browser.prefs.sidebar && !browser.folded ? browser.prefs.sideWidth : 0
    }

    private var tint: Color { Spaces.shared.space(in: browser).tint }

    // MARK: - keys (App.swift `take`)

    /// While the picker is up in this window, the keyboard is its own:
    /// ↑ ↓ walk, ↩ shares, ⎋ cancels, ⌫ and letters edit the filter. ⌘Q, ⌘H
    /// and ⌘M still reach the app.
    static func take(_ event: NSEvent, in browser: Browser) -> Bool {
        let share = TabShare.shared
        guard let picking = share.picking, picking.browser == ObjectIdentifier(browser) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ["q", "h", "m"].contains(key) { return false }
            if key == "." || key == "w" { share.choose(.cancel) }
            return true
        }
        let rows = share.rows
        switch event.keyCode {
        case 53: share.choose(.cancel) // ⎋
        case 36, 76: // ↩, enter
            if rows.indices.contains(share.highlighted) { share.choose(rows[share.highlighted]) }
        case 125: share.highlighted = TabShareRules.step(share.highlighted, by: 1, count: rows.count) // ↓
        case 126: share.highlighted = TabShareRules.step(share.highlighted, by: -1, count: rows.count) // ↑
        case 51: // ⌫
            if !share.query.isEmpty { share.query.removeLast(); share.highlighted = 0 }
        case 48: share.highlighted = TabShareRules.step(share.highlighted, by: flags.contains(.shift) ? -1 : 1, count: rows.count) // ⇥
        default:
            guard picking.canShareTab, !flags.contains(.control), let text = event.characters,
                  !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { break }
            share.query += text
            share.highlighted = 0
        }
        return true
    }
}

/// The card itself, apart from where it sits — so the bench can draw it on its own.
struct SharePickerCard: View {
    let picking: TabShare.Picking
    let query: String
    let highlighted: Int
    let rows: [TabShare.Choice]
    let tint: Color
    let scheme: ColorScheme
    let stamp: Int
    var room: CGFloat = 520
    /// Off for a picture of the card: ImageRenderer leaves a ScrollView out.
    var scrolls = true
    let choose: (TabShare.Choice) -> Void

    private static let rowHeight: CGFloat = 36
    private static let headingHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline.opacity(0.55)).frame(height: 1)
            list
            Rectangle().fill(Palette.hairline.opacity(0.55)).frame(height: 1)
            footer
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.ground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.26), radius: 48, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Share with \(picking.host)" + (picking.within.map { ", in a frame on " + $0 } ?? ""))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Share with \(picking.host)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            // A frame of another site inside the page asked: say whose
            // page it sits in, so the site named above is not taken for it.
            if let within = picking.within {
                Text("In a frame on \(within)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if picking.canShareTab {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Text(query.isEmpty ? "Choose a tab, a window or your whole screen" : query)
                        .font(.system(size: 12.5))
                        .foregroundStyle(query.isEmpty ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                }
            } else {
                Text("Choose a window or your whole screen")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private struct Line: Identifiable {
        let id: Int
        let heading: String?
        let choice: TabShare.Choice
    }

    /// The rows in order, each with the heading that goes above it, if any.
    private var lines: [Line] {
        var out: [Line] = []
        var lastSpace: String?? = .none
        let tabs = Dictionary(uniqueKeysWithValues: picking.tabs.map { ($0.id, $0) })
        for (index, choice) in rows.enumerated() {
            var heading: String?
            switch choice {
            case .tab(let id):
                let space = tabs[id]?.space
                if lastSpace == .none || lastSpace! != space { heading = space ?? "Tabs" }
                lastSpace = .some(space)
            case .window:
                heading = lastSpace == .none ? nil : "Window or screen"
            default: break
            }
            out.append(Line(id: index, heading: heading, choice: choice))
        }
        return out
    }

    private var naturalHeight: CGFloat {
        let headings = CGFloat(lines.filter { $0.heading != nil }.count)
        return CGFloat(rows.count) * (SharePickerCard.rowHeight + 1) + headings * (SharePickerCard.headingHeight + 2) + 14
    }

    private var list: some View {
        ScrollViewReader { reader in
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { rowStack }
                    .frame(height: min(naturalHeight, max(room, 220)))
                    .onChange(of: highlighted) { _, row in
                        withAnimation(Motion.quick) { reader.scrollTo(row) }
                    }
            } else {
                rowStack
            }
        }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            if picking.canShareTab, !rows.contains(where: { if case .tab = $0 { return true } else { return false } }) {
                Text(query.isEmpty ? "No other tabs to share" : "No tabs match")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: SharePickerCard.rowHeight)
            }
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 1) {
                    if let heading = line.heading {
                        Text(heading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: SharePickerCard.headingHeight, alignment: .bottomLeading)
                            .padding(.bottom, 1)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ShareRow(choice: line.choice, candidate: candidate(line.choice), picked: line.id == highlighted,
                             tint: tint, scheme: scheme, stamp: stamp)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(line.choice) }
                }
                .id(line.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Tab audio isn't shared")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted.opacity(picking.canShareTab && picking.systemAudio ? 1 : 0))
            Spacer()
            Button { choose(.cancel) } label: {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            Button {
                if rows.indices.contains(highlighted) { choose(rows[highlighted]) }
            } label: {
                Text("Share")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func candidate(_ choice: TabShare.Choice) -> TabShareRules.Candidate? {
        guard case .tab(let id) = choice else { return nil }
        return picking.tabs.first { $0.id == id }
    }
}

private struct ShareRow: View {
    let choice: TabShare.Choice
    let candidate: TabShareRules.Candidate?
    let picked: Bool
    let tint: Color
    let scheme: ColorScheme
    let stamp: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            mark.frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
            Spacer(minLength: 12)
            if candidate?.isCaller == true {
                Text("This tab")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
            Text("↩")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .opacity(picked ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background {
            if picked {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.17))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.hover)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: picked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (detail.map { ", " + $0 } ?? ""))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String {
        switch choice {
        case .tab: return candidate?.title ?? "Tab"
        case .window: return "A window…"
        case .screen: return "Entire screen…"
        case .cancel: return "Cancel"
        }
    }

    private var detail: String? {
        switch choice {
        case .tab: return candidate?.host
        default: return nil
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch choice {
        case .tab(let id):
            let tab = AgentTabs.find(id)
            RowMark(icon: tab?.icon, letter: tab?.monogram ?? String((candidate?.title ?? "T").prefix(1)).uppercased(),
                    tint: SpaceTint(scheme).offColumn)
        case .window:
            glyph("macwindow")
        case .screen:
            glyph("display")
        case .cancel:
            glyph("xmark")
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(picked ? tint : Palette.muted)
            .frame(width: 18, height: 18)
    }
}
