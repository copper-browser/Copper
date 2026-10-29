import AppKit
import SwiftUI

// Settings search: the matcher over `SettingsIndex`, and the state one
// panel's field, results and highlight share.
//
// Matching is per word, after folding case and diacritics. A query word
// scores against each word of a field: exact, then prefix, then inside a
// word, then a typo (one edit, two for words of nine letters or more —
// transpositions count as one; only in words of five letters or more, first
// letter kept), then the letters in order. Fields weigh title > keywords > page and
// section > subtitle, every query word has to land somewhere (synonyms
// count), and a few whole-query bonuses put the obvious answer first.

struct SettingsHit: Identifiable {
    let entry: SettingsEntry
    let score: Double
    /// Character offsets in the title and subtitle that matched.
    let titleMarks: Set<Int>
    let subtitleMarks: Set<Int>
    var id: String { entry.id }
}

@MainActor
enum SettingsMatcher {
    // MARK: prepared fields

    struct Word {
        let chars: [Character]
        /// Where the word sits in the field, in characters.
        let start: Int
        let span: Int
    }

    struct Field {
        let words: [Word]
        /// Neighbouring words run together ("auto-lock" → "autolock"), so a
        /// query typed as one word still finds two.
        let pairs: [Word]
        let joined: String

        static let empty = Field(words: [], pairs: [], joined: "")
    }

    struct Prepared {
        let entry: SettingsEntry
        let order: Int
        let title: Field
        let subtitle: Field
        let section: Field
        let page: Field
        let keywords: [Field]
    }

    static let prepared: [Prepared] = SettingsIndex.entries.enumerated().map { index, entry in
        Prepared(
            entry: entry,
            order: index,
            title: field(entry.title),
            subtitle: field(entry.subtitle),
            section: field(entry.section),
            page: field(entry.page.title + " " + entry.page.keywords.joined(separator: " ")),
            keywords: entry.keywords.map(field)
        )
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func field(_ text: String) -> Field {
        let chars = Array(text)
        var words: [Word] = []
        var i = 0
        while i < chars.count {
            guard isWordCharacter(chars[i]) else { i += 1; continue }
            let start = i
            while i < chars.count, isWordCharacter(chars[i]) { i += 1 }
            var folded = Array(fold(String(chars[start..<i])))
            if folded.count != i - start { folded = Array(String(chars[start..<i]).lowercased()) }
            words.append(Word(chars: folded, start: start, span: i - start))
        }
        var pairs: [Word] = []
        if words.count > 1 {
            for k in 0..<(words.count - 1) {
                let a = words[k], b = words[k + 1]
                pairs.append(Word(chars: a.chars + b.chars, start: a.start, span: b.start + b.span - a.start))
            }
        }
        return Field(words: words, pairs: pairs, joined: words.map { String($0.chars) }.joined(separator: " "))
    }

    // MARK: query

    private static let stopWords: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "for", "my", "and", "with", "how", "do", "i", "is", "where", "can"]

    /// Other words for a query word. The index's keywords carry most of the
    /// vocabulary; these are the ones that cut across pages.
    static let synonyms: [String: [String]] = [
        "pw": ["password", "passwords"], "pwd": ["password"], "passwd": ["password"],
        "login": ["sign", "password"], "logins": ["sign", "passwords"], "signin": ["sign"], "keychain": ["passwords"],
        "credential": ["password"], "credentials": ["passwords"],
        "ai": ["intelligence", "model"], "llm": ["intelligence", "model"], "gpt": ["model", "openai"],
        "claude": ["claude", "intelligence"], "model": ["model", "intelligence"], "anthropic": ["claude"],
        "proxy": ["agents", "mcp"], "mcp": ["agents"], "bot": ["agents", "bots"], "bots": ["agents"],
        "automation": ["agents", "script"], "automate": ["agents", "script"],
        "update": ["updates"], "upgrade": ["updates", "update"],
        "adblock": ["block", "ads", "shield"], "adblocker": ["block", "ads"], "ublock": ["block", "ads"],
        "tracker": ["trackers", "block"], "tracking": ["trackers"],
        "dark": ["appearance"], "night": ["appearance", "dark"], "theme": ["appearance", "look"], "darkmode": ["appearance"],
        "color": ["colour", "colours"], "colors": ["colours"], "colour": ["color", "colours"],
        "download": ["downloads"], "folder": ["save", "directory"],
        "shortcut": ["shortcuts"], "hotkey": ["shortcuts"], "hotkeys": ["shortcuts"], "keybinding": ["shortcuts"], "keybindings": ["shortcuts"],
        "extension": ["extensions"], "addon": ["extensions"], "plugin": ["extensions"], "plugins": ["extensions"],
        "icloud": ["cloud", "sync"], "memory": ["sleep"], "spell": ["spelling"],
        "1pw": ["1password"], "onepassword": ["1password"],
        "mic": ["microphone"], "webcam": ["camera"], "workspace": ["spaces"], "workspaces": ["spaces"],
        "vertical": ["sidebar"], "browser": ["browser", "default"],
        "dictate": ["dictation", "voice"], "dictation": ["voice"], "speech": ["voice"], "transcribe": ["transcription", "voice"],
        "stt": ["speech", "voice"], "ptt": ["talk"],
    ]

    struct Token {
        let text: [Character]
        let alternatives: [[Character]]
    }

    static func tokens(_ query: String) -> [Token] {
        let words = field(query).words.map { String($0.chars) }
        let kept = words.filter { !stopWords.contains($0) }
        let use = kept.isEmpty ? words : kept
        return use.map { word in
            Token(text: Array(word), alternatives: (synonyms[word] ?? []).filter { $0 != word }.map(Array.init))
        }
    }

    // MARK: scoring one word

    /// How well a query word matches a field word, and which of the field
    /// word's letters it lit.
    static func match(_ q: [Character], _ w: [Character]) -> (score: Double, lit: [Int])? {
        guard !q.isEmpty, !w.isEmpty else { return nil }
        if q == w { return (1.0, Array(0..<w.count)) }
        // One and many are the same thing: "shortcut" / "shortcuts".
        if q.count >= 3, plural(q, of: w) || plural(w, of: q) { return (0.97, Array(0..<min(q.count, w.count))) }
        if w.count > q.count, Array(w.prefix(q.count)) == q {
            // Two letters are weak evidence of a word; four are strong.
            let start = q.count >= 4 ? 0.80 : (q.count == 3 ? 0.75 : 0.70)
            return (start + 0.18 * Double(q.count) / Double(w.count), Array(0..<q.count))
        }
        if q.count >= 3, let at = find(q, in: w) {
            return (0.55, Array(at..<(at + q.count)))
        }
        // A slip keeps the first letter: "extensons", "dowloads", "privcy" —
        // but not "block" for "lock". Only in words of five letters or more:
        // a slip in four was as often another word ("font" lit "front",
        // "unpacked" ranked "unlocked"). (settings-browse)
        if q.count >= 5, q[0] == w[0] {
            let most = q.count >= 9 ? 2 : 1
            let whole = distance(q, w, cap: most)
            if whole <= most, abs(q.count - w.count) <= most {
                return (whole == 1 ? 0.62 : 0.48, Array(0..<w.count))
            }
            // Still typing, with a slip: the word's start, give or take a letter.
            if w.count > q.count {
                var best = Int.max
                for length in [q.count - 1, q.count, q.count + 1] where length > 2 && length <= w.count {
                    best = min(best, distance(q, Array(w.prefix(length)), cap: 1))
                }
                if best <= 1 { return (0.5, Array(0..<min(q.count, w.count))) }
            }
        }
        // The letters in order ("pswd"). One letter short of the word is a
        // slip, not shorthand, so it takes the same five letters a slip
        // does ("font" is not "front").
        if q.count >= 3, q[0] == w[0], w.count - q.count > 1 || q.count >= 5, let lit = subsequence(q, in: w) {
            let spread = Double(lit.last! - lit.first! + 1)
            return (0.35 + 0.25 * Double(q.count) / spread, lit)
        }
        return nil
    }

    /// `many` is `one` with an s.
    private static func plural(_ many: [Character], of one: [Character]) -> Bool {
        guard many.count == one.count + 1, many.last == "s" else { return false }
        return Array(many.dropLast()) == one
    }

    private static func find(_ q: [Character], in w: [Character]) -> Int? {
        guard q.count <= w.count else { return nil }
        for start in 0...(w.count - q.count) where w[start] == q[0] {
            if Array(w[start..<(start + q.count)]) == q { return start }
        }
        return nil
    }

    private static func subsequence(_ q: [Character], in w: [Character]) -> [Int]? {
        var lit: [Int] = []
        var j = 0
        for (i, c) in w.enumerated() where j < q.count && c == q[j] {
            lit.append(i)
            j += 1
        }
        return j == q.count ? lit : nil
    }

    /// Optimal string alignment distance (Levenshtein with adjacent
    /// transpositions), giving up past `cap`.
    static func distance(_ a: [Character], _ b: [Character], cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var before = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, before[j - 2] + 1)
                }
                current[j] = value
                rowBest = min(rowBest, value)
            }
            if rowBest > cap { return cap + 1 }
            before = previous
            previous = current
        }
        return previous[b.count]
    }

    /// The best match of a word anywhere in a field: its score and the
    /// field's character offsets it lit.
    static func best(_ q: [Character], in field: Field) -> (score: Double, lit: [Int])? {
        var top: (score: Double, lit: [Int])?
        for word in field.words {
            if let m = match(q, word.chars), m.score > (top?.score ?? 0) {
                top = (m.score, m.lit.map { min(word.start + $0, word.start + word.span - 1) })
            }
        }
        if q.count >= 4 {
            for pair in field.pairs {
                // Two words run together ("darkmode", "signin") — whole, from
                // the start, or with one slip. Not letters picked out of
                // the pair: "font" isn't "front of". (settings-browse)
                if let m = match(q, pair.chars), m.score >= 0.62, m.score > (top?.score ?? 0) {
                    // A pair's letters span a gap; light the words, not the gap.
                    top = (m.score * 0.95, Array(pair.start..<(pair.start + pair.span)))
                }
            }
        }
        return top
    }

    // MARK: scoring an entry

    private static let weights = (title: 1.0, keyword: 0.85, page: 0.6, section: 0.55, subtitle: 0.45)

    static func score(_ p: Prepared, _ tokens: [Token], phrase: String) -> SettingsHit? {
        var total = 0.0
        var titleMarks = Set<Int>()
        var subtitleMarks = Set<Int>()
        var allInTitle = true
        var allOnPage = true

        for token in tokens {
            var tokenBest = 0.0
            var titleBest = 0.0
            var pageBest = 0.0
            // Lit letters come from the word as typed when it matched; a
            // synonym lights its own letters only when the typed word didn't.
            var titleLit: [Int]?
            var subtitleLit: [Int]?
            let candidates: [([Character], Double)] = [(token.text, 1.0)] + token.alternatives.map { ($0, 0.92) }
            for (word, factor) in candidates {
                // A synonym counts only as itself (or the start of a word),
                // never through a typo of its own.
                let floor = factor < 1 ? 0.75 : 0
                func best(_ word: [Character], in field: Field) -> (score: Double, lit: [Int])? {
                    guard let m = SettingsMatcher.best(word, in: field), m.score >= floor else { return nil }
                    return m
                }
                if let m = best(word, in: p.title) {
                    tokenBest = max(tokenBest, m.score * weights.title * factor)
                    titleBest = max(titleBest, m.score * factor)
                    if m.score >= 0.45, titleLit == nil { titleLit = m.lit }
                }
                for keyword in p.keywords {
                    if let m = best(word, in: keyword) { tokenBest = max(tokenBest, m.score * weights.keyword * factor) }
                }
                if let m = best(word, in: p.page) {
                    tokenBest = max(tokenBest, m.score * weights.page * factor)
                    pageBest = max(pageBest, m.score * factor)
                }
                if let m = best(word, in: p.section) { tokenBest = max(tokenBest, m.score * weights.section * factor) }
                if let m = best(word, in: p.subtitle) {
                    tokenBest = max(tokenBest, m.score * weights.subtitle * factor)
                    if m.score >= 0.55, subtitleLit == nil { subtitleLit = m.lit }
                }
            }
            titleMarks.formUnion(titleLit ?? [])
            subtitleMarks.formUnion(subtitleLit ?? [])
            // Every word has to land somewhere.
            guard tokenBest > 0 else { return nil }
            total += tokenBest
            if titleBest < 0.5 { allInTitle = false }
            if pageBest < 0.97 { allOnPage = false }
        }

        var score = total / Double(tokens.count) * 100
        let title = p.title.joined
        if title == phrase { score += 40 }
        else if title.hasPrefix(phrase) { score += 22 * min(1, Double(phrase.count) / 4) }
        else if title.contains(" " + phrase) { score += 10 }
        if p.keywords.contains(where: { $0.joined == phrase }) { score += 28 }
        else if phrase.count >= 3, p.keywords.contains(where: { $0.joined.hasPrefix(phrase) }) { score += 12 }
        if allInTitle { score += 8 }
        // The page itself leads when the query names it; its rows get a
        // smaller lift; a page the query doesn't name sinks below rows.
        if p.entry.isPage { score += allInTitle ? 12 : -8 }
        else if allOnPage { score += 6 }
        return SettingsHit(entry: p.entry, score: score, titleMarks: titleMarks, subtitleMarks: subtitleMarks)
    }

    /// Ranked hits for a query: best first, within reach of the best.
    static func search(_ query: String, limit: Int = 60) -> [SettingsHit] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.map { String($0.text) }.joined(separator: " ")
        var hits: [(SettingsHit, Int)] = []
        for p in prepared {
            if let hit = score(p, tokens, phrase: phrase) { hits.append((hit, p.order)) }
        }
        hits.sort { a, b in
            if abs(a.0.score - b.0.score) > 0.001 { return a.0.score > b.0.score }
            return a.1 < b.1
        }
        guard let top = hits.first?.0.score else { return [] }
        let floor = max(30, top * 0.42)
        return Array(hits.lazy.filter { $0.0.score >= floor }.map(\.0).prefix(limit))
    }

    /// The hits in the order the results draw them: grouped by page, the
    /// pages in the order of their best hit.
    static func grouped(_ hits: [SettingsHit]) -> [SettingsHitGroup] {
        var order: [SettingsPanel.Page] = []
        var by: [SettingsPanel.Page: [SettingsHit]] = [:]
        for hit in hits {
            if by[hit.entry.page] == nil { order.append(hit.entry.page) }
            by[hit.entry.page, default: []].append(hit)
        }
        return order.map { SettingsHitGroup(page: $0, hits: by[$0] ?? []) }
    }
}

/// One page's hits in the results.
struct SettingsHitGroup: Identifiable {
    let page: SettingsPanel.Page
    let hits: [SettingsHit]
    var id: String { page.rawValue }
}

// MARK: - one panel's search

/// What one window's Settings search is doing. Kept outside the panel's
/// views so changing page (which rebuilds the page) keeps the query.
@MainActor
final class SettingsFinder: ObservableObject {
    private static var all: [ObjectIdentifier: SettingsFinder] = [:]

    static func of(_ browser: Browser) -> SettingsFinder {
        let key = ObjectIdentifier(browser)
        if let found = all[key] { return found }
        let made = SettingsFinder(browser: browser)
        all[key] = made
        return made
    }

    weak var browser: Browser?
    init(browser: Browser) { self.browser = browser }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            run()
        }
    }
    /// In results order (grouped by page), so ↑/↓ walk what is drawn.
    @Published private(set) var results: [SettingsHit] = []
    @Published private(set) var groups: [SettingsHitGroup] = []
    @Published private(set) var counts: [SettingsPanel.Page: Int] = [:]
    @Published var selection = 0
    /// The results take the content's place while true; picking one (or a
    /// page in the rail) puts the page back and leaves the query in the field.
    @Published var showingResults = false
    /// Bumped to put the keyboard in the field.
    @Published private(set) var focusTick = 0
    @Published var fieldFocused = false
    /// The anchor search just landed on, lit for a moment.
    @Published private(set) var flashing: String?
    /// Where the page should scroll once it is drawn.
    @Published private(set) var pending: Target?

    struct Target: Equatable {
        let anchor: String
        let fallback: String?
        let flash: Bool
        let token = UUID()
    }

    /// Anchors each page drew, last time it was shown (from the panel's
    /// preference), for the index check and for choosing the fallback.
    var drawn: [SettingsPanel.Page: Set<String>] = [:]
    /// Time of the last query change, for the bench's timing line.
    private(set) var lastSearchMs = 0.0

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func run() {
        let started = CFAbsoluteTimeGetCurrent()
        let hits = SettingsMatcher.search(query)
        let grouped = SettingsMatcher.grouped(hits)
        groups = grouped
        results = grouped.flatMap(\.hits)
        var counts: [SettingsPanel.Page: Int] = [:]
        for hit in hits where !hit.entry.isPage { counts[hit.entry.page, default: 0] += 1 }
        for hit in hits where hit.entry.isPage && counts[hit.entry.page] == nil { counts[hit.entry.page] = 0 }
        self.counts = counts
        selection = 0
        showingResults = searching
        lastSearchMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    func focus() { focusTick += 1 }

    /// Esc: the query first, then (returning false) the panel.
    func clear() -> Bool {
        guard !query.isEmpty || showingResults else { return false }
        query = ""
        showingResults = false
        return true
    }

    func move(_ by: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + by + results.count) % results.count
    }

    func pickSelected() {
        guard results.indices.contains(selection) else { return }
        pick(results[selection])
    }

    func pick(_ hit: SettingsHit) {
        guard let browser else { return }
        let entry = hit.entry
        showingResults = false
        pending = Target(anchor: entry.anchor, fallback: entry.fallback, flash: !entry.isPage)
        if browser.settingsPage != entry.page { browser.settingsPage = entry.page }
        if !browser.tuning { browser.tuning = true }
    }

    /// Scroll the open page to `anchor`, as a picked result would.
    func land(on anchor: String) {
        pending = Target(anchor: anchor, fallback: nil, flash: true)
    }

    /// A page chosen in the rail while searching: the page, the query kept.
    func leaveResults() { showingResults = false }

    /// The anchor to scroll to on `page`: the row, else its fallback.
    func resolve(_ target: Target, on page: SettingsPanel.Page) -> String? {
        let drawn = drawn[page] ?? []
        if drawn.contains(target.anchor) { return target.anchor }
        if let fallback = target.fallback, drawn.contains(fallback) { return fallback }
        return nil
    }

    func landed(_ target: Target, on anchor: String?) {
        guard pending == target else { return }
        pending = nil
        guard target.flash, let anchor else { return }
        flashing = anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.flashing == anchor { self?.flashing = nil }
        }
    }

    /// Type-to-search: a key pressed in Settings while no field has the
    /// keyboard goes into the field.
    func type(_ characters: String, in window: NSWindow?) {
        query += characters
        self.window = window
        caretToEnd = true
        focus()
        // In case the field already thought it had the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if self?.caretToEnd == true { self?.placeCaret() }
        }
    }

    /// The window type-to-search last came through, for its field editor.
    weak var window: NSWindow?
    /// Set by type-to-search: when the field takes the keyboard, the caret
    /// goes after the letters rather than selecting them all (the next
    /// letter would replace the query).
    var caretToEnd = false

    /// Called when the field has just taken the keyboard.
    func fieldTookKeyboard() {
        guard caretToEnd else { return }
        placeCaret()
    }

    private func placeCaret() {
        caretToEnd = false
        for delay in [0.0, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let editor = (self?.window ?? Links.window)?.firstResponder as? NSTextView else { return }
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    /// The panel opened: a fresh field with the keyboard in it.
    func opened() {
        if !query.isEmpty { query = "" }
        showingResults = false
        pending = nil
        flashing = nil
        focus()
    }
}
