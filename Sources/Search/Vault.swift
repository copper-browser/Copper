import Foundation
import Security
import LocalAuthentication

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are Copper's
// — in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Fork (origin-save): the scheme, host and port it was saved from
    /// (`http://example.com`, `https://example.com:8443`), when the save
    /// knew them. Nil: saved before they were kept, or imported.
    var origin: String? = nil
    /// Fork (ardia profiles): the profile whose drawer it is in, or is to be
    /// saved for; nil, Shared's, which every profile sees.
    var profile: String? = nil

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let label = Store.world.map { "\(Fork.name) (\($0))" } ?? Fork.name

    /// Fork (exowatt signing): an item label of ours, Shared's or a profile's
    /// (CopperKeychain's sweep of the login keychain).
    static func isOurs(_ itemLabel: String) -> Bool { itemLabel == label || itemLabel.hasPrefix(label + " · ") }

    // MARK: - drawers (Fork: ardia profiles)
    //
    // A profile keeps its own passwords: items labelled "Copper · Work",
    // with the profile as their security domain too, so one never shares a
    // keychain identity with a Shared login of the same account. Shared's
    // drawer is what was always there — plain "Copper", no domain — and
    // every profile reads it after its own. A save in a profile changes the
    // login that profile sees (its own, else Shared's) and otherwise adds
    // one to its own drawer; Shared never reads a profile's.

    /// The label of a drawer: Shared's, or a profile's.
    private static func drawerLabel(_ drawer: String?) -> String { drawer.map { "\(label) · \($0)" } ?? label }

    /// The drawers a profile reads, its own first.
    static func drawers(_ profile: String?) -> [String?] { profile.map { [$0, nil] } ?? [nil] }

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret — not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back. So: the list first, without
    /// secrets, then each secret on its own.

    /// What is kept for a host, exactly. See `logins(matching:)` for the
    /// version that also looks across a site's subdomains.
    static func logins(for host: String, in profile: String? = Profiles.ambient) -> [Login] {
        rows(where: [kSecAttrServer as String: host], profile: profile).compactMap(login(from:))
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from — accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    static func logins(matching host: String, in profile: String? = Profiles.ambient) -> [Login] {
        let domain = registrable(host)
        let exact = logins(for: host, in: profile)
        let wider = rows(where: [:], profile: profile)
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && registrable($0) == domain } ?? false }
            .compactMap(login(from:))
        return (exact + wider).sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Everything this app holds, for the list. Read on demand and never kept
    /// in a property.
    static func all(in profile: String? = Profiles.ambient) -> [Login] {
        rows(where: [:], profile: profile).compactMap(login(from:))
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given:
    /// a profile's and then Shared's, an account in both once, its own
    /// (Fork: ardia profiles). Each row says its drawer (`drawerKey`).
    private static func rows(where extra: [String: Any], profile: String?) -> [[String: Any]] {
        var seen = Set<String>()
        return drawers(profile).flatMap { drawer in
            rows(where: extra, drawer: drawer).map { row in
                var row = row
                row[drawerKey] = drawer
                return row
            }
        }.filter { row in
            seen.insert("\(row[kSecAttrServer as String] ?? "")\u{1}\(row[kSecAttrAccount as String] ?? "")").inserted
        }
    }

    /// Fork (ardia profiles): the key a row's drawer rides under, ours.
    private static let drawerKey = "copper.drawer"

    /// One drawer's items.
    private static func rows(where extra: [String: Any], drawer: String?) -> [[String: Any]] {
        if ProbeKeychain.active { return ProbeKeychain.rows(server: extra[kSecAttrServer as String] as? String, drawer: drawer) } // Fork (probe-keychain)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: drawerLabel(drawer),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = CopperKeychain.copyMatching(query, &out) // Fork (exowatt signing)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound { NSLog("Vault: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    /// One item's secret, by the two things that name it. This is the one
    /// call the keychain guards with its dialog: an item saved by an earlier
    /// build of this app (a different ad-hoc signature) asks once, per item,
    /// and "Always Allow" is remembered. So it is made only for the one
    /// account you actually picked — never to draw a list.
    /// Fork (ardia profiles): from the profile's own drawer first, then Shared's.
    static func secret(host: String, user: String, in profile: String? = Profiles.ambient) -> String? {
        for drawer in drawers(profile) {
            if let found = secret(host: host, user: user, drawer: drawer) { return found }
        }
        return nil
    }

    private static func secret(host: String, user: String, drawer: String?) -> String? {
        if ProbeKeychain.active { return ProbeKeychain.secret(host: host, user: user, drawer: drawer) } // Fork (probe-keychain)
        var out: CFTypeRef?
        let status = CopperKeychain.copyMatching([ // Fork (exowatt signing)
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: drawerLabel(drawer),
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ], &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Vault: keychain read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A list entry: what names the account, without its secret. The
    /// password is an empty string until `resolve` fills it in — reading
    /// every secret just to show a list is what made the keychain ask for
    /// each one in turn, on every click into a sign-in box.
    private static func login(from row: [String: Any]) -> Login? {
        guard let host = row[kSecAttrServer as String] as? String,
              let user = row[kSecAttrAccount as String] as? String
        else { return nil }
        // The keychain has no "last used" of its own; it rides in the comment.
        let used = (row[kSecAttrComment as String] as? String)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return Login(host: host, user: user, password: "", used: used, origin: origin(of: row, host: host), // Fork (origin-save)
                     profile: row[drawerKey] as? String) // Fork (ardia profiles)
    }

    /// Fork (origin-save): the scheme and port an item was saved with, as an
    /// origin. Nil when it has no http(s) protocol (saved before they were kept).
    static func origin(of row: [String: Any], host: String) -> String? {
        let kept = row[kSecAttrProtocol as String] as? String
        let scheme: String
        if kept == kSecAttrProtocolHTTP as String { scheme = "http" } else if kept == kSecAttrProtocolHTTPS as String { scheme = "https" } else { return nil }
        return Credentials.origin(scheme: scheme, host: host, port: (row[kSecAttrPort as String] as? NSNumber)?.intValue)
    }

    /// Fork (origin-save): the keychain attributes for where a login was saved from.
    static func place(_ origin: String?) -> [String: Any] {
        guard let origin, let url = URL(string: origin) else { return [:] }
        switch url.scheme {
        case "http": return [kSecAttrProtocol as String: kSecAttrProtocolHTTP, kSecAttrPort as String: url.port ?? 80]
        case "https": return [kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrPort as String: url.port ?? 443]
        default: return [:]
        }
    }

    /// The same account with its password read in. Nil when the keychain
    /// refused (Deny in its dialog) or the item is gone.
    static func resolve(_ login: Login) -> Login? {
        if !login.password.isEmpty { return login }
        guard let password = secret(host: login.host, user: login.user, drawer: login.profile) else { return nil } // Fork (ardia profiles): its own drawer's
        var full = login
        full.password = password
        return full
    }

    // MARK: - writing

    /// Fork (ardia profiles): into `profile` — the login it already sees
    /// (its own, else Shared's) changes; a new one goes in its own drawer.
    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, origin: String? = nil, in profile: String? = Profiles.ambient) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }
        let drawer: String? = profile.flatMap { profile -> String? in
            let seen = rows(where: [kSecAttrServer as String: host], profile: profile)
                .first { $0[kSecAttrAccount as String] as? String == user }
            guard let seen else { return profile }
            return seen[drawerKey] as? String
        }
        if ProbeKeychain.active { return ProbeKeychain.save(host: host, user: user, password: password, used: used, origin: origin, drawer: drawer) } // Fork (probe-keychain)

        var identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
        ]
        // A profile's drawer by its label. Shared's as it always was, by the
        // account alone — unless a profile keeps a login for the same
        // account, which a Shared save mustn't reach.
        if drawer != nil || twinned(host: host, user: user) { identity[kSecAttrLabel as String] = drawerLabel(drawer) }
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: drawerLabel(drawer),
        ]
        if let drawer { fields[kSecAttrSecurityDomain as String] = drawer }
        if let used { fields[kSecAttrComment as String] = String(used.timeIntervalSince1970) }
        fields.merge(place(origin)) { _, new in new } // Fork (origin-save): the latest save's scheme and port

        return CopperKeychain.save(identity, fields) // Fork (exowatt signing): update, else add
    }

    /// It was just used to sign in. Lists put it first from now on. Only the
    /// comment moves; the secret is neither read nor rewritten.
    static func touch(_ login: Login) {
        if ProbeKeychain.active { return ProbeKeychain.touch(host: login.host, user: login.user, drawer: login.profile) } // Fork (probe-keychain)
        CopperKeychain.update([ // Fork (exowatt signing)
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: login.host,
            kSecAttrAccount as String: login.user,
            kSecAttrLabel as String: drawerLabel(login.profile), // Fork (ardia profiles): its own drawer's
        ], [
            kSecAttrComment as String: String(Date().timeIntervalSince1970),
        ])
    }

    /// Fork (ardia profiles): from one drawer, the login's own.
    static func forget(host: String, user: String, in drawer: String? = nil) {
        KeychainCodes.forget(host: host, user: user) // Fork (keychain-codes): the account's two-step key goes with it
        if ProbeKeychain.active { return ProbeKeychain.forget(host: host, user: user, drawer: drawer) } // Fork (probe-keychain)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
        ]
        if drawer != nil || twinned(host: host, user: user) { query[kSecAttrLabel as String] = drawerLabel(drawer) }
        CopperKeychain.delete(query) // Fork (exowatt signing)
    }

    /// Fork (ardia profiles): a profile keeps a login for this account too.
    private static func twinned(host: String, user: String) -> Bool {
        var out: CFTypeRef?
        let status = CopperKeychain.copyMatching([ // Fork (exowatt signing)
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ], &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return false }
        return rows.contains { ($0[kSecAttrLabel as String] as? String)?.hasPrefix(label + " · ") == true }
    }

    // MARK: - sites that asked not to be asked

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        if ProbeKeychain.active { return done(ProbeKeychain.proves) } // Fork (probe-keychain): no Touch ID sheet in a probe
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all — a Mac with no password set. Then there is
            // nothing to prove.
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk. The handful of two-part endings that matter here are
    /// listed; a full public suffix list would be a library for a corner.
    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let seconds: Set<String> = ["co", "com", "org", "net", "gov", "gouv", "ac", "edu", "asso", "or", "ne"]
        if seconds.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it: name, url,
    /// username, password, note. Read once, put in the keychain, and the file
    /// is yours to delete — this never keeps a copy of it.
    /// Fork (flow-files): `keep` stands in for the keychain — Move in's
    /// test runs keep what a file brings in memory instead.
    static func take(csv text: String, keep: ((String, String, String) -> Bool)? = nil) -> (kept: Int, skipped: Int) {
        var rows = parse(csv: text)
        guard !rows.isEmpty else { return (0, 0) }

        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }

        var kept = 0, skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            // Fork (origin-save): a row's own scheme and port, when its address has them.
            let origin = URL(string: row[urlAt].trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : Credentials.origin(of: $0) }
            let saved = keep.map { $0(host, row[userAt], password) } ?? save(host: host, user: row[userAt], password: password, origin: origin, in: nil) // Fork (ardia profiles): imports land in Shared
            saved ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Quoted fields, doubled quotes inside them, and newlines inside those —
    /// all three turn up in a real export.
    private static func parse(csv text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
