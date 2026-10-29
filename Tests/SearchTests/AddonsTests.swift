import Foundation
import Testing
@testable import Search

// Addons (Fork/Addons, docs/addons.md): the rules shared with copper-linux's
// core — manifest, host list, bundle paths, served-bundle verification, the
// plan a cloud answer makes — and the Mac's own fences: the CSP, the
// `copper-addon://` files, the navigation policy, storage limits, what
// `copper.fetch` will send. No web view and no network.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func manifest(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var object: [String: Any] = [
        "schema": "copper-addon/1", "id": "com.example.sidebar", "name": "Example sidebar", "version": "1.2.3",
        "slot": "agent-sidebar", "entry": "index.html", "bridge": 1,
        "permissions": ["hosts": ["api.example.com", "*.example.org", "127.0.0.1:8080"], "capabilities": ["fetch", "storage"]],
        "settings": ["url": ["type": "string", "default": "https://api.example.com/"]],
    ]
    change(&object)
    return object
}

/// A served bundle, built as Copper Cloud builds one (CONTRACT §3).
private func served(_ object: [String: Any] = manifest(), files: [(String, Data)]? = nil,
                    tamper: (inout [[String: Any]]) -> Void = { _ in }, format: String = "copper-addon-bundle/1") -> (Data, String) {
    let list = files ?? [("index.html", Data("<!doctype html><html><head><title>x</title></head><body>hi</body></html>".utf8)),
                         ("app.js", Data("console.log(1)".utf8))]
    var entries: [[String: Any]] = list.sorted { $0.0 < $1.0 }.map { path, data in
        ["path": path, "size": data.count, "sha256": Addons.sha256(data), "data": data.base64EncodedString()]
    }
    tamper(&entries)
    let doc: [String: Any] = ["format": format, "manifest": object, "files": entries]
    let bytes = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
    return (bytes, Addons.sha256(bytes))
}

private func verify(_ pair: (Data, String), id: String = "com.example.sidebar", version: String = "1.2.3") -> String? {
    do {
        _ = try AddonBundle.verify(pair.0, sha256: pair.1, id: id, version: version, slot: "agent-sidebar")
        return nil
    } catch let problem as AddonProblem {
        return problem.code
    } catch {
        return "other"
    }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("addons-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AddonsRulesTests {
    @Test func theBridgeShimIsTheCanonicalBytes() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Sources/Search/Fork/Addons/Resources/bridge.js"))
        #expect(Addons.sha256(data) == "fff9196744c69f90bea87b10062024953017b0c9dea1d3fab37800601ef2235e")
    }

    @Test func ids() {
        for good in ["com.example.sidebar", "a.b", "0x.y-z", "example.sidebar-two"] { #expect(Addons.validID(good), "\(good)") }
        for bad in ["ab", "nodot", "Com.example", "-a.b", ".ab", "a..b", "a_b.c", String(repeating: "a", count: 63) + ".b", "a.b/c"] {
            #expect(!Addons.validID(bad), "\(bad)")
        }
    }

    @Test func versions() {
        for good in ["0.0.0", "1.2.3", "10.20.30", "1.0.0-beta", "1.0.0-beta.1", "1.0.0-rc-1"] { #expect(Addons.validVersion(good), "\(good)") }
        for bad in ["1.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0-a..b", "1.0.0-é", "v1.0.0", "1.0.0+build", "1234567890.0.0"] {
            #expect(!Addons.validVersion(bad), "\(bad)")
        }
    }

    @Test func bundlePaths() {
        for good in ["index.html", "a/b/c.js", "@scope/x.css", "_x-y.z", ".well-known/x"] { #expect(Addons.validPath(good), "\(good)") }
        for bad in ["", "/a", "a/", "a//b", "../a", "a/../b", "./a", "a/.", "a b", "a\\b", "é.js", "a?b", String(repeating: "a", count: 201)] {
            #expect(!Addons.validPath(bad), "\(bad)")
        }
        #expect(Addons.validPath(String(repeating: "a", count: 200)))
    }

    @Test func aGoodManifestHasNoProblems() {
        #expect(AddonManifest(manifest()).problems().isEmpty)
    }

    @Test func eachRuleNamesItsField() {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schema"] = "copper-addon/2" }),
            ("id", { $0["id"] = "nodot" }),
            ("name", { $0["name"] = "" }),
            ("name", { $0["name"] = String(repeating: "n", count: 61) }),
            ("version", { $0["version"] = "1.0" }),
            ("description", { $0["description"] = String(repeating: "d", count: 281) }),
            ("slot", { $0["slot"] = "toolbar" }),
            ("entry", { $0["entry"] = "index.js" }),
            ("entry", { $0["entry"] = "../index.html" }),
            ("bridge", { $0["bridge"] = 0 }),
            ("bridge", { $0.removeValue(forKey: "bridge") }),
            ("bridge", { $0["bridge"] = "1" }),
            ("bridge", { $0["bridge"] = true }),
            ("hosts", { $0["permissions"] = ["hosts": ["http://api.example.com"]] }),
            ("hosts", { $0["permissions"] = ["hosts": (0...32).map { "h\($0).example.com" }] }),
            ("capabilities", { $0["permissions"] = ["capabilities": ["camera"]] }),
            ("settings", { $0["settings"] = ["x": ["type": "date"]] }),
            ("platforms", { $0["platforms"] = ["mac", "beos"] }),
        ]
        for (code, change) in cases {
            #expect(AddonManifest(manifest(change)).problems().first?.code == code, "\(code)")
        }
    }

    @Test func unknownKeysAreKeptAndPlatformsSkipOthers() {
        let read = AddonManifest(manifest { $0["future"] = ["a": 1]; $0["platforms"] = ["linux"] })
        #expect(read.problems().isEmpty)
        #expect(read.raw["future"] != nil)
        #expect(!Addons.runsHere(read.platforms))
        #expect(Addons.runsHere(nil) && Addons.runsHere([]) && Addons.runsHere(["mac", "windows"]))
        #expect(read.defaultSettings["url"] as? String == "https://api.example.com/")
    }

    @Test func hostRulesParse() throws {
        #expect(try AddonHostRule.parse("example.com") == AddonHostRule(wildcard: false, host: "example.com", port: nil, scheme: nil))
        #expect(try AddonHostRule.parse("*.example.com:8443") == AddonHostRule(wildcard: true, host: "example.com", port: 8443, scheme: nil))
        #expect(try AddonHostRule.parse("http://localhost:3000").scheme == "http")
        #expect(try AddonHostRule.parse("https://203.0.113.7").host == "203.0.113.7")
        for bad in ["Example.com", "http://example.com", "http://*.localhost", "*.com", "example.com:0", "example.com:70000",
                    "example.com:", "-x.example.com", "exa mple.com", "", "*.", "example..com"] {
            #expect(throws: AddonProblem.self, "\(bad)") { try AddonHostRule.parse(bad) }
        }
    }

    @Test func hostRulesAllow() throws {
        let rules = try ["api.example.com", "*.example.org", "127.0.0.1:8080", "localhost"].map(AddonHostRule.parse)
        func allows(_ text: String) -> Bool { URL(string: text).map { AddonHostRule.allows($0, rules: rules) } ?? false }
        #expect(allows("https://api.example.com/v1"))
        #expect(allows("https://API.example.com/v1"))
        #expect(!allows("http://api.example.com/v1"), "https only")
        #expect(!allows("https://example.com/"))
        #expect(!allows("https://evil-api.example.com/"))
        #expect(allows("https://a.b.example.org/"))
        #expect(!allows("https://example.org/"), "a wildcard needs a label in front")
        #expect(!allows("https://xexample.org/"))
        #expect(allows("http://127.0.0.1:8080/"))
        #expect(!allows("http://127.0.0.1:8081/"))
        #expect(allows("http://localhost:9999/"))
        #expect(!allows("ftp://api.example.com/"))
        #expect(!allows("javascript:alert(1)"))
        let explicit = try AddonHostRule.parse("https://api.example.com")
        #expect(!explicit.matches(try #require(URL(string: "http://api.example.com/"))))
    }
}

@Suite struct AddonsBundleTests {
    @Test func aGoodBundleVerifies() throws {
        let pair = served()
        let bundle = try AddonBundle.verify(pair.0, sha256: pair.1.uppercased(), id: "com.example.sidebar", version: "1.2.3", slot: "agent-sidebar")
        #expect(bundle.sha256 == pair.1)
        #expect(bundle.files.map(\.path) == ["app.js", "index.html"])
        #expect(bundle.manifest.id == "com.example.sidebar")
    }

    @Test func failuresInTheContractsOrder() {
        #expect(verify((Data(count: AddonBundle.maxServedBytes + 1), "x")) == "too_large")
        #expect(verify((served().0, String(repeating: "0", count: 64))) == "sha256")
        #expect(verify(served(format: "copper-addon-bundle/2")) == "format")
        #expect(verify(served(manifest { $0["version"] = "1.0" })) == "manifest")
        #expect(verify(served(), version: "1.2.4") == "mismatch")
        #expect(verify(served(), id: "com.example.other") == "mismatch")
        #expect(verify(served(files: [("index.html", Data("x".utf8)), ("../up.js", Data())])) == "path")
        #expect(verify(served(files: [("index.html", Data("x".utf8)), ("a b.js", Data())])) == "path")
        #expect(verify(served(tamper: { $0[0]["sha256"] = String(repeating: "a", count: 64) })) == "file")
        #expect(verify(served(tamper: { $0[0]["size"] = 1 })) == "file")
        #expect(verify(served(tamper: { $0[0]["data"] = "!!" })) == "file")
        #expect(verify(served(files: [("index.html", Data("x".utf8)), ("App.js", Data()), ("app.js", Data())])) == "file", "case-folded twice")
        #expect(verify(served(files: [("index.html", Data("x".utf8)), ("a", Data()), ("a/b.js", Data())])) == "file", "file and folder")
        #expect(verify(served(files: [("main.html", Data("x".utf8))])) == "entry")
        #expect(verify(served(files: (0...AddonBundle.maxFiles).map { ("f\($0).txt", Data()) } + [("index.html", Data())])) == "too_many_files")
    }

    @Test func unpackingIsWholeAndIdempotent() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try AddonBundle.parse(served(files: [("index.html", Data("<p>".utf8)), ("js/app.js", Data("1".utf8))]).0)
        let folder = root.appendingPathComponent("bundles/com.example.sidebar/\(bundle.sha256)", isDirectory: true)
        try bundle.write(to: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("js/app.js"), encoding: .utf8) == "1")
        try bundle.write(to: folder)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        #expect(leftovers == [bundle.sha256], "no .tmp- sibling left behind")
    }
}

@Suite struct AddonsStateTests {
    private func resolved(_ addons: [[String: Any]], revision: String = "r_1") -> AddonResolvedSet {
        let data = (try? JSONSerialization.data(withJSONObject: ["revision": revision, "addons": addons])) ?? Data()
        return AddonResolvedSet.parse(data) ?? .empty
    }

    private func entry(sha: String = "aa", version: String = "1.0.0", settings: [String: Any] = [:], id: String = "com.example.sidebar",
                       platforms: [String]? = nil, bridge: Int = 1) -> [String: Any] {
        var out: [String: Any] = ["id": id, "slot": "agent-sidebar", "name": "Example", "version": version, "sha256": sha, "size": 10,
                                  "entry": "index.html", "bridge": bridge, "settings": settings,
                                  "permissions": ["hosts": ["api.example.com"], "capabilities": ["fetch"]],
                                  "bundle": "/v1/addons/\(id)/bundle/\(sha)"]
        if let platforms { out["platforms"] = platforms }
        return out
    }

    private func installed(sha: String = "aa", settings: [String: Any] = [:]) -> AddonInstalled? {
        guard let resolved = AddonResolved(entry(sha: sha, settings: settings)) else { return nil }
        return AddonInstalled(resolved, dir: "bundles/com.example.sidebar/\(sha)", source: "cloud.example.com")
    }

    @Test func aNewAddonIsStaged() {
        let plan = AddonPlan.make(AddonState(), resolved([entry()]))
        #expect(plan.stage.map(\.sha256) == ["aa"])
        #expect(plan.remove.isEmpty && plan.settings.isEmpty)
    }

    @Test func aNewVersionIsStagedAndTheOldOneKept() throws {
        var state = AddonState()
        state.installed["agent-sidebar"] = try #require(installed())
        let plan = AddonPlan.make(state, resolved([entry(sha: "bb", version: "1.1.0")]))
        #expect(plan.stage.map(\.sha256) == ["bb"])
        #expect(plan.remove.isEmpty)
    }

    @Test func settingsAloneApplyAtOnce() throws {
        var state = AddonState()
        state.installed["agent-sidebar"] = try #require(installed(settings: ["a": 1]))
        #expect(AddonPlan.make(state, resolved([entry(settings: ["a": 1])])).isEmpty)
        let plan = AddonPlan.make(state, resolved([entry(settings: ["a": 2])]))
        #expect(plan.settings == [.agentSidebar])
        #expect(plan.stage.isEmpty)
    }

    @Test func goneFromTheCloudIsRemovedAtOnce() throws {
        var state = AddonState()
        state.installed["agent-sidebar"] = try #require(installed())
        state.setPending(try #require(installed(sha: "bb")), for: .agentSidebar)
        let plan = AddonPlan.make(state, resolved([]))
        #expect(plan.remove == [.agentSidebar])
        #expect(plan.dropPending == [.agentSidebar])
    }

    @Test func addonsThatCantRunHereAreSkipped() {
        #expect(AddonPlan.make(AddonState(), resolved([entry(platforms: ["linux"])])).isEmpty)
        #expect(AddonPlan.make(AddonState(), resolved([entry(bridge: 2)])).isEmpty)
        #expect(AddonPlan.make(AddonState(), resolved([entry(platforms: ["linux"]), entry(sha: "cc", platforms: ["mac"])])).stage.map(\.sha256) == ["cc"])
        var other = entry()
        other["slot"] = "toolbar"
        #expect(AddonPlan.make(AddonState(), resolved([other])).isEmpty)
    }

    @Test func resolvedIsReadLeniently() {
        let set = resolved([entry(), ["id": "x"], ["nonsense": true]])
        #expect(set.revision == "r_1")
        #expect(set.addons.count == 1)
        #expect(AddonResolvedSet.parse(Data("[]".utf8)) == nil)
        #expect(set.addons.first?.bundlePath == "/v1/addons/com.example.sidebar/bundle/aa")
        var odd = entry()
        odd["bundle"] = "https://elsewhere.example.net/steal"
        #expect(resolved([odd]).addons.first?.bundlePath == "/v1/addons/com.example.sidebar/bundle/aa")
    }

    @Test func stateJSONHasTheContractsShape() throws {
        var state = AddonState()
        state.revision = "r_9"
        state.installed["agent-sidebar"] = try #require(installed(settings: ["k": "v"]))
        state.disabled = ["com.example.other"]
        state.lastCheck = "2026-10-19T12:00:00Z"
        let data = try JSONEncoder().encode(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["pending"] is NSNull, "pending is null, not missing")
        #expect(object["last_check"] as? String == "2026-10-19T12:00:00Z")
        let slot = try #require((object["installed"] as? [String: Any])?["agent-sidebar"] as? [String: Any])
        for key in ["id", "version", "sha256", "dir", "settings", "installed_at"] { #expect(slot[key] != nil, "\(key)") }
        #expect(try JSONDecoder().decode(AddonState.self, from: data) == state)
    }

    @Test func anotherPlatformsStateJSONReads() throws {
        let text = """
        {"schema":1,"revision":"r_1","installed":{"agent-sidebar":{"id":"com.example.sidebar","version":"1.0.0","sha256":"aa",
        "dir":"bundles/com.example.sidebar/aa","settings":{"x":[1,true,null]},"installed_at":"2026-10-19T12:00:00Z"}},
        "pending":null,"disabled":["com.example.sidebar"],"last_check":"2026-10-19T12:00:00Z"}
        """
        let state = try JSONDecoder().decode(AddonState.self, from: Data(text.utf8))
        #expect(state.installed["agent-sidebar"]?.sha256 == "aa")
        #expect(state.pending == nil)
        #expect(state.active(.agentSidebar) == nil, "turned off on this Mac")
        #expect((state.installed["agent-sidebar"]?.settings.object["x"] as? [Any])?.count == 3)
    }

    @Test func theStoreWritesAtomicallyAndSetsAsideWhatItCantRead() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AddonStore(root: root)
        var state = AddonState()
        state.revision = "r_2"
        try store.save(state)
        #expect(store.load().revision == "r_2")
        try Data("{not json".utf8).write(to: store.stateFile)
        #expect(store.load() == AddonState())
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("state.unreadable-") })
    }
}

@Suite struct AddonsFenceTests {
    @Test func theCSPGoesFirstInHead() {
        let meta = AddonCSP.meta
        #expect(AddonCSP.inject("<html><head><title>t</title></head></html>") == "<html><head>\(meta)<title>t</title></head></html>")
        #expect(AddonCSP.inject("<HTML><HEAD lang=en><script src=a.js></script>").hasPrefix("<HTML><HEAD lang=en>\(meta)<script"))
        #expect(AddonCSP.inject("<html><body><header>x</header></body></html>") == "<html><head>\(meta)</head><body><header>x</header></body></html>")
        #expect(AddonCSP.inject("<header>x</header><head></head>") == "<header>x</header><head>\(meta)</head>")
        #expect(AddonCSP.inject("<p>bare</p>") == "<head>\(meta)</head><p>bare</p>")
        #expect(AddonCSP.policy.contains("connect-src 'none'"))
    }

    @Test func theSchemeServesOnlyTheBundle() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        try Data("<html><head></head><body>hi</body></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("1".utf8).write(to: folder.appendingPathComponent("js/app.js"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("secret.txt"))
        func answer(_ text: String) throws -> AddonFiles.Answer {
            AddonFiles.answer(try #require(URL(string: text)), id: "com.example.sidebar", folder: folder, entry: "index.html")
        }
        let home = try answer("copper-addon://com.example.sidebar/")
        #expect(home.status == 200)
        #expect(home.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(home.headers["Content-Security-Policy"] == AddonCSP.policy)
        #expect(home.headers["X-Content-Type-Options"] == "nosniff")
        #expect(String(decoding: home.body, as: UTF8.self).contains(AddonCSP.meta))
        let script = try answer("copper-addon://com.example.sidebar/js/app.js?v=1")
        #expect(script.status == 200 && script.headers["Content-Type"] == "text/javascript; charset=utf-8" && script.body == Data("1".utf8))
        for refused in ["copper-addon://com.example.sidebar/missing.js", "copper-addon://com.example.sidebar/../secret.txt",
                        "copper-addon://com.example.sidebar/%2e%2e/secret.txt", "copper-addon://com.example.sidebar/link.txt",
                        "copper-addon://com.example.other/index.html", "https://com.example.sidebar/index.html",
                        "copper-addon://com.example.sidebar/js"] {
            #expect(try answer(refused).status == 404, "\(refused)")
        }
        #expect(AddonFiles.type(of: "a.woff2") == "font/woff2")
        #expect(AddonFiles.type(of: "a.unknown") == "application/octet-stream")
    }

    @Test func navigationStaysHome() throws {
        func decide(_ text: String, link: Bool = false) -> AddonNavigation {
            AddonNavigation.decide(URL(string: text), id: "com.example.sidebar", linkActivated: link)
        }
        #expect(decide("copper-addon://com.example.sidebar/page.html") == .allow)
        #expect(decide("copper-addon://com.example.other/") == .cancel)
        #expect(decide("https://example.com/") == .cancel, "a script moving the page")
        #expect(decide("https://example.com/", link: true) == .openInTab(try #require(URL(string: "https://example.com/"))))
        #expect(decide("javascript:alert(1)", link: true) == .cancel)
        #expect(decide("file:///etc/passwd", link: true) == .cancel)
        #expect(AddonNavigation.decide(nil, id: "x.y", linkActivated: true) == .cancel)
    }

    @Test func storageKeepsItsLimits() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data/com.example.sidebar/storage.json")
        let storage = AddonStorage(file: file)
        try storage.set("a", ["n": 1])
        try storage.set("b", "text")
        #expect(storage.keys() == ["a", "b"])
        try storage.remove("b")
        #expect(try storage.get("b") is NSNull)
        let again = AddonStorage(file: file)
        #expect((try again.get("a") as? [String: Any])?["n"] as? Int == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(throws: AddonBridgeError.self) { try storage.set(String(repeating: "k", count: 129), 1) }
        #expect(throws: AddonBridgeError.self) { try storage.set("", 1) }
        #expect(throws: AddonBridgeError.self) { try storage.set("big", String(repeating: "x", count: AddonStorage.maxBytes)) }
        #expect(storage.keys() == ["a"], "a refused write changes nothing")
    }

    @Test func fetchSendsOnlyWhatItMay() throws {
        let rules = try ["api.example.com", "127.0.0.1:8080"].map(AddonHostRule.parse)
        func code(_ params: [String: Any]) -> String? {
            do { _ = try AddonFetch.request(params, rules: rules); return nil } catch let e as AddonBridgeError { return e.code } catch { return "other" }
        }
        #expect(code(["url": "https://elsewhere.example.com/"]) == "denied")
        #expect(code(["url": "http://api.example.com/"]) == "denied")
        #expect(code(["url": "relative/path"]) == "bad_request")
        #expect(code(["url": "https://api.example.com/", "method": "TRACE"]) == "bad_request")
        #expect(code(["url": "https://api.example.com/", "method": "POST", "body": String(repeating: "x", count: AddonFetch.maxBody + 1)]) == "bad_request")
        let request = try AddonFetch.request(["url": "https://api.example.com/v1", "method": "post", "body": "{}", "timeoutMs": 999_999,
                                              "headers": ["Authorization": "Bearer t", "Cookie": "s=1", "Host": "evil.example.com", "X-N": 5]],
                                             rules: rules)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.timeoutInterval == 120)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
        #expect(request.value(forHTTPHeaderField: "X-N") == nil, "header values are strings")
        #expect(try AddonFetch.request(["url": "http://127.0.0.1:8080/x"], rules: rules).timeoutInterval == 30)
    }

    @MainActor @Test func oauthRedirectPrefixes() throws {
        let rules = try ["login.example.com"].map(AddonHostRule.parse)
        #expect(AddonOAuth.validPrefix("http://127.0.0.1:53682/callback", rules: rules))
        #expect(AddonOAuth.validPrefix("http://localhost:8765/", rules: rules))
        #expect(AddonOAuth.validPrefix("https://login.example.com/done", rules: rules))
        #expect(!AddonOAuth.validPrefix("http://127.0.0.1/callback", rules: rules), "loopback needs a port")
        #expect(!AddonOAuth.validPrefix("http://login.example.com/done", rules: rules))
        #expect(!AddonOAuth.validPrefix("https://elsewhere.example.com/", rules: rules))
        #expect(!AddonOAuth.validPrefix("copper://x", rules: rules))
    }

    @MainActor @Test func agentItemsInTheBridgesShape() {
        let user = AddonBridge.item(Agent.Item(kind: .user, text: "hi"))
        #expect(user["role"] as? String == "user" && user["text"] as? String == "hi")
        #expect((user["id"] as? String) == (user["id"] as? String)?.lowercased())
        #expect((user["at"] as? String)?.hasSuffix("Z") == true)
        #expect(AddonBridge.item(Agent.Item(kind: .assistant, text: "a"))["role"] as? String == "assistant")
        #expect(AddonBridge.item(Agent.Item(kind: .assistant, text: "a", aside: true))["role"] as? String == "activity")
        let tool = AddonBridge.item(Agent.Item(kind: .tool, text: "3 tabs", tool: "list_tabs", running: true, title: "Listed tabs"))
        #expect(tool["role"] as? String == "activity" && tool["text"] as? String == "Listed tabs" && tool["detail"] as? String == "3 tabs")
        #expect(tool["busy"] as? Bool == true)
        #expect(AddonBridge.item(Agent.Item(kind: .note, text: "x", ok: false))["role"] as? String == "error")
        #expect(AddonBridge.item(Agent.Item(kind: .drive, text: "x"))["role"] as? String == "drive")
    }
}
