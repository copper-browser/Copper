import Foundation

// What Copper keeps about addons, and what it does with a new answer from
// the cloud (contract §6.1, §6.3). Plain data and plain functions: the
// sync (AddonSync.swift) does the asking and the downloading, this decides.
//
//     addons/
//       state.json                 what is installed, staged, turned off
//       bundles/<id>/<sha256>/…    unpacked bundles, never changed once written
//       staging/<sha256>.json      downloaded and verified, not yet installed
//       data/<id>/storage.json     copper.storage (0600)
//
// state.json has the contract's shape so a tool or another platform's
// Copper reads it the same way; the extra keys an entry carries (name,
// entry, permissions, source) are what the slot needs to run it without
// opening the manifest again.

/// One addon as `GET /v1/addons` lists it. Read leniently: a missing or
/// wrongly typed field is empty, and the entry is skipped if it can't be
/// used at all.
struct AddonResolved: Equatable {
    var id: String
    var slot: String
    var name: String
    var version: String
    var sha256: String
    var size: Int
    var entry: String
    var bridge: Int
    var platforms: [String]?
    var hosts: [String]
    var capabilities: [String]
    var settings: [String: Any]
    /// `/v1/addons/<id>/bundle/<sha256>`.
    var bundle: String
    var updatedAt: String?

    static func == (a: AddonResolved, b: AddonResolved) -> Bool {
        a.id == b.id && a.slot == b.slot && a.version == b.version && a.sha256 == b.sha256
            && NSDictionary(dictionary: a.settings).isEqual(to: b.settings)
    }

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let slot = object["slot"] as? String,
              let version = object["version"] as? String, let sha = object["sha256"] as? String,
              !id.isEmpty, !slot.isEmpty, !sha.isEmpty else { return nil }
        self.id = id
        self.slot = slot
        self.version = version
        sha256 = sha.lowercased()
        name = object["name"] as? String ?? id
        size = AddonManifest.wholeNumber(object["size"]) ?? 0
        entry = object["entry"] as? String ?? ""
        bridge = AddonManifest.wholeNumber(object["bridge"]) ?? 1
        platforms = (object["platforms"] as? [Any])?.compactMap { $0 as? String }
        let permissions = object["permissions"] as? [String: Any] ?? [:]
        hosts = (permissions["hosts"] as? [Any])?.compactMap { $0 as? String } ?? []
        capabilities = (permissions["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []
        settings = object["settings"] as? [String: Any] ?? [:]
        bundle = object["bundle"] as? String ?? ""
        updatedAt = object["updated_at"] as? String
    }

    /// Where to download it: the path the cloud gave, when it is one of its
    /// addon routes; otherwise the route the contract names.
    var bundlePath: String {
        let trimmed = bundle.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/v1/addons/"), !trimmed.contains("..") { return trimmed }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return "/v1/addons/\(escaped)/bundle/\(sha256)"
    }

    /// Whether this Copper can run it: a slot it knows, meant for the Mac,
    /// a bridge it speaks.
    var runsHere: Bool {
        AddonSlot(rawValue: slot) != nil && Addons.runsHere(platforms) && bridge <= Addons.bridge && bridge >= 1
    }
}

/// The whole answer of `GET /v1/addons`.
struct AddonResolvedSet: Equatable {
    var revision: String
    var addons: [AddonResolved]

    static let empty = AddonResolvedSet(revision: "", addons: [])

    /// Nil only when the body is not a JSON object.
    static func parse(_ data: Data) -> AddonResolvedSet? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let list = (object["addons"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(AddonResolved.init) }
        return AddonResolvedSet(revision: object["revision"] as? String ?? "", addons: list)
    }

    /// The first addon listed for the slot that can run here.
    func addon(for slot: AddonSlot) -> AddonResolved? {
        addons.first { $0.slot == slot.rawValue && $0.runsHere }
    }
}

/// One installed (or staged) addon: `state.json`'s `installed.<slot>` entry.
struct AddonInstalled: Codable, Equatable {
    var id: String
    var version: String
    var sha256: String
    /// Relative to the addons folder: `bundles/<id>/<sha>` once installed,
    /// `staging/<sha>.json` while pending. A development folder's is absolute.
    var dir: String
    var settings: AddonJSON
    var installedAt: String
    var name: String
    var slot: String
    var entry: String
    var bridge: Int
    var hosts: [String]
    var capabilities: [String]
    /// The cloud it came from (`host:port`), `development` for a folder.
    var source: String

    enum CodingKeys: String, CodingKey {
        case id, version, sha256, dir, settings, name, slot, entry, bridge, hosts, capabilities, source
        case installedAt = "installed_at"
    }

    init(id: String, version: String, sha256: String, dir: String, settings: AddonJSON, installedAt: String,
         name: String, slot: String, entry: String, bridge: Int, hosts: [String], capabilities: [String], source: String) {
        self.id = id
        self.version = version
        self.sha256 = sha256
        self.dir = dir
        self.settings = settings
        self.installedAt = installedAt
        self.name = name
        self.slot = slot
        self.entry = entry
        self.bridge = bridge
        self.hosts = hosts
        self.capabilities = capabilities
        self.source = source
    }

    /// Entries written by a client that kept only the contract's keys still read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        settings = try c.decodeIfPresent(AddonJSON.self, forKey: .settings) ?? .object([:])
        installedAt = try c.decodeIfPresent(String.self, forKey: .installedAt) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        slot = try c.decodeIfPresent(String.self, forKey: .slot) ?? AddonSlot.agentSidebar.rawValue
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "index.html"
        bridge = try c.decodeIfPresent(Int.self, forKey: .bridge) ?? 1
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }

    init(_ resolved: AddonResolved, dir: String, source: String, at: Date = Date()) {
        self.init(id: resolved.id, version: resolved.version, sha256: resolved.sha256, dir: dir,
                  settings: AddonJSON(resolved.settings), installedAt: AddonTime.text(at), name: resolved.name,
                  slot: resolved.slot, entry: resolved.entry, bridge: resolved.bridge, hosts: resolved.hosts,
                  capabilities: resolved.capabilities, source: source)
    }

    var hostRules: [AddonHostRule] { hosts.compactMap { try? AddonHostRule.parse($0) } }
    var granted: Set<AddonCapability> { Set(capabilities.compactMap(AddonCapability.init(rawValue:))) }
    var development: Bool { source == AddonInstalled.developmentSource }
    static let developmentSource = "development"

    /// What a slot's web view is showing: a new key means a new page.
    var pageKey: String { "\(id)|\(sha256)|\(dir)|\(entry)" }
}

/// `state.json`.
struct AddonState: Codable, Equatable {
    var schema = 1
    /// The `revision` of the last cloud answer applied in full. Kept back
    /// when a download failed, so the next check tries again.
    var revision = ""
    var installed: [String: AddonInstalled] = [:]
    /// Nil when nothing is waiting (the contract's `null`).
    var pending: [String: AddonInstalled]?
    /// Addon ids turned off on this Mac: their slot shows its own view.
    var disabled: [String] = []
    var lastCheck: String?
    /// `link URL|user id` the installs were resolved for; another person
    /// signing in on this Mac is a reason to ask afresh.
    var owner: String?

    enum CodingKeys: String, CodingKey {
        case schema, revision, installed, pending, disabled, owner
        case lastCheck = "last_check"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        installed = try c.decodeIfPresent([String: AddonInstalled].self, forKey: .installed) ?? [:]
        pending = try c.decodeIfPresent([String: AddonInstalled].self, forKey: .pending)
        disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
        lastCheck = try c.decodeIfPresent(String.self, forKey: .lastCheck)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
    }

    /// `pending` is written as `null`, not left out, when nothing waits.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(revision, forKey: .revision)
        try c.encode(installed, forKey: .installed)
        if let pending, !pending.isEmpty { try c.encode(pending, forKey: .pending) } else { try c.encodeNil(forKey: .pending) }
        try c.encode(disabled, forKey: .disabled)
        try c.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try c.encodeIfPresent(owner, forKey: .owner)
    }

    func pending(_ slot: AddonSlot) -> AddonInstalled? { pending?[slot.rawValue] }

    mutating func setPending(_ entry: AddonInstalled?, for slot: AddonSlot) {
        var all = pending ?? [:]
        all[slot.rawValue] = entry
        pending = all.isEmpty ? nil : all
    }

    /// What the slot shows: its install, unless turned off on this Mac.
    func active(_ slot: AddonSlot) -> AddonInstalled? {
        guard let entry = installed[slot.rawValue], !disabled.contains(entry.id) else { return nil }
        return entry
    }
}

// MARK: - the plan

/// What a cloud answer means for what is installed (contract §6.3).
struct AddonPlan: Equatable {
    /// Slots whose addon went (turned off, unassigned, or replaced by
    /// nothing): applied at once, the slot shows its own view again.
    var remove: [AddonSlot] = []
    /// Same bundle, new settings: applied at once, the page told.
    var settings: [AddonSlot] = []
    /// New addons and new versions: downloaded, verified, staged, offered.
    var stage: [AddonResolved] = []
    /// Staged bundles the cloud no longer lists.
    var dropPending: [AddonSlot] = []

    var isEmpty: Bool { remove.isEmpty && settings.isEmpty && stage.isEmpty && dropPending.isEmpty }

    static func make(_ state: AddonState, _ resolved: AddonResolvedSet) -> AddonPlan {
        var plan = AddonPlan()
        for slot in AddonSlot.allCases {
            let want = resolved.addon(for: slot)
            let have = state.installed[slot.rawValue]
            let waiting = state.pending(slot)
            guard let want else {
                if have != nil { plan.remove.append(slot) }
                if waiting != nil { plan.dropPending.append(slot) }
                continue
            }
            if let have, have.id == want.id, have.sha256 == want.sha256 {
                if !NSDictionary(dictionary: have.settings.object).isEqual(to: want.settings) { plan.settings.append(slot) }
                if waiting != nil { plan.dropPending.append(slot) }
                continue
            }
            // Already staged and the same bundle: only its settings may be news.
            if let waiting, waiting.id == want.id, waiting.sha256 == want.sha256 {
                if !NSDictionary(dictionary: waiting.settings.object).isEqual(to: want.settings) { plan.stage.append(want) }
                continue
            }
            plan.stage.append(want)
        }
        return plan
    }
}

// MARK: - files

/// Where addon files live, under one folder (Copper's data folder, so each
/// test world has its own).
struct AddonStore {
    let root: URL

    var stateFile: URL { root.appendingPathComponent("state.json") }
    var bundles: URL { root.appendingPathComponent("bundles", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    func bundleDir(_ id: String, _ sha: String) -> String { "bundles/\(id)/\(sha)" }
    func stagingPath(_ sha: String) -> String { "staging/\(sha).json" }
    func dataDir(_ id: String) -> URL { data.appendingPathComponent(id, isDirectory: true) }

    /// An entry's folder (installed) or file (staged); absolute for a
    /// development folder.
    func url(_ dir: String) -> URL {
        dir.hasPrefix("/") ? URL(fileURLWithPath: dir, isDirectory: true) : root.appendingPathComponent(dir)
    }

    func load() -> AddonState {
        guard let data = try? Data(contentsOf: stateFile) else { return AddonState() }
        guard let state = try? JSONDecoder().decode(AddonState.self, from: data) else {
            // Unreadable: set aside rather than written over, and start empty
            // — the next check installs again what the cloud assigns.
            let aside = root.appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: stateFile, to: aside)
            return AddonState()
        }
        return state
    }

    /// Atomic: a private temporary file renamed over the old one.
    func save(_ state: AddonState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AddonStore.writeAtomically(try encoder.encode(state), to: stateFile, mode: 0o644)
    }

    static func writeAtomically(_ data: Data, to file: URL, mode: Int) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw AddonProblem(code: "io", message: "couldn't write \(file.lastPathComponent)")
        }
        if rename(temporary.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw AddonProblem(code: "io", message: "couldn't replace \(file.lastPathComponent)")
        }
    }

    /// At launch: bundle folders nothing installed points at (the one an
    /// install replaced was kept until now), staged files nothing waits on,
    /// and half-written leftovers. Never a data folder — an addon's storage
    /// outlives its versions.
    func collect(keeping state: AddonState) {
        let files = FileManager.default
        let keepDirs = Set(state.installed.values.map(\.dir))
        let keepStaged = Set((state.pending ?? [:]).values.map(\.dir))
        for id in (try? files.contentsOfDirectory(atPath: bundles.path)) ?? [] {
            let idFolder = bundles.appendingPathComponent(id)
            if id.hasPrefix(".tmp-") { try? files.removeItem(at: idFolder); continue }
            for sha in (try? files.contentsOfDirectory(atPath: idFolder.path)) ?? [] where !keepDirs.contains("bundles/\(id)/\(sha)") {
                try? files.removeItem(at: idFolder.appendingPathComponent(sha))
            }
            if ((try? files.contentsOfDirectory(atPath: idFolder.path)) ?? []).isEmpty { try? files.removeItem(at: idFolder) }
        }
        for name in (try? files.contentsOfDirectory(atPath: staging.path)) ?? [] where !keepStaged.contains("staging/\(name)") {
            try? files.removeItem(at: staging.appendingPathComponent(name))
        }
        for name in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".state.json.") {
            try? files.removeItem(at: root.appendingPathComponent(name))
        }
    }
}

enum AddonTime {
    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

// MARK: - free JSON

/// A JSON value that survives `Codable` — addon settings are whatever the
/// manifest says they are.
enum AddonJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AddonJSON])
    case object([String: AddonJSON])

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.map { AddonJSON($0) })
        case let object as [String: Any]: self = .object(object.mapValues { AddonJSON($0) })
        default: self = .null
        }
    }

    /// As `JSONSerialization` would hand it over.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): return s
        case .array(let list): return list.map(\.any)
        case .object(let object): return object.mapValues(\.any)
        }
    }

    var object: [String: Any] { (any as? [String: Any]) ?? [:] }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let list = try? c.decode([AddonJSON].self) { self = .array(list) }
        else { self = .object(try c.decode([String: AddonJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let list): try c.encode(list)
        case .object(let object): try c.encode(object)
        }
    }
}
