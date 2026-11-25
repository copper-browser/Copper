import CommonCrypto
import Compression
import CryptoKit
import Foundation
import SQLite3

/// Moving in from Firefox and Zen (Mozilla's engine, Gecko): one more kind of
/// source in the Move-in sheet, beside the Chromium browsers and Safari.
///
/// Each profile listed in `profiles.ini` with a `places.sqlite` is read; the
/// one this install opens comes first and its spaces wear the shared jar, as
/// Chrome's `Default` does. What comes over:
///
/// - **Open tabs** from the newest session file (`sessionstore-backups/
///   recovery.jsonlz4` while it runs, `sessionstore.jsonlz4` after a quit,
///   Zen's `zen-sessions.jsonlz4`), mozLz4-compressed JSON. Firefox: a space
///   per window with its pinned tabs and tab groups. Zen: a space per Zen
///   space (its name and emoji), Essentials as pins, pinned tabs as Saved.
/// - **Bookmarks and history** from `places.sqlite`, **sign-ins** from
///   `cookies.sqlite` (not encrypted). Both are copied with their
///   write-ahead log, which holds the newest rows while the browser runs.
/// - **Passwords** from `logins.json`, unlocked with the profile's own
///   `key4.db` (NSS: PBKDF2 + AES-256 or the older SHA-1 + 3DES), the way
///   Firefox does it with no Primary Password. No macOS prompt: nothing here
///   is in the keychain. Behind a Primary Password they stay, and the summary
///   says to export them (about:logins) and bring the file in instead.
///
/// Add-ons only run in Firefox and are named in the summary; site data
/// (localStorage) isn't read.
enum FlowFirefox {
    /// The Gecko browsers, by their folder under ~/Library/Application Support.
    /// `service`/`account` are unused: there is no keychain key to ask for.
    static let known: [Chromium.Source] = [
        Chromium.Source(name: "Firefox", folder: "Firefox", service: "", account: ""),
        Chromium.Source(name: "Zen", folder: "zen", service: "", account: ""),
    ]

    enum Trouble: Error, Equatable {
        /// key4.db didn't open with the empty password: a Primary Password.
        case primaryPassword
        case unreadable
    }

    /// What a Firefox move can bring of what was chosen: no passkeys, site
    /// data or Web Store extensions (its add-ons are Firefox's own).
    static func usable(_ choice: FlowModel.Choice) -> FlowModel.Choice {
        var out = choice
        out.passkeys = false
        out.localStorage = false
        out.extensions = false
        return out
    }

    // MARK: - profiles

    struct Profile: Equatable {
        /// As profiles.ini has it: under the root ("Profiles/ab12.default-release") or absolute.
        var path: String
        var name: String
        /// The one this install opens: its `[Install…] Default`, else `Default=1`.
        var everyday: Bool
    }

    static func folder(_ path: String, in root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : root.appendingPathComponent(path, isDirectory: true)
    }

    /// The profiles with something in them (a `places.sqlite`), the everyday one first.
    static func profiles(at root: URL) -> [Profile] {
        let fm = FileManager.default
        var found = (try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8)).map(ini) ?? []
        if found.isEmpty {
            // No profiles.ini (a copy of the folder): every folder under Profiles/.
            let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Profiles").path)) ?? []
            found = names.sorted().map { Profile(path: "Profiles/\($0)", name: $0, everyday: false) }
        }
        found = found.filter { fm.fileExists(atPath: folder($0.path, in: root).appendingPathComponent("places.sqlite").path) }
        if !found.isEmpty, !found.contains(where: \.everyday) { found[0].everyday = true }
        return found.filter(\.everyday) + found.filter { !$0.everyday }
    }

    static func ini(_ text: String) -> [Profile] {
        var sections: [(name: String, keys: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1].keys[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        let opened = sections.first { $0.name.hasPrefix("Install") }?.keys["Default"]
            ?? sections.first { $0.name.hasPrefix("Profile") && $0.keys["Default"] == "1" }?.keys["Path"]
        return sections.compactMap { section in
            guard section.name.hasPrefix("Profile"), let path = section.keys["Path"] else { return nil }
            return Profile(path: path, name: section.keys["Name"] ?? path, everyday: path == opened)
        }
    }

    // MARK: - the sheet's counts

    /// The cheap, non-secret read for the sheet: open tabs and counts.
    static func haul(root: URL, name: String) -> FlowModel.Haul {
        var haul = FlowModel.Haul()
        do {
            haul.spaces = try spaces(root: root, name: name)
        } catch {
            haul.notes.append(error.localizedDescription)
            haul.tabsTrouble = "couldn't read \(name)'s open tabs"
        }
        haul.bookmarkCount = FlowBookmarks.count(bookmarks(root: root).nodes)
        haul.placeCount = placeCount(root: root)
        haul.loginCount = loginCount(root: root)
        let addons = addons(root: root)
        if !addons.isEmpty {
            let names = addons.prefix(3).joined(separator: ", ") + (addons.count > 3 ? " and \(addons.count - 3) more" : "")
            haul.stays.append("\(name) add-ons (\(names)) only run in \(name); most have a Chrome Web Store version.")
        }
        haul.notes.append("\(haul.bookmarkCount) bookmarks")
        haul.notes.append("\(haul.placeCount) places")
        return haul
    }

    // MARK: - open tabs

    /// Firefox's LZ4 wrapper: "mozLz40\0", the size (4 bytes, little-endian),
    /// then one raw LZ4 block.
    static func mozLz4(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes.prefix(8).elementsEqual(Array("mozLz40\0".utf8)) else { return nil }
        let size = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        guard size > 0, size < 1 << 30 else { return nil }
        var out = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeBufferPointer { source in
            compression_decode_buffer(&out, size, source.baseAddress! + 12, bytes.count - 12, nil, COMPRESSION_LZ4_RAW)
        }
        return written > 0 ? Data(out.prefix(written)) : nil
    }

    /// A profile's session files, newest first.
    static func sessionFiles(in profile: URL) -> [URL] {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4", "zen-sessions.jsonlz4", "sessionstore-backups/recovery.baklz4"]
            .map { profile.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
    }

    /// Every profile's open tabs. A profile with no session file has none
    /// open; one whose files are all unreadable is trouble.
    static func spaces(root: URL, name: String) throws -> [FlowModel.Space] {
        var out: [FlowModel.Space] = []
        var files = false
        var read = false
        for profile in profiles(at: root) {
            for file in sessionFiles(in: folder(profile.path, in: root)) {
                files = true
                guard let data = try? Data(contentsOf: file), let text = mozLz4(data),
                      let top = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { continue }
                read = true
                out += spaces(session: top, name: profile.everyday ? name : "\(name) · \(profile.name)",
                              profile: profile.everyday ? nil : profile.path)
                break
            }
        }
        guard read || !files else { throw FlowModel.Trouble.unreadable("\(name)'s session files") }
        return out
    }

    /// One session file as spaces. Firefox: a space per window ("Firefox",
    /// "Firefox 2"), pinned tabs as pins, tab groups as folders. Zen: a space
    /// per Zen space, Essentials as pins, a space's pinned tabs as Saved.
    /// Zen's own `zen-sessions` file is one window: its tabs and spaces at the top.
    static func spaces(session top: [String: Any], name base: String, profile: String?) -> [FlowModel.Space] {
        let windows = top["windows"] as? [[String: Any]] ?? (top["tabs"] == nil ? [] : [top])
        var out: [FlowModel.Space] = []
        var zen: [String: Int] = [:]
        for window in windows where window["isPrivate"] as? Bool != true {
            var groups: [String: FlowModel.Group] = [:]
            for raw in (window["groups"] as? [[String: Any]] ?? []) + (window["folders"] as? [[String: Any]] ?? []) {
                guard let id = raw["id"] as? String, groups[id] == nil else { continue }
                let label = raw["name"] as? String ?? ""
                groups[id] = FlowModel.Group(name: label.isEmpty ? "Tab Group" : label, hue: hue(raw["color"] as? String),
                                             collapsed: raw["collapsed"] as? Bool ?? false)
            }
            let zenSpaces = window["spaces"] as? [[String: Any]] ?? []
            var home = out.count
            if zenSpaces.isEmpty {
                let number = out.count + 1
                out.append(FlowModel.Space(name: number == 1 ? base : "\(base) \(number)", profile: profile))
            } else {
                for space in zenSpaces {
                    guard let uuid = space["uuid"] as? String, zen[uuid] == nil else { continue }
                    let label = space["name"] as? String ?? ""
                    zen[uuid] = out.count
                    out.append(FlowModel.Space(name: label.isEmpty ? base : label, icon: space["icon"] as? String, profile: profile))
                }
                home = (window["activeZenSpace"] as? String).flatMap { zen[$0] }
                    ?? (zenSpaces.first?["uuid"] as? String).flatMap { zen[$0] } ?? home
                guard out.indices.contains(home) else { continue }
            }
            let selected = (window["selected"] as? Int).map { $0 - 1 }
            for (index, raw) in (window["tabs"] as? [[String: Any]] ?? []).enumerated() {
                guard raw["zenIsGlance"] as? Bool != true, let page = page(raw) else { continue }
                let target = (raw["zenWorkspace"] as? String).flatMap { zen[$0] } ?? home
                let pinned = raw["pinned"] as? Bool ?? false
                var tab = FlowModel.Tab(url: page.url, title: page.title)
                if zenSpaces.isEmpty {
                    tab.pinned = pinned
                } else {
                    let essential = raw["zenEssential"] as? Bool ?? false
                    tab.pinned = essential
                    tab.saved = pinned && !essential
                }
                tab.seen = (raw["lastAccessed"] as? Double).map { $0 / 1000 }
                tab.active = index == selected
                if let id = raw["groupId"] as? String, let group = groups[id] {
                    tab.group = group.id
                    if !out[target].groups.contains(where: { $0.id == group.id }) { out[target].groups.append(group) }
                }
                out[target].tabs.append(tab)
            }
        }
        return out
    }

    /// The page a session tab shows: its current history entry (`index` is
    /// 1-based), or what was typed into a tab that never loaded. Web pages only.
    static func page(_ tab: [String: Any]) -> (url: URL, title: String)? {
        let entries = tab["entries"] as? [[String: Any]] ?? []
        let index = (tab["index"] as? Int ?? entries.count) - 1
        let entry = entries.indices.contains(index) ? entries[index] : entries.last ?? [:]
        let text = entry["url"] as? String ?? tab["userTypedValue"] as? String ?? ""
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        let title = entry["title"] as? String ?? ""
        return (url, title.isEmpty ? url.host ?? text : title)
    }

    /// Firefox's tab group colours on Copper's hue wheel; grey has none.
    static func hue(_ color: String?) -> Double? {
        ["red": 0.0, "orange": 0.08, "yellow": 0.15, "green": 0.35, "cyan": 0.5, "blue": 0.6, "purple": 0.75, "pink": 0.9][color ?? ""]
    }

    // MARK: - places.sqlite

    private static func placesFiles(root: URL) -> [URL] {
        profiles(at: root).map { folder($0.path, in: root).appendingPathComponent("places.sqlite") }
    }

    /// Bookmarks of every profile: the toolbar at the top level, then the
    /// Bookmarks Menu, Other Bookmarks and Mobile as folders (Chrome's shape).
    static func bookmarks(root: URL) -> FlowBookmarks.Read {
        var top: [Bookmark] = []
        var menu: [Bookmark] = []
        var other: [Bookmark] = []
        var mobile: [Bookmark] = []
        var failed: [URL] = []
        for file in placesFiles(root: root) {
            guard let tree = try? bookmarkTree(file) else { failed.append(file); continue }
            FlowBookmarks.merge(tree["toolbar_____"] ?? [], into: &top)
            FlowBookmarks.merge(tree["menu________"] ?? [], into: &menu)
            FlowBookmarks.merge(tree["unfiled_____"] ?? [], into: &other)
            FlowBookmarks.merge(tree["mobile______"] ?? [], into: &mobile)
        }
        if !menu.isEmpty { top.append(.folder("Bookmarks Menu", menu)) }
        if !other.isEmpty { top.append(.folder("Other", other)) }
        if !mobile.isEmpty { top.append(.folder("Mobile", mobile)) }
        return FlowBookmarks.Read(nodes: top, failedFiles: failed)
    }

    /// The four roots' trees by their fixed guids.
    static func bookmarkTree(_ file: URL) throws -> [String: [Bookmark]] {
        struct Row { var id: Int64; var folder: Bool; var title: String; var url: String? }
        var children: [Int64: [Row]] = [:]
        var roots: [String: Int64] = [:]
        try withCopy(file) { db in
            try each(db, """
            SELECT b.id, b.type, b.parent, b.title, p.url, b.guid FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """) { row in
                let id = sqlite3_column_int64(row, 0)
                if let guid = text(row, 5) { roots[guid] = id }
                let type = sqlite3_column_int(row, 1)
                guard type == 1 || type == 2 else { return } // 3 = a separator
                children[sqlite3_column_int64(row, 2), default: []]
                    .append(Row(id: id, folder: type == 2, title: text(row, 3) ?? "", url: text(row, 4)))
            }
        }
        var seen = Set<Int64>()
        func build(_ parent: Int64) -> [Bookmark] {
            guard seen.insert(parent).inserted else { return [] }
            return (children[parent] ?? []).compactMap { row in
                if row.folder { return Bookmark.folder(row.title.isEmpty ? "Folder" : row.title, build(row.id)) }
                guard let address = row.url, let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else { return nil }
                return Bookmark.site(row.title, url)
            }
        }
        var out: [String: [Bookmark]] = [:]
        for guid in ["toolbar_____", "menu________", "unfiled_____", "mobile______"] {
            if let id = roots[guid] { out[guid] = build(id) }
        }
        return out
    }

    private static let visited = "hidden = 0 AND visit_count > 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')"

    /// Every visible web page with a visit, newest first.
    static func places(root: URL, limit: Int = Int.max) -> [Chromium.Place] {
        var out: [Chromium.Place] = []
        for file in placesFiles(root: root) {
            try? withCopy(file) { db in
                try each(db, "SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE \(visited) ORDER BY last_visit_date DESC LIMIT \(limit)") { row in
                    guard let address = text(row, 0), let url = URL(string: address) else { return }
                    let micros = sqlite3_column_int64(row, 3) // microseconds since 1970
                    out.append(Chromium.Place(url: url, title: self.text(row, 1) ?? "", count: max(1, Int(sqlite3_column_int(row, 2))),
                                              last: micros > 0 ? Date(timeIntervalSince1970: Double(micros) / 1_000_000) : Date()))
                }
            }
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    static func placeCount(root: URL) -> Int {
        placesFiles(root: root).reduce(0) { total, file in
            var count = 0
            try? withCopy(file) { db in try each(db, "SELECT COUNT(*) FROM moz_places WHERE \(visited)") { count = Int(sqlite3_column_int64($0, 0)) } }
            return total + count
        }
    }

    // MARK: - cookies.sqlite

    /// Every profile's unexpired cookies, each marked with its profile, least
    /// recently used first: set in this order, the newest copy of a cookie two
    /// profiles share is the one a jar keeps. Only the plain jar: container
    /// and partitioned cookies (`originAttributes`) stay.
    static func cookies(root: URL) -> [FlowModel.Cookie] {
        let now = Date()
        var out: [(cookie: FlowModel.Cookie, used: Int64)] = []
        for profile in profiles(at: root) {
            let file = folder(profile.path, in: root).appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try? withCopy(file) { db in
                try each(db, """
                SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite, lastAccessed
                FROM moz_cookies WHERE originAttributes = ''
                """) { row in
                    guard let host = text(row, 0), !host.isEmpty, let name = text(row, 1) else { return }
                    let expiry = sqlite3_column_int64(row, 4)
                    // Seconds until 2025, milliseconds since; no cookie lives to the year 5138.
                    let expires = Date(timeIntervalSince1970: expiry > 100_000_000_000 ? Double(expiry) / 1000 : Double(expiry))
                    guard expires > now else { return }
                    let sameSite: String? = ["None", "Lax", "Strict"].indices.contains(Int(sqlite3_column_int(row, 7)))
                        ? ["None", "Lax", "Strict"][Int(sqlite3_column_int(row, 7))] : nil
                    let cookie = FlowModel.Cookie(domain: host, name: name, value: text(row, 2) ?? "", path: text(row, 3) ?? "/",
                                                  expires: expires, secure: sqlite3_column_int(row, 5) != 0,
                                                  httpOnly: sqlite3_column_int(row, 6) != 0, sameSite: sameSite, profile: profile.path)
                    out.append((cookie, sqlite3_column_int64(row, 8)))
                }
            }
        }
        return out.sorted { $0.used < $1.used }.map { $0.cookie }
    }

    /// One of each cookie (the last, so the newest), for the shared jar.
    static func oneEach(_ cookies: [FlowModel.Cookie]) -> [FlowModel.Cookie] {
        var last: [String: Int] = [:]
        for (index, cookie) in cookies.enumerated() { last["\(cookie.domain)\t\(cookie.name)\t\(cookie.path)"] = index }
        return cookies.enumerated().filter { last["\($0.element.domain)\t\($0.element.name)\t\($0.element.path)"] == $0.offset }.map { $0.element }
    }

    // MARK: - logins.json + key4.db

    static func loginCount(root: URL) -> Int {
        profiles(at: root).reduce(0) { total, profile in
            let file = folder(profile.path, in: root).appendingPathComponent("logins.json")
            guard let data = try? Data(contentsOf: file),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return total }
            return total + (top["logins"] as? [[String: Any]] ?? []).count
        }
    }

    /// Every profile's saved logins, decrypted, and the sites it was told
    /// never to save for. A profile behind a Primary Password is skipped;
    /// when every profile with logins is, that is the trouble.
    // shortcut: reads logins.json only; Firefox's newer Rust store (logins.db, secFields)
    // is a mirror as of Firefox 160. Read it once logins.json stops being written.
    static func logins(root: URL) throws -> Chromium.Found {
        var logins: [Login] = []
        var never: [String] = []
        var seen = Set<String>()
        var locked = false
        var read = false
        for profile in profiles(at: root) {
            let dir = folder(profile.path, in: root)
            never += neverSave(dir)
            let file = dir.appendingPathComponent("logins.json")
            guard FileManager.default.fileExists(atPath: file.path) else { read = true; continue } // none saved
            guard let data = try? Data(contentsOf: file),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let rows = top["logins"] as? [[String: Any]] ?? []
            guard !rows.isEmpty else { read = true; continue }
            let keys: [Data: [UInt8]]
            do {
                keys = try self.keys(in: dir.appendingPathComponent("key4.db"))
            } catch Trouble.primaryPassword {
                locked = true
                continue
            } catch {
                continue
            }
            read = true
            for row in rows {
                guard let origin = row["hostname"] as? String, case let host = Vault.host(of: origin), !host.isEmpty,
                      let user = (row["encryptedUsername"] as? String).flatMap({ decrypt($0, keys: keys) }),
                      let password = (row["encryptedPassword"] as? String).flatMap({ decrypt($0, keys: keys) }), !password.isEmpty
                else { continue }
                let used = (row["timeLastUsed"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                let login = Login(host: host, user: user, password: password, used: used)
                if seen.insert(login.id).inserted { logins.append(login) }
            }
        }
        guard read else { throw locked ? Trouble.primaryPassword : Trouble.unreadable }
        return Chromium.Found(logins: logins, never: never)
    }

    /// Sites the browser was told never to save a password for.
    static func neverSave(_ profile: URL) -> [String] {
        let file = profile.appendingPathComponent("permissions.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var out: [String] = []
        try? withCopy(file) { db in
            try each(db, "SELECT origin FROM moz_perms WHERE type = 'login-saving' AND permission = 2") { row in
                if let origin = text(row, 0) { out.append(Vault.host(of: origin)) }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// key4.db's keys by their id (CKA_ID), unlocked with `password` — empty
    /// for a Firefox without a Primary Password. NSS checks the password by
    /// decrypting "password-check" first.
    static func keys(in key4: URL, password: String = "") throws -> [Data: [UInt8]] {
        guard FileManager.default.fileExists(atPath: key4.path) else { throw Trouble.unreadable }
        return try withCopy(key4) { (db: OpaquePointer) throws -> [Data: [UInt8]] in
            var salt = Data()
            var check = Data()
            try each(db, "SELECT item1, item2 FROM metaData WHERE id = 'password'") { row in
                salt = blob(row, 0)
                check = blob(row, 1)
            }
            guard !check.isEmpty else { throw Trouble.unreadable }
            guard let clear = try? pbe(check, password: password, salt: salt), clear.starts(with: Array("password-check".utf8))
            else { throw Trouble.primaryPassword }
            var out: [Data: [UInt8]] = [:]
            try each(db, "SELECT a11, a102 FROM nssPrivate") { row in
                if let key = try? pbe(blob(row, 0), password: password, salt: salt), key.count >= 24 { out[blob(row, 1)] = key }
            }
            guard !out.isEmpty else { throw Trouble.unreadable }
            return out
        }
    }

    /// One `logins.json` field: SEQUENCE { key id, SEQUENCE { cipher, iv }, ciphertext }.
    static func decrypt(_ base64: String, keys: [Data: [UInt8]]) -> String? {
        guard let data = Data(base64Encoded: base64), let top = DER.parse(data), top.children.count == 3,
              let algorithm = top.children[1].children.first?.oid,
              let iv = top.children[1].children.dropFirst().first?.bytes,
              let key = keys[Data(top.children[0].bytes)] ?? keys.values.first else { return nil }
        let cipher = top.children[2].bytes
        let clear: [UInt8]?
        switch algorithm {
        case "2.16.840.1.101.3.4.1.42" where key.count >= 32: // AES-256-CBC
            clear = crypt(CCAlgorithm(kCCAlgorithmAES), key: Array(key.prefix(32)), iv: iv, cipher)
        case "1.2.840.113549.3.7": // DES-EDE3-CBC
            clear = crypt(CCAlgorithm(kCCAlgorithm3DES), key: Array(key.prefix(24)), iv: iv, cipher)
        default:
            clear = nil
        }
        return clear.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// NSS's password-based encryption: SEQUENCE { SEQUENCE { algorithm, params }, ciphertext }.
    static func pbe(_ der: Data, password: String, salt global: Data) throws -> [UInt8] {
        guard let top = DER.parse(der), top.children.count == 2, top.children[0].children.count == 2,
              let algorithm = top.children[0].children[0].oid else { throw Trouble.unreadable }
        let params = top.children[0].children[1]
        let cipher = top.children[1].bytes
        let pass = Array(password.utf8)
        let hashed = Array(Insecure.SHA1.hash(data: Array(global) + pass))
        switch algorithm {
        case "1.2.840.113549.1.5.13": // PBES2: PBKDF2 then AES-256-CBC
            guard params.children.count == 2, params.children[0].children.count == 2,
                  params.children[1].children.count == 2 else { throw Trouble.unreadable }
            let kdf = params.children[0].children[1].children
            guard kdf.count >= 2, let rounds = kdf[1].int else { throw Trouble.unreadable }
            let length = kdf.count > 2 ? kdf[2].int ?? 32 : 32
            // The PRF: hmacWithSHA256 in every key4.db; PKCS#5's default (SHA-1) when absent.
            let sha256 = kdf.last.flatMap { $0.tag == 0x30 ? $0.children.first?.oid : nil } == "1.2.840.113549.2.9"
            var key = [UInt8](repeating: 0, count: length)
            let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), hashed.map { CChar(bitPattern: $0) }, hashed.count,
                                              kdf[0].bytes, kdf[0].bytes.count,
                                              CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1),
                                              UInt32(rounds), &key, key.count)
            guard status == kCCSuccess else { throw Trouble.unreadable }
            var iv = params.children[1].children[1].bytes
            // NSS stores a 14-byte IV and uses it with its DER header (04 0E) in front.
            if iv.count == 14 { iv = [0x04, 0x0E] + iv }
            guard let clear = crypt(CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, cipher) else { throw Trouble.primaryPassword }
            return clear
        case "1.2.840.113549.1.12.5.1.3": // pbeWithSha1AndTripleDES-CBC (key4.db before 2019)
            guard let entry = params.children.first?.bytes else { throw Trouble.unreadable }
            let padded = entry + [UInt8](repeating: 0, count: max(0, 20 - entry.count))
            let chp = Array(Insecure.SHA1.hash(data: hashed + entry))
            func hmac(_ data: [UInt8]) -> [UInt8] { Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: chp))) }
            let k = hmac(padded + entry) + hmac(hmac(padded) + entry)
            guard let clear = crypt(CCAlgorithm(kCCAlgorithm3DES), key: Array(k.prefix(24)), iv: Array(k.suffix(8)), cipher)
            else { throw Trouble.primaryPassword }
            return clear
        default:
            throw Trouble.unreadable
        }
    }

    /// CBC decryption with PKCS#7 padding; nil when the padding is wrong
    /// (the wrong key, or the wrong password).
    static func crypt(_ algorithm: CCAlgorithm, key: [UInt8], iv: [UInt8], _ cipher: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: cipher.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, cipher, cipher.count, &out, out.count, &moved)
        return status == kCCSuccess ? Array(out.prefix(moved)) : nil
    }

    /// Just enough DER for NSS: tag, contents, and the children of a
    /// constructed value (SEQUENCE).
    struct DER {
        var tag: UInt8
        var bytes: [UInt8]
        var children: [DER] = []

        static func parse(_ data: Data) -> DER? {
            let bytes = [UInt8](data)
            var at = 0
            return node(bytes, &at)
        }

        static func node(_ b: [UInt8], _ at: inout Int) -> DER? {
            guard at + 2 <= b.count else { return nil }
            let tag = b[at]
            var length = Int(b[at + 1])
            at += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), at + count <= b.count else { return nil }
                length = b[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
                at += count
            }
            guard at + length <= b.count else { return nil }
            var out = DER(tag: tag, bytes: Array(b[at..<at + length]))
            at += length
            if tag & 0x20 != 0 {
                var inner = 0
                while inner < out.bytes.count {
                    guard let child = node(out.bytes, &inner) else { return nil }
                    out.children.append(child)
                }
            }
            return out
        }

        var int: Int? {
            guard tag == 0x02, bytes.count <= 8 else { return nil }
            return bytes.reduce(0) { $0 << 8 | Int($1) }
        }

        var oid: String? {
            guard tag == 0x06, let first = bytes.first else { return nil }
            var parts = [Int(first) / 40, Int(first) % 40]
            var value = 0
            for byte in bytes.dropFirst() {
                value = value << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { parts.append(value); value = 0 }
            }
            return parts.map(String.init).joined(separator: ".")
        }
    }

    // MARK: - add-ons

    /// The add-ons a person installed (not Mozilla's built-in ones), by name.
    static func addons(root: URL) -> [String] {
        var out: [String] = []
        for profile in profiles(at: root) {
            let file = folder(profile.path, in: root).appendingPathComponent("extensions.json")
            guard let data = try? Data(contentsOf: file),
                  let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for addon in top["addons"] as? [[String: Any]] ?? [] {
                guard addon["type"] as? String == "extension", addon["location"] as? String == "app-profile",
                      let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String, !out.contains(name) else { continue }
                out.append(name)
            }
        }
        return out
    }

    // MARK: - SQLite

    /// A copy of a SQLite file and its write-ahead log, opened read-write so
    /// the log is applied: while Firefox runs, its newest rows are there. The
    /// browser's own file is only ever copied.
    static func withCopy<T>(_ file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("flow-gecko-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try fm.copyItem(at: file, to: copy)
        if fm.fileExists(atPath: file.path + "-wal") {
            try? fm.copyItem(atPath: file.path + "-wal", toPath: copy.path + "-wal")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw FlowModel.Trouble.unreadable(file.path)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func each(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FlowModel.Trouble.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}
