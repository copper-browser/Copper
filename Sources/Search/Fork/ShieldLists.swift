import Foundation
import WebKit

// Fork (ardia-shield): the lists behind the blocker (Shield.swift). EasyList,
// EasyPrivacy, uBlock's own filters, the cookie-notice lists and a regional
// list for each language the Mac reads, turned into WebKit rule JSON before a
// release (tools/shield/refresh.py, with AdGuard's SafariConverterLib) and
// carried in the app as Resources/shield. Each file is compiled once per
// version into this world's own store; every launch after that only looks it
// up. Settings › Privacy turns each kind on or off and takes your own list.

enum ShieldLists {
    enum Kind: String, CaseIterable {
        case ads, trackers, cookies, regional, custom

        var title: String {
            switch self {
            case .ads: return "Ads"
            case .trackers: return "Trackers"
            case .cookies: return "Cookie banners"
            case .regional: return "Regional lists"
            case .custom: return "Your own filters"
            }
        }
    }

    struct File: Decodable { let file: String; let rules: Int; let sha: String }
    struct List: Decodable { let id: String; let group: String; let title: String; let lang: [String]; let files: [File] }
    private struct Index: Decodable { let lists: [List] }

    /// One rule list as WebKit keeps it: its identifier carries the version,
    /// so a new release's lists are new identifiers and the old ones go.
    struct Piece {
        let id: String
        let title: String
        let kind: Kind
        let rules: Int
        let file: URL? // bundled, xz
        let text: String? // your own filters, converted when it is compiled
    }

    // MARK: what is bundled

    static let folder: URL? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        var candidates: [URL] = []
        for root in roots {
            let bundle = root.appendingPathComponent(name)
            if let inner = Bundle(url: bundle)?.resourceURL { candidates.append(inner.appendingPathComponent("shield")) }
            candidates.append(bundle.appendingPathComponent("shield"))
            candidates.append(bundle.appendingPathComponent("Contents/Resources/shield"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.json").path) }
    }()

    static let bundled: [List] = {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { return [] }
        return (try? JSONDecoder().decode(Index.self, from: data))?.lists ?? []
    }()

    /// The two-letter languages the Mac reads, in its order ("de-CH" → "de").
    static func languages(_ preferred: [String] = Locale.preferredLanguages) -> [String] {
        var seen: [String] = []
        for tag in preferred {
            if let code = Locale(identifier: tag).language.languageCode?.identifier, !seen.contains(code) { seen.append(code) }
        }
        return seen
    }

    /// The regional lists for those languages (none for English: EasyList is English).
    static func regional(for languages: [String], in lists: [List] = bundled) -> [List] {
        lists.filter { $0.group == Kind.regional.rawValue && !Set($0.lang).isDisjoint(with: languages) }
    }

    // MARK: what is on

    static func isOn(_ kind: Kind) -> Bool {
        Store.settings.object(forKey: "shield.\(kind.rawValue)") as? Bool ?? true
    }

    @MainActor static func set(_ kind: Kind, _ on: Bool) {
        Store.settings.set(on, forKey: "shield.\(kind.rawValue)")
        Shield.shared.load()
    }

    /// Every bundled piece, on or not: what the store may keep.
    static var every: [Piece] { bundled.flatMap(pieces) }

    /// The pieces to put on pages now: the kinds switched on, regional lists
    /// for the Mac's languages, and your own filters if there are any.
    static func wanted() -> [Piece] {
        var lists = bundled.filter { $0.group != Kind.regional.rawValue && isOn(Kind(rawValue: $0.group) ?? .ads) }
        if isOn(.regional) { lists += regional(for: languages()) }
        var pieces = lists.flatMap(pieces)
        if let own = custom() { pieces.append(own) }
        return pieces
    }

    private static func pieces(_ list: List) -> [Piece] {
        list.files.enumerated().map { n, file in
            Piece(id: "shield-\(file.file.replacingOccurrences(of: ".json.xz", with: ""))-\(file.sha)",
                  title: list.files.count > 1 ? "\(list.title) (\(n + 1) of \(list.files.count))" : list.title,
                  kind: Kind(rawValue: list.group) ?? .ads, rules: file.rules,
                  file: folder?.appendingPathComponent(file.file), text: nil)
        }
    }

    /// A piece's JSON and rule count. Off the main thread: the biggest file is ~16 MB.
    static func read(_ piece: Piece) -> (json: String, rules: Int)? {
        if let text = piece.text {
            let made = convert(text)
            return made.rules > 0 ? (made.json, made.rules) : nil
        }
        // An NSString made here, off the main thread, is what WebKit copies in one go when the
        // compile is asked for on the main thread; a Swift string would be re-read there.
        guard let file = piece.file, let packed = try? Data(contentsOf: file),
              let raw = try? (packed as NSData).decompressed(using: .lzma),
              let json = NSString(data: raw as Data, encoding: String.Encoding.utf8.rawValue) else { return nil }
        return (json as String, piece.rules)
    }

    // MARK: your own filters

    static let rulesKey = "shield.custom.rules"
    static let urlKey = "shield.custom.url"
    static var fetchedFile: URL { Store.file("shield-custom.txt") }

    /// Your rules plus the last copy of your list's address, as one piece,
    /// named by a hash of the text (converted later, off the main thread).
    static func custom() -> Piece? {
        guard isOn(.custom) else { return nil }
        let typed = Store.settings.string(forKey: rulesKey) ?? ""
        let fetched = (Store.settings.string(forKey: urlKey) ?? "").isEmpty ? "" : (try? String(contentsOf: fetchedFile, encoding: .utf8)) ?? ""
        let text = (typed + "\n" + fetched).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Piece(id: String(format: "shield-custom-%016llx", hash), title: Kind.custom.title, kind: .custom,
                     rules: 0, file: nil, text: text)
    }

    /// Filters in the forms people paste: `||host^` (`$third-party` too), a
    /// bare host or a hosts-file line, `##selector`, `site.com,other.org##selector`.
    /// A list already in WebKit's JSON (it starts with `[`) is taken as it is.
    /// shortcut: only these forms; paths, other `$` options, `@@` and scriptlets
    /// are counted as skipped. Put a big list through tools/shield/refresh.py.
    static func convert(_ text: String) -> (json: String, rules: Int, skipped: Int) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("["), let data = body.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return (body, array.count, 0)
        }
        var rules: [[String: Any]] = []
        var skipped = 0
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("# ") || line == "#" { continue }
            if let mark = line.range(of: "##") {
                let selector = String(line[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
                let sites = line[..<mark.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard !selector.isEmpty, !sites.contains(where: { $0.hasPrefix("~") || !isHost($0) }) else { skipped += 1; continue }
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !sites.isEmpty { trigger["if-domain"] = sites.map { "*" + $0 } }
                // One rule each: WebKit drops a rule whose selector it can't read, not its neighbours.
                rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
                continue
            }
            var host = line
            var thirdParty = false
            if host.hasPrefix("||") {
                host.removeFirst(2)
                if let options = host.firstIndex(of: "$") {
                    guard ["third-party", "3p"].contains(host[host.index(after: options)...]) else { skipped += 1; continue }
                    thirdParty = true
                    host = String(host[..<options])
                }
                guard host.hasSuffix("^") else { skipped += 1; continue }
                host.removeLast()
            } else {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count == 2, ["0.0.0.0", "127.0.0.1"].contains(parts[0]) { host = String(parts[1]) }
                else if parts.count != 1 { skipped += 1; continue }
            }
            host = host.lowercased()
            guard isHost(host), host.contains(".") else { skipped += 1; continue }
            var trigger: [String: Any] = ["url-filter": "^[^:]+://+([^:/]+\\.)?" + NSRegularExpression.escapedPattern(for: host) + "[/:]"]
            if thirdParty { trigger["load-type"] = ["third-party"] }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return (String(data: data, encoding: .utf8) ?? "[]", rules.count, skipped)
    }

    private static func isHost(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    /// Your list's address, fetched again: when it is set, and at launch once a day.
    @MainActor static func fetch(force: Bool = false, done: (@MainActor (String?) -> Void)? = nil) {
        let address = (Store.settings.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { done?(address.isEmpty ? nil : "Not a web address"); return }
        let age = (try? fetchedFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        guard force || age > 86_400 else { done?(nil); return }
        URLSession.shared.dataTask(with: url) { data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let text = data.flatMap { $0.count <= 20_000_000 ? String(data: $0, encoding: .utf8) : nil }
            if ok, let text { try? text.write(to: fetchedFile, atomically: true, encoding: .utf8) }
            let trouble: String? = ok && text != nil ? nil : (error?.localizedDescription ?? "The list didn't download")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if trouble == nil { Shield.shared.load() }
                    done?(trouble)
                }
            }
        }.resume()
    }
}

// MARK: - what WebKit says it did

extension Browser {
    /// WKNavigationDelegatePrivate: a rule list acted on a load. Blocked loads
    /// are counted per page for `bench shield blocked`.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        if action.value(forKey: "blockedLoad") as? Bool == true { Shield.shared.counted(webView) }
    }
}

// MARK: - bench

/// `bench shield stats|blocked|set KIND on|off|pause HOST on|off|recompile|custom rules TEXT|custom url URL|custom clear`.
@MainActor
enum ShieldBench {
    static func handle(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? "stats"
        let arg = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch op {
        case "stats":
            break
        case "set":
            guard words.count == 2, let kind = ShieldLists.Kind(rawValue: words[0]), ["on", "off"].contains(words[1]) else {
                return ["error": "shield set ads|trackers|cookies|regional|custom on|off"]
            }
            ShieldLists.set(kind, words[1] == "on")
        case "recompile":
            Shield.shared.load(fresh: true)
        case "blocked": // each open page's blocked loads since it started
            let tabs = Windows.all.flatMap(\.tabs).compactMap { tab -> [String: Any]? in
                guard let web = tab.built else { return nil }
                return ["id": Bench.short(tab), "url": web.url?.absoluteString ?? "", "blocked": Shield.shared.blocked(on: web)]
            }
            return ["tabs": tabs]
        case "pause": // off (on) for one site, as Settings' Block on HOST switch
            guard words.count == 2, ["on", "off"].contains(words[1]) else { return ["error": "shield pause HOST on|off"] }
            let host = words[0].lowercased()
            Shield.shared.pause(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, words[1] == "on") // as Curtain.host names it
        case "custom":
            switch words.first {
            case "rules": Store.settings.set(words.count > 1 ? words[1].replacingOccurrences(of: "\\n", with: "\n") : "", forKey: ShieldLists.rulesKey)
            case "url": Store.settings.set(words.count > 1 ? words[1] : "", forKey: ShieldLists.urlKey); ShieldLists.fetch(force: true)
            case "clear": Store.settings.removeObject(forKey: ShieldLists.rulesKey); Store.settings.removeObject(forKey: ShieldLists.urlKey)
            default: return ["error": "shield custom rules TEXT|url URL|clear"]
            }
            Shield.shared.load()
        default:
            return ["error": "shield stats|blocked|set KIND on|off|pause HOST on|off|recompile|custom rules TEXT|url URL|clear"]
        }
        return Shield.shared.report()
    }
}
