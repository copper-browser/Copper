import Foundation

/// The rest of Arc that a move in brings with its spaces: its Air Traffic
/// Control rules (`StorableLinkRouting.json`) become Copper's
/// (Fork/AirTraffic.swift), and its archived tabs (`StorableArchiveItems.json`)
/// go to Recently Cleaned (Fork/Cleaned.swift). Both files sit beside
/// `StorableSidebar.json` and name spaces by Arc's space id, which the move
/// maps to the Copper space each one became.
///
/// Only what Arc writes is read (checked against two real Arc folders and
/// Ardia's importer): a rule with one `urlMatch` condition, `contains` or
/// `matches`, sent to a space, Little Arc or the most recent space. Anything
/// else is left out and counted.
enum FlowArcExtras {
    struct Rule: Equatable {
        /// AirTraffic's site pattern for Arc's text.
        var site: String
        /// Arc's space id; nil for the most recent space.
        var space: String?
        var little: Bool
    }

    struct Archived: Equatable {
        var url: URL
        var title: String
        /// Arc's space id; nil for Little Arc or an unknown source.
        var space: String?
    }

    struct Read: Equatable {
        var rules: [Rule] = []
        var skipped = 0
        /// Where everything else goes, only when Arc names a space for it
        /// (its own default, Little Arc in front, is not a choice to carry).
        var fallback: Rule?
        /// Newest first.
        var archived: [Archived] = []
    }

    static let routingFile = "StorableLinkRouting.json"
    static let archiveFile = "StorableArchiveItems.json"

    /// Both files from Arc's folder; a missing or unreadable one is empty.
    static func read(folder: URL) -> Read {
        var out = Read()
        if let data = try? Data(contentsOf: folder.appendingPathComponent(routingFile)) { routing(data, into: &out) }
        if let data = try? Data(contentsOf: folder.appendingPathComponent(archiveFile)) { out.archived = archive(data) }
        return out
    }

    static func routing(_ data: Data, into out: inout Read) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        for value in root["rules"] as? [Any] ?? [] {
            if let rule = rule(value as? [String: Any]) { out.rules.append(rule) } else { out.skipped += 1 }
        }
        if let to = destination(root["defaultDestination"]), to.space != nil {
            out.fallback = Rule(site: "", space: to.space, little: to.little)
        }
    }

    /// A dictionary with exactly one key, as Swift's Codable writes an enum.
    private static func only(_ value: Any?) -> (key: String, value: Any)? {
        guard let d = value as? [String: Any], d.count == 1, let entry = d.first else { return nil }
        return (entry.key, entry.value)
    }

    private static func destination(_ value: Any?) -> (space: String?, little: Bool)? {
        guard let outer = only(value), outer.key == "space" || outer.key == "littleArc",
              let target = only((outer.value as? [String: Any])?["_0"]) else { return nil }
        if target.key == "mostRecent" { return (nil, outer.key == "littleArc") }
        guard target.key == "space", let id = (target.value as? [String: Any])?["_0"] as? String, !id.isEmpty else { return nil }
        return (id, outer.key == "littleArc")
    }

    private static func rule(_ rule: [String: Any]?) -> Rule? {
        guard let rule, let to = destination(rule["destination"]),
              let parts = rule["sourceComponents"] as? [Any], parts.count == 1,
              let type = only((parts[0] as? [String: Any])?["componentType"]), type.key == "urlMatch",
              let match = type.value as? [String: Any],
              let style = only(match["_0"]), style.key == "contains" || style.key == "matches",
              let text = match["_1"] as? String,
              let site = site(text, exact: style.key == "matches")
        else { return nil }
        return Rule(site: site, space: to.space, little: to.little)
    }

    /// Arc's text as an AirTraffic site: "contains" becomes `*text*` (over
    /// the host, or host and path once the text has a slash), "matches" the
    /// plain address. Scheme, `www.`, a trailing slash and any query are
    /// dropped: AirTraffic looks at host and path only. Text that would then
    /// take every link (`/`, `www.`) is no rule.
    // shortcut: "matches" also takes subdomains and deeper paths (AirTraffic has no exact match); add one if Arc users miss it.
    static func site(_ text: String, exact: Bool) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where t.hasPrefix(scheme) { t.removeFirst(scheme.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        if let cut = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<cut]) }
        while t.hasSuffix("/") { t.removeLast() }
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return exact ? t : "*\(t)*"
    }

    /// Arc's archive, web pages only, newest first; a custom name wins.
    static func archive(_ data: Data) -> [Archived] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var out: [(Double, Archived)] = []
        for value in root["items"] as? [Any] ?? [] {
            guard let entry = value as? [String: Any],
                  let item = entry["sidebarItem"] as? [String: Any],
                  let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                  let raw = tab["savedURL"] as? String, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let at = (entry["archivedAt"] as? NSNumber)?.doubleValue
            else { continue }
            let custom = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let space = ((entry["source"] as? [String: Any])?["space"] as? [String: Any])?["_0"] as? String
            out.append((at, Archived(url: url, title: custom ?? tab["savedTitle"] as? String ?? "", space: space)))
        }
        return out.sorted { $0.0 > $1.0 }.map(\.1)
    }

    // MARK: - landing

    /// Arc's space id → the Copper space it became: the move's registry by
    /// each space's key, for the same spaces (those with a tab) the move
    /// adopted. A space since deleted here maps to nothing.
    static func spaces(_ adopted: [FlowModel.Space], source: String, registry: [String: UUID], alive: Set<UUID>) -> [String: UUID] {
        var out: [String: UUID] = [:]
        for (space, key) in zip(adopted, FlowAdopt.keys(adopted, source: source)) {
            if let arc = space.source, let id = registry[key], alive.contains(id) { out[arc] = id }
        }
        return out
    }

    /// Rules for AirTraffic, in Arc's order. One that names a space that
    /// didn't come over is left out (Ardia's rule), Little Arc's included.
    static func rules(_ read: Read, spaces: [String: UUID]) -> [AirTraffic.Rule] {
        read.rules.compactMap { rule in
            var to = AirTraffic.Target(space: nil, open: rule.little ? .little : .tab)
            if let arc = rule.space {
                guard let id = spaces[arc] else { return nil }
                to.space = id
            }
            return AirTraffic.Rule(site: rule.site, to: to)
        }
    }

    /// Archived tabs as Recently Cleaned entries: each in the space it
    /// became, else (Little Arc, a deleted space) `fallback`. Only into the
    /// room each space has left under `Cleaned.most`, so the person's own
    /// entries stay, and only pages not listed there yet, so a second move
    /// adds nothing. `have` answers a space's listed addresses. Kept a week
    /// from the move: Arc's own dates are mostly older than that.
    static func cleaned(_ archived: [Archived], spaces: [String: UUID], fallback: UUID,
                        have: (UUID) -> Set<URL>, movedAt: Date) -> [CleanedEntry] {
        var listed: [UUID: Set<URL>] = [:]
        var out: [CleanedEntry] = []
        for tab in archived {
            let space = tab.space.flatMap { spaces[$0] } ?? fallback
            var there = listed[space] ?? have(space)
            guard there.count < Cleaned.most, there.insert(tab.url).inserted else { continue }
            listed[space] = there
            // A millisecond apart, so Recently Cleaned keeps Arc's order.
            out.append(CleanedEntry(url: tab.url, title: tab.title, space: space,
                                    when: movedAt.addingTimeInterval(-Double(out.count) / 1000)))
        }
        return out
    }

    /// Hands both over. Answers what was added.
    @MainActor
    static func land(_ read: Read, adopted: [FlowModel.Space], source: String, registry: [String: UUID],
                     fallback: UUID, movedAt: Date) -> (rules: Int, archived: Int) {
        let map = spaces(adopted, source: source, registry: registry, alive: Set(Spaces.shared.all.map(\.id)))
        let atc = AirTraffic.shared
        let before = atc.book.rules.count
        atc.adopt(rules(read, spaces: map))
        if let rule = read.fallback, let arc = rule.space, let id = map[arc], atc.book.otherwise == AirTraffic.Target() {
            atc.book.otherwise = AirTraffic.Target(space: id, open: rule.little ? .little : .tab)
        }
        let cleaned = Cleaned.shared
        let entries = Self.cleaned(read.archived, spaces: map, fallback: fallback,
                                   have: { Set(cleaned.list(in: $0).map(\.url)) }, movedAt: movedAt)
        cleaned.add(entries)
        return (atc.book.rules.count - before, entries.count)
    }
}
