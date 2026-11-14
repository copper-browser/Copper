import AppKit
import PDFKit
import WebKit

// The browser's own state, for agents: files out (browser_pdf_save,
// browser_downloads), what the page fetched (browser_network_requests,
// NetLog.swift), its cookies, the user's history, bookmarks and spaces — and
// browser_file_upload (FileChooser.swift). Playwright MCP's name and shape
// where it has one (browser_file_upload, browser_pdf_save,
// browser_network_requests); Copper's own, in the same style, where it
// doesn't.
//
// Page tools work on the caller's tab (Tools.current), never another's: a
// download list is that tab's downloads, cookies are that tab's site in that
// tab's cookie jar, and a space move takes only a tab of the caller's own that
// is off the user's screen. HttpOnly cookies are a site's sign-in: their
// values, and changing them, need that site shared with agents in Settings ›
// Passwords › Agent access, the same gate browser_sign_in has.

@MainActor
enum StateTools {
    nonisolated static var catalogue: [[String: Any]] {
        [
            FileChooser.tool,
            tool("browser_pdf_save", "Save your tab's page as a PDF (letter-proportioned pages). Into the downloads folder unless filename says where.", [
                "filename": string("Where to save: an absolute path, or a name under the downloads folder; default <page title>.pdf"),
            ]),
            tool("browser_downloads", "Downloads your tab started (or a popup it opened): name, state, bytes, and where the file is.", [
                "wait": number("Seconds to wait for running downloads to finish, at most 60; default 0"),
            ]),
            NetLog.tool,
            tool("browser_cookies", "Your tab's site's cookies in its cookie jar: list (all or by name), set, or delete. HttpOnly values, and changes to HttpOnly cookies, need the site shared in Settings › Passwords › Agent access.", [
                "action": string("Default list", ["enum": ["list", "set", "delete"]]),
                "name": string("Cookie name: filters list; required for set and delete"),
                "value": string("Value, for set"),
                "domain": string("For set: the tab's host (default) or a parent domain of it; for delete: only this domain"),
                "path": string("Default /"),
                "expires": number("For set: Unix time in seconds; omit for a session cookie"),
                "httpOnly": bool("For set"),
                "secure": bool("For set"),
                "sameSite": string("For set", ["enum": ["Strict", "Lax", "None"]]),
            ]),
            tool("browser_history", "Search the user's browsing history on this Mac (newest first): title, address, last visit, visit count.", [
                "query": string("Words or part of an address; omit for the most recent"),
                "limit": number("Default 20, at most 200"),
            ], tab: false),
            tool("browser_bookmarks", "The user's bookmarks: list them (with folders), search them, or add a page (your tab's, unless url is given).", [
                "action": string("Default list", ["enum": ["list", "search", "add"]]),
                "query": string("For search"),
                "url": string("For add; default your tab's address"),
                "title": string("For add; default the page's title"),
            ]),
            tool("browser_spaces", "Copper's spaces (sets of tabs, each window shows one): list them without switching, or move your own tab — one you opened, off the user's screen — into one.", [
                "action": string("Default list", ["enum": ["list", "move"]]),
                "space": string("For move: the space's name, index or id from list"),
            ]),
        ]
    }

    nonisolated static var names: Set<String> { Set(catalogue.compactMap { $0["name"] as? String }) }

    /// No tab to stage first: these read or write the browser, not a page.
    nonisolated static func tabless(_ name: String, _ args: [String: Any]) -> Bool {
        switch name {
        case "browser_history": return true
        case "browser_bookmarks": return (args["action"] as? String) != "add" || args["url"] != nil
        case "browser_spaces": return (args["action"] as? String) != "move"
        default: return false
        }
    }

    static func call(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        switch name {
        case "browser_file_upload": return try await FileChooser.call(args, in: browser)
        case "browser_pdf_save": return try await pdf(args, in: browser)
        case "browser_downloads": return try await downloads(args, in: browser)
        case "browser_network_requests": return try NetLog.call(args, in: browser)
        case "browser_cookies": return try await cookies(args, in: browser)
        case "browser_history": return try history(args, in: browser)
        case "browser_bookmarks": return try bookmarks(args, in: browser)
        case "browser_spaces": return try spaces(args, in: browser)
        default: throw Tools.Failure(text: "Unknown tool \(name)")
        }
    }

    // MARK: - PDF

    private static func pdf(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let tab = try Tools.current(browser)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            tab.web.createPDF(configuration: WKPDFConfiguration()) { continuation.resume(with: $0) }
        }
        let paged = Self.paged(data)
        let url = try destination(args["filename"] as? String, title: tab.title, in: browser.prefs.downloads)
        do {
            try await OffMainWrite.write(paged.data, to: url)
        } catch let timedOut as OffMainWrite.TimedOut {
            throw Tools.Failure(text: timedOut.description)
        } catch {
            throw Tools.Failure(text: "couldn't save \(url.path): \(error.localizedDescription)")
        }
        return [.text("Saved a \(paged.pages)-page PDF to \(url.path). \(Tools.pageLine(tab))")]
    }

    /// Where the PDF goes: an absolute (or ~) path as given; a bare name, or
    /// nothing, under the downloads folder, numbered rather than overwriting.
    nonisolated static func destination(_ given: String?, title: String, in folder: URL, files: FileManager = .default) throws -> URL {
        let raw = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            var folderFlag: ObjCBool = false
            guard files.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &folderFlag), folderFlag.boolValue else {
                throw Tools.Failure(text: "no folder \(url.deletingLastPathComponent().path)")
            }
            return url
        }
        let clean = (raw.isEmpty ? title : raw).components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-")
        var name = clean.trimmingCharacters(in: .whitespaces).isEmpty ? "page" : clean
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        let stem = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while files.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n).pdf")
            n += 1
        }
        return url
    }

    /// WebKit draws the whole page as one tall sheet; cut it into
    /// letter-proportioned pages so it reads and prints as a document.
    nonisolated static func paged(_ data: Data) -> (data: Data, pages: Int) {
        guard let source = PDFDocument(data: data), source.pageCount == 1, let sheet = source.page(at: 0) else {
            return (data, PDFDocument(data: data)?.pageCount ?? 1)
        }
        let box = sheet.bounds(for: .mediaBox)
        let height = box.width * 11 / 8.5
        guard box.height > height * 1.05 else { return (data, 1) }
        let out = PDFDocument()
        var top = box.maxY
        while top > box.minY + 1 {
            guard let slice = sheet.copy() as? PDFPage else { break }
            let cut = CGRect(x: box.minX, y: max(box.minY, top - height), width: box.width, height: min(height, top - box.minY))
            slice.setBounds(cut, for: .mediaBox)
            slice.setBounds(cut, for: .cropBox)
            out.insert(slice, at: out.pageCount)
            top -= height
        }
        guard out.pageCount > 0, let joined = out.dataRepresentation() else { return (data, 1) }
        return (joined, out.pageCount)
    }

    // MARK: - downloads

    private static func downloads(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let tab = try Tools.current(browser)
        func mine() -> [Downloads.Item] { Downloads.shared.items.filter { $0.tabs.contains(tab.id) } }
        let wait = min(max((args["wait"] as? NSNumber)?.doubleValue ?? 0, 0), 60)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, mine().contains(where: { if case .running = $0.state { return true }; return false }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let items = mine()
        guard !items.isEmpty else { return [.text("No downloads from this tab. A click that downloads lands the file in \(browser.prefs.downloads.path).")] }
        return [.text("### Downloads (newest first)\n" + items.map(line).joined(separator: "\n"))]
    }

    private static func line(_ item: Downloads.Item) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.done, countStyle: .file)
        let state: String
        switch item.state {
        case .running: state = "downloading \(size)" + (item.total.map { " of " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case .finished: state = "finished, \(size)"
        case .failed(let why): state = "failed: \(why)"
        case .cancelled: state = "cancelled"
        }
        let place = item.file.map { " → \($0.path)" } ?? ""
        return "- \(item.name) — \(state)\(place) (from \(item.from.isEmpty ? "?" : item.from))"
    }

    // MARK: - cookies

    private static func cookies(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let tab = try Tools.current(browser)
        guard let host = tab.address?.host()?.lowercased(), !host.isEmpty else { throw Tools.Failure(text: "your tab has no site — navigate first") }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let access = AgentAccess.shareAll || !AgentAccess.permitted(for: site).isEmpty
        let refusal = "HttpOnly cookies are \(site)'s sign-in — the user can share this site with agents in Settings › Passwords › Agent access"
        let store = tab.web.configuration.websiteDataStore.httpCookieStore
        let jar = await store.allCookies().filter { CookieRules.matches($0.domain, host: host) }
        let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"

        switch (args["action"] as? String) ?? "list" {
        case "list":
            let shown = jar.filter { name == nil || $0.name == name }.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
            guard !shown.isEmpty else { return [.text(name.map { "No cookie \($0) for \(host)." } ?? "No cookies for \(host).")] }
            let lines = shown.map { c -> String in
                let value = c.isHTTPOnly && !access ? "(hidden — \(refusal))" : c.value
                var flags = ["domain=\(c.domain)", "path=\(c.path)"]
                if c.isHTTPOnly { flags.append("HttpOnly") }
                if c.isSecure { flags.append("Secure") }
                if let same = c.sameSitePolicy?.rawValue { flags.append("SameSite=\(same)") }
                flags.append(c.expiresDate.map { "expires=\(Int($0.timeIntervalSince1970))" } ?? "session")
                return "- \(c.name)=\(value); " + flags.joined(separator: "; ")
            }
            return [.text("### Cookies for \(host)\n" + lines.joined(separator: "\n"))]
        case "set":
            guard let name else { throw Tools.Failure(text: "name required") }
            guard let value = args["value"] as? String else { throw Tools.Failure(text: "value required") }
            let domain = (args["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            guard CookieRules.mayScope(domain, host: host) else { throw Tools.Failure(text: "\(domain) is not \(host) or a parent domain of it") }
            let httpOnly = (args["httpOnly"] as? Bool) ?? false
            let replaces = jar.contains { $0.name == name && $0.path == path && $0.isHTTPOnly && CookieRules.same($0.domain, domain) }
            if (httpOnly || replaces), !access { throw Tools.Failure(text: "not set: \(refusal)") }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if (args["secure"] as? Bool) == true { properties[.secure] = "TRUE" }
            if let expires = (args["expires"] as? NSNumber)?.doubleValue { properties[.expires] = Date(timeIntervalSince1970: expires) }
            switch (args["sameSite"] as? String)?.lowercased() {
            case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            default: break
            }
            guard let cookie = HTTPCookie(properties: properties) else { throw Tools.Failure(text: "not a valid cookie") }
            await store.setCookie(cookie)
            return [.text("Set \(name) for \(domain)\(httpOnly ? " (HttpOnly)" : "").")]
        case "delete":
            guard let name else { throw Tools.Failure(text: "name required") }
            let domain = (args["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let gone = jar.filter { $0.name == name && (domain == nil || CookieRules.same($0.domain, domain!)) && (args["path"] == nil || $0.path == path) }
            guard !gone.isEmpty else { return [.text("No cookie \(name) for \(host); nothing deleted.")] }
            if gone.contains(where: \.isHTTPOnly), !access { throw Tools.Failure(text: "not deleted: \(refusal)") }
            for cookie in gone { await store.deleteCookie(cookie) }
            return [.text("Deleted \(gone.count) cookie\(gone.count == 1 ? "" : "s") named \(name).")]
        default:
            throw Tools.Failure(text: "action must be list, set or delete")
        }
    }

    // MARK: - history

    private static func history(_ args: [String: Any], in browser: Browser) throws -> [Tools.Content] {
        if let caller = AgentTabs.callerKey, caller.hasPrefix("bot:") {
            throw Tools.Failure(text: "browser_history is only for agents the user runs on this Mac, not linked apps")
        }
        let query = (args["query"] as? String) ?? ""
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 20, 1), 200)
        let found = query.isEmpty ? browser.history.recent(limit) : Array(browser.history.everything(matching: query).prefix(limit))
        guard !found.isEmpty else { return [.text(query.isEmpty ? "History is empty." : "Nothing in history matches “\(query)”.")] }
        let when = ISO8601DateFormatter()
        let lines = found.map { "- [\($0.title.isEmpty ? $0.key : $0.title)](\($0.url.absoluteString)) · last \(when.string(from: $0.last)) · \($0.count) visit\($0.count == 1 ? "" : "s")" }
        return [.text("### History\(query.isEmpty ? " (most recent)" : " matching “\(query)”")\n" + lines.joined(separator: "\n"))]
    }

    // MARK: - bookmarks

    private static func bookmarks(_ args: [String: Any], in browser: Browser) throws -> [Tools.Content] {
        let marks = browser.bookmarks
        switch (args["action"] as? String) ?? "list" {
        case "list", "search":
            let query = ((args["query"] as? String) ?? "").lowercased()
            var lines: [String] = []
            func walk(_ nodes: [Bookmark], _ trail: String) {
                for node in nodes {
                    if node.isFolder { walk(node.children ?? [], trail.isEmpty ? node.title : "\(trail) › \(node.title)"); continue }
                    guard let url = node.url else { continue }
                    if !query.isEmpty, !node.title.lowercased().contains(query), !url.lowercased().contains(query) { continue }
                    lines.append("- [\(node.title)](\(url))" + (trail.isEmpty ? "" : " in \(trail)"))
                }
            }
            walk(marks.roots, "")
            guard !lines.isEmpty else { return [.text(query.isEmpty ? "No bookmarks." : "No bookmark matches “\(query)”.")] }
            let more = lines.count > 200 ? "\n… \(lines.count - 200) more — search to narrow" : ""
            return [.text("### Bookmarks\n" + lines.prefix(200).joined(separator: "\n") + more)]
        case "add":
            var title = args["title"] as? String
            let url: URL
            if let raw = args["url"] as? String {
                guard let parsed = Address.url(from: raw) else { throw Tools.Failure(text: "not an address: \(raw)") }
                url = parsed
            } else {
                let tab = try Tools.current(browser)
                guard let address = tab.address else { throw Tools.Failure(text: "your tab has no page to bookmark") }
                url = address
                title = title ?? tab.title
            }
            if marks.contains(url) { return [.text("Already bookmarked: \(url.absoluteString)")] }
            marks.add(url, title: (title?.isEmpty == false ? title : nil) ?? url.host ?? url.absoluteString)
            return [.text("Bookmarked \(url.absoluteString).")]
        default:
            throw Tools.Failure(text: "action must be list, search or add")
        }
    }

    // MARK: - spaces

    private static func spaces(_ args: [String: Any], in browser: Browser) throws -> [Tools.Content] {
        let spaces = Spaces.shared
        switch (args["action"] as? String) ?? "list" {
        case "list":
            let here = spaces.current(in: browser)
            let own = AgentTabs.own()
            let lines = spaces.all.enumerated().map { i, space -> String in
                var marks: [String] = []
                if space.id == here { marks.append("on screen in this window") }
                if let own, spaces.spaceID(of: own) == space.id { marks.append("holds your tab") }
                let profile = space.profile.map { " (profile \($0))" } ?? ""
                return "- \(i): \(space.name.isEmpty ? "Untitled" : space.name) {space \(short(space.id))}\(profile) — \(spaces.row(space.id).count) tabs" + (marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))")
            }
            return [.text("### Spaces\n" + lines.joined(separator: "\n"))]
        case "move":
            guard let raw = (args["space"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { throw Tools.Failure(text: "space required (name, index or id from browser_spaces list)") }
            guard let space = pick(raw, in: spaces.all) else { throw Tools.Failure(text: "no single space \(raw) — browser_spaces list names them") }
            let tab = try Tools.current(browser)
            guard tab.id == AgentTabs.own()?.id || AgentTabs.opened.contains(tab.id) else {
                throw Tools.Failure(text: "only a tab of your own moves — open one with browser_tabs new")
            }
            guard tab.pin == nil else { throw Tools.Failure(text: "a pinned tab is in every space already") }
            guard !AgentTabs.onScreen(tab) else { throw Tools.Failure(text: "your tab is on the user's screen; moving it would change what they see") }
            if spaces.spaceID(of: tab) == space.id { return [.text("Your tab is already in \(space.name).")] }
            spaces.move(tab, to: space.id, in: AgentTabs.owner(of: tab))
            guard spaces.spaceID(of: tab) == space.id else { throw Tools.Failure(text: "Copper did not move the tab") }
            return [.text("Moved your tab to \(space.name); your calls still land on it. {tab \(AgentTabs.short(tab))}")]
        default:
            throw Tools.Failure(text: "action must be list or move")
        }
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// A space by index, exact name (any case), or the start of its id.
    nonisolated static func pick(_ raw: String, in all: [Space]) -> Space? {
        if let i = Int(raw), all.indices.contains(i) { return all[i] }
        let named = all.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
        if named.count == 1 { return named[0] }
        let ids = all.filter { $0.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }
        return ids.count == 1 ? ids[0] : nil
    }

    // MARK: - schema

    nonisolated private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [], tab: Bool = true) -> [String: Any] {
        var all = properties
        all["reason"] = Tools.reasonProperty
        if tab { all["tab"] = Tools.tabProperty }
        return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": all, "required": required] as [String: Any]]
    }
    nonisolated private static func string(_ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "string", "description": description].merging(extra) { a, _ in a }
    }
    nonisolated private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    nonisolated private static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
}

/// Which cookies belong to a tab's site.
enum CookieRules {
    private static func bare(_ domain: String) -> String {
        let d = domain.lowercased()
        return d.hasPrefix(".") ? String(d.dropFirst()) : d
    }

    /// A cookie for `domain` is sent to `host`: the host itself or a subdomain of it.
    static func matches(_ domain: String, host: String) -> Bool {
        let d = bare(domain), h = host.lowercased()
        return !d.isEmpty && (h == d || h.hasSuffix("." + d))
    }

    /// An agent may set a cookie for `domain` from `host`: the host, or a
    /// parent domain with a dot in it (never a bare top-level domain); an IP
    /// address or a dotless host only for itself.
    static func mayScope(_ domain: String, host: String) -> Bool {
        let d = bare(domain), h = host.lowercased()
        if d == h { return true }
        let ip = h.allSatisfy { $0.isNumber || $0 == "." } || h.contains(":")
        return !ip && d.contains(".") && h.hasSuffix("." + d)
    }

    static func same(_ a: String, _ b: String) -> Bool { bare(a) == bare(b) }
}
