import AppKit
import SwiftUI

// What the field does with words (Ardia parity, B3).
//
// Words go to the engine picked in Settings › General — Google until you pick
// another, or any address with %s where the words go. A few things never
// reach an engine at all: a sum (`2*21`) is worked out on the spot and Return
// copies it; `doc.new` or `new doc` opens a blank Google Doc and the other
// sixteen `.new` shortcuts; `!w paris` (or `paris !w`) searches the site the
// !bang names, from DuckDuckGo's 200 most used (Fork/BangList.swift), and any
// other !bang goes to DuckDuckGo, which knows the rest; and Tab after a site
// (`yt`, `github.com`) puts its !bang in the field, so what you type next
// searches that site. All of it is worked out here, on this Mac: nothing is
// asked of anyone before Return.

/// One search engine: where the words go, and where its completions for ⌘T's
/// card come from (OpenSearch's `["words", ["completion", …]]`).
struct SearchEngine: Equatable {
    let id: String
    let name: String
    /// The search address, `%s` where the words go.
    let template: String
    /// Its completions, `%s` where the words go; nil asks no one.
    var suggest: String? = nil

    func url(for words: String) -> URL? { SearchEngines.fill(template, with: words) }
}

enum SearchEngines {
    static let builtIn: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%s",
                     suggest: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=%s"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s",
                     suggest: "https://duckduckgo.com/ac/?q=%s&type=list"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s",
                     suggest: "https://api.bing.com/osjson.aspx?query=%s"),
        SearchEngine(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s",
                     suggest: "https://kagi.com/api/autosuggest?q=%s"),
        SearchEngine(id: "perplexity", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s"),
        SearchEngine(id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q=%s",
                     suggest: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
        SearchEngine(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%s",
                     suggest: "https://search.brave.com/api/suggest?q=%s"),
    ]

    /// Settings keys: the engine's id, and the custom engine's address.
    static let key = "search.engine"
    static let customKey = "search.custom"

    /// The engine words go to now. A custom address that isn't a usable one
    /// falls back to Google rather than to nowhere.
    static var current: SearchEngine {
        let id = Store.settings.string(forKey: key) ?? "google"
        if id == "custom", let template = Store.settings.string(forKey: customKey), let engine = custom(template) { return engine }
        return builtIn.first { $0.id == id } ?? builtIn[0]
    }

    /// A custom engine from its address, named by its host. Nil unless it is
    /// http(s), has a host, and has `%s` outside the host: the words never
    /// choose which site they go to.
    static func custom(_ template: String) -> SearchEngine? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("%s"),
              let one = URL(string: template.replacingOccurrences(of: "%s", with: "a")),
              let other = URL(string: template.replacingOccurrences(of: "%s", with: "b")),
              ["http", "https"].contains(one.scheme?.lowercased() ?? ""),
              let host = one.host(), !host.isEmpty, host == other.host()
        else { return nil }
        return SearchEngine(id: "custom", name: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, template: template)
    }

    /// `template` with the words in place of `%s`, escaped as a query string
    /// needs them — the plus sign included, or it arrives as a space.
    static func fill(_ template: String, with words: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: escaped))
    }

    /// Words, said as a search: where they go, who answers, and the row's
    /// wording. A !bang goes to its site; anything else to the engine.
    static func search(_ text: String) -> (url: URL, name: String, label: String)? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        if let bang = Bangs.resolve(words) { return bang }
        let engine = current
        guard let url = engine.url(for: words) else { return nil }
        return (url, engine.name, "Search \(engine.name) for “\(words)”")
    }

    /// True when the field's text is answered here — a sum, a `.new`, a
    /// !bang, a site Tab would search — so ⌘T asks no engine to complete it.
    static func local(_ text: String) -> Bool {
        Calculator.answer(text) != nil || QuickNew.find(text) != nil || Bangs.resolve(text) != nil || Bangs.keyword(text) != nil
    }

    /// The row that leads the card (⌘T) and the list (⌘L) for a sum or a
    /// `.new` shortcut; nil for anything else.
    static func answer(for text: String) -> Suggestion? {
        if let sum = Calculator.answer(text) {
            var row = Suggestion(key: "\(sum.expression) = \(sum.value)", title: "",
                                 url: URL(string: "copper://copy/")!.appending(path: sum.value), kind: .command)
            row.glyph = "equal"
            row.hint = "Copy"
            return row
        }
        if let new = QuickNew.find(text), let url = URL(string: new.url) {
            var row = Suggestion(key: new.title, title: url.host() ?? "", url: url, kind: .known)
            row.detail = url.host() ?? ""
            return row
        }
        return nil
    }

    /// A sum's row, taken: its value on the clipboard. True when `url` was one.
    @MainActor static func run(_ url: URL, in browser: Browser) -> Bool {
        guard url.scheme == "copper", url.host() == "copy" else { return false }
        let value = url.lastPathComponent
        SettingsActions.copy(value) // a probe world's own pasteboard in a test run (`bench ai clipboard`)
        browser.announce("Copied \(value)")
        return true
    }
}

// MARK: - !bangs

/// DuckDuckGo's !bangs: `!w paris` or `paris !w`. The 200 most used ship in
/// Copper (Fork/BangList.swift, `tools/bangs/refresh.py`); the rest go to
/// DuckDuckGo as typed, which answers all ~13,000.
enum Bangs {
    struct Bang {
        let trigger: String
        let name: String
        /// `%s` where the words go.
        let template: String
        /// The site's own host, without www.
        let host: String
        /// Where a bare `!yt` goes: the template's scheme and host.
        let home: URL?
    }

    /// By trigger, and in DuckDuckGo's order of use.
    static let ordered: [Bang] = bundled.map { entry in
        let (trigger, name, template) = entry
        let site = URL(string: template.replacingOccurrences(of: "%s", with: "q"))
        let host = site?.host() ?? ""
        return Bang(trigger: trigger, name: name, template: template, host: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                    home: site.flatMap { URL(string: "\($0.scheme ?? "https")://\(host)") })
    }
    static let table: [String: Bang] = Dictionary(ordered.map { ($0.trigger, $0) }, uniquingKeysWith: { first, _ in first })

    /// A first or last word that is `!` and a trigger. A bare `!yt` opens the
    /// site; an unknown trigger asks DuckDuckGo. `hello!` and `wow ! nice`
    /// are just words.
    static func resolve(_ text: String) -> (url: URL, name: String, label: String)? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        let word: Substring
        let rest: ArraySlice<Substring>
        if let first = parts.first, first.count > 1, first.hasPrefix("!") {
            word = first
            rest = parts.dropFirst()
        } else if parts.count > 1, let last = parts.last, last.count > 1, last.hasPrefix("!") {
            word = last
            rest = parts.dropLast()
        } else {
            return nil
        }
        let trigger = word.dropFirst().lowercased()
        guard trigger.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        let words = rest.joined(separator: " ")
        guard let bang = table[trigger] else {
            let ddg = SearchEngines.builtIn[1]
            return ddg.url(for: text.trimmingCharacters(in: .whitespacesAndNewlines)).map { (url: $0, name: ddg.name, label: "Search \(ddg.name) for “\(text.trimmingCharacters(in: .whitespaces))”") }
        }
        if words.isEmpty {
            return bang.home.map { (url: $0, name: bang.name, label: "Open \(bang.name)") }
        }
        return SearchEngines.fill(bang.template, with: words).map { (url: $0, name: bang.name, label: "Search \(bang.name) for “\(words)”") }
    }

    /// Site search: the trigger for what was typed if it names a site — its
    /// trigger (two letters or more: Tab after "w" still completes), its
    /// address (`github.com`, `wikipedia.org`) or its name (`youtube`).
    static func keyword(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" "), !text.hasPrefix("!") else { return nil }
        if text.count >= 2, table[text] != nil { return text }
        if text.contains(".") { return ordered.first { $0.host == text || $0.host.hasSuffix("." + text) }?.trigger }
        guard text.count >= 3 else { return nil }
        return ordered.first { $0.host.split(separator: ".").first.map(String.init) == text }?.trigger
    }
}

// MARK: - .new

/// The `.new` shortcuts Ardia's bar knows, by the names you would type:
/// `doc.new` or `new doc`.
enum QuickNew {
    static let all: [(title: String, url: String, names: [String])] = [
        ("New Google Doc", "https://docs.new", ["doc", "docs", "document"]),
        ("New Google Sheet", "https://sheets.new", ["sheet", "sheets", "spreadsheet"]),
        ("New Google Slides", "https://slides.new", ["slides", "slide", "deck", "presentation"]),
        ("New Google Form", "https://forms.new", ["form", "forms", "survey"]),
        ("New Google Calendar Event", "https://cal.new", ["cal", "calendar", "event", "meeting"]),
        ("New Google Meet", "https://meet.new", ["meet", "call"]),
        ("New Notion Page", "https://notion.new", ["notion", "note"]),
        ("New Linear Issue", "https://linear.new", ["linear", "issue"]),
        ("New Jira Issue", "https://jira.new", ["jira", "ticket"]),
        ("New Confluence Page", "https://confluence.new", ["confluence", "wiki"]),
        ("New GitHub Gist", "https://gist.new", ["gist", "snippet"]),
        ("New GitHub Repository", "https://repo.new", ["repo", "repository"]),
        ("New Figma Design", "https://figma.new", ["figma", "design"]),
        ("New FigJam Board", "https://figjam.new", ["figjam", "whiteboard", "board"]),
        ("New Word Document", "https://word.new", ["word"]),
        ("New Excel Workbook", "https://excel.new", ["excel", "workbook"]),
        ("New PowerPoint Presentation", "https://powerpoint.new", ["powerpoint", "ppt"]),
    ]

    /// `doc.new` (a name, exactly), or `new …` / `create …` with a name or,
    /// unless `exact`, the start of one — a whole name first, so `new issue`
    /// is Linear's, not a guess.
    static func find(_ typed: String, exact: Bool = false) -> (title: String, url: String)? {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let dotted = text.hasSuffix(".new")
        let name: String
        if dotted {
            name = String(text.dropLast(4))
        } else {
            let words = text.split(separator: " ", maxSplits: 1)
            guard words.count == 2, ["new", "create"].contains(words[0]) else { return nil }
            name = words[1].trimmingCharacters(in: .whitespaces)
        }
        let hit = all.first { $0.names.contains(name) }
            ?? (exact || dotted ? nil : all.first { $0.names.contains { $0.hasPrefix(name) } })
        return hit.map { (title: $0.title, url: $0.url) }
    }

    /// For Return: a name typed in full (`new doc`, `doc.new`), never the
    /// start of one still being typed.
    static func url(_ typed: String) -> URL? { find(typed, exact: true).flatMap { URL(string: $0.url) } }
}

// MARK: - the calculator

/// Sums typed into the field: + − × ÷ ^, brackets, and % (of the number
/// before it: `50 * 20%` is 10; between two numbers it is the remainder).
/// A small parser of its own — the text is never handed to NSExpression,
/// which would run whatever it was given.
enum Calculator {
    /// The sum and its value as the row shows it, or nil when the text is
    /// not a sum: no operator, a date (2026-11-25) or phone number
    /// (1-800-555-0100), a version (1.2.3), words.
    static func answer(_ typed: String) -> (expression: String, value: String)? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if text.hasSuffix("=") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, text.count <= 200, text.contains(where: \.isNumber),
              text.range(of: #"^\d+(-\d+){2,}$"#, options: .regularExpression) == nil,
              let tokens = tokens(text),
              // An operator between values: `-5`, `(5)` and `50%` are numbers, not sums.
              tokens.indices.dropFirst().dropLast().contains(where: { at in
                  guard case .op(let op) = tokens[at], "+-*/^%".contains(op), tokens[at - 1] != .op("(") else { return false }
                  if case .op(let before) = tokens[at - 1], before != ")" && before != "%" { return false }
                  if case .op(let after) = tokens[at + 1] { return after == "(" || after == "-" || after == "+" }
                  return true
              })
        else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return (text, format(value))
    }

    enum Token: Equatable { case number(Double), op(Character) }

    static func tokens(_ text: String) -> [Token]? {
        var out: [Token] = []
        var chars = Array(text)[...]
        while let c = chars.first {
            if c.isWhitespace { chars = chars.dropFirst(); continue }
            if c.isASCII, c.isNumber || c == "." {
                let digits = chars.prefix { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
                chars = chars.dropFirst(digits.count)
                // 1,000 is a thousand; 1,2 and a version like 1.2.3 are not numbers.
                let run = String(digits)
                guard !run.contains(",") || run.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil,
                      let number = Double(run.replacingOccurrences(of: ",", with: "")) else { return nil }
                out.append(.number(number))
                continue
            }
            let op: Character
            switch c {
            case "+", "-", "*", "/", "^", "%", "(", ")": op = c
            case "×", "x", "X", "·": op = "*"
            case "÷": op = "/"
            case "−", "–": op = "-"
            default: return nil
            }
            out.append(.op(op))
            chars = chars.dropFirst()
        }
        return out
    }

    /// expr := term (± term)* · term := unary ((× ÷ %) unary)* ·
    /// unary := ± unary | power · power := postfix (^ unary)? ·
    /// postfix := primary %* · primary := number | ( expr )
    struct Parser {
        let tokens: [Token]
        var at = 0

        mutating func parse() -> Double? {
            guard let value = expr(), at == tokens.count else { return nil }
            return value
        }

        private func peek(_ offset: Int = 0) -> Token? { at + offset < tokens.count ? tokens[at + offset] : nil }
        private func isOp(_ op: Character, _ offset: Int = 0) -> Bool { peek(offset) == .op(op) }
        /// A number or a bracket at `offset`: what makes % a remainder
        /// (`10 % 3`) rather than a percent (`20% + 1`).
        private func startsValue(_ offset: Int) -> Bool {
            switch peek(offset) {
            case .number: return true
            case .op(let op): return op == "("
            case nil: return false
            }
        }

        private mutating func expr() -> Double? {
            guard var value = term() else { return nil }
            while isOp("+") || isOp("-") {
                let plus = isOp("+")
                at += 1
                guard let rhs = term() else { return nil }
                value = plus ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while true {
                if isOp("*") || isOp("/") || (isOp("%") && startsValue(1)) {
                    guard case .op(let op) = peek() else { return nil }
                    at += 1
                    guard let rhs = unary() else { return nil }
                    switch op {
                    case "*": value *= rhs
                    case "/": value /= rhs
                    default: value = value.truncatingRemainder(dividingBy: rhs)
                    }
                } else {
                    return value
                }
            }
        }

        private mutating func unary() -> Double? {
            if isOp("-") { at += 1; return unary().map { -$0 } }
            if isOp("+") { at += 1; return unary() }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            guard isOp("^") else { return base }
            at += 1
            return unary().map { pow(base, $0) }
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while isOp("%"), !startsValue(1) {
                at += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            switch peek() {
            case .number(let number):
                at += 1
                return number
            case .op("("):
                at += 1
                guard let value = expr(), isOp(")") else { return nil }
                at += 1
                return value
            default:
                return nil
            }
        }
    }

    /// Twelve significant digits, no trailing zeros: 0.1+0.2 is 0.3.
    static func format(_ value: Double) -> String {
        let text = String(format: "%.12g", value)
        return text == "-0" ? "0" : text
    }
}

// MARK: - Settings › General

/// The engine, and a custom engine's address when that is the one picked.
struct SearchEngineLine: View {
    @AppStorage(SearchEngines.key, store: Store.settings) private var engine = "google"
    @AppStorage(SearchEngines.customKey, store: Store.settings) private var custom = ""

    var body: some View {
        Line("Search engine", "Where words go when they aren't an address. Sums, !bangs and .new shortcuts are worked out on this Mac and send nothing before Return.") {
            Menu {
                ForEach(SearchEngines.builtIn, id: \.id) { choice in
                    Button(choice.name) { engine = choice.id }
                }
                Divider()
                Button("Custom…") { engine = "custom" }
            } label: {
                HStack(spacing: 6) {
                    Text(engine == "custom" ? "Custom" : SearchEngines.builtIn.first(where: { $0.id == engine })?.name ?? "Google")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Palette.wash, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Search engine")
        }
        if engine == "custom" {
            Rule()
            Line("Custom engine", SearchEngines.custom(custom) == nil
                 ? "An address with %s where the words go — until then, Google"
                 : "Searches go to \(SearchEngines.custom(custom)?.name ?? "")") {
                TextField("", text: $custom)
                    .fieldExample("https://example.com/search?q=%s", when: custom.isEmpty)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .settingsField()
                    .accessibilityLabel("Custom search engine address")
            }
        }
    }
}
