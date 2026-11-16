import AppKit
import SwiftUI

// What Settings search draws: the field at the top of the rail, the rail's
// page rows (dimmed when a page has nothing for the query), and the results
// that take the content's place while searching.

// MARK: - the field

struct SettingsSearchField: View {
    @ObservedObject var finder: SettingsFinder
    @FocusState private var focused: Bool

    var body: some View {
        let _ = SettingsPerf.tick("searchField") // Fork (settings-perf)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsInk.detail)
            ZStack(alignment: .leading) {
                if finder.query.isEmpty {
                    Text("Search settings")
                        .foregroundStyle(SettingsInk.detail) // Fork (ui-system): 4.6:1 on the field, not 3.6
                        .allowsHitTesting(false)
                }
                TextField("", text: $finder.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { finder.pickSelected() }
                    .accessibilityLabel("Search settings")
            }
            .font(.system(size: 13))
            if finder.query.isEmpty {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(SettingsInk.detail.opacity(0.8))
                    .opacity(focused ? 0 : 1)
            } else {
                Button { _ = finder.clear(); finder.focus() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Clear  ⎋")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(SettingsInk.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.ink.opacity(focused ? 0.2 : 0), lineWidth: 1)
        )
        .animation(Motion.quick, value: focused)
        .onChange(of: finder.focusTick) { _, _ in
            if focused, !((finder.window ?? Links.window)?.firstResponder is NSText) {
                // SwiftUI still thinks the field has the keyboard; it doesn't.
                focused = false
                DispatchQueue.main.async { focused = true }
            } else {
                focused = true
            }
        }
        .onChange(of: focused) { _, now in
            finder.fieldFocused = now
            if now { finder.fieldTookKeyboard() }
        }
        .onAppear {
            focused = true
            finder.fieldFocused = true
        }
    }
}

// MARK: - a page in the rail

struct SettingsRailRow: View {
    let page: SettingsPanel.Page
    let on: Bool
    /// While searching: how many rows on the page match (nil when not searching).
    let count: Int?
    let act: () -> Void
    @State private var hovering = false

    private var empty: Bool { count == 0 }
    private var dimmed: Bool { count == nil ? false : (empty && !hovering) }

    var body: some View {
        let _ = SettingsPerf.tick("railRow") // Fork (settings-perf)
        Button(action: act) {
            HStack(spacing: 9) {
                Image(systemName: page.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: on ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(SettingsInk.detail)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Palette.ink.opacity(0.06), in: Capsule())
                }
            }
            .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink : Palette.ink.opacity(0.78)))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? SettingsInk.chosen : (hovering ? Palette.ink.opacity(0.05) : .clear))
                    .shadow(color: .black.opacity(on ? 0.07 : 0), radius: 2.5, y: 1)
            )
            .opacity(dimmed ? 0.36 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: count)
        .accessibilityLabel(count.map { "\(page.title), \($0) matches" } ?? page.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - the results

struct SettingsResults: View {
    @ObservedObject var finder: SettingsFinder
    let browser: Browser
    /// Narrow, the section names on the right give their room to the
    /// sentences under the titles.
    @State private var wide = true
    /// The preferences most in-place switches stand for, watched so a flip —
    /// here or anywhere else — shows in its row at once rather than at the
    /// next keystroke. (Rows are equatable on the switch's value, so only the
    /// flipped row redraws.)
    @ObservedObject private var prefs: Preferences
    /// Bumped by a flip in the list, for the switches that stand for
    /// something other than the preferences (agents, Labs).
    @State private var flips = 0

    init(finder: SettingsFinder, browser: Browser) {
        self.finder = finder
        self.browser = browser
        self._prefs = ObservedObject(wrappedValue: browser.prefs)
    }

    static let suggestions = ["dark mode", "passwords", "downloads folder", "agents", "default browser", "updates", "block ads", "1Password"]

    var body: some View {
        let _ = SettingsPerf.tick("results") // Fork (settings-perf)
        if finder.results.isEmpty {
            empty
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(finder.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: group.page.icon)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(width: 15)
                                Text(group.page.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(SettingsInk.heading)
                            .padding(.leading, 16)
                            Card {
                                ForEach(Array(group.hits.enumerated()), id: \.element.id) { index, hit in
                                    if index > 0 { Rule() }
                                    row(hit)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide = $0 }
            .onChange(of: finder.selection) { _, now in
                guard finder.results.indices.contains(now) else { return }
                proxy.scrollTo(finder.results[now].id)
            }
        }
    }

    private func row(_ hit: SettingsHit) -> some View {
        let index = finder.results.firstIndex { $0.id == hit.id } ?? -1
        let _ = flips
        let toggle = (hit.entry.toggle?(browser)).map { binding in
            Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; flips &+= 1 })
        }
        return SettingsResultRow(
            hit: hit,
            index: index,
            chosen: index == finder.selection,
            crumb: wide,
            switched: toggle?.wrappedValue,
            toggle: toggle,
            hover: { if index >= 0 { finder.selection = index } },
            pick: { finder.pick(hit) }
        )
        // Only the rows whose choice changed redraw as the pointer or the
        // arrows walk the list (settings-perf), not all sixty.
        .equatable()
        .id(hit.id)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("No settings match “\(finder.query.trimmingCharacters(in: .whitespaces))”")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Try another word for it — or one of these:")
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsInk.detail)
            }
            SettingsFlow(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { word in
                    Pill(word) {
                        finder.query = word
                        finder.focus()
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsResultRow: View, Equatable {
    let hit: SettingsHit
    /// Where the row is in the results; its `hover` closure carries it.
    var index = -1
    let chosen: Bool
    var crumb = true
    /// The in-place switch's value when the list was drawn, so a flip redraws its row.
    var switched: Bool? = nil
    let toggle: Binding<Bool>?
    let hover: () -> Void
    let pick: () -> Void

    /// The closures are made afresh on every redraw of the list; what they do
    /// follows from the hit and its index, so those stand in for them.
    nonisolated static func == (a: SettingsResultRow, b: SettingsResultRow) -> Bool {
        a.hit.id == b.hit.id && a.index == b.index && a.chosen == b.chosen && a.crumb == b.crumb
            && a.hit.titleMarks == b.hit.titleMarks && a.hit.subtitleMarks == b.hit.subtitleMarks
            && (a.toggle == nil) == (b.toggle == nil) && a.switched == b.switched
    }

    var body: some View {
        let _ = SettingsPerf.tick("resultRow") // Fork (settings-perf)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsMarks.title(hit.entry.title, hit.titleMarks))
                    .lineLimit(1)
                Text(SettingsMarks.subtitle(hit.entry.subtitle, hit.subtitleMarks))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if crumb {
                Text(hit.entry.isPage ? "Page" : hit.entry.section)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsInk.detail)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let toggle {
                Switch(on: toggle, label: hit.entry.title) // settings-a11y
            }
            Image(systemName: "return")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SettingsInk.detail)
                .frame(width: 14)
                .opacity(chosen ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.ink.opacity(chosen ? 0.055 : 0))
                .padding(3)
        )
        .contentShape(Rectangle())
        .onHover { if $0 { hover() } }
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The matched letters, set apart by weight rather than colour.
enum SettingsMarks {
    static func title(_ text: String, _ marks: Set<Int>) -> AttributedString {
        build(text, marks, size: 13, plain: (.regular, Palette.ink), lit: (.semibold, Palette.ink))
    }

    static func subtitle(_ text: String, _ marks: Set<Int>) -> AttributedString {
        build(text, marks, size: 12, plain: (.regular, SettingsInk.detail), lit: (.medium, Palette.ink.opacity(0.85)))
    }

    private static func build(_ text: String, _ marks: Set<Int>, size: CGFloat,
                              plain: (Font.Weight, Color), lit: (Font.Weight, Color)) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var runLit = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            let style = runLit ? lit : plain
            piece.font = .system(size: size, weight: style.0)
            piece.foregroundColor = style.1
            out += piece
            run = ""
        }
        for (i, c) in text.enumerated() {
            let on = marks.contains(i)
            if on != runLit { flush(); runLit = on }
            run.append(c)
        }
        flush()
        return out
    }
}

/// Wraps its children onto as many lines as they need — the suggestions.
struct SettingsFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
