import Foundation

// Copper addons (docs/addons.md): a slot of the window — v1 has one, the
// agent sidebar ⌘E opens — can show a small web bundle a Copper Cloud admin
// assigned to this person instead of its built-in view. The bundle is HTML,
// JS and CSS with a `manifest.json`, served by the cloud as one JSON document
// whose SHA-256 is its identity; it runs in a web view of its own and talks
// to Copper through `window.copper` (Resources/bridge.js, the same bytes on
// every platform).
//
// This file is the vocabulary every other piece shares — slots, the
// manifest and its rules, host rules — and nothing in it touches a window,
// the network or the disk, so the rules can be tested on their own
// (Tests/SearchTests/AddonsTests.swift). The rules are the contract's, word
// for word, and the same ones Copper Cloud and copper-linux's core apply: an
// addon one of them accepts, the others accept too.

/// A named region of the window an addon can take over. The list is closed
/// and compiled in: an addon for a slot this Copper doesn't know is skipped,
/// and its slot keeps its own view.
enum AddonSlot: String, CaseIterable, Codable, Identifiable {
    case agentSidebar = "agent-sidebar"

    var id: String { rawValue }

    /// As Settings says it.
    var name: String {
        switch self {
        case .agentSidebar: return "Agent sidebar"
        }
    }

    /// `^[a-z][a-z0-9-]{1,40}$` — the shape any slot id has, known or not.
    static func wellFormed(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (2...41).contains(bytes.count), let first = bytes.first, (0x61...0x7A).contains(first) else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}

/// What an addon may ask Copper for (`permissions.capabilities`).
enum AddonCapability: String, CaseIterable, Codable {
    case identity, storage, fetch, oauth
    case openURL = "open-url"
    case page, agent
}

/// Why something about an addon was refused: a short code, and the reason
/// in words for a log line or Settings.
struct AddonProblem: Error, Equatable, LocalizedError {
    var code: String
    var message: String
    var errorDescription: String? { message }
}

enum Addons {
    /// The bridge version this Copper speaks. An addon that needs a newer
    /// one is skipped, as an addon for an unknown slot is.
    static let bridge = 1
    /// What `platforms` calls this Copper.
    static let platform = "mac"
    static let schema = "copper-addon/1"
    static let bundleFormat = "copper-addon-bundle/1"
    static let settingTypes = ["string", "number", "boolean", "object", "array"]
    static let maxNameLength = 60
    static let maxDescriptionLength = 280
    static let maxHosts = 32

    /// `^[a-z0-9][a-z0-9.-]{2,63}$`, no `..`, and a vendor prefix (a dot).
    static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (3...64).contains(bytes.count), let first = bytes.first,
              (0x61...0x7A).contains(first) || (0x30...0x39).contains(first) else { return false }
        let allowed = bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D }
        return allowed && !id.contains("..") && id.contains(".")
    }

    /// `MAJOR.MINOR.PATCH`, numbers without leading zeros, and an optional
    /// `-pre` of `[0-9A-Za-z.-]` with no empty dotted part.
    static func validVersion(_ version: String) -> Bool {
        let core: Substring
        var pre: Substring?
        if let dash = version.firstIndex(of: "-") {
            core = version[..<dash]
            pre = version[version.index(after: dash)...]
        } else {
            core = Substring(version)
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 9 && part.allSatisfy { $0.isASCII && $0.isNumber }
                && (part.count == 1 || !part.hasPrefix("0"))
        }
        guard numbers else { return false }
        guard let pre else { return true }
        return !pre.isEmpty
            && pre.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
            && pre.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// The bundle path rule: `^[A-Za-z0-9._@-]+(/[A-Za-z0-9._@-]+)*$`, no
    /// `.` or `..` segment, at most 200 characters. The same rule guards the
    /// `copper-addon://` scheme, so no request can climb out of a bundle.
    static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 200 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.utf8.allSatisfy { byte in
                    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                        || byte == 0x2E || byte == 0x5F || byte == 0x40 || byte == 0x2D
                }
        }
    }

    /// `platforms` absent or empty means every platform.
    static func runsHere(_ platforms: [String]?) -> Bool {
        guard let platforms, !platforms.isEmpty else { return true }
        return platforms.contains(platform)
    }

    /// Lowercase hex SHA-256 — a served bundle's identity, and each file's.
    static func sha256(_ data: Data) -> String {
        AddonDigest.hex(data)
    }
}

// MARK: - the manifest

/// `manifest.json`, schema `copper-addon/1`. Read leniently — a wrong type
/// is read as absent and then refused by `problems()` — and every key is
/// kept as it came (`raw`), so a key a later Copper adds survives a trip
/// through this one.
struct AddonManifest: Equatable {
    var schema: String
    var id: String
    var name: String
    var version: String
    var slot: String
    var entry: String
    var description: String?
    var author: String?
    /// Nil when absent or not a whole number; refused by `problems()`.
    var bridge: Int?
    var hosts: [String]
    var capabilities: [String]
    /// Key → `{type, default?, title?, description?}`, as written.
    var settings: [String: [String: Any]]
    var platforms: [String]?
    /// The whole object as it was read.
    var raw: [String: Any]

    static func == (a: AddonManifest, b: AddonManifest) -> Bool {
        NSDictionary(dictionary: a.raw).isEqual(to: b.raw)
    }

    /// The object, or why it isn't one.
    static func parse(_ data: Data) throws -> AddonManifest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AddonProblem(code: "json", message: "manifest.json is not a JSON object")
        }
        return AddonManifest(object)
    }

    init(_ object: [String: Any]) {
        func text(_ key: String) -> String { object[key] as? String ?? "" }
        func strings(_ any: Any?) -> [String] { (any as? [Any])?.compactMap { $0 as? String } ?? [] }
        schema = text("schema")
        id = text("id")
        name = text("name")
        version = text("version")
        slot = text("slot")
        entry = text("entry")
        description = object["description"] as? String
        author = object["author"] as? String
        bridge = AddonManifest.wholeNumber(object["bridge"])
        let permissions = object["permissions"] as? [String: Any] ?? [:]
        hosts = strings(permissions["hosts"])
        capabilities = strings(permissions["capabilities"])
        var specs: [String: [String: Any]] = [:]
        for (key, value) in object["settings"] as? [String: Any] ?? [:] {
            specs[key] = value as? [String: Any] ?? [:]
        }
        settings = specs
        platforms = object["platforms"].map(strings)
        raw = object
    }

    /// A JSON number that is a whole number and not a boolean.
    static func wholeNumber(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.rounded() == value, abs(value) < 1e9 else { return nil }
        return Int(value)
    }

    var knownSlot: AddonSlot? { AddonSlot(rawValue: slot) }

    /// The capabilities this manifest asks for that this Copper knows.
    var granted: [AddonCapability] { capabilities.compactMap(AddonCapability.init(rawValue:)) }

    var hostRules: [AddonHostRule] { hosts.compactMap { try? AddonHostRule.parse($0) } }

    /// Each setting's `default`, where it has one — the settings an addon
    /// gets when nothing resolved them (a development folder).
    var defaultSettings: [String: Any] {
        var out: [String: Any] = [:]
        for (key, spec) in settings {
            if let value = spec["default"] { out[key] = value }
        }
        return out
    }

    /// Every rule this manifest breaks, in field order; empty when valid.
    /// Whether `entry` exists is the bundle's to check (it has the files).
    func problems() -> [AddonProblem] {
        var out: [AddonProblem] = []
        func fail(_ code: String, _ message: String) { out.append(AddonProblem(code: code, message: message)) }
        if schema != Addons.schema { fail("schema", "schema must be \"\(Addons.schema)\", not \"\(schema)\"") }
        if !Addons.validID(id) {
            fail("id", "id \"\(id)\" must be 3–64 of a-z 0-9 . - with a vendor prefix (a dot), no \"..\"")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > Addons.maxNameLength {
            fail("name", "name must be 1–\(Addons.maxNameLength) characters")
        }
        if !Addons.validVersion(version) { fail("version", "version \"\(version)\" must be MAJOR.MINOR.PATCH (optional -pre)") }
        if let description, description.count > Addons.maxDescriptionLength {
            fail("description", "description must be at most \(Addons.maxDescriptionLength) characters")
        }
        if knownSlot == nil { fail("slot", "unknown slot \"\(slot)\"") }
        if !Addons.validPath(entry) || !entry.hasSuffix(".html") {
            fail("entry", "entry \"\(entry)\" must be a bundle path ending .html")
        }
        if (bridge ?? 0) < 1 { fail("bridge", "bridge must be an integer ≥ 1") }
        if hosts.count > Addons.maxHosts { fail("hosts", "at most \(Addons.maxHosts) hosts") }
        for host in hosts {
            do { _ = try AddonHostRule.parse(host) } catch let problem as AddonProblem {
                fail("hosts", "host \"\(host)\": \(problem.message)")
            } catch {}
        }
        for capability in capabilities where AddonCapability(rawValue: capability) == nil {
            fail("capabilities", "unknown capability \"\(capability)\"")
        }
        for key in settings.keys.sorted() {
            if key.isEmpty { fail("settings", "a setting key is empty") }
            let kind = settings[key]?["type"] as? String ?? ""
            if !Addons.settingTypes.contains(kind) {
                fail("settings", "setting \"\(key)\" has type \"\(kind)\"; use one of \(Addons.settingTypes.joined(separator: ", "))")
            }
        }
        for platform in platforms ?? [] where !["mac", "linux", "windows"].contains(platform) {
            fail("platforms", "unknown platform \"\(platform)\" (mac, linux, windows)")
        }
        return out
    }

    func validate() throws {
        if let first = problems().first { throw first }
    }
}

// MARK: - hosts

/// One `permissions.hosts` entry: `host` or `*.host`, an optional `:port`,
/// and optionally an explicit `https://` (or, for 127.0.0.1 and localhost
/// only, `http://`) in front. A plain host matches exactly that host;
/// `*.example.com` matches any subdomain but not example.com itself; no port
/// means any port.
struct AddonHostRule: Equatable {
    var wildcard: Bool
    var host: String
    var port: Int?
    var scheme: String?

    static func parse(_ text: String) throws -> AddonHostRule {
        var rest = Substring(text)
        var scheme: String?
        for prefix in ["https://", "http://"] where rest.hasPrefix(prefix) {
            scheme = String(prefix.dropLast(3))
            rest = rest.dropFirst(prefix.count)
        }
        var wildcard = false
        if rest.hasPrefix("*.") {
            wildcard = true
            rest = rest.dropFirst(2)
        }
        var host = rest
        var port: Int?
        if let colon = rest.lastIndex(of: ":") {
            let digits = rest[rest.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), (1...65535).contains(n) else {
                throw AddonProblem(code: "hosts", message: "bad port \"\(digits)\"")
            }
            port = n
            host = rest[..<colon]
        }
        let name = String(host)
        if name != name.lowercased() { throw AddonProblem(code: "hosts", message: "hosts are written in lowercase") }
        if !AddonHostRule.validHostname(name) { throw AddonProblem(code: "hosts", message: "not a hostname") }
        if wildcard && !name.contains(".") {
            throw AddonProblem(code: "hosts", message: "a wildcard needs at least two labels after \"*.\"")
        }
        if scheme == "http" && (wildcard || !AddonHostRule.isLoopback(name)) {
            throw AddonProblem(code: "hosts", message: "http:// is only for 127.0.0.1 and localhost")
        }
        return AddonHostRule(wildcard: wildcard, host: name, port: port, scheme: scheme)
    }

    /// Whether the URL's host and port fall under this rule. The scheme rule
    /// (https, or http for loopback) is `AddonHostRule.allows`'.
    func matches(_ url: URL) -> Bool {
        guard let raw = url.host?.lowercased(), !raw.isEmpty else { return false }
        let hostOK: Bool
        if wildcard {
            hostOK = raw.count > host.count + 1 && raw.hasSuffix("." + host)
        } else {
            hostOK = raw == host
        }
        let portOK = port.map { $0 == AddonHostRule.port(of: url) } ?? true
        let schemeOK = scheme.map { $0 == url.scheme?.lowercased() } ?? true
        return hostOK && portOK && schemeOK
    }

    /// Whether `copper.fetch` or `copper.oauth.authorize` may go to `url`:
    /// https, or http to 127.0.0.1 / localhost only, on a listed host.
    static func allows(_ url: URL, rules: [AddonHostRule]) -> Bool {
        let schemeOK: Bool
        switch url.scheme?.lowercased() {
        case "https": schemeOK = true
        case "http": schemeOK = isLoopback(url.host ?? "")
        default: schemeOK = false
        }
        return schemeOK && rules.contains { $0.matches(url) }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host.lowercased() == "localhost"
    }

    static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// DNS labels of `a-z0-9-` (1–63, not starting or ending with `-`,
    /// ≤ 253 in all) or a dotted IPv4 address.
    static func validHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last else { return false }
            return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
                && first != 0x2D && last != 0x2D
        }
    }
}

// MARK: - the page's security policy

enum AddonCSP {
    /// The slot page may load only its own bundle; the network goes through
    /// `copper.fetch`, which holds it to the manifest's hosts.
    static let policy = "default-src copper-addon:; script-src copper-addon:; style-src copper-addon: 'unsafe-inline'; img-src copper-addon: https: data: blob:; font-src copper-addon: data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    static var meta: String { "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" }

    /// The policy as the first element of `<head>`, so it is in force before
    /// anything the page itself lists; a page without a `<head>` gets one.
    /// Matching is case-insensitive and skips `<header>`.
    static func inject(_ html: String) -> String {
        var search = html.startIndex
        while let range = html.range(of: "<head", options: .caseInsensitive, range: search..<html.endIndex) {
            let after = range.upperBound
            let next: Character = after < html.endIndex ? html[after] : ">"
            if next == ">" || next == " " || next == "\t" || next == "\n" || next == "\r" || next == "/" {
                if let close = html.range(of: ">", range: after..<html.endIndex) {
                    return String(html[..<close.upperBound]) + meta + String(html[close.upperBound...])
                }
                break
            }
            search = after
        }
        // No <head>: one goes right after <html …>, or at the very start.
        if let open = html.range(of: "<html", options: .caseInsensitive),
           let close = html.range(of: ">", range: open.upperBound..<html.endIndex) {
            return String(html[..<close.upperBound]) + "<head>" + meta + "</head>" + String(html[close.upperBound...])
        }
        return "<head>" + meta + "</head>" + html
    }
}
