import AppKit
import SwiftUI

// What to share, asked the way ⌘K asks things: one card a fifth of the way
// down the window, the page dimmed behind it. At the top, side by side,
// Entire screen and A window, which hand over to macOS's own picker: always
// there, never under a list. Below them the tabs: a search field, the few
// last looked at in any space, and "All tabs", which opens onto every one —
// this window's space, then the others under their names. Typing searches
// all of them. Return shares the highlighted choice; Escape, a click outside
// or Cancel refuse, and the page hears NotAllowedError.
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
    /// Where the card's top sits, as a share of the window's height.
    static let drop: CGFloat = 0.22

    /// The most the card may stand in a window this tall: down to just above
    /// its bottom edge.
    static func room(in height: CGFloat) -> CGFloat {
        height * (1 - drop) - 28
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { share.choose(.cancel) }

            SharePickerCard(picking: picking, query: share.query, highlighted: share.highlighted,
                            rows: share.rows, tint: tint, scheme: scheme, stamp: marks.landed,
                            room: place.height > 0 ? SharePicker.room(in: place.height) : 640,
                            pick: { share.pick($0) }, cancel: { share.choose(.cancel) }, clear: { share.edited("") })
                .frame(width: SharePicker.width)
                .offset(x: -inset / 2, y: place.height > 0 ? place.height * SharePicker.drop - place.top : 200)
        }
        .background(WindowRuler { place = $0 })
    }

    private var inset: CGFloat {
        browser.prefs.sidebar && !browser.folded ? browser.prefs.sideWidth : 0
    }

    private var tint: Color { Spaces.shared.space(in: browser).tint }

    // MARK: - keys (App.swift `take`)

    /// While the picker is up in this window, the keyboard is its own:
    /// ↑ ↓ ⇥ walk, ← → go between Entire screen and A window, ↩ shares, ⎋
    /// cancels, ⌫ and letters edit the search. ⌘Q, ⌘H and ⌘M still reach
    /// the app.
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
            if rows.indices.contains(share.highlighted) { share.pick(rows[share.highlighted]) }
        case 125: share.highlighted = TabShareRules.step(share.highlighted, by: 1, count: rows.count) // ↓
        case 126: share.highlighted = TabShareRules.step(share.highlighted, by: -1, count: rows.count) // ↑
        case 123: share.highlighted = TabShareRules.across(share.highlighted, by: -1) // ←
        case 124: share.highlighted = TabShareRules.across(share.highlighted, by: 1) // →
        case 51: // ⌫
            if !share.query.isEmpty { share.edited(String(share.query.dropLast())) }
        case 48: share.highlighted = TabShareRules.step(share.highlighted, by: flags.contains(.shift) ? -1 : 1, count: rows.count) // ⇥
        default:
            guard picking.canShareTab, !flags.contains(.control), let text = event.characters,
                  !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
                  // A space before anything is typed searches for nothing.
                  !(share.query.isEmpty && text.allSatisfy(\.isWhitespace))
            else { break }
            share.edited(share.query + text)
        }
        return true
    }
}

/// The card itself, apart from where it sits — so the bench can draw it on its own.
struct SharePickerCard: View {
    let picking: TabShare.Picking
    let query: String
    let highlighted: Int
    let rows: [TabShareRules.Row]
    let tint: Color
    let scheme: ColorScheme
    let stamp: Int
    /// The most the card may stand, top to bottom. The tabs scroll inside
    /// whatever the rest leaves them.
    var room: CGFloat = 640
    /// Off for a picture of the card: ImageRenderer leaves a ScrollView out,
    /// so the list is drawn from its top and cut where the scroll view would
    /// end.
    var scrolls = true
    var pick: (TabShareRules.Row) -> Void = { _ in }
    var cancel: () -> Void = {}
    var clear: () -> Void = {}

    // Fixed, so the card's height is known before it is drawn: a scroll view
    // left to size itself takes all the room it is offered.
    private static let rowHeight: CGFloat = 36
    private static let headingHeight: CGFloat = 26
    private static let tileHeight: CGFloat = 44
    private static let fieldHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            if picking.canShareTab {
                hairline
                field
                list
            }
            hairline
            footer
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.ground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        // One shadow, the card's. Without the group every field, tile and
        // word on it cast one of its own.
        .compositingGroup()
        .shadow(color: .black.opacity(0.09), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.26), radius: 48, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Share with \(picking.host)" + (picking.within.map { ", in a frame on " + $0 } ?? ""))
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline.opacity(0.55)).frame(height: 1)
    }

    // MARK: - the top: who asks, and the screen or a window

    private var topHeight: CGFloat {
        16 + 20 + (picking.within == nil ? 0 : 19) + 12 + SharePickerCard.tileHeight + 12
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share with \(picking.host)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 20, alignment: .leading)
                .padding(.horizontal, 12)
            // A frame of another site inside the page asked: say whose
            // page it sits in, so the site named above is not taken for it.
            if let within = picking.within {
                Text("In a frame on \(within)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 17, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { index in
                    if rows.indices.contains(index) {
                        ShareTile(row: rows[index], picked: highlighted == index, tint: tint, height: SharePickerCard.tileHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { pick(rows[index]) }
                            .accessibilityAction { pick(rows[index]) }
                    }
                }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(height: topHeight, alignment: .top)
    }

    // MARK: - the search

    /// The field and the room around it. The gap under it is the list's
    /// own: rows scrolled up pass under it, never against the field's edge.
    private static let fieldBlock: CGFloat = 12 + fieldHeight + 6

    /// It looks like a field and is not one: the keys come through
    /// `SharePicker.take` whatever has the focus, so typing anywhere on the
    /// card searches.
    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            HStack(spacing: 1) {
                if query.isEmpty {
                    Caret(blinks: scrolls)
                    Text("Search all tabs")
                        .foregroundStyle(Palette.muted)
                } else {
                    Text(query)
                        .foregroundStyle(Palette.ink)
                        .truncationMode(.head)
                    Caret(blinks: scrolls)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            Spacer(minLength: 6)
            if !query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .frame(height: SharePickerCard.fieldHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.faint.opacity(0.8), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search all tabs")
        .accessibilityValue(query)
        .accessibilityAddTraits(.isSearchField)
    }

    // MARK: - the tabs

    private struct Line: Identifiable {
        /// The tab's, so a row keeps its identity as the list changes under it.
        let id: String
        /// Its place in `rows`, which is what the highlight counts.
        let index: Int
        let heading: String?
        let row: TabShareRules.Row
        var candidate: TabShareRules.Candidate? = nil
    }

    private var typed: Bool { !query.split(whereSeparator: \.isWhitespace).isEmpty }

    /// The rows below the top two, each with the heading that goes above it,
    /// if any: "Recent tabs" (or what the search found), then, with All tabs
    /// open, a space's name wherever the full list moves into another.
    private var lines: [Line] {
        let tabs = Dictionary(uniqueKeysWithValues: picking.tabs.map { ($0.id, $0) })
        let found = rows.filter { if case .tab = $0 { return true } else { return false } }.count
        var out: [Line] = []
        var lastSpace: String?? = .none
        for index in rows.indices.dropFirst(2) {
            let row = rows[index]
            switch row {
            case .tab(let id):
                let heading = out.isEmpty ? (typed ? (found == 1 ? "1 tab matches" : "\(found) tabs match") : "Recent tabs") : nil
                out.append(Line(id: "t" + id.uuidString, index: index, heading: heading, row: row, candidate: tabs[id]))
            case .all:
                out.append(Line(id: "all", index: index, heading: nil, row: row))
            case .listed(let id):
                let space = tabs[id]?.space
                var heading: String?
                if lastSpace == .none || lastSpace! != space { heading = space ?? picking.home ?? "This space" }
                lastSpace = .some(space)
                out.append(Line(id: "l" + id.uuidString, index: index, heading: heading, row: row, candidate: tabs[id]))
            case .screen, .window:
                continue
            }
        }
        return out
    }

    /// No tab to offer, or none matching: one quiet line says so.
    private var emptyNote: String? {
        guard lines.isEmpty else { return nil }
        return typed ? "No tabs match" : "No other tabs to share"
    }

    private var listHeight: CGFloat {
        let lines = self.lines
        let headings = CGFloat(lines.filter { $0.heading != nil }.count)
        let count = CGFloat(max(lines.count, 1))
        let natural = count * SharePickerCard.rowHeight + (count - 1) + headings * (SharePickerCard.headingHeight + 2) + 8
        let chrome = topHeight + 1 + SharePickerCard.fieldBlock + 1 + SharePickerCard.footerHeight
        return min(natural, max(room - chrome, 160))
    }

    private var list: some View {
        ScrollViewReader { reader in
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { rowStack }
                    .frame(height: listHeight)
                    .onChange(of: highlighted) { _, index in
                        guard let line = lines.first(where: { $0.index == index }) else { return }
                        withAnimation(Motion.quick) { reader.scrollTo(line.id) }
                    }
                    .onChange(of: query) { _, _ in
                        if let first = lines.first { reader.scrollTo(first.id, anchor: .top) }
                    }
            } else {
                rowStack
                    .frame(height: listHeight, alignment: .top)
                    .clipped()
            }
        }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let emptyNote {
                Text(emptyNote)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: SharePickerCard.rowHeight)
            }
            ForEach(lines) { line in
                // A heading and the row under it scroll as one, so walking
                // back up to the first row shows its heading too.
                VStack(alignment: .leading, spacing: 1) {
                    if let heading = line.heading {
                        Text(heading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: SharePickerCard.headingHeight, alignment: .bottomLeading)
                            .padding(.bottom, 1)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ShareRow(row: line.row, candidate: line.candidate, grouped: isListed(line.row),
                             picked: line.index == highlighted, tint: tint, scheme: scheme, stamp: stamp)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(line.row) }
                        .accessibilityAction { pick(line.row) }
                }
                .id(line.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isListed(_ row: TabShareRules.Row) -> Bool {
        if case .listed = row { return true }
        return false
    }

    // MARK: - the foot

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Tab audio isn't shared")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted.opacity(picking.canShareTab && picking.systemAudio ? 1 : 0))
            Spacer()
            Button(action: cancel) {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            Button {
                // Share answers; it never opens All tabs (Return does).
                guard rows.indices.contains(highlighted) else { return }
                if case .all = rows[highlighted] { return }
                pick(rows[highlighted])
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
        .padding(.horizontal, 20)
        .frame(height: SharePickerCard.footerHeight)
    }
}

/// Entire screen or A window: one click, and macOS's own picker takes it from there.
private struct ShareTile: View {
    let row: TabShareRules.Row
    let picked: Bool
    let tint: Color
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row == .screen ? "display" : "macwindow")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(picked ? tint : Palette.muted)
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("↩")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .opacity(picked ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Outlined at rest, so the highlight is the same wash a row wears
        // and never a shade away from a resting fill.
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if picked {
                shape.fill(tint.opacity(0.17))
            } else {
                shape.fill(hovering ? Palette.hover : .clear)
                    .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: picked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String { row == .screen ? "Entire screen…" : "A window…" }
}

/// The search field's caret: it blinks while the card is up, and stands
/// still in a picture of it.
private struct Caret: View {
    let blinks: Bool

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                bar.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
            }
        } else {
            bar
        }
    }

    private var bar: some View {
        Rectangle().fill(Palette.ink).frame(width: 1.5, height: 15)
    }
}

private struct ShareRow: View {
    let row: TabShareRules.Row
    let candidate: TabShareRules.Candidate?
    /// Under its space's heading, where naming the space again is noise.
    let grouped: Bool
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
            // The site, whole, and the space a tab of another space is in:
            // the title gives way first (⌘K's rows do the same).
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
        .accessibilityLabel(title + (detail.map { ", " + $0.replacingOccurrences(of: " · ", with: ", ") } ?? "")
                            + (candidate?.isCaller == true ? ", this tab" : ""))
        .accessibilityValue(open.map { $0 ? "expanded" : "collapsed" } ?? "")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var open: Bool? {
        if case .all(_, let open) = row { return open }
        return nil
    }

    private var title: String {
        switch row {
        case .all: return "All tabs"
        default: return candidate?.title ?? "Tab"
        }
    }

    private var detail: String? {
        switch row {
        case .all(let count, _): return "\(count)"
        default:
            guard let candidate else { return nil }
            guard !grouped, let space = candidate.space else { return candidate.host }
            let name = space.count <= 22 ? space : String(space.prefix(21)) + "…"
            return candidate.host.isEmpty ? name : candidate.host + " · " + name
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch row {
        case .tab(let id), .listed(let id):
            let tab = AgentTabs.find(id)
            RowMark(icon: tab?.icon, letter: tab?.monogram ?? Tab.monogram(host: candidate?.host, title: candidate?.title ?? "Tab"),
                    tint: SpaceTint(scheme).offColumn)
        case .all(_, let open):
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 18, height: 18)
        case .screen, .window:
            EmptyView()
        }
    }
}
