import Foundation

/// Reads Arc's sidebar without asking Arc to export or rewriting its file.
/// The sidebar lives beside Arc's Chromium profile directory, not inside it.
enum FlowArc {
    private static let arcEpoch = 978_307_200.0

    // JSONSerialization gives convenient dictionaries, but dictionaries do
    // not retain Arc's colour order. Keep a small ordered view for hue(),
    // whose first saturated colour is part of Arc's import behaviour.
    private indirect enum OrderedJSON {
        case object([(String, OrderedJSON)])
        case array([OrderedJSON])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    private enum JSONParseError: Error { case invalid }

    private struct OrderedParser {
        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) { bytes = Array(data) + [0] }

        mutating func parse() throws -> OrderedJSON {
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count - 1 else { throw JSONParseError.invalid }
            return value
        }

        private mutating func parseValue() throws -> OrderedJSON {
            skipWhitespace()
            switch bytes[index] {
            case 123: return try parseObject() // {
            case 91: return try parseArray() // [
            case 34: return .string(try parseString())
            case 116: try literal(Array("true".utf8)); return .bool(true)
            case 102: try literal(Array("false".utf8)); return .bool(false)
            case 110: try literal(Array("null".utf8)); return .null
            default: return try parseNumber()
            }
        }

        private mutating func parseObject() throws -> OrderedJSON {
            try expect(123)
            var values: [(String, OrderedJSON)] = []
            skipWhitespace()
            if bytes[index] == 125 { index += 1; return .object(values) }
            while true {
                skipWhitespace()
                guard bytes[index] == 34 else { throw JSONParseError.invalid }
                let key = try parseString()
                skipWhitespace()
                try expect(58)
                values.append((key, try parseValue()))
                skipWhitespace()
                if bytes[index] == 125 { index += 1; return .object(values) }
                try expect(44)
            }
        }

        private mutating func parseArray() throws -> OrderedJSON {
            try expect(91)
            var values: [OrderedJSON] = []
            skipWhitespace()
            if bytes[index] == 93 { index += 1; return .array(values) }
            while true {
                values.append(try parseValue())
                skipWhitespace()
                if bytes[index] == 93 { index += 1; return .array(values) }
                try expect(44)
            }
        }

        private mutating func parseString() throws -> String {
            try expect(34)
            var output: [UInt8] = []
            while index < bytes.count - 1 {
                let byte = bytes[index]
                index += 1
                if byte == 34 { return String(decoding: output, as: UTF8.self) }
                guard byte != 92 else {
                    guard index < bytes.count - 1 else { throw JSONParseError.invalid }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case 34, 47, 92: output.append(escaped)
                    case 98: output.append(8)
                    case 102: output.append(12)
                    case 110: output.append(10)
                    case 114: output.append(13)
                    case 116: output.append(9)
                    case 117:
                        guard index + 4 <= bytes.count - 1 else { throw JSONParseError.invalid }
                        var scalar = UInt32(0)
                        for _ in 0..<4 {
                            guard let digit = Self.hex(bytes[index]) else { throw JSONParseError.invalid }
                            scalar = scalar * 16 + digit
                            index += 1
                        }
                        if let value = UnicodeScalar(scalar) {
                            output.append(contentsOf: String(value).utf8)
                        } else {
                            output.append(contentsOf: "�".utf8)
                        }
                    default: throw JSONParseError.invalid
                    }
                    continue
                }
                guard byte >= 0x20 else { throw JSONParseError.invalid }
                output.append(byte)
            }
            throw JSONParseError.invalid
        }

        private mutating func parseNumber() throws -> OrderedJSON {
            let start = index
            while index < bytes.count - 1,
                  Array("-+0123456789.eE".utf8).contains(bytes[index]) {
                index += 1
            }
            guard start < index else { throw JSONParseError.invalid }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text) else { throw JSONParseError.invalid }
            return .number(value)
        }

        private mutating func literal(_ expected: [UInt8]) throws {
            guard bytes[index..<min(index + expected.count, bytes.count)] == expected[...] else {
                throw JSONParseError.invalid
            }
            index += expected.count
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard bytes[index] == byte else { throw JSONParseError.invalid }
            index += 1
        }

        private mutating func skipWhitespace() {
            while bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 32 { index += 1 }
        }

        private static func hex(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 48...57: return UInt32(byte - 48)
            case 65...70: return UInt32(byte - 55)
            case 97...102: return UInt32(byte - 87)
            default: return nil
            }
        }
    }

    private struct RawTab {
        let url: URL
        let title: String
        let group: UUID?
        let seen: Double?
        var split: UUID? = nil
    }

    /// Arc keeps this file one level above `Arc/User Data`.
    static var sidebar: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arc", isDirectory: true)
            .appendingPathComponent("StorableSidebar.json")
    }

    /// Presence is deliberately just a file check; reading is the operation
    /// that reports a corrupt or inaccessible sidebar.
    static var present: Bool {
        FileManager.default.fileExists(atPath: sidebar.path)
    }

    static func read() throws -> [FlowModel.Space] {
        try read(sidebar: sidebar)
    }

    /// Reads a caller-supplied copy so importing can be tested without
    /// touching Arc's live sidebar.
    static func read(sidebar file: URL) throws -> [FlowModel.Space] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw FlowModel.Trouble.unreadable("Arc sidebar")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FlowModel.Trouble.unreadable("Arc sidebar")
        }
        guard let document = object as? [String: Any],
              let sidebar = document["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              // Arc can keep more than one container of spaces — a fresh
              // window's one untitled space beside the real ones. The real
              // ones are the container with the most spaces.
              let container = containers
                .compactMap({ $0 as? [String: Any] })
                .filter({ $0["spaces"] != nil })
                .max(by: { Self.spaceCount($0) < Self.spaceCount($1) }),
              let rawSpaces = container["spaces"] as? [Any]
        else {
            throw FlowModel.Trouble.unreadable("Arc sidebar")
        }

        var orderedParser = OrderedParser(data: data)
        let orderedRoot: OrderedJSON
        do {
            orderedRoot = try orderedParser.parse()
        } catch {
            throw FlowModel.Trouble.unreadable("Arc sidebar")
        }
        let orderedSpaces = Self.orderedSpaces(in: orderedRoot)

        // Arc's item array contains both IDs and item dictionaries. Only the
        // dictionaries are nodes; children refer to them by ID.
        var items: [String: [String: Any]] = [:]
        for value in (container["items"] as? [Any] ?? []) {
            guard let item = value as? [String: Any],
                  let id = item["id"] as? String
            else { continue }
            items[id] = item
        }

        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            return nil
        }

        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        // The folders Arc has open, in any window. Arc keeps this per window
        // rather than on the folder; everything else comes in shut.
        var pinnedWalk = false
        let opened: Set<String> = {
            let windows = file.deletingLastPathComponent().appendingPathComponent("StorableWindows.json")
            guard let data = try? Data(contentsOf: windows),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["windows"] as? [[String: Any]]
            else { return [] }
            return Set(list.flatMap { $0["expandedItems"] as? [Any] ?? [] }.compactMap { $0 as? String })
        }()

        // Arc's order, folders and all: Copper draws a folder's tabs either
        // side of the folders inside it under one header (FolderTree.plan).
        // A split view's first two panes share a token; the pane holds two.
        func tabs(in parentID: String, folder: UUID?, split: UUID? = nil, groups: inout [FlowModel.Group]) -> [RawTab] {
            guard let parent = items[parentID],
                  let childIDs = parent["childrenIds"] as? [Any]
            else { return [] }

            var children: [[String: Any]] = []
            for child in childIDs {
                guard let childID = child as? String, let item = items[childID] else { continue }
                children.append(item)
            }
            var result: [RawTab] = []
            var panes = 0
            for node in children {
                guard let id = node["id"] as? String,
                      let data = node["data"] as? [String: Any]
                else { continue }

                if let tab = data["tab"] as? [String: Any] {
                    guard let rawURL = tab["savedURL"] as? String,
                          let url = URL(string: rawURL),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https"
                    else { continue }
                    let title = nonEmpty(node["title"] as? String)
                        ?? nonEmpty(tab["savedTitle"] as? String)
                        ?? ""
                    let seen = number(tab["timeLastActiveAt"]).flatMap { value in
                        value == 0 ? nil : value + arcEpoch
                    }
                    result.append(RawTab(url: url, title: title, group: folder, seen: seen,
                                         split: panes < 3 ? split : nil)) // Fork (ardia split): up to three panes (Split.most)
                    panes += 1
                } else if data["list"] != nil {
                    var name = nonEmpty(node["title"] as? String) ?? "Folder"
                    if let folder,
                       let parentGroup = groups.first(where: { $0.id == folder }) {
                        name = parentGroup.name + " › " + name
                    }
                    var group = FlowModel.Group(name: name)
                    group.collapsed = !opened.contains(id)
                    let slot = result.count
                    groups.append(group)
                    let held = tabs(in: id, folder: group.id, groups: &groups)
                    // Only an empty folder in the Saved list needs a place of
                    // its own; one with tabs stands wherever they do.
                    if held.isEmpty, pinnedWalk, let at = groups.firstIndex(where: { $0.id == group.id }) {
                        groups[at].slot = slot
                    }
                    result += held
                } else if data["splitView"] != nil {
                    result += tabs(in: id, folder: folder, split: UUID(), groups: &groups)
                }
            }
            return result
        }

        func hue(from theme: OrderedJSON) -> Double? {
            var found: [Double] = []

            func number(_ value: OrderedJSON?) -> Double? {
                guard let value else { return nil }
                if case .number(let value) = value { return value }
                return nil
            }

            func walk(_ node: OrderedJSON) {
                switch node {
                case .object(let dictionary):
                    func value(_ key: String) -> OrderedJSON? {
                        dictionary.first(where: { $0.0 == key })?.1
                    }
                    if let red = number(value("red")),
                       let green = number(value("green")),
                       let blue = number(value("blue")),
                       (number(value("alpha")) ?? 1) > 0 {
                        let r = min(1, max(0, red))
                        let g = min(1, max(0, green))
                        let b = min(1, max(0, blue))
                        let maximum = max(r, max(g, b))
                        let minimum = min(r, min(g, b))
                        let delta = maximum - minimum
                        let saturation = maximum == 0 ? 0 : delta / maximum
                        var h = 0.0
                        if delta != 0 {
                            if maximum == r {
                                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                            } else if maximum == g {
                                h = (b - r) / delta + 2
                            } else {
                                h = (r - g) / delta + 4
                            }
                            h /= 6
                            if h < 0 { h += 1 }
                        }
                        if saturation > 0.25 && maximum > 0.2 { found.append(h) }
                    }
                    for (_, value) in dictionary { walk(value) }
                case .array(let array):
                    for value in array { walk(value) }
                case .string, .number, .bool, .null:
                    break
                }
            }

            func truthy(_ value: OrderedJSON) -> Bool {
                switch value {
                case .object(let values): return !values.isEmpty
                case .array(let values): return !values.isEmpty
                case .string(let value): return !value.isEmpty
                case .number(let value): return value != 0
                case .bool(let value): return value
                case .null: return false
                }
            }

            let palette: OrderedJSON?
            if let primary = Self.orderedValue(theme, key: "primaryColorPalette"), truthy(primary) {
                palette = primary
            } else {
                palette = nil
            }
            walk(palette ?? theme)
            guard let first = found.first else { return nil }
            return (first * 1_000).rounded(.toNearestOrEven) / 1_000
        }

        func profileName(_ value: Any?) -> String? {
            guard let profile = value as? [String: Any],
                  profile["default"] as? Bool != true,
                  let custom = profile["custom"] as? [String: Any],
                  let zero = custom["_0"] as? [String: Any],
                  let basename = zero["directoryBasename"] as? String,
                  !basename.isEmpty
            else { return nil }
            return basename
        }

        // Favourites are shared by every default-profile space. Arc stores
        // profile/container pairs in one alternating array.
        let topIDs = container["topAppsContainerIDs"] as? [Any] ?? []
        var favourites: [RawTab] = []
        var favouriteGroups: [FlowModel.Group] = []
        if topIDs.count >= 2 {
            for index in stride(from: 0, to: topIDs.count - 1, by: 2) {
                guard let profile = topIDs[index] as? [String: Any],
                      profile.count == 1,
                      profile["default"] as? Bool == true,
                      let containerID = topIDs[index + 1] as? String
                else { continue }
                favourites = tabs(in: containerID, folder: nil, groups: &favouriteGroups)
            }
        }

        var output: [FlowModel.Space] = []
        for (spaceIndex, rawSpace) in rawSpaces.enumerated() {
            guard let space = rawSpace as? [String: Any] else { continue }
            let title = space["title"] as? String ?? ""
            var groups: [FlowModel.Group] = []
            let orderedTheme: OrderedJSON? = {
                guard orderedSpaces.indices.contains(spaceIndex),
                      let custom = Self.orderedValue(orderedSpaces[spaceIndex], key: "customInfo") else { return nil }
                return Self.orderedValue(custom, key: "windowTheme")
            }()
            let pinnedID = Self.containerID(in: space["containerIDs"], after: "pinned")
            let unpinnedID = Self.containerID(in: space["containerIDs"], after: "unpinned")
            var incoming = FlowModel.Space(name: title)
            incoming.hue = orderedTheme.flatMap(hue)
            incoming.profile = profileName(space["profile"])
            incoming.source = space["id"] as? String
            let custom = space["customInfo"] as? [String: Any]
            incoming.theme = SpaceTheme.arc(custom?["windowTheme"] as? [String: Any])
            incoming.icon = SpaceTheme.arcIcon(custom?["iconType"] as? [String: Any])

            var imported: [FlowModel.Tab] = favourites.map { favourite in
                var tab = FlowModel.Tab(url: favourite.url, title: favourite.title)
                tab.pinned = true
                return tab
            }

            pinnedWalk = true
            let pinned = pinnedID.map { tabs(in: $0, folder: nil, groups: &groups) } ?? []
            pinnedWalk = false
            // Arc's own order, as its Today list shows it.
            let today = unpinnedID.map { tabs(in: $0, folder: nil, groups: &groups) } ?? []

            var rows: [(RawTab, Bool)] = pinned.map { ($0, true) }
            rows.append(contentsOf: today.map { ($0, false) })
            for (raw, saved) in rows {
                var tab = FlowModel.Tab(url: raw.url, title: raw.title)
                tab.saved = saved
                tab.group = raw.group
                // A row Arc still has open counts as seen now: Arc's archive
                // has had its say, and an old stamp would have Copper's sweep
                // close every one on the first launch.
                tab.seen = saved ? raw.seen : Date().timeIntervalSince1970
                tab.split = raw.split
                imported.append(tab)
            }

            // Keep one deterministic active tab so the adopter can select a
            // page immediately, including spaces containing only favourites.
            if !imported.isEmpty { imported[0].active = true }
            // Empty folders too: Arc keeps them, so the column does.
            incoming.groups = groups
            incoming.tabs = imported
            output.append(incoming)
        }
        return output
    }

    private static func orderedValue(_ value: OrderedJSON, key: String) -> OrderedJSON? {
        guard case .object(let dictionary) = value else { return nil }
        return dictionary.first(where: { $0.0 == key })?.1
    }

    private static func orderedSpaces(in root: OrderedJSON) -> [OrderedJSON] {
        guard let sidebar = orderedValue(root, key: "sidebar"),
              let containers = orderedValue(sidebar, key: "containers"),
              case .array(let values) = containers
        else { return [] }
        // The same container `read` picked: the one with the most spaces.
        var best: [OrderedJSON] = []
        var most = -1
        for value in values {
            guard let spaces = orderedValue(value, key: "spaces"),
                  case .array(let spaces) = spaces
            else { continue }
            let count = spaces.filter { if case .object = $0 { return true } else { return false } }.count
            if count > most { most = count; best = spaces }
        }
        return best
    }

    private static func spaceCount(_ container: [String: Any]) -> Int {
        (container["spaces"] as? [Any] ?? []).filter { $0 is [String: Any] }.count
    }

    private static func containerID(in value: Any?, after marker: String) -> String? {
        guard let ids = value as? [Any], let index = ids.firstIndex(where: { ($0 as? String) == marker }),
              index + 1 < ids.count
        else { return nil }
        return ids[index + 1] as? String
    }
}
