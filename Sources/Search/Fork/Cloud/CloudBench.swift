import AppKit
import Foundation

// `./bench cloud …` — drive Copper Cloud from a script, so two probe worlds
// can be linked, signed in and synced end to end without a click:
//
//   cloud status                     link, account, sync switches, state, devices (no secrets)
//   cloud link CODE                  connect with a link code (or http://127.0.0.1:PORT/#k=KEY)
//   cloud signup EMAIL PW NAME       create the account and sign in
//   cloud signin EMAIL PW            sign in
//   cloud signout | disconnect
//   cloud pair CODE [--trust FP] [--sync DOMAINS|none]
//                                    link + sign in with a pairing code (the whole
//                                    copper-cloud://…#p=… or, already linked, a bare cp_…),
//                                    then turn on sync as the page does (all, unless --sync)
//   cloud sso [CODE] [--trust FP] [--sync DOMAINS|none] [--follow]
//                                    single sign-on with a join link (copper-cloud://…#sso=google&fp=…)
//                                    or the linked instance: opens the system browser (--follow: Copper
//                                    fetches the provider page itself, for a test server) and answers
//                                    when signed in, failed, cancelled or timed out (5 min)
//   cloud sso discover [CODE]        what GET /v1/auth/sso offers; `cloud sso cancel` | `cloud sso state`
//   cloud pairing-code               signed in: mint a code for another Mac → {id, code, link, expiresAt}
//   cloud pairing-codes              my codes still open
//   cloud revoke-pairing ID          revoke one (ID from pairing-codes, or `current`)
//   cloud sync on DOMAINS            "Turn on sync" with these (spaces,settings,bookmarks,tabs,history | all)
//   cloud sync off | now
//   cloud devices                    other devices' open tabs
//   cloud doc DOMAIN                 this Mac's document for DOMAIN, as it would be pushed
//   cloud log                        the last lines of the log
//   cloud history-limits [ENTRY BATCH]
//                                    what a history push believes the cloud takes; with numbers
//                                    (test worlds only) believe those until /v1/info is read again
//   cloud selftest                   the pure parts: link codes, the settings allowlist, merges,
//                                    history pushes against a pretend cloud (CloudHistory)
//   cloud bookmark URL [TITLE]       test worlds only: add a bookmark
//   cloud pin URL                    test worlds only: open URL as a pinned tab
//   cloud open URL                   test worlds only: open URL as an ordinary tab
//   cloud picture PATH [dark] [CODE] the whole Cloud page as a PNG, for a look at it; CODE pre-fills Connect
//   cloud wstest                     a canvas WebSocket through the pinned session: open, frames, close
//
// Passwords given here are used once and never echoed back.

@MainActor
enum CloudBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "status"
        let words = (request["arg"] as? String ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let cloud = Cloud.shared
        let sync = CloudSync.shared

        func run(_ body: @escaping () async throws -> Void) {
            Task { @MainActor in
                do {
                    try await body()
                    answer(status())
                } catch {
                    var out = status()
                    out["error"] = error.localizedDescription
                    if let failure = error as? Cloud.Failure { out["code"] = failure.code; out["status"] = failure.status }
                    answer(out)
                }
            }
        }

        switch op {
        case "status":
            answer(status())
        case "link":
            if let code = words.first, case .pairing? = Cloud.parseCode(code) {
                return answer(["error": "That's a pairing code (#p=) — use `cloud pair CODE`, which links and signs in"])
            }
            guard let code = words.first, let link = Cloud.parseLinkCode(code) else { return answer(["error": "usage: cloud link CODE (copper-cloud://HOST:PORT/#k=KEY&fp=HEX)"]) }
            run { try await cloud.connect(link) }
        case "signup":
            guard words.count >= 3 else { return answer(["error": "usage: cloud signup EMAIL PASSWORD NAME"]) }
            run { try await cloud.signUp(email: words[0], password: words[1], displayName: words[2...].joined(separator: " ")) }
        case "signin":
            guard words.count >= 2 else { return answer(["error": "usage: cloud signin EMAIL PASSWORD"]) }
            run { try await cloud.signIn(email: words[0], password: words[1]) }
        case "signout":
            run {
                await sync.signingOut()
                await cloud.signOut()
            }
        case "disconnect":
            sync.turnOff()
            cloud.disconnect()
            answer(status())
        case "pair":
            pair(words, answer: answer)
        case "sso":
            sso(words, in: browser, answer: answer)
        case "pairing-code":
            Task { @MainActor in
                do {
                    let minted = try await CloudPairing.shared.mint()
                    answer(["id": minted.id.uuidString.lowercased(), "code": minted.code, "link": minted.link,
                            "expiresAt": CloudSync.stamp(minted.expiresAt),
                            "expiresIn": Int(minted.expiresAt.timeIntervalSinceNow.rounded())])
                } catch {
                    answer(failure(error))
                }
            }
        case "pairing-codes":
            Task { @MainActor in
                do {
                    let codes = try await cloud.pairingCodes()
                    await CloudPairing.shared.check()
                    answer(["codes": codes.map { code -> [String: Any] in
                        ["id": code.id.uuidString.lowercased(),
                         "deviceName": code.deviceName ?? NSNull(),
                         "createdAt": code.createdAt.map(CloudSync.stamp) ?? NSNull(),
                         "expiresAt": CloudSync.stamp(code.expiresAt),
                         "usedAt": code.usedAt.map(CloudSync.stamp) ?? NSNull(),
                         "current": code.id == CloudPairing.shared.current?.id]
                    }])
                } catch {
                    answer(failure(error))
                }
            }
        case "revoke-pairing":
            let raw = words.first ?? ""
            let id = raw == "current" ? CloudPairing.shared.current?.id : UUID(uuidString: raw)
            guard let id else { return answer(["error": "usage: cloud revoke-pairing ID|current (IDs from cloud pairing-codes)"]) }
            Task { @MainActor in
                do {
                    if id == CloudPairing.shared.current?.id, CloudPairing.shared.outcome == nil {
                        await CloudPairing.shared.revoke()
                        if let problem = CloudPairing.shared.problem { throw Cloud.Failure(status: 0, code: "revoke", message: problem) }
                    } else {
                        try await cloud.revokePairingCode(id)
                    }
                    answer(["revoked": id.uuidString.lowercased()])
                } catch {
                    answer(failure(error))
                }
            }
        case "sync":
            switch words.first ?? "now" {
            case "on":
                let list = words.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }
                let domains: Set<CloudSync.Domain> = list.contains("all") || list.isEmpty
                    ? Set(CloudSync.Domain.allCases)
                    : Set(list.compactMap(CloudSync.Domain.init(rawValue:)))
                guard !domains.isEmpty else { return answer(["error": "usage: cloud sync on spaces,settings,bookmarks,tabs,history|all"]) }
                run { await sync.turnOn(domains) }
            case "off":
                sync.turnOff()
                answer(status())
            case "now":
                run { await sync.syncNow() }
            case "set":
                // cloud sync set DOMAIN on|off
                guard words.count == 3, let domain = CloudSync.Domain(rawValue: words[1]) else { return answer(["error": "usage: cloud sync set DOMAIN on|off"]) }
                sync.set(domain, words[2] == "on")
                answer(status())
            default:
                answer(["error": "usage: cloud sync on DOMAINS | off | now | set DOMAIN on|off"])
            }
        case "devices":
            run {
                await sync.refreshDevices()
            }
        case "doc":
            guard let domain = words.first.flatMap(CloudSync.Domain.init(rawValue:)) else { return answer(["error": "usage: cloud doc spaces|settings|bookmarks|tabs|history"]) }
            answer(["domain": domain.rawValue, "doc": sync.preview(domain) ?? NSNull()])
        case "log":
            answer(["log": sync.log.suffix(60).map { "\(CloudSync.stamp($0.at)) \($0.text)" }])
        case "selftest":
            Task { answer(await CloudSelfTest.run()) }
        case "history-limits":
            // A stale belief, on purpose: the push then meets the cloud's own
            // refusals (400 at most N / entry I exceeds N) and must learn from them.
            if words.count == 2, let entry = Int(words[0]), let batch = Int(words[1]), entry > 0, batch > 0 {
                guard Store.testing else { return answer(["error": "test worlds only"]) }
                cloud.historyLimits = CloudHistory.Limits(entryBytes: entry, batch: min(batch, CloudHistory.most), requestBytes: max(1 << 20, entry + 64))
            } else if !words.isEmpty {
                return answer(["error": "usage: cloud history-limits [ENTRY_BYTES BATCH]"])
            }
            answer(["historyLimits": cloud.historyLimits.map { ["entryBytes": $0.entryBytes, "batch": $0.batch, "requestBytes": $0.requestBytes] } ?? NSNull()])
        case "bookmark":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud bookmark URL [TITLE]"]) }
            browser.bookmarks.add(url, title: words.dropFirst().joined(separator: " "))
            answer(["bookmarks": Bookmarks.count(browser.bookmarks.roots)])
        case "wstest":
            // cloud wstest — open the first canvas's WebSocket through the pinned
            // session, wait for the server's first frame (y-sync step 1), close.
            Task { @MainActor in
                struct Canvas: Decodable { var id: UUID; var name: String }
                do {
                    let list: [Canvas] = try await cloud.requestJSON("GET", "/v1/canvases")
                    guard let canvas = list.first else { return answer(["error": "no canvas on this account"]) }
                    let socket = cloud.socket(path: "/v1/canvases/\(canvas.id.uuidString.lowercased())/ws")
                    var frames = 0, bytes = 0, opened = false
                    socket.onOpen = { opened = true }
                    socket.onData = { data in
                        frames += 1
                        bytes += data.count
                        if frames == 1 { socket.send(Data([0, 0, 1, 0])) } // y-sync step 1 with an empty state vector
                        if frames >= 2 { socket.close() }
                    }
                    socket.onClose = { error in
                        socket.onData = nil
                        socket.onOpen = nil
                        answer(["canvas": canvas.name, "opened": opened, "open": socket.isOpen, "frames": frames, "bytes": bytes,
                                "closedWith": error.map { $0.localizedDescription } ?? "close()"])
                    }
                    socket.connect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { socket.close() }
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        case "picture":
            // cloud picture PATH [dark] [CODE] — the whole Cloud page, laid out
            // off screen; CODE starts the Connect field with it (not linked yet).
            guard let path = words.first else { return answer(["error": "usage: cloud picture PATH [dark] [CODE]"]) }
            let rest = words.dropFirst()
            let draft = rest.first { $0 != "dark" } ?? ""
            guard let picture = SettingsPicture.draw(CloudPage(browser: browser, draft: draft), dark: rest.contains("dark")),
                  let png = picture.representation(using: .png, properties: [:]) else { return answer(["error": "could not draw the page"]) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return answer(["error": error.localizedDescription]) }
            answer(["path": path, "size": [picture.pixelsWide, picture.pixelsHigh]])
        case "open":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud open URL"]) }
            _ = browser.open(url, foreground: false, atEnd: true)
            answer(["opened": url.absoluteString, "tabs": browser.tabs.count])
        case "pin":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud pin URL"]) }
            let tab = browser.open(url, foreground: false, atEnd: true)
            browser.pin(tab)
            answer(["pinned": url.absoluteString, "pins": browser.pinnedCount])
        default:
            answer(["error": "unknown cloud op \(op) — status|link|pair|sso|pairing-code|pairing-codes|revoke-pairing|signup|signin|signout|disconnect|sync|devices|doc|log|history-limits|selftest|wstest|picture"])
        }
    }

    /// `cloud pair CODE [--trust FP] [--sync DOMAINS|none]`.
    private static func pair(_ words: [String], answer: @escaping ([String: Any]) -> Void) {
        let usage = "usage: cloud pair CODE [--trust FINGERPRINT] [--sync DOMAINS|all|none] — CODE is copper-cloud://HOST:PORT/#p=cp_…&fp=…, or a bare cp_… when already linked"
        var text: String?
        var trust: String?
        var domains: Set<CloudSync.Domain>? = nil
        var skipSync = false
        var i = 0
        while i < words.count {
            switch words[i] {
            case "--trust":
                guard i + 1 < words.count else { return answer(["error": usage]) }
                trust = words[i + 1]; i += 2
            case "--sync":
                guard i + 1 < words.count else { return answer(["error": usage]) }
                let list = words[i + 1].split(separator: ",").map(String.init)
                if list == ["none"] { skipSync = true }
                else if !list.contains("all") {
                    domains = Set(list.compactMap(CloudSync.Domain.init(rawValue:)))
                    if domains?.isEmpty == true { return answer(["error": usage]) }
                }
                i += 2
            default:
                if text == nil { text = words[i] } else { return answer(["error": usage]) }
                i += 1
            }
        }
        guard let text else { return answer(["error": usage]) }
        let parsed = Cloud.parseCode(text, linkedTo: Cloud.shared.link)
        guard case .pairing(let code)? = parsed else {
            if case .link? = parsed { return answer(["error": "That's a link code (#k=), not a pairing code — use `cloud link`"]) }
            if Cloud.isBarePairingCode(text) { return answer(["error": "A bare pairing code needs this Copper linked already — give the whole copper-cloud://…#p=… code"]) }
            return answer(["error": usage])
        }
        Task { @MainActor in
            do {
                if skipSync {
                    try await Cloud.shared.pair(code, trusting: trust)
                } else {
                    try await CloudPairing.pairAndSync(code, trusting: trust, domains: domains)
                }
                answer(status())
            } catch {
                answer(failure(error))
            }
        }
    }

    /// `cloud sso [CODE] [--trust FP] [--sync DOMAINS|none] [--follow]`,
    /// `cloud sso discover [CODE]`, `cloud sso cancel`, `cloud sso state`.
    private static func sso(_ words: [String], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let usage = "usage: cloud sso [CODE] [--trust FINGERPRINT] [--sync DOMAINS|all|none] [--follow] | cloud sso discover [CODE] | cloud sso cancel | cloud sso state — CODE is copper-cloud://HOST:PORT/#sso=google&fp=…; without one, the linked instance"
        let flow = CloudSSO.shared
        func phase() -> [String: Any] {
            var out = status()
            switch flow.phase {
            case .idle: out["sso"] = "idle"
            case .starting: out["sso"] = "starting"
            case .waiting(let name): out["sso"] = "waiting"; out["provider"] = name
            case .finishing: out["sso"] = "finishing"
            case .failed(let text): out["sso"] = "failed"; out["error"] = text
            }
            if let seen = flow.seen { out["seen"] = seen }
            return out
        }
        var rest = words
        let verb = rest.first.flatMap { ["discover", "cancel", "state"].contains($0) ? $0 : nil }
        if verb != nil { rest.removeFirst() }
        if verb == "cancel" { flow.cancel(); return answer(phase()) }
        if verb == "state" { return answer(phase()) }
        var text: String?
        var trust: String?
        var domains: Set<CloudSync.Domain>? = nil
        var skipSync = false
        var follow = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--trust":
                guard i + 1 < rest.count else { return answer(["error": usage]) }
                trust = rest[i + 1]; i += 2
            case "--sync":
                guard i + 1 < rest.count else { return answer(["error": usage]) }
                let list = rest[i + 1].split(separator: ",").map(String.init)
                if list == ["none"] { skipSync = true }
                else if !list.contains("all") {
                    domains = Set(list.compactMap(CloudSync.Domain.init(rawValue:)))
                    if domains?.isEmpty == true { return answer(["error": usage]) }
                }
                i += 2
            case "--follow":
                follow = true; i += 1
            default:
                if text == nil { text = rest[i] } else { return answer(["error": usage]) }
                i += 1
            }
        }
        let target: CloudSSO.Target
        if let text {
            guard case .sso(let code)? = Cloud.parseCode(text) else {
                return answer(["error": "That isn't a join link (copper-cloud://…#sso=…) — " + usage])
            }
            target = CloudSSO.Target(code)
        } else if let link = Cloud.shared.link {
            target = CloudSSO.Target(link, provider: nil)
        } else {
            return answer(["error": "Not linked — give a join link. " + usage])
        }
        if verb == "discover" {
            Task { @MainActor in
                do {
                    let pin = try CloudSSO.pin(target, trusting: trust)
                    let found = try await Cloud.discoverSSO(url: target.url, pin: pin)
                    answer(["enabled": found.enabled, "passwordSignin": found.passwordSignin,
                            "providers": found.providers.map { ["id": $0.id, "kind": $0.kind, "name": $0.name, "domains": $0.domains, "hd": $0.hd ?? NSNull(),
                                                                "authorizationEndpoint": $0.authorizationEndpoint] as [String: Any] }])
                } catch {
                    answer(failure(error))
                }
            }
            return
        }
        // --follow: Copper fetches the provider's page itself and follows its
        // redirect back — for a pretend provider that answers at once
        // (a test server); without it, the system browser, for a person.
        let open: ((URL) -> Bool)? = follow ? { url in
            Task.detached { _ = try? await URLSession.shared.data(from: url) }
            return true
        } : nil
        flow.start(target, trusting: trust, domains: domains, sync: !skipSync, in: browser, open: open)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(CloudSSO.timeout + 30)
            while flow.busy, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            answer(phase())
        }
    }

    /// `status()` with the error said, its code, and — for `untrusted` — the
    /// fingerprint the server showed (pass it back with `--trust`).
    private static func failure(_ error: Error) -> [String: Any] {
        var out = status()
        out["error"] = error.localizedDescription
        if let failure = error as? Cloud.Failure {
            out["code"] = failure.code
            out["status"] = failure.status
            if let seen = failure.seen {
                out["seen"] = seen
                // The bench prints only the error: say the fingerprint in it.
                out["error"] = "\(failure.message) It showed \(Cloud.pairs(seen)) — `cloud pair CODE --trust \(seen)` trusts it."
            }
        }
        return out
    }

    static func status() -> [String: Any] {
        let cloud = Cloud.shared
        var out: [String: Any] = [
            "linked": cloud.isLinked,
            "signedIn": cloud.isSignedIn,
            "reachable": cloud.reachable,
            "deviceId": cloud.deviceId.uuidString.lowercased(),
            "deviceName": cloud.deviceName,
        ]
        if let link = cloud.link {
            out["host"] = link.host
            out["url"] = link.url.absoluteString
            out["fingerprint"] = link.fingerprint ?? NSNull()
            out["serverVersion"] = cloud.serverVersion ?? NSNull()
            out["shareLinks"] = cloud.supports(.shareLinks) ?? NSNull()
        }
        if let account = cloud.account {
            out["email"] = account.email
            out["displayName"] = account.displayName
            out["userId"] = account.userId.uuidString.lowercased()
        }
        // The code this Copper is showing, never the code itself.
        if let shown = CloudPairing.shared.current {
            var pairing: [String: Any] = ["id": shown.id.uuidString.lowercased(), "expiresAt": CloudSync.stamp(shown.expiresAt),
                                          "live": CloudPairing.shared.live != nil]
            switch CloudPairing.shared.outcome {
            case .used(let at)?: pairing["used"] = CloudSync.stamp(at)
            case .revoked?: pairing["revoked"] = true
            case .none: break
            }
            out["pairing"] = pairing
        }
        out["sync"] = CloudSync.shared.status
        out["devices"] = CloudSync.shared.otherDevices.map { device in
            ["name": device.name, "domain": device.domain,
             "updated": device.updated.map { CloudSync.stamp($0) } ?? NSNull(),
             "tabs": device.tabs.map { ["url": $0.url, "title": $0.title, "space": $0.space.map { $0 as Any } ?? NSNull()] as [String: Any] }] as [String: Any]
        }
        return out
    }
}

/// The pure parts, checked with made-up inputs. The package has no test
/// target; this is what `bench cloud selftest` runs instead.
@MainActor
enum CloudSelfTest {
    static func run() async -> [String: Any] {
        var failures: [String] = []
        var count = 0
        func check(_ ok: Bool, _ name: String) {
            count += 1
            if !ok { failures.append(name) }
        }
        let fp = String(repeating: "ab", count: 32)

        // Link codes.
        let a = Cloud.parseLinkCode("copper-cloud://cloud.example.com:8443/#k=KEY_abc-123&fp=\(fp)")
        check(a?.url.absoluteString == "https://cloud.example.com:8443" && a?.key == "KEY_abc-123" && a?.fingerprint == fp, "link: copper-cloud with fp")
        let b = Cloud.parseLinkCode("  copper-cloud://10.0.0.5:443/#k=abc\n")
        check(b?.url.absoluteString == "https://10.0.0.5:443" && b?.fingerprint == nil, "link: no fp, whitespace")
        let c = Cloud.parseLinkCode("copper-cloud://h:1/#k=x&fp=" + Array(repeating: "AB", count: 32).joined(separator: ":"))
        check(c?.fingerprint == fp, "link: colon-separated upper-case fp")
        check(Cloud.parseLinkCode("copper-cloud://h:1/#k=x&fp=1234") == nil, "link: short fp refused")
        check(Cloud.parseLinkCode("copper-cloud://h:1/") == nil, "link: no key refused")
        check(Cloud.parseLinkCode("http://evil.example.com:80/#k=x") == nil, "link: plain http off-loopback refused")
        check(Cloud.parseLinkCode("http://127.0.0.1:8443/#k=x")?.url.absoluteString == "http://127.0.0.1:8443", "link: loopback http allowed")
        check(Cloud.parseLinkCode("copper-cloud://127.0.0.1:8443/#k=x&tls=off")?.url.scheme == "http", "link: tls=off on loopback")
        check(Cloud.parseLinkCode("copper-cloud://[::1]:8443/#k=x")?.host == "[::1]:8443", "link: ipv6 host")
        check(Cloud.link(address: "cloud.example.com", key: "k", fingerprint: "")?.url.absoluteString == "https://cloud.example.com", "link: advanced fields")
        if let a { check(Cloud.parseLinkCode(a.code) == a, "link: code round trip") }
        let access = Cloud.parseLinkCode("copper-cloud://cloud.example.com:443/#k=ck_" + String(repeating: "Zz9-_", count: 8) + "&fp=\(fp)")
        check(access?.key.hasPrefix("ck_") == true && access?.fingerprint == fp, "link: an access key is a key like any other")

        // Pairing codes.
        let secret = "cp_" + String(repeating: "aB3-_", count: 6) + "xY"
        let p = Cloud.parseCode("copper-cloud://cloud.example.com:8443/#p=\(secret)&fp=\(fp)")
        if case .pairing(let code)? = p {
            check(code.url.absoluteString == "https://cloud.example.com:8443" && code.code == secret && code.fingerprint == fp, "pair: copper-cloud with fp")
            check(Cloud.parseCode(code.link) == p, "pair: code round trip")
        } else {
            check(false, "pair: copper-cloud with fp")
        }
        check(Cloud.parseLinkCode("copper-cloud://cloud.example.com:8443/#p=\(secret)&fp=\(fp)") == nil, "pair: not a link code")
        if case .link? = Cloud.parseCode(a?.code ?? "") {} else { check(false, "pair: a link code still reads as one") }
        if case .pairing(let code)? = Cloud.parseCode(" copper-cloud://[::1]:8443/#p=\(secret)\n") {
            check(code.host == "[::1]:8443" && code.fingerprint == nil, "pair: ipv6, no fp, whitespace")
        } else { check(false, "pair: ipv6, no fp, whitespace") }
        if case .pairing(let code)? = Cloud.parseCode("http://127.0.0.1:9/#p=\(secret)") {
            check(code.url.absoluteString == "http://127.0.0.1:9", "pair: loopback http")
        } else { check(false, "pair: loopback http") }
        check(Cloud.parseCode("http://evil.example.com/#p=\(secret)") == nil, "pair: plain http off-loopback refused")
        check(Cloud.parseCode("copper-cloud://h:1/#p=\(secret)&fp=12") == nil, "pair: short fp refused")
        check(Cloud.parseCode(secret) == nil, "pair: bare code needs a link")
        if let a, case .pairing(let code)? = Cloud.parseCode(secret, linkedTo: a) {
            check(code.url == a.url && code.fingerprint == a.fingerprint, "pair: bare code on the linked instance")
        } else { check(false, "pair: bare code on the linked instance") }
        check(Cloud.pairFailure(Cloud.Failure(status: 401, code: "pairing_code", message: "unauthorized")).message.contains("10 minutes"), "pair: used code said in words")
        check(CloudPairing.left(599.2) == "10:00" && CloudPairing.left(61) == "1:01" && CloudPairing.left(-3) == "0:00", "pair: countdown")

        // The settings allowlist.
        let filtered = CloudSettingsKeys.filter([
            "look": "dark", "sidebar": "true", "downloads": "/tmp", "passwords.save": "true", "bench": "true",
            "glyph": "weird", "shield": "false", "passkeys": "true", "sections.archive": "h48",
        ])
        check(filtered == ["look": "dark", "sidebar": "true", "shield": "false", "sections.archive": "h48"], "settings: allowlist + value shapes")

        // Lists, three ways.
        struct Item: Equatable { var id: String; var v: Int }
        let base = [Item(id: "a", v: 1), Item(id: "b", v: 1), Item(id: "c", v: 1)]
        let local = [Item(id: "a", v: 2), Item(id: "c", v: 1), Item(id: "d", v: 1)] // edited a, deleted b, added d
        let server = [Item(id: "a", v: 1), Item(id: "b", v: 3), Item(id: "c", v: 5), Item(id: "e", v: 1)] // edited b, c; added e
        let merged = CloudMerge.list(base: base, local: local, server: server) { $0.id }
        check(merged.first { $0.id == "a" }?.v == 2, "merge: local-only edit kept")
        check(merged.first { $0.id == "b" }?.v == 3, "merge: delete vs remote edit keeps the edit")
        check(merged.first { $0.id == "c" }?.v == 5, "merge: remote edit wins")
        check(merged.contains { $0.id == "d" } && merged.contains { $0.id == "e" }, "merge: both additions kept")
        let deleted = CloudMerge.list(base: base, local: [base[0], base[2]], server: base) { $0.id }
        check(deleted.map(\.id) == ["a", "c"], "merge: local delete sticks")
        let union = CloudMerge.list(base: nil, local: [Item(id: "x", v: 1), Item(id: "y", v: 1)], server: [Item(id: "y", v: 9)]) { $0.id }
        check(union.map(\.id) == ["y", "x"] && union[0].v == 9, "merge: first sync is a union, server wins")
        let reordered = CloudMerge.list(base: base, local: [base[2], base[0], base[1]], server: base) { $0.id }
        check(reordered.map(\.id) == ["c", "a", "b"], "merge: local reorder kept when server didn't move")

        // Settings, three ways.
        let s = CloudMerge.settings(base: .init(values: ["look": "light", "sidebar": "true"]),
                                    local: .init(values: ["look": "dark", "sidebar": "true"]),
                                    server: .init(values: ["look": "light", "sidebar": "false"]))
        check(s.values == ["look": "dark", "sidebar": "false"], "settings: each side's change kept")
        let s2 = CloudMerge.settings(base: .init(values: ["look": "light"]), local: .init(values: ["look": "dark"]), server: .init(values: ["look": "system"]))
        check(s2.values["look"] == "system", "settings: conflict, server wins")

        // Bookmarks: tree round trip, a folder moved, a site added on each side.
        let folder = UUID(), site1 = UUID(), site2 = UUID(), site3 = UUID(), site4 = UUID()
        let tree: [Bookmark] = [
            Bookmark(id: folder, title: "Work", url: nil, children: [Bookmark(id: site1, title: "One", url: "https://one.example", children: nil)]),
            Bookmark(id: site2, title: "Two", url: "https://two.example", children: nil),
        ]
        check(CloudMerge.tree(CloudMerge.flatten(tree)) == tree, "bookmarks: flatten/tree round trip")
        var mine = tree
        mine.append(Bookmark(id: site3, title: "Three", url: "https://three.example", children: nil))
        var theirs = tree
        theirs[0].children?.append(Bookmark(id: site4, title: "Four", url: "https://four.example", children: nil))
        theirs[1].title = "Two (renamed)"
        let mb = CloudMerge.bookmarks(base: .init(roots: tree), local: .init(roots: mine), server: .init(roots: theirs))
        let flat = CloudMerge.flatten(mb.roots)
        check(flat.count == 5, "bookmarks: union of additions")
        check(flat.first { $0.id == site4 }?.parent == folder, "bookmarks: addition stays in its folder")
        check(flat.first { $0.id == site2 }?.title == "Two (renamed)", "bookmarks: remote rename")
        let orphan = CloudMerge.tree([CloudMerge.Node(id: site1, parent: UUID(), title: "Lost", url: "https://x.example")])
        check(orphan.count == 1 && orphan[0].id == site1, "bookmarks: orphan surfaces at the top")
        let loop = CloudMerge.tree([CloudMerge.Node(id: folder, parent: site3, title: "A", url: nil),
                                    CloudMerge.Node(id: site3, parent: folder, title: "B", url: nil)])
        check(CloudMerge.flatten(loop).count == 2, "bookmarks: a loop is broken, nothing lost")

        // Spaces: a space deleted elsewhere takes its kept tabs.
        let home = Space(name: "Home"), work = Space(name: "Work")
        let pinA = CloudDocs.KeptTab(key: "\(work.id)|pin|a|0", space: work.id, url: "https://a.example", title: "A", pinned: true, pin: "A")
        let sb = CloudDocs.Spaces(spaces: [home, work], tabs: [pinA])
        let sm = CloudMerge.spaces(base: sb, local: sb, server: CloudDocs.Spaces(spaces: [home], tabs: [pinA]))
        check(sm.spaces == [home] && sm.tabs.isEmpty, "spaces: removed space drops its tabs")

        // Two fresh Macs, each with its own "Home": the first sync makes them one.
        let homeA = Space(name: "Home"), homeB = Space(name: "home")
        let pinB = CloudDocs.KeptTab(key: "\(homeB.id.uuidString.lowercased())|pin|b|https://b.example", space: homeB.id, url: "https://b.example", title: "B", pinned: true, pin: "B")
        let first = CloudMerge.spaces(base: nil, local: CloudDocs.Spaces(spaces: [homeB], tabs: [pinB]), server: CloudDocs.Spaces(spaces: [homeA], tabs: []))
        check(first.spaces.map(\.id) == [homeA.id] && first.tabs.first?.space == homeA.id
              && first.tabs.first?.key.hasPrefix(homeA.id.uuidString.lowercased()) == true, "spaces: same-named spaces join on first sync")

        // Folders travel with the spaces; a document without them (an older
        // build's) leaves each side's folders alone.
        let ex = CloudDocs.Folder(id: UUID(), name: "Exowatt", hue: 0.03, space: work.id, slot: nil)
        let exApps = CloudDocs.Folder(id: UUID(), name: "Exowatt › Apps", hue: 0.03, space: nil, slot: nil)
        var filed = pinA
        filed.group = exApps.id
        let fb = CloudDocs.Spaces(spaces: [home, work], tabs: [pinA], groups: [ex])
        let fm = CloudMerge.spaces(base: fb, local: fb, server: CloudDocs.Spaces(spaces: [home, work], tabs: [filed], groups: [ex, exApps]))
        check(fm.groups == [ex, exApps] && fm.tabs.first?.group == exApps.id, "spaces: folders and filing come in")
        let old = CloudMerge.spaces(base: fb, local: fb, server: CloudDocs.Spaces(spaces: [home, work], tabs: [pinA]))
        check(old.groups == [ex], "spaces: a document without folders keeps this Mac's")
        let mineFiled = CloudDocs.Spaces(spaces: [home, work], tabs: [filed], groups: [ex, exApps])
        let older = CloudMerge.spaces(base: mineFiled, local: mineFiled, server: CloudDocs.Spaces(spaces: [home, work], tabs: [pinA]))
        check(older.tabs.first?.group == exApps.id, "spaces: an older build's blank filing unfiles nothing")
        let json = try? JSONDecoder().decode(CloudDocs.Spaces.self, from: Data(#"{"v":1,"spaces":[],"tabs":[]}"#.utf8))
        check(json != nil && json?.groups == nil, "spaces: a document from before folders still reads")

        // History de-duplication.
        let now = Date()
        check(CloudMerge.sameVisit(now, now.addingTimeInterval(0.6)) && !CloudMerge.sameVisit(now, now.addingTimeInterval(1.5)), "history: same visit within 1 s")
        check(CloudSync.date(CloudSync.stamp(now)).map { abs($0.timeIntervalSince(now)) < 0.01 } == true, "history: RFC 3339 round trip")

        historyPush(check)
        await historyDelete(check)

        // Single sign-on and copper://cloud/join (CloudSSO.swift).
        for (name, ok) in CloudSSO.selfTest() { check(ok, name) }

        return ["checks": count, "passed": count - failures.count, "failures": failures]
    }

    /// History going up (CloudHistory) against a pretend copper-cloud: what
    /// 0.4.0 refuses, what 0.5.0 skips, a dropped connection. Deterministic —
    /// no network, no clock but the one given.
    private static func historyPush(_ check: (Bool, String) -> Void) {
        typealias H = CloudHistory
        let now = 2_000_000_000.0
        let start = now - 100_000
        func visits(_ count: Int, at: ((Int) -> Double)? = nil) -> [H.Visit] {
            (0..<count).map { H.Visit(key: "site\($0).example/p", url: "https://site\($0).example/p", title: "Page \($0)", at: at?($0) ?? start + Double($0) + 1) }
        }
        func fields(_ entry: Data) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any] ?? [:]
        }
        func refusal(_ message: String, _ status: Int = 400) -> Cloud.Failure {
            Cloud.Failure(status: status, code: status == 400 ? "bad_request" : "payload_too_large", message: message)
        }
        /// copper-cloud 0.4.0's checks of `POST /v1/sync/history`, in its
        /// order and words; a title with POISON in it stands for a rule this
        /// Copper doesn't know (refused without naming the entry).
        func server040(entryBytes: Int = 16_384, batch: Int = 2_000) -> ([Data]) throws -> [(index: Int, why: String)] {
            return { entries in
                if H.body(entries).count > batch * (entryBytes + 8) + 1_024 { throw refusal("payload too large", 413) }
                if entries.count > batch { throw refusal("at most \(batch) entries per request") }
                for (i, entry) in entries.enumerated() {
                    if entry.count > entryBytes { throw refusal("entry \(i) exceeds \(entryBytes) bytes") }
                    if entry.first != UInt8(ascii: "{") { throw refusal("entry \(i) must be a JSON object") }
                    let object = fields(entry)
                    if object.isEmpty { throw refusal("entry \(i): expected value") }
                    if let at = object["visited_at"] as? String, CloudSync.date(at) == nil { throw refusal("visited_at must be RFC 3339 or a Unix timestamp") }
                    if (object["title"] as? String)?.contains("POISON") == true { throw refusal("visited_at must be RFC 3339 or a Unix timestamp") }
                }
                return []
            }
        }
        struct Run {
            var stored: [[String: Any]] = []
            var error: Error?
            var resentRefused = false
        }
        /// What CloudSync's push does with the network, against `server`;
        /// `dropAt` makes that request fail as a dropped connection would.
        func drive(_ upload: H.Upload, _ server: ([Data]) throws -> [(index: Int, why: String)], dropAt: Int? = nil) -> Run {
            var run = Run()
            var refused = Set<Data>()
            while let entries = upload.next() {
                let body = H.body(entries)
                if refused.contains(body) { run.resentRefused = true }
                if upload.requests == dropAt {
                    run.error = Cloud.Failure(status: 0, code: "network", message: "dropped")
                    return run
                }
                do {
                    let rejected = try server(entries)
                    let skipped = Set(rejected.map { $0.index })
                    run.stored += entries.indices.filter { !skipped.contains($0) }.map { fields(entries[$0]) }
                    upload.accepted(rejected: rejected)
                } catch let failure as Cloud.Failure where H.refuses(failure) {
                    refused.insert(body)
                    do { try upload.refused(failure) } catch { run.error = error; return run }
                } catch {
                    run.error = error
                    return run
                }
                if upload.requests > 5_000 { run.error = refusal("runaway"); return run }
            }
            return run
        }
        func upload(_ list: [H.Visit], limits: H.Limits = .standard, from through: Double = 0, known: [String: Double] = [:]) -> H.Upload {
            H.Upload(H.plan(list, after: through, known: known, now: now, limits: limits), limits: limits, from: through, now: now)
        }
        let big = String(repeating: "a", count: 20_000)

        // The limits /v1/info gives.
        let info = H.Limits(info: ["limits": ["max_blob_bytes": 8_000_000, "max_history_batch": 100, "max_history_entry_bytes": 4_096]])
        check(info.entryBytes == 4_096 && info.batch == 100 && info.requestBytes == 100 * (4_096 + 8) + 1_024, "history: limits from /v1/info")
        check(H.Limits(info: ["limits": ["max_history_batch": 2_000, "max_history_entry_bytes": 16_384]]).batch == H.most, "history: never more than 500 a request")
        check(H.Limits(info: ["version": "0.1.0"]) == .standard, "history: no limits said, copper-cloud's own")
        check(H.number(after: "entry ", in: "entry 12 exceeds 16384 bytes") == 12
              && H.number(after: "exceeds ", in: "entry 12 exceeds 16384 bytes") == 16_384
              && H.number(after: "at most ", in: "too many entries: 900 in one request; at most 500 (see GET /v1/info limits)") == 500
              && H.number(after: "entry ", in: "too many entries: 900") == nil, "history: reading the server's refusals")

        // One entry, measured as sent.
        let plain = H.Visit(key: "a.example/x/y", url: "https://a.example/x/y?q=1", title: "A \"quoted\" title", at: start)
        if case .fits(let item) = H.item(plain, now: now, limit: 16_384) {
            let text = String(decoding: item.data, as: UTF8.self)
            check(text.contains("https://a.example/x/y?q=1") && !text.contains("\\/") && !item.shortened, "history: slashes as they are")
            check(fields(item.data)["title"] as? String == plain.title && fields(item.data)["url"] as? String == plain.url, "history: entry round trip")
            check(fields(H.body([item.data, item.data]))["entries"].map { ($0 as? [Any])?.count == 2 } == true, "history: body is {entries: […]}")
        } else { check(false, "history: slashes as they are") }
        let wordy = H.Visit(key: "b.example", url: "https://b.example/", title: String(repeating: "é", count: 40_000), at: start)
        if case .fits(let item) = H.item(wordy, now: now, limit: 16_384) {
            let title = fields(item.data)["title"] as? String ?? ""
            check(item.shortened && item.data.count <= 16_384 && item.data.count > 16_000 && title.hasSuffix("…") && title.hasPrefix("ééé"), "history: a long title is shortened to fit")
        } else { check(false, "history: a long title is shortened to fit") }
        let huge = H.Visit(key: "c.example", url: "https://c.example/?state=" + big, title: "Sign in", at: start)
        if case .tooBig(let skip) = H.item(huge, now: now, limit: 16_384) {
            check(skip.host == "c.example" && skip.bytes > 20_000, "history: an address too big is left out")
        } else { check(false, "history: an address too big is left out") }
        let later = H.Visit(key: "d.example", url: "https://d.example/", title: "", at: now + 86_400 * 365)
        let ancient = H.Visit(key: "e.example", url: "https://e.example/", title: "", at: -1e12)
        if case .fits(let a) = H.item(later, now: now, limit: 16_384), case .fits(let b) = H.item(ancient, now: now, limit: 16_384) {
            check(a.sentAt == now && b.sentAt == H.earliest
                  && (fields(b.data)["visited_at"] as? String).flatMap(CloudSync.date) != nil, "history: visited_at always a time the server reads")
        } else { check(false, "history: visited_at always a time the server reads") }

        // The wedge: 1,200 places, one with a 20 KB address and one with a
        // 40 KB title, against 0.4.0. Nothing is refused; the address is left
        // out, the title shortened, the cursor reaches the newest visit.
        var wedge = visits(1_200)
        wedge[700].url = "https://sso.example/saml?SAMLRequest=" + big
        wedge[800].title = String(repeating: "T", count: 40_000)
        let fixed = upload(wedge)
        let first = drive(fixed, server040())
        check(first.error == nil && first.stored.count == 1_199 && fixed.requests == 3, "history: an oversized place no longer wedges the push")
        check(fixed.skipped.count == 1 && fixed.skipped.first?.host == "sso.example" && fixed.shortened == 1, "history: left out and shortened, said")
        check(fixed.through == wedge[1_199].at, "history: cursor past everything dealt with")
        check(upload(wedge, from: fixed.through).next() == nil, "history: nothing sent twice")

        // A server whose limit is smaller than the one believed: it names the
        // entry and the limit; the limit is learned, nothing refused is resent.
        let stale = upload(wedge, limits: H.Limits(entryBytes: 65_536, batch: 500, requestBytes: 1 << 22))
        let second = drive(stale, server040())
        check(second.error == nil && second.stored.count == 1_199 && !second.resentRefused, "history: a named entry is skipped, the rest resent")
        check(stale.limits.entryBytes == 16_384 && stale.through == wedge[1_199].at && stale.requests <= 6, "history: the server's limit is learned")

        // Refusals that name no entry: halves until each stands alone.
        var poisoned = visits(1_200)
        for index in [300, 301, 900] { poisoned[index].title = "POISON \(index)" }
        let split = upload(poisoned)
        let third = drive(split, server040())
        let titles = Set(third.stored.compactMap { $0["title"] as? String })
        check(third.error == nil && third.stored.count == 1_197 && !titles.contains("POISON 300") && titles.contains("Page 302"), "history: unnamed refusals are found and skipped")
        check(split.skipped.count == 3 && !third.resentRefused && split.requests < 60 && split.through == poisoned[1_199].at, "history: no identical batch resent, cursor through the end")

        // All of it believed wrong (16 KB, 500 a request) against a cloud
        // taking 1 KB and 100: bodies too big (413), then an entry too big.
        var wordy2 = visits(300)
        for index in 0..<296 { wordy2[index].title = String(repeating: "long title ", count: 140) }
        for index in [296, 297] { wordy2[index].url = "https://big\(index).example/?q=" + String(repeating: "x", count: 2_048) }
        let small = upload(wordy2)
        let ninth = drive(small, server040(entryBytes: 1_024, batch: 100))
        check(ninth.error == nil && ninth.stored.count == 298 && small.skipped.count == 2 && small.shortened == 296 && !ninth.resentRefused
              && small.limits.entryBytes == 1_024 && small.limits.requestBytes <= 100 * (1_024 + 8) + 1_024 && small.through == wordy2[299].at,
              "history: a body too big is split, and the size learned")

        // "at most N entries": smaller requests, nothing skipped.
        let fewer = upload(visits(1_200))
        let fourth = drive(fewer, server040(batch: 100))
        check(fourth.error == nil && fourth.stored.count == 1_200 && fewer.skipped.isEmpty && fewer.limits.batch == 100, "history: the batch limit is learned")

        // A dropped connection: the cursor stays where what went up ends.
        let list = visits(1_200)
        let dropped = upload(list)
        let fifth = drive(dropped, server040(), dropAt: 2)
        check(fifth.error != nil && fifth.stored.count == 500 && dropped.through == list[499].at, "history: cursor stops at what went up")
        let resumed = upload(list, from: dropped.through)
        check(drive(resumed, server040()).stored.count == 700, "history: the rest goes next time")

        // Visits at the same instant split across requests: the cursor stops
        // just short of that instant, so none of them is passed over.
        let tied = visits(10) { _ in start }
        let ties = upload(tied, limits: H.Limits(entryBytes: 16_384, batch: 5, requestBytes: 1 << 20))
        _ = drive(ties, server040(), dropAt: 2)
        check(ties.through < start && ties.through > start - 1, "history: tied visits aren't passed over")

        // A server refusing everything: the push stops, nothing is skipped.
        let closed = upload(visits(40))
        let sixth = drive(closed, { _ in throw refusal("history is closed") })
        check((sixth.error as? Cloud.Failure)?.code == "history_refused" && closed.skipped.isEmpty && closed.through == 0, "history: a server refusing everything skips nothing")

        // Stamped in the future: sent as now, the cursor stays at now, and
        // it is remembered so it isn't sent again.
        var ahead = visits(3)
        ahead[2].at = now + 86_400 * 365
        let future = upload(ahead)
        let seventh = drive(future, server040())
        let stamp = (seventh.stored.last?["visited_at"] as? String).flatMap(CloudSync.date)?.timeIntervalSince1970 ?? .infinity
        check(seventh.stored.count == 3 && stamp <= now && future.through == now, "history: a future visit doesn't move the cursor past now")
        let known = Dictionary(uniqueKeysWithValues: future.ahead.map { ($0.key, $0.at) })
        check(upload(ahead, from: future.through, known: known).next() == nil, "history: a future visit isn't sent again")

        // 0.5.0 stores what it can and lists what it skipped.
        let newer = upload(visits(10))
        let eighth = drive(newer, { entries in entries.count > 3 ? [(index: 3, why: "entry is 20000 bytes; the limit is 16384")] : [] })
        check(eighth.error == nil && newer.sent == 9 && newer.skipped.count == 1 && newer.through == start + 10, "history: a 0.5.0 server's skips are said, the cursor moves on")
    }

    /// Deleting history (CloudHistoryDelete) against a pretend copper-cloud
    /// 0.8.0: what each request carries, paging and matching on this Mac,
    /// the batches, a stop, the page's choices, and that nothing deleted is
    /// sent back up. No network, no clock but the one given.
    private static func historyDelete(_ check: (Bool, String) -> Void) async {
        typealias D = CloudHistoryDelete
        typealias H = CloudHistory
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let mac = UUID(), other = UUID()

        // What goes in a request.
        let named = D.seqs([3, 1, 2])
        check(named.method == "DELETE" && named.query.isEmpty
              && named.body.map { String(decoding: $0, as: UTF8.self) } == "{\"seqs\":[3,1,2]}", "delete: seqs in the body, no query")
        let hourAgo = now.addingTimeInterval(-3_600)
        let filtered = D.window(D.Selector(since: hourAgo, until: now, device: other))
        check(filtered.method == "DELETE" && filtered.body == nil && filtered.query.keys.sorted() == ["device", "since", "until"]
              && filtered.query["device"] == other.uuidString.lowercased() && filtered.query["since"].flatMap(CloudSync.date) == hourAgo
              && filtered.query["until"]?.hasSuffix("Z") == true && !filtered.query.values.contains { $0.contains("+") },
              "delete: since, until, device in the query, in UTC, and no body")
        let everything = D.window(D.Selector(everything: true))
        check(everything.method == "DELETE" && everything.query.isEmpty && everything.body == nil, "delete: everything is no filters at all")
        check(D.page(after: 42) == D.Ask(method: "GET", query: ["since": "42", "limit": "500"]), "delete: paging asks for every Mac's rows")
        check(D.batches((1...12_345).map(Int64.init)).map(\.count) == [5_000, 5_000, 2_345] && D.batches([]).isEmpty, "delete: 5,000 seqs a request at most")
        check(!D.Selector().valid && D.Selector(everything: true).valid && !D.Selector(hosts: ["x.com"], everything: true).valid
              && !D.Selector(since: now, until: now).valid && D.Selector(device: mac).valid, "delete: nothing chosen is never everything")

        // What the cloud can do.
        check(Cloud.features(in: ["version": "0.8.0", "features": ["history_delete", "other"]]).contains(D.feature), "delete: /v1/info lists history_delete")
        check(!Cloud.features(in: ["version": "0.7.0"]).contains(D.feature) && Cloud.features(in: ["features": "history_delete"]).isEmpty,
              "delete: no feature listed, no delete")

        // Words in, a choice out.
        check(D.site("https://WWW.X.com/a?b") == "x.com" && D.site(" x.com. ") == "x.com" && D.site("*.x.com") == "x.com"
              && D.site("not a site") == nil && D.site("com") == nil && D.site("") == nil, "delete: a site as typed")
        check(D.within("x.com", "x.com") && D.within("www.x.com", "x.com") && D.within("a.b.x.com", "x.com")
              && !D.within("notx.com", "x.com") && !D.within("x.com.evil.org", "x.com"), "delete: a site and its subdomains, nothing else")
        check(D.time("1h", now: now) == hourAgo && D.time("24h", now: now) == now.addingTimeInterval(-86_400)
              && D.time("7d", now: now) == now.addingTimeInterval(-604_800)
              && D.time("2026-10-07T10:00:00+02:00", now: now) == CloudSync.date("2026-10-07T08:00:00Z")
              && D.time("soon", now: now) == nil && D.time("-1h", now: now) == nil, "delete: 1h, 24h, 7d and RFC 3339")
        let asked = try? D.selector(from: ["since": "7d", "host": ["x.com", "https://www.x.com/"], "page": "x.com/a?q=1"], now: now, me: mac)
        check(asked?.since == now.addingTimeInterval(-604_800) && asked?.hosts == ["x.com"] && asked?.pages == ["x.com/a"] && asked?.everything == false,
              "delete: since, host and page as an agent says them")
        check((try? D.selector(from: [:], now: now, me: mac)) == nil && (try? D.selector(from: ["all": true, "host": "x.com"], now: now, me: mac)) == nil
              && (try? D.selector(from: ["since": "1h", "until": "2h"], now: now, me: mac)) == nil
              && (try? D.selector(from: ["all": true], now: now, me: mac))?.everything == true
              && (try? D.selector(from: ["device": "this"], now: now, me: mac))?.device == mac, "delete: nothing chosen, or all and more, refused")
        let hour = CloudHistoryEraser.selector(.hour, site: nil, now: now)
        let allOfIt = CloudHistoryEraser.selector(.all, site: nil, now: now)
        let oneSite = CloudHistoryEraser.selector(.all, site: "x.com", now: now)
        check(hour.since == hourAgo && !hour.scans && !hour.everything && allOfIt.everything && allOfIt.valid
              && oneSite.hosts == ["x.com"] && oneSite.since == nil && !oneSite.everything && oneSite.valid, "delete: the page's choices")

        // Rows read leniently: a time from the payload in milliseconds, a
        // row with no time or address, a page that still reads.
        let odd = Data(#"{"entries":[{"seq":1,"payload":{"url":"https://x.com/","visited_at":2000000000000}},{"seq":2,"device_id":"nope","payload":7},{"seq":3,"visited_at":"2033-05-18T03:33:20Z","payload":{"url":"https://x.com/"}}],"next":3,"more":false}"#.utf8)
        let oddPage = try? JSONDecoder().decode(D.Page.self, from: odd)
        let clock = D.Clock()
        check(oddPage?.entries.count == 3 && oddPage?.entries[0].at(clock) == now && oddPage?.entries[1].at(clock) == nil
              && oddPage?.entries[1].url == nil && oddPage?.entries[2].at(clock) == now
              && oddPage.map { page in page.entries.filter { D.covers(D.Selector(since: now, hosts: ["x.com"]), url: $0.url, at: $0.at(clock), device: $0.device) }.count } == 2,
              "delete: odd rows read, and match only on what they show")

        // A history of 1,234 rows from two Macs, a minute apart: x.com as it
        // is written, things that only look like it, and others.
        let urls = ["https://x.com/", "https://www.x.com/a", "https://a.b.x.com/c", "https://X.COM/d", "https://notx.com/",
                    "https://x.com.evil.org/", "https://other.org/x.com", "https://x.com/a?utm=1", "not a url"]
        // Spelled out so an older compiler type-checks it in time.
        var rows: [PretendHistory.Row] = []
        for i in 1...1_234 {
            let device: UUID = i % 2 == 0 ? mac : other
            let at: Date = now.addingTimeInterval(-Double(1_234 - i) * 60)
            rows.append(PretendHistory.Row(seq: Int64(i), device: device, at: at, url: urls[i % urls.count]))
        }
        let xSlots: Set<Int> = [0, 1, 2, 3, 7]
        let onX: Set<Int64> = Set(rows.filter { (row: PretendHistory.Row) -> Bool in xSlots.contains(Int(row.seq) % urls.count) }.map { (row: PretendHistory.Row) -> Int64 in row.seq })

        // A site: paged through here, matched here, deleted by seq.
        let cloud = PretendHistory(rows)
        let bySite = try? await D.run(D.Selector(hosts: ["x.com"])) { try await cloud.answer($0) }
        let left = await cloud.rows, requests = await cloud.asked, mixed = await cloud.mixed
        check(bySite?.deleted == onX.count && bySite?.matched == onX.count && bySite?.looked == 1_234 && bySite?.scanned == true && bySite?.cut == false,
              "delete: a site is found on this Mac and deleted by seq")
        check(left.count == 1_234 - onX.count && !left.contains { onX.contains($0.seq) }
              && left.contains { $0.url.contains("notx.com") } && left.contains { $0.url.contains("evil.org") } && left.contains { $0.url.contains("other.org") },
              "delete: x.com and www.x.com go, notx.com and x.com.evil.org stay")
        check(requests.filter { $0.method == "GET" }.count == 3 && requests.filter { $0.method == "DELETE" }.count == 1 && !mixed
              && !requests.contains { $0.body != nil && !$0.query.isEmpty }, "delete: three pages read, one delete, never seqs and filters together")

        // A page, in a window, from one Mac — what a forget in the History
        // window asks for, narrowed further.
        let windowed = PretendHistory(rows)
        let from = now.addingTimeInterval(-600 * 60), to = now.addingTimeInterval(-100 * 60)
        let page = D.Selector(since: from, until: to, device: mac, pages: ["x.com/a"])
        let pageURLs: Set<String> = ["https://www.x.com/a", "https://x.com/a?utm=1"]
        let pageRows: Set<Int64> = Set(rows.filter { (row: PretendHistory.Row) -> Bool in
            row.device == mac && row.at >= from && row.at < to && pageURLs.contains(row.url)
        }.map { (row: PretendHistory.Row) -> Int64 in row.seq })
        let byPage = try? await D.run(page) { try await windowed.answer($0) }
        let windowedLeft: [PretendHistory.Row] = await windowed.rows
        let pageLeft: Set<Int64> = Set(windowedLeft.map { (row: PretendHistory.Row) -> Int64 in row.seq })
        check(!pageRows.isEmpty && byPage?.deleted == pageRows.count && pageLeft.isDisjoint(with: pageRows) && pageLeft.count == 1_234 - pageRows.count,
              "delete: one page, inside the window, from one Mac only")
        let forgotten = PretendHistory(rows)
        let forgot = try? await D.run(D.forgot("x.com/a")) { try await forgotten.answer($0) }
        let forgotLeft = await forgotten.rows
        check(forgot?.deleted == rows.filter { ["https://www.x.com/a", "https://x.com/a?utm=1"].contains($0.url) }.count
              && !forgotLeft.contains { $0.url.hasSuffix("x.com/a") || $0.url.hasSuffix("/a?utm=1") } && forgotLeft.contains { $0.url == "https://x.com/" },
              "delete: a forgotten page goes from every Mac, the rest of the site stays")

        // A time window, and everything: the server's own filters, no paging.
        let lastHour = PretendHistory(rows)
        let byWindow = try? await D.run(D.Selector(since: hourAgo)) { try await lastHour.answer($0) }
        let windowAsks = await lastHour.asked, windowLeft = await lastHour.rows
        check(byWindow?.deleted == 61 && byWindow?.scanned == false && windowAsks.count == 1 && windowAsks.first?.query.keys.sorted() == ["since"]
              && windowAsks.first?.body == nil && !windowLeft.contains { $0.at >= hourAgo }, "delete: the last hour is one request")
        let cleared = PretendHistory(rows)
        let all = try? await D.run(D.cleared) { try await cleared.answer($0) }
        let clearedAsks = await cleared.asked, clearedLeft = await cleared.rows
        check(all?.deleted == 1_234 && clearedLeft.isEmpty && clearedAsks == [D.Ask(method: "DELETE")], "delete: History cleared here clears it all there")
        let untouched = PretendHistory(rows)
        let refused = try? await D.run(D.Selector()) { try await untouched.answer($0) }
        let untouchedAsks = await untouched.asked
        check(refused == nil && untouchedAsks.isEmpty, "delete: nothing chosen asks the cloud nothing")

        // More than 5,000 matches: three deletes.
        let many = (1...12_345).map { i in
            PretendHistory.Row(seq: Int64(i), device: mac, at: now, url: i % 100 == 0 ? "https://keep.example/" : "https://x.com/\(i)")
        }
        let large = PretendHistory(many)
        let batched = try? await D.run(D.Selector(hosts: ["x.com"])) { try await large.answer($0) }
        let largeAsks = await large.asked, largeLeft = await large.rows
        let sizes = largeAsks.filter { $0.method == "DELETE" }.compactMap { ask in
            ask.body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["seqs"].flatMap { ($0 as? [Any])?.count }
        }
        check(batched?.deleted == 12_222 && sizes == [5_000, 5_000, 2_222] && largeLeft.count == 123 && largeAsks.filter { $0.method == "GET" }.count == 25,
              "delete: 12,222 matches go in three requests of 5,000 at most")

        // Bounded: the page limit stops the looking, and says so.
        let bounded = PretendHistory(rows)
        let cut = try? await D.run(D.Selector(hosts: ["x.com"]), pageLimit: 2) { try await bounded.answer($0) }
        check(cut?.cut == true && cut?.looked == 1_000 && cut?.deleted == onX.filter { $0 <= 1_000 }.count, "delete: looking stops at the page limit, and says so")

        // A stop while looking deletes nothing.
        let stoppable = PretendHistory(rows)
        let stopping = Task { () -> Bool in
            do {
                _ = try await D.run(D.Selector(hosts: ["x.com"])) { ask in
                    let data = try await stoppable.answer(ask)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return data
                }
                return false
            } catch {
                return error is CancellationError
            }
        }
        let stopped = await stopping.value
        let stoppedAsks = await stoppable.asked, stoppedLeft = await stoppable.rows
        check(stopped && stoppedAsks.count == 1 && stoppedLeft.count == 1_234, "delete: a stop while looking deletes nothing")

        // Nothing deleted is sent back up. The push cursor is at `through`:
        // what is older went up already and is never offered again; what is
        // newer and covered is settled as on the server already.
        let t0 = now.timeIntervalSince1970 - 10_000, through = t0 + 100, moment = now.timeIntervalSince1970
        let visits = [
            H.Visit(key: "x.com/old", url: "https://x.com/old", title: "", at: t0 + 1),
            H.Visit(key: "x.com/new", url: "https://www.x.com/new", title: "", at: t0 + 200),
            H.Visit(key: "notx.com", url: "https://notx.com/", title: "", at: t0 + 300),
        ]
        func sends(_ plan: [(visit: H.Visit, slot: H.Slot)]) -> [String] {
            plan.compactMap { step -> String? in if case .send(let item) = step.slot { return item.visit.key } else { return nil } }
        }
        let siteSince = D.Selector(since: Date(timeIntervalSince1970: t0), hosts: ["x.com"])
        let kept = D.push(after: siteSince, here: .kept, visits: visits, through: through, remote: ["far.org": t0 + 9_000], device: mac, now: moment)
        check(kept.through == through && kept.remote == ["far.org": t0 + 9_000, "x.com/new": t0 + 200]
              && D.push(after: D.Selector(device: other), here: .kept, visits: visits, through: through, remote: [:], device: mac, now: moment).remote.isEmpty,
              "no resend: a delete settles only covered visits not yet pushed")
        let plan = H.plan(visits, after: kept.through ?? 0, known: kept.remote, now: moment, limits: .standard)
        check(sends(plan) == ["notx.com"], "no resend: the push sends neither what went up nor what was deleted before it could")
        let push = H.Upload(plan, limits: .standard, from: through, now: moment)
        if push.next() != nil { push.accepted() }
        check(push.through == t0 + 300 && H.plan(visits, after: push.through, known: [:], now: moment, limits: .standard).isEmpty,
              "no resend: the cursor passes them, and they are never offered again")
        let revisited = [visits[0], H.Visit(key: "x.com/new", url: "https://www.x.com/new", title: "", at: t0 + 500), visits[2]]
        check(sends(H.plan(revisited, after: kept.through ?? 0, known: kept.remote, now: moment, limits: .standard)) == ["notx.com", "x.com/new"],
              "no resend: a page visited again after the delete is new history, and goes up")
        let clearedHere = D.push(after: D.cleared, here: .cleared, visits: visits, through: through, remote: ["x.com/new": t0 + 200], device: mac, now: moment)
        check(clearedHere.through == moment && clearedHere.remote.isEmpty
              && H.plan(visits, after: clearedHere.through ?? 0, known: clearedHere.remote, now: moment, limits: .standard).isEmpty,
              "no resend: History cleared, the cursor at now, nothing old goes up")
        let forgotHere = D.push(after: D.forgot("x.com/new"), here: .forgot, visits: visits, through: through, remote: [:], device: mac, now: moment)
        let stale = D.unforgotten(visits + [H.Visit(key: "y.com", url: "https://y.com/", title: "", at: t0 + 400)], ["x.com/new": t0 + 250, "y.com": t0 + 350])
        check(forgotHere.through == through && stale.map(\.key) == ["x.com/old", "notx.com", "y.com"]
              && sends(H.plan(stale, after: through, known: forgotHere.remote, now: moment, limits: .standard)) == ["notx.com", "y.com"],
              "no resend: a forgotten page isn't pushed from a stale history.json, unless visited again")
        check(D.cleared.everything && D.cleared.valid && D.forgot("x.com/a") == D.Selector(pages: ["x.com/a"]),
              "mirror: Clear History is everything, a forgotten page is that page")
        check(!clearedLeft.contains { $0.seq > 0 } && !left.contains { onX.contains($0.seq) }, "no re-import: deleted rows aren't there to pull")
    }
}

/// copper-cloud 0.8.0's `/v1/sync/history`, as paging and deleting see it:
/// rows by seq, deleted by seq or by window, refusing seqs and filters
/// together and more than 5,000 seqs at once.
private actor PretendHistory {
    struct Row {
        var seq: Int64
        var device: UUID
        var at: Date
        var url: String
    }

    private(set) var rows: [Row]
    private(set) var asked: [CloudHistoryDelete.Ask] = []
    /// Seqs and filters in one request.
    private(set) var mixed = false
    /// Each row's time as the server writes it, once.
    private var stamps: [Int64: String] = [:]

    init(_ rows: [Row]) {
        self.rows = rows
        var seen: [Date: String] = [:]
        for row in rows {
            if seen[row.at] == nil { seen[row.at] = CloudSync.stamp(row.at) }
            stamps[row.seq] = seen[row.at]
        }
    }

    func answer(_ ask: CloudHistoryDelete.Ask) throws -> Data {
        asked.append(ask)
        let query = ask.query
        func refuse(_ text: String) -> Cloud.Failure { Cloud.Failure(status: 400, code: "bad_request", message: text) }
        func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        switch ask.method {
        case "GET":
            guard query["exclude_device"] == nil, let since = query["since"].flatMap({ Int64($0) }) else { throw refuse("since") }
            let page = rows.filter { $0.seq > since }.prefix(min(Int(query["limit"] ?? "") ?? 100, 500))
            let next = page.last?.seq ?? since
            let entries = page.map { row -> [String: Any] in
                let stamp = stamps[row.seq] ?? ""
                return ["seq": row.seq, "device_id": row.device.uuidString.lowercased(), "visited_at": stamp,
                        "payload": ["url": row.url, "title": "", "visited_at": stamp]]
            }
            return json(["entries": entries, "next": next, "more": rows.contains { $0.seq > next }])
        case "DELETE":
            let before = rows.count
            if let body = ask.body {
                guard query.isEmpty else {
                    mixed = true
                    throw refuse("seqs and filters can't be used together")
                }
                guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let seqs = object["seqs"] as? [NSNumber], seqs.count <= CloudHistoryDelete.batch else { throw refuse("seqs") }
                let doomed = Set(seqs.map(\.int64Value))
                rows.removeAll { doomed.contains($0.seq) }
            } else {
                let since = query["since"].flatMap(CloudSync.date), until = query["until"].flatMap(CloudSync.date)
                let device = query["device"].flatMap(UUID.init(uuidString:))
                rows.removeAll { row in
                    (since.map { row.at >= $0 } ?? true) && (until.map { row.at < $0 } ?? true) && (device.map { row.device == $0 } ?? true)
                }
            }
            return json(["deleted": before - rows.count])
        default:
            throw Cloud.Failure(status: 405, code: "method_not_allowed", message: ask.method)
        }
    }
}
