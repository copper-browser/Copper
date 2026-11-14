import AppKit

// ⌘T's and ⌘K's rows, in sections.
//
// The card answers in one fixed order — the tabs you already have open, then
// where you have been, then the browser's own shelves (bookmarks, canvases,
// commands), and asking Google last — so the first row, the one Return
// takes, is always the best place you already know. A section only exists
// while it has rows; its heading is a quiet label over its first one.
//
// Tab and ⇧Tab move the highlight a section at a time, to the first row of
// the next or the previous one, round the end; ↑ and ↓ still walk row by row
// across the whole list. The field keeps the keyboard either way.
//
// The order and the jumps are pure — rows in, rows and headings out — so the
// tests can hold them to it without a window (Tests/SearchTests).

/// The sections, in the order they are drawn.
enum CardSection: Int, CaseIterable, Comparable {
    case tabs, history, bookmarks, canvases, commands, search

    var title: String {
        switch self {
        case .tabs: return "Open Tabs"
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        case .canvases: return "Canvases"
        case .commands: return "Commands"
        case .search: return "Search"
        }
    }

    static func < (a: CardSection, b: CardSection) -> Bool { a.rawValue < b.rawValue }

    /// Where a ⌘K row belongs. A canvas row is a command that names a
    /// canvas; an open canvas is an open tab like any other.
    static func of(_ row: Suggestion) -> CardSection {
        if row.kind != .open, CanvasLinks.isCanvas(row.url) { return .canvases }
        switch row.kind {
        case .open: return .tabs
        case .visited, .known: return .history
        case .bookmark: return .bookmarks
        case .command: return .commands
        case .search: return .search
        }
    }
}

/// The headings of the card on screen, read by Fork/CommandPalette. Written
/// in the same breath as the browser's rows (`Launcher`, `CommandBar.offers`),
/// so the two always describe the same list.
@MainActor
final class CardSections: ObservableObject {
    static let shared = CardSections()

    /// The row each heading sits above, and what it says.
    @Published private(set) var headings: [Int: String] = [:]

    func show(_ headings: [Int: String]) {
        if self.headings != headings { self.headings = headings }
    }

    // MARK: - laying out

    /// Rows in order, and where each titled group begins. `lead` rows come
    /// first under no heading (⌘T's "Open github.com" for an address typed in
    /// full); an empty group draws nothing, heading included.
    nonisolated static func lay<Row>(lead: [Row] = [], _ groups: [(title: String, rows: [Row])]) -> (rows: [Row], headings: [Int: String]) {
        var rows = lead
        var headings: [Int: String] = [:]
        for group in groups where !group.rows.isEmpty {
            headings[rows.count] = group.title
            rows.append(contentsOf: group.rows)
        }
        return (rows, headings)
    }

    /// The fixed order, whatever order the groups were found in.
    nonisolated static func lay<Row>(lead: [Row] = [], sections: [CardSection: [Row]]) -> (rows: [Row], headings: [Int: String]) {
        lay(lead: lead, CardSection.allCases.map { (title: $0.title, rows: sections[$0] ?? []) })
    }

    /// A ranked list cut into the fixed order, each section keeping the
    /// order its rows came in (today's ranking, within the section).
    nonisolated static func group<Row>(_ rows: [Row], by section: (Row) -> CardSection) -> (rows: [Row], headings: [Int: String]) {
        var sections: [CardSection: [Row]] = [:]
        for row in rows { sections[section(row), default: []].append(row) }
        return lay(sections: sections)
    }

    // MARK: - the highlight

    /// The row highlighted when the card opens or the question changes: the
    /// first row of the first section that has any — which, sections being
    /// laid end to end with the empty ones left out, is the first row.
    nonisolated static func first(count: Int) -> Int? { count > 0 ? 0 : nil }

    /// Where each section's rows begin: every heading, and the lead row(s)
    /// at the top when the list starts under no heading.
    nonisolated static func starts(count: Int, headings: [Int: String]) -> [Int] {
        guard count > 0 else { return [] }
        return Set([0] + headings.keys.filter { $0 >= 0 && $0 < count }).sorted()
    }

    /// Tab (`step` 1) and ⇧Tab (`step` -1): the first row of the next or the
    /// previous section, round the end. From a row inside a section, ⇧Tab
    /// goes to the section before it, not to the top of its own. Nothing
    /// highlighted: Tab starts at the first section, ⇧Tab at the last.
    nonisolated static func jump(from picked: Int?, by step: Int, count: Int, headings: [Int: String]) -> Int? {
        let starts = starts(count: count, headings: headings)
        guard !starts.isEmpty else { return nil }
        guard let picked, picked >= 0, picked < count else {
            return step < 0 ? starts.last : starts.first
        }
        // The section the highlight is in: the last start at or above it.
        let here = starts.lastIndex { $0 <= picked } ?? 0
        let next = (here + (step < 0 ? -1 : 1) + starts.count) % starts.count
        return starts[next]
    }
}

// MARK: - bench

extension CardSections {
    /// `bench newtab TEXT --keys …` / `bench summon TEXT --keys …`: keys
    /// pressed in the card's field as the keyboard would press them — each
    /// one a key event handed to the field's editor, so it goes through the
    /// same key bindings and `AddressField` commands a real press does,
    /// without the window having to be key (a headless probe's never is).
    /// ⇥ is Tab, ⇧⇥ Shift-Tab, ↑ ↓ → the arrows, ↩ Return; ⎋ goes in at
    /// NSApp.sendEvent, where the app's Escape ladder hears it. What the highlight did
    /// after each, and whether the editor had them (`via: field`) or the
    /// field was not first responder and the browser was told directly
    /// (`via: model`).
    static func press(_ keys: String, in browser: Browser) -> (steps: [[String: Any]], via: String) {
        let window = Windows.window(of: browser) ?? Links.window
        let editor = window?.firstResponder as? NSTextView
        var steps: [[String: Any]] = []
        var shift = false
        for character in keys {
            if character == "\u{21E7}" { shift = true; continue }
            let key: (code: UInt16, chars: String, name: String)?
            switch character {
            case "\u{21E5}": key = shift ? (48, "\u{19}", "⇧⇥") : (48, "\t", "⇥")
            case "\u{2193}": key = (125, "\u{F701}", "↓")
            case "\u{2191}": key = (126, "\u{F700}", "↑")
            case "\u{2192}": key = (124, "\u{F703}", "→")
            case "\u{21A9}": key = (36, "\r", "↩")
            case "\u{238B}": key = (53, "\u{1B}", "⎋")
            default: key = nil
            }
            defer { shift = false }
            guard let key else { continue }
            if key.code == 53, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: key.chars,
                charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code
            ) {
                // Escape is the app's key monitor's (App.swift take()), not the
                // field's: in at the app, the way a press arrives.
                NSApp.sendEvent(event)
            } else if let editor, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: key.chars, charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code
            ) {
                editor.keyDown(with: event)
            } else {
                switch key.code {
                case 48: browser.jumpSection(shift ? -1 : 1)
                case 125: browser.walk(1)
                case 126: browser.walk(-1)
                case 36: browser.submit()
                default: break
                }
            }
            let picked = browser.picked
            steps.append(["key": key.name, "picked": picked ?? -1,
                          "row": picked.flatMap { browser.offers.indices.contains($0) ? browser.offers[$0].key : nil } ?? "",
                          "typed": browser.typed, "fieldText": editor?.string ?? "", "summoning": browser.summoning])
        }
        return (steps, editor == nil ? "model" : "field")
    }
}
