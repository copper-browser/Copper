import AppKit

// Air Traffic Control: where a link from another app lands.
//
// An ordered list of rules. Each names who sent the link (an app, or any
// app) and where it points (any site, a host and its subdomains, or a
// pattern with `*`), and sends it to a space and into a tab, a new window
// or Little Copper (Fork/Little.swift). The first rule that fits wins;
// "Everything else" takes the rest, and left as it comes (the space in
// front, a tab) it is what Copper always did. A click inside Copper is
// never routed: only `LinkRelay.land` and the links that launched the app
// (`Links.hand`) ask here.
//
// Kept in air-traffic.json beside the session. Settings › General › Where
// links open edits it (Fork/AirTrafficSettings.swift); `adopt` is the door
// for a move-in from Arc, whose rules have the same shape.

@MainActor
final class AirTraffic: ObservableObject {
    static let shared = AirTraffic()

    enum Opening: String, Codable, CaseIterable {
        case tab, window, little

        var title: String {
            switch self {
            case .tab: return "Tab"
            case .window: return "New Window"
            case .little: return "Little Copper"
            }
        }
    }

    /// Where a link goes: a space (nil = whichever is in front) and how.
    struct Target: Codable, Equatable {
        var space: UUID? = nil
        var open: Opening = .tab
    }

    struct Rule: Codable, Equatable, Identifiable {
        var id = UUID()
        /// The sending app's bundle id; nil for any app.
        var app: String? = nil
        /// That app's name as shown — it may not be on this Mac.
        var appName: String? = nil
        /// Empty for any site; `github.com` for it and its subdomains;
        /// `github.com/copper-browser` for addresses under that path; with
        /// `*` a pattern over host and path (`*.google.com`, `*/pull/*`).
        var site = ""
        var to = Target()
    }

    struct Book: Codable, Equatable {
        var rules: [Rule] = []
        /// Everything else.
        var otherwise = Target()
    }

    @Published var book: Book {
        didSet { if book != oldValue { save() } }
    }

    /// The last link routed, for `bench atc last` and the Try a Link line.
    private(set) var last: [String: Any] = [:]

    private static var file: URL { Store.file("air-traffic.json") }

    private init() {
        guard let data = try? Data(contentsOf: Self.file) else { book = Book(); return }
        if let read = try? JSONDecoder().decode(Book.self, from: data) {
            book = read
        } else {
            Store.quarantine(Self.file)
            book = Book()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    /// Rules from elsewhere (Arc's, on a move in), after the ones already
    /// here; one already kept is not added twice.
    func adopt(_ rules: [Rule]) {
        let known = Set(book.rules.map { "\($0.app ?? "")|\($0.site.lowercased())" })
        book.rules += rules.filter { !known.contains("\($0.app ?? "")|\($0.site.lowercased())") }
    }

    // MARK: - deciding

    /// The rule that takes this link, or nil for Everything else, and where
    /// it goes. A space since deleted means the one in front.
    func decide(_ url: URL, from app: String?) -> (rule: Rule?, to: Target) {
        let rule = book.rules.first { Self.matches($0, url, from: app) }
        var to = rule?.to ?? book.otherwise
        if let space = to.space, !Spaces.shared.all.contains(where: { $0.id == space }) { to.space = nil }
        return (rule, to)
    }

    /// Sends a link from another app where the rules say. True when it went
    /// to Little Copper or a new window and the caller has nothing left to
    /// do; for a tab, the rule's space is chosen in `browser` first and the
    /// caller lands the link there as it always has.
    func route(_ url: URL, from app: String?, in browser: Browser?) -> Bool {
        let (rule, to) = decide(url, from: app)
        let index = rule.flatMap { r in book.rules.firstIndex { $0.id == r.id } }
        last = ["url": url.absoluteString, "from": app ?? "", "rule": index ?? -1,
                "open": to.open.rawValue, "space": to.space?.uuidString ?? ""]
        if rule != nil || to != Target() {
            Updates.note("air traffic: \(url.absoluteString) from \(app ?? "an unknown app") → \(index.map { "rule \($0 + 1)" } ?? "everything else"): \(to.open.rawValue)\(to.space.map { " in space \($0.uuidString.prefix(8))" } ?? "")")
        }
        switch to.open {
        case .little:
            Little.open(url, space: to.space)
            return true
        case .window:
            Self.newWindow(url, space: to.space)
            return true
        case .tab:
            if let space = to.space, let browser { Spaces.shared.select(space, in: browser) }
            return false
        }
    }

    /// ⌘N, and the link in the new window once it is up.
    static func newWindow(_ url: URL, space: UUID?) {
        let before = Set(Windows.all.map(ObjectIdentifier.init))
        Windows.newWindow()
        NSApp.activate(ignoringOtherApps: true)
        func land(_ tries: Int) {
            if let made = Windows.all.first(where: { !before.contains(ObjectIdentifier($0)) }), Windows.window(of: made) != nil {
                if let space { Spaces.shared.select(space, in: made) }
                made.arrive(url)
                return
            }
            // shortcut: a window that never comes (headless without a scene) gets the link in front after 3 s.
            guard tries < 60 else { Windows.current.arrive(url); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { land(tries + 1) }
        }
        land(0)
    }

    // MARK: - matching

    nonisolated static func matches(_ rule: Rule, _ url: URL, from app: String?) -> Bool {
        if let want = rule.app, !want.isEmpty, want.caseInsensitiveCompare(app ?? "") != .orderedSame { return false }
        return site(rule.site, matches: url)
    }

    nonisolated static func site(_ pattern: String, matches url: URL) -> Bool {
        var want = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if want.isEmpty { return true }
        for scheme in ["https://", "http://"] where want.hasPrefix(scheme) { want.removeFirst(scheme.count) }
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if want.hasPrefix("www.") { want.removeFirst(4) }
        let path = url.path(percentEncoded: false).lowercased()
        if want.contains("*") {
            // Over the host alone, or host and path once the pattern has a slash.
            return glob(Array(want), Array(want.contains("/") ? host + path : host))
        }
        guard let slash = want.firstIndex(of: "/") else { return host == want || host.hasSuffix("." + want) }
        let place = String(want[..<slash])
        var under = String(want[slash...])
        guard host == place || host.hasSuffix("." + place) else { return false }
        if under.hasSuffix("/") { under.removeLast() }
        return under.isEmpty || path == under || path.hasPrefix(under + "/")
    }

    /// `*` stands for any run of characters, none included; everything else
    /// is itself. Anchored at both ends.
    nonisolated static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1; t += 1
            } else if star >= 0 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    // MARK: - who sent it

    /// The app a GetURL event came from: the sender's bundle id, or — for a
    /// command-line `open` or a script, which have none — the app it runs
    /// under (Terminal, iTerm, an editor), the nearest ancestor that has one.
    nonisolated static func sender(of event: NSAppleEventDescriptor) -> String? {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 else { return nil }
        return app(of: pid)
    }

    nonisolated static func app(of pid: pid_t) -> String? {
        var pid = pid
        for _ in 0..<8 {
            if pid == getpid() { return Bundle.main.bundleIdentifier }
            if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier, app.activationPolicy != .prohibited {
                return id
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_ppid > 1 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// An app's name for a bundle id, from wherever it is installed.
    static func name(of bundle: String?) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - bench

    /// `atc` the rules; `atc add site=S [app=BUNDLE] [space=N] [open=tab|window|little]`;
    /// `atc else [space=N] [open=…]`; `atc clear`; `atc try URL [APP]` what
    /// would happen; `atc route URL [APP]` a link from that app, landed for
    /// real (LinkRelay.land); `atc last` the last link routed; `atc from PID`
    /// the app a process's link counts as coming from.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let atc = shared
        let op = request["op"] as? String ?? "list"
        let arg = request["arg"] as? String ?? ""
        let words = arg.split(separator: " ").map(String.init)
        var pairs: [String: String] = [:]
        for word in words { if let eq = word.firstIndex(of: "=") { pairs[String(word[..<eq])] = String(word[word.index(after: eq)...]) } }
        func target(_ base: Target) -> Target? {
            var to = base
            if let open = pairs["open"] { guard let o = Opening(rawValue: open) else { return nil }; to.open = o }
            if let space = pairs["space"] {
                guard let n = Int(space), Spaces.shared.all.indices.contains(n) else { return nil }
                to.space = Spaces.shared.all[n].id
            }
            return to
        }
        switch op {
        case "add":
            guard let to = target(Target()) else { return ["error": "atc add site=S [app=BUNDLE] [space=N] [open=tab|window|little]"] }
            atc.book.rules.append(Rule(app: pairs["app"], appName: name(of: pairs["app"]), site: pairs["site"] ?? "", to: to))
        case "else":
            guard let to = target(atc.book.otherwise) else { return ["error": "atc else [space=N] [open=tab|window|little]"] }
            atc.book.otherwise = to
        case "clear":
            atc.book = Book()
        case "try", "route":
            guard let url = words.first.flatMap({ URL(string: $0) }) else { return ["error": "atc \(op) URL [APP]"] }
            let app = words.count > 1 ? words[1] : nil
            if op == "route" {
                LinkRelay.land(url, from: app, first: Windows.main)
                return atc.last
            }
            let (rule, to) = atc.decide(url, from: app)
            return ["rule": rule.flatMap { r in atc.book.rules.firstIndex { $0.id == r.id } } ?? -1,
                    "open": to.open.rawValue, "space": to.space?.uuidString ?? ""]
        case "last":
            return atc.last
        case "from":
            guard let pid = words.first.flatMap(Int32.init) else { return ["error": "atc from PID"] }
            return ["app": app(of: pid) ?? ""]
        default: break
        }
        return ["rules": atc.book.rules.map { ["app": $0.app ?? "", "site": $0.site, "open": $0.to.open.rawValue,
                                               "space": $0.to.space?.uuidString ?? ""] },
                "else": ["open": atc.book.otherwise.open.rawValue, "space": atc.book.otherwise.space?.uuidString ?? ""]]
    }
}
