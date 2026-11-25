import Compression
import Foundation
import SQLite3
import Testing
@testable import Search

// Moving in from Firefox and Zen (Fork/Flow/FlowFirefox.swift) on small
// synthetic profiles. The password vectors are from a real Firefox 160
// throwaway profile (no Primary Password, made-up logins), so NSS's own
// key4.db and logins.json are what is decrypted here.

private struct GeckoScratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gecko-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A profile folder with an (empty) places.sqlite, so it counts.
    func profile(_ path: String) throws -> URL {
        let folder = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try db(folder.appendingPathComponent("places.sqlite"), "CREATE TABLE IF NOT EXISTS x (y)")
        return folder
    }

    @discardableResult
    func db(_ file: URL, _ sql: String) throws -> URL {
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw FlowModel.Trouble.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        return file
    }
}

private func hex(_ text: String) -> String { "X'\(text)'" }

@Suite struct FlowFirefoxProfileTests {
    @Test func theInstallsProfileComesFirst() throws {
        let profiles = FlowFirefox.ini("""
        [General]
        StartWithLastProfile=1

        [Profile1]
        Name=default
        IsRelative=1
        Path=Profiles/b.default
        Default=1

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/a.default-release

        [Install2656FF1E876E9973]
        Default=Profiles/a.default-release
        Locked=1
        """)
        #expect(profiles.map(\.path) == ["Profiles/b.default", "Profiles/a.default-release"])
        #expect(profiles.map(\.everyday) == [false, true])
    }

    @Test func onlyProfilesWithSomethingInThemAreListed() throws {
        let scratch = try GeckoScratch()
        _ = try scratch.profile("Profiles/a.default-release")
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("Profiles/b.default"), withIntermediateDirectories: true)
        try """
        [Profile1]
        Name=default
        Path=Profiles/b.default
        Default=1
        [Profile0]
        Name=default-release
        Path=Profiles/a.default-release
        """.write(to: scratch.root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        // b is Default=1 but has nothing; a is the one there is, and so the everyday one.
        let found = FlowFirefox.profiles(at: scratch.root)
        #expect(found.map(\.path) == ["Profiles/a.default-release"])
        #expect(found.first?.everyday == true)
    }
}

@Suite struct FlowFirefoxSessionTests {
    @Test func mozLz4RoundTrips() throws {
        let json = Data(#"{"windows":[{"tabs":[]}],"padding":"\#(String(repeating: "abc", count: 400))"}"#.utf8)
        var packed = [UInt8](repeating: 0, count: json.count + 64)
        let size = json.withUnsafeBytes { source in
            compression_encode_buffer(&packed, packed.count, source.bindMemory(to: UInt8.self).baseAddress!, json.count, nil, COMPRESSION_LZ4_RAW)
        }
        #expect(size > 0 && size < json.count)
        let count = UInt32(json.count)
        let file = Data("mozLz40\0".utf8) + Data([UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)])
            + Data(packed.prefix(size))
        #expect(FlowFirefox.mozLz4(file) == json)
        #expect(FlowFirefox.mozLz4(Data("not a session".utf8)) == nil)
    }

    private func tab(_ url: String, title: String = "", _ extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = ["entries": [["url": "https://old.example/", "title": "Old"], ["url": url, "title": title]], "index": 2]
        out.merge(extra) { $1 }
        return out
    }

    @Test func firefoxWindowsAreSpacesWithPinsAndGroups() {
        let session: [String: Any] = ["windows": [
            ["selected": 2, "groups": [["id": "g1", "name": "Research", "color": "blue", "collapsed": true]],
             "tabs": [
                tab("https://pinned.example/", title: "Pinned", ["pinned": true, "lastAccessed": 1_795_000_000_000.0]),
                tab("https://loose.example/"),
                tab("about:blank"),
                tab("https://grouped.example/", ["groupId": "g1"]),
             ]],
            ["isPrivate": true, "tabs": [tab("https://secret.example/")]],
            ["tabs": [tab("https://second.example/")]],
        ]]
        let spaces = FlowFirefox.spaces(session: session, name: "Firefox", profile: nil)
        #expect(spaces.map(\.name) == ["Firefox", "Firefox 2"])
        let first = spaces[0]
        #expect(first.tabs.map(\.url.host) == ["pinned.example", "loose.example", "grouped.example"])
        #expect(first.tabs[0].pinned && !first.tabs[0].saved)
        #expect(first.tabs[0].title == "Pinned")
        #expect(first.tabs[0].seen == 1_795_000_000)
        #expect(first.tabs[1].title == "loose.example") // no title: its host
        #expect(first.tabs[1].active)
        #expect(first.groups.count == 1 && first.groups[0].name == "Research" && first.groups[0].collapsed && first.groups[0].hue == 0.6)
        #expect(first.tabs[2].group == first.groups[0].id)
        #expect(spaces[1].tabs.map(\.url.host) == ["second.example"])
    }

    @Test func zenSpacesEssentialsAndPinnedTabs() {
        let home = "{07d9b62a}"
        let work = "{6c375391}"
        let session: [String: Any] = ["windows": [[
            "activeZenSpace": home,
            "spaces": [["uuid": home, "name": "Space"], ["uuid": work, "name": "Work", "icon": "💼"]],
            "tabs": [
                tab("https://essential.example/", ["pinned": true, "zenEssential": true]),
                tab("https://saved.example/", ["pinned": true, "zenWorkspace": home]),
                tab("https://home.example/", ["zenWorkspace": home]),
                tab("https://glance.example/", ["zenWorkspace": home, "zenIsGlance": true]),
                tab("https://work.example/", ["zenWorkspace": work]),
            ],
        ]]]
        let spaces = FlowFirefox.spaces(session: session, name: "Zen", profile: "Profiles/x")
        #expect(spaces.map(\.name) == ["Space", "Work"])
        #expect(spaces[1].icon == "💼")
        #expect(spaces.allSatisfy { $0.profile == "Profiles/x" })
        #expect(spaces[0].tabs.map(\.url.host) == ["essential.example", "saved.example", "home.example"])
        #expect(spaces[0].tabs[0].pinned && !spaces[0].tabs[0].saved) // Essentials: Copper's pins
        #expect(!spaces[0].tabs[1].pinned && spaces[0].tabs[1].saved) // a space's pinned tab: Saved
        #expect(spaces[1].tabs.map(\.url.host) == ["work.example"])
    }
}

@Suite struct FlowFirefoxPlacesTests {
    @Test func bookmarksHistoryAndCookies() throws {
        let scratch = try GeckoScratch()
        let profile = try scratch.profile("Profiles/a.default")
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try scratch.db(profile.appendingPathComponent("places.sqlite"), """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
        INSERT INTO moz_places VALUES (1, 'https://a.example/', 'A', 3, 0, \(micros)), (2, 'https://b.example/', 'B', 1, 0, \(micros - 5_000_000)),
          (3, 'https://never.example/', 'Never visited', 0, 0, NULL), (4, 'place:sort=8', 'Query', 1, 1, NULL);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________'),
          (2, 2, NULL, 1, 0, 'menu', 'menu________'), (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____'),
          (4, 2, NULL, 1, 3, 'unfiled', 'unfiled_____'), (5, 2, NULL, 1, 4, 'mobile', 'mobile______'),
          (10, 1, 1, 3, 0, 'A on the bar', 'x1'), (11, 2, NULL, 3, 1, 'Reading', 'x2'), (12, 1, 2, 11, 0, 'B', 'x3'),
          (13, 3, NULL, 11, 1, '', 'x4'), (14, 1, 4, 11, 2, 'Query', 'x5'), (15, 1, 3, 2, 0, 'In the menu', 'x6');
        """)
        let read = FlowFirefox.bookmarks(root: scratch.root)
        #expect(read.complete)
        #expect(read.nodes.map(\.title) == ["A on the bar", "Reading", "Bookmarks Menu"])
        #expect(read.nodes[1].children?.map(\.title) == ["B"]) // the separator and the place: query stay
        #expect(FlowBookmarks.count(read.nodes) == 3)
        #expect(FlowFirefox.placeCount(root: scratch.root) == 2)
        #expect(FlowFirefox.places(root: scratch.root).map(\.url.host) == ["a.example", "b.example"])
        #expect(FlowFirefox.places(root: scratch.root).first?.count == 3)

        let soon = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try scratch.db(profile.appendingPathComponent("cookies.sqlite"), """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT,
          path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
        INSERT INTO moz_cookies VALUES (1, '', 'sid', 'v1', '.a.example', '/', \(soon * 1000), 2, 1, 1, 1, 1),
          (2, '', 'old', 'v2', 'a.example', '/', 1000, 1, 1, 0, 0, 0),
          (3, '^userContextId=1', 'work', 'v3', 'a.example', '/', \(soon), 1, 1, 0, 0, 0),
          (4, '', 'secs', 'v4', 'b.example', '/x', \(soon), 1, 1, 0, 0, 2);
        """)
        let cookies = FlowFirefox.cookies(root: scratch.root)
        #expect(cookies.map(\.name) == ["secs", "sid"]) // least recently used first; expired and container ones stay
        #expect(cookies[1].secure && cookies[1].httpOnly && cookies[1].sameSite == "Lax")
        #expect(cookies[0].path == "/x" && cookies[0].sameSite == "Strict")
        #expect(abs((cookies[0].expires?.timeIntervalSince1970 ?? 0) - Double(soon)) < 1) // seconds and milliseconds both read
        #expect(abs((cookies[1].expires?.timeIntervalSince1970 ?? 0) - Double(soon)) < 1)
        #expect(cookies.allSatisfy { $0.profile == "Profiles/a.default" })

        // Add-ons stay in Firefox, and the summary names the person's own only.
        let addons: [String: Any] = ["addons": [
            ["type": "extension", "location": "app-profile", "hidden": true, "defaultLocale": ["name": "New Tab"]],
            ["type": "extension", "location": "app-builtin-addons", "hidden": true, "defaultLocale": ["name": "Form Autofill"]],
            ["type": "theme", "location": "app-profile", "hidden": false, "defaultLocale": ["name": "A theme"]],
            ["type": "extension", "location": "app-profile", "hidden": false, "defaultLocale": ["name": "uBlock Origin"]],
        ]]
        try JSONSerialization.data(withJSONObject: addons).write(to: profile.appendingPathComponent("extensions.json"))
        #expect(FlowFirefox.addons(root: scratch.root) == ["uBlock Origin"])
    }
}

@Suite struct FlowFirefoxPasswordTests {
    /// key4.db and logins.json of a Firefox 160 profile made for this test.
    private func profile(_ scratch: GeckoScratch) throws -> URL {
        let profile = try scratch.profile("Profiles/a.default-release")
        try scratch.db(profile.appendingPathComponent("key4.db"), """
        CREATE TABLE metaData (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2);
        CREATE TABLE nssPrivate (id PRIMARY KEY UNIQUE ON CONFLICT ABORT DEFAULT 0, a11, a102);
        INSERT INTO metaData VALUES ('password', \(hex("26BD9E0764B69B87E243D7FBE450339CE7FB3BA0")), \(hex(
            "308181306D06092A864886F70D01050D3060304106092A864886F70D01050C3034042065490F1B8A9F19379A88903C15E2DC0072F461C50BF4B79ED55AFD64B41538FB"
            + "020101020120300A06082A864886F70D0209301B060960864801650304012A040E3EF1C15EE01FAF97CA163387AF7B0410412D0B896B666D3F8BF000132FF2D93B")));
        INSERT INTO nssPrivate VALUES (1, \(hex(
            "3081A1306D06092A864886F70D01050D3060304106092A864886F70D01050C30340420A5511EAE9090CA2E005BE6F338C952BD435363622335D194D4559DF4A740DDCD"
            + "020101020120300A06082A864886F70D0209301B060960864801650304012A040E9ED688D2725B8D7C5751C71F15380430A972180D2E6C9B60C6C750E600E6AE4FE7"
            + "F677ABB2DA85DDB188712DC0582466DEDE1A8E0B0A525AF1B1C8F0C5F3879E")), \(hex("F8000000000000000000000000000001")));
        """)
        let logins: [String: Any] = ["version": 3, "logins": [
            ["hostname": "https://example.com", "timeLastUsed": 1_795_631_980_911.0,
             "encryptedUsername": "MFMEEPgAAAAAAAAAAAAAAAAAAAEwHQYJYIZIAWUDBAEqBBC5f4DZ4zfsSL4fMdbyW7BWBCA1B4PF+TqtenAeWnENSlElk+1OcsyTxk2Hpic/ZrX9QA==",
             "encryptedPassword": "MEMEEPgAAAAAAAAAAAAAAAAAAAEwHQYJYIZIAWUDBAEqBBD2Xtj/6YF4sDKXyq6OZlg3BBDPhQovOBS1o9cN2r9+SOME"],
            ["hostname": "https://github.com",
             "encryptedUsername": "MEMEEPgAAAAAAAAAAAAAAAAAAAEwHQYJYIZIAWUDBAEqBBCIXKJXXM2h157M/pro7dQlBBDa3iEcGh9sW6WRVXMvPnjD",
             "encryptedPassword": "MEMEEPgAAAAAAAAAAAAAAAAAAAEwHQYJYIZIAWUDBAEqBBCh3B0np+acu/BCI+vPiICkBBA1FiUwE9RW7BOeagOwOIZ7"],
        ]]
        try JSONSerialization.data(withJSONObject: logins).write(to: profile.appendingPathComponent("logins.json"))
        try scratch.db(profile.appendingPathComponent("permissions.sqlite"), """
        CREATE TABLE moz_perms (id INTEGER PRIMARY KEY, origin TEXT, type TEXT, permission INTEGER);
        INSERT INTO moz_perms VALUES (1, 'https://www.never.example', 'login-saving', 2), (2, 'https://cam.example', 'camera', 2);
        """)
        return profile
    }

    @Test func decryptsWithoutAPrimaryPassword() throws {
        let scratch = try GeckoScratch()
        _ = try profile(scratch)
        #expect(FlowFirefox.loginCount(root: scratch.root) == 2)
        let found = try FlowFirefox.logins(root: scratch.root)
        let pairs = found.logins.map { "\($0.host) \($0.user) \($0.password)" }
        #expect(pairs == ["example.com alice@example.com hunter2-firefox", "github.com copper-tester gh-Secret-42!"])
        #expect(found.logins[0].used == Date(timeIntervalSince1970: 1_795_631_980.911))
        #expect(found.never == ["never.example"])
    }

    @Test func aPrimaryPasswordIsSaidNotGuessed() throws {
        let scratch = try GeckoScratch()
        let profile = try profile(scratch)
        #expect(throws: FlowFirefox.Trouble.primaryPassword) {
            try FlowFirefox.keys(in: profile.appendingPathComponent("key4.db"), password: "not it")
        }
    }

    @Test func noLoginsIsNoneNotTrouble() throws {
        let scratch = try GeckoScratch()
        _ = try scratch.profile("Profiles/a.default")
        let found = try FlowFirefox.logins(root: scratch.root)
        #expect(found.logins.isEmpty)
    }
}
