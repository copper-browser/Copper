import CryptoKit
import Foundation
import Security

// Copper Cloud: one self-hosted copper-cloud instance this browser is linked
// to, the account signed in on it, and the one authenticated, certificate-
// pinned HTTP client everything Cloud-shaped talks through — the sync engine
// (CloudSync.swift), the canvas host (Fork/Canvas/) and the settings page.
//
// Nothing here runs on its own. A link is made by pasting a link code, an
// account by signing in — or both at once with a pairing code another
// signed-in Copper made (CloudPairing.swift), or with the company's single
// sign-on from a join link (CloudSSO.swift); until then no request leaves
// the Mac. What is kept
// lives in `cloud.json` beside the session, mode 0600 like agent.json: the
// instance address, its key and certificate fingerprint, the account, the
// session token and the sync switches. The token is never published, never
// logged and never handed to a page. See docs/cloud.md.

@MainActor
final class Cloud: ObservableObject {
    static let shared = Cloud()

    /// Where the instance is and how to know it is the one meant.
    struct Link: Codable, Equatable {
        /// `https://host[:port]` — `http://` only for a loopback host (a
        /// development server with `tls off`).
        var url: URL
        /// The instance key every `/v1` request carries.
        var key: String
        /// SHA-256 of the server's leaf certificate (DER), lowercase hex. Nil
        /// means the system's own trust decides (an ACME certificate).
        var fingerprint: String?

        /// `host:port` as people read it.
        var host: String { Cloud.hostText(url) }

        /// The fingerprint in pairs, `ab:cd:…`, for comparing by eye.
        var fingerprintPairs: String? { fingerprint.map(Cloud.pairs) }

        /// The code that would make this link again.
        var code: String { Cloud.codeText(url, "k=\(key)", fingerprint) }
    }

    /// A pairing code: `copper-cloud://HOST:PORT/#p=CODE&fp=HEX`, minted by a
    /// Copper already signed in (Settings › Cloud › Pair another Mac). Where
    /// the instance is and the one-time credential that links this Mac to it
    /// and signs it in — no instance key in it: the server answers with the
    /// gate credential this Mac keeps (`/v1/auth/pair`). Never kept on disk.
    struct PairingCode: Equatable {
        var url: URL
        /// `cp_…`, single use, ten minutes.
        var code: String
        /// As in a link code: the certificate's SHA-256, or nil for one the
        /// system trusts (an ACME certificate).
        var fingerprint: String?

        var host: String { Cloud.hostText(url) }
        var fingerprintPairs: String? { fingerprint.map(Cloud.pairs) }
        /// The whole code, as the minting Mac shows it.
        var link: String { Cloud.codeText(url, "p=\(code)", fingerprint) }
    }

    /// A join link: `copper-cloud://HOST:PORT/#sso=PROVIDER&fp=HEX`, what
    /// `copper-cloud link-code --sso` prints and the instance's `/start` page
    /// hands over. No secret in it: where the instance is, how to know it,
    /// and which of its sign-ins to use (`GET /v1/auth/sso`). Signing in with
    /// that provider — a company Google account — links this Mac and signs it
    /// in (CloudSSO.swift).
    struct SSOCode: Equatable {
        var url: URL
        /// The provider's id on the instance (`google`).
        var provider: String
        /// As in a link code: the certificate's SHA-256, or nil for one the
        /// system trusts (an ACME certificate).
        var fingerprint: String?

        var host: String { Cloud.hostText(url) }
        var fingerprintPairs: String? { fingerprint.map(Cloud.pairs) }
        /// The whole link, as the instance prints it.
        var link: String { Cloud.codeText(url, "sso=\(provider)", fingerprint) }
    }

    /// What a pasted code turned out to be.
    enum Code: Equatable {
        /// `#k=`: connects; signing in comes next.
        case link(Link)
        /// `#p=`: connects and signs in, in one step.
        case pairing(PairingCode)
        /// `#sso=`: connects and signs in through the instance's single
        /// sign-on, in one step.
        case sso(SSOCode)

        var url: URL {
            switch self {
            case .link(let link): return link.url
            case .pairing(let code): return code.url
            case .sso(let code): return code.url
            }
        }

        var fingerprint: String? {
            switch self {
            case .link(let link): return link.fingerprint
            case .pairing(let code): return code.fingerprint
            case .sso(let code): return code.fingerprint
            }
        }

        var host: String { Cloud.hostText(url) }
        var fingerprintPairs: String? { fingerprint.map(Cloud.pairs) }
    }

    /// Who is signed in, and as which device.
    struct Account: Codable, Equatable {
        var userId: UUID
        var email: String
        var displayName: String
        var deviceId: UUID
    }

    /// A refusal from the server (`{"error": code, "message": …}`), or a
    /// failure to reach it (status 0, code `network`, `tls`, `fingerprint`,
    /// `not_linked`, `not_signed_in`, `untrusted`).
    struct Failure: Error, LocalizedError {
        var status: Int
        var code: String
        var message: String
        /// The answer's body, for a 409 that carries the server's copy.
        /// Never logged.
        var body: Data? = nil
        /// `untrusted`: the fingerprint of the certificate the server showed,
        /// for a person to compare and trust on first use.
        var seen: String? = nil

        var errorDescription: String? { message }
    }

    /// The per-domain sync switches and history cursors, kept in the same
    /// file (`sync.*`, `history.*`). Owned by CloudSync; stored here so one
    /// file holds everything Cloud keeps.
    struct SyncPrefs: Codable, Equatable {
        var spaces = false
        var settings = false
        var bookmarks = false
        var history = false
        var tabs = false
        /// "Turn on sync" was pressed: the chosen switches act.
        var on = false
        /// History: the newest local visit already pushed (Unix seconds).
        var pushedThrough: Double?
        /// History: the newest server sequence number already pulled.
        var pulledSeq: Int64 = 0
    }

    @Published private(set) var link: Link?
    @Published private(set) var account: Account?          // the token is never published; it lives in cloud.json (0600)
    @Published private(set) var reachable: Bool = false     // the last request or health check got an answer
    /// How many requests the server has answered (any status) this run.
    /// CloudSync stamps "last synced" only when this moved: a sync that
    /// sent nothing proves nothing about the server.
    private(set) var answers = 0

    var isLinked: Bool { link != nil }
    var isSignedIn: Bool { account != nil }

    /// What the instance says it runs (`GET /v1/info` → `version`, e.g.
    /// `"0.2.0"`): read once per link, again whenever the event stream comes
    /// (back) up, and forgotten when the link goes. Nil until it has answered.
    /// What a Copper can offer depends on it — share links and the people
    /// directory arrived in 0.3.0 (`Cloud.supports`).
    @Published private(set) var serverVersion: String?
    /// Features this instance answered with a bare route-level `404
    /// not_found` while its version was unknown — it doesn't have them.
    @Published private(set) var lacking: Set<Feature> = []
    /// The link `serverVersion` and `lacking` were learned for.
    private var infoFor: URL?
    /// What `/v1/info` says a history push may weigh (`limits`), read with
    /// the version; smaller if a refusal has said so since. Nil until known.
    var historyLimits: CloudHistory.Limits?
    /// `/v1/info`'s `features`, read with the version: what this instance can
    /// do that its version alone doesn't say. Nil until it has answered.
    @Published private(set) var features: Set<String>?

    /// Things a copper-cloud has from some version on.
    enum Feature: String {
        /// `/v1/canvases/:id/links`, `/v1/canvas-links/:token`, `/join/:token`.
        case shareLinks
        /// `GET /v1/people`.
        case people
        /// Inviting someone already invited reminds them (`nudged`,
        /// `nudged_at`), an invite says whether its address has an account
        /// yet (`invitee`), and `DELETE /v1/canvases/:id/invites/:invite_id`
        /// withdraws one.
        case inviteReminders
        /// Canvas chat mentions: `POST /v1/canvases/:id/mentions`,
        /// `GET /v1/mentions`, `POST /v1/mentions/read` (CanvasChat.swift).
        case mentions

        /// The first copper-cloud release with it.
        var since: String {
            switch self {
            case .shareLinks, .people: return "0.3.0"
            case .inviteReminders: return "0.5.0"
            case .mentions: return "0.6.0"
            }
        }
    }

    /// This Copper, as the server knows it: minted once per data folder, so
    /// each probe world is a device of its own.
    private(set) var deviceId: UUID
    /// Shown on other devices beside this one's tabs. Editable in Settings.
    @Published var deviceName: String {
        didSet { if deviceName != oldValue { save() } }
    }
    /// See `SyncPrefs`. Writes through to cloud.json.
    var sync: SyncPrefs {
        get { saved.sync }
        set { guard newValue != saved.sync else { return }; saved.sync = newValue; save() }
    }

    /// link, account or reachable changed.
    static let didChange = Notification.Name("Cloud.didChange")
    /// One event from `GET /v1/sync/events`: `userInfo["event"]` is the
    /// decoded dictionary (`type`: `doc` | `history` | `canvas`, plus `open`
    /// when the stream (re)connects — anything may have been missed).
    static let event = Notification.Name("Cloud.event")

    // MARK: - what is kept

    struct Saved: Codable {
        var deviceId: UUID
        var deviceName: String
        var link: Link?
        var account: Account?
        var token: String?
        var sync = SyncPrefs()
    }

    static var file: URL { Store.file("cloud.json") }

    private var saved: Saved
    private var session: URLSession
    private var trust: CloudTrust
    private var events: Task<Void, Never>?

    private init() {
        let loaded = (try? Data(contentsOf: Cloud.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let fresh = loaded == nil
        saved = loaded ?? Saved(deviceId: UUID(), deviceName: Cloud.defaultDeviceName())
        link = saved.link
        account = saved.token == nil ? nil : saved.account
        deviceId = saved.deviceId
        deviceName = saved.deviceName
        trust = CloudTrust(pin: saved.link?.fingerprint)
        session = Cloud.makeSession(trust)
        if fresh { save() }
        if isSignedIn { startEvents() } else if link != nil { Task { await self.loadInfo() } }
    }

    private static func defaultDeviceName() -> String {
        let name = Host.current().localizedName ?? "Mac"
        // Two probe worlds on one Mac are two devices; say which is which.
        return Store.world.map { "\(name) (\($0))" } ?? name
    }

    /// Atomic, and 0600 from the first byte: written to a private temporary
    /// file and renamed over the old one, so the token is never readable by
    /// anyone else even for the moment between a write and a chmod.
    private func save() {
        saved.deviceName = deviceName
        saved.link = link
        saved.account = account
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let file = Cloud.file
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".cloud.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }


    // MARK: - linking

    /// `copper-cloud://HOST:PORT/#k=KEY&fp=HEX` (what `copper-cloud link-code`
    /// prints, or the admin portal for a person's access key — `k` is either),
    /// or the same fragment on an `https://` address — or `http://` for a
    /// loopback host. Spaces and line breaks a paste picked up are ignored;
    /// colons in the fingerprint are allowed. Nil when it is not one —
    /// including a pairing code (`#p=`), which `parseCode` tells apart.
    nonisolated static func parseLinkCode(_ text: String) -> Link? {
        if case .link(let link)? = parseCode(text) { return link }
        return nil
    }

    /// A link code (`#k=`), a pairing code (`#p=`) or a join link (`#sso=`),
    /// whichever was pasted. A bare `cp_…` pairing code has no address in
    /// it: it reads only with `linkedTo`, the instance this Mac already knows.
    nonisolated static func parseCode(_ text: String, linkedTo current: Link? = nil) -> Code? {
        let raw = text.filter { !$0.isWhitespace }
        if let current, isBarePairingCode(raw) {
            return .pairing(PairingCode(url: current.url, code: raw, fingerprint: current.fingerprint))
        }
        guard let hash = raw.firstIndex(of: "#") else { return nil }
        let head = String(raw[..<hash])
        var fields: [String: String] = [:]
        for pair in raw[raw.index(after: hash)...].split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { continue }
            fields[bits[0].lowercased()] = bits[1].removingPercentEncoding ?? bits[1]
        }
        let plain = ["off", "none", "plain", "http"].contains(fields["tls"]?.lowercased() ?? "")
        var address = head
        if address.lowercased().hasPrefix("copper-cloud://") {
            address = (plain ? "http://" : "https://") + address.dropFirst("copper-cloud://".count)
        }
        if let key = fields["k"] ?? fields["key"], !key.isEmpty {
            return link(address: address, key: key, fingerprint: fields["fp"]).map(Code.link)
        }
        if let code = fields["p"] ?? fields["pair"], !code.isEmpty,
           !code.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "?" }),
           let end = endpoint(address: address, fingerprint: fields["fp"]) {
            return .pairing(PairingCode(url: end.url, code: code, fingerprint: end.pin))
        }
        if let provider = fields["sso"], isProviderId(provider),
           let end = endpoint(address: address, fingerprint: fields["fp"]) {
            return .sso(SSOCode(url: end.url, provider: provider, fingerprint: end.pin))
        }
        return nil
    }

    /// A provider id as the instance names one: short, and nothing that could
    /// leave the path segment it goes in (`/v1/auth/sso/{id}`).
    nonisolated static func isProviderId(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return text.count <= 64
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// `cp_` and base64url: a pairing code on its own, without the address.
    nonisolated static func isBarePairingCode(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("cp_"), raw.count >= 19 else { return false }
        return raw.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A link from the advanced fields: an address (`host:port` or a URL),
    /// the key, and an optional fingerprint. Nil when one of them is not
    /// usable — a bad fingerprint is refused rather than dropped, because
    /// dropping it would silently fall back to the system's trust.
    nonisolated static func link(address: String, key: String, fingerprint: String?) -> Link? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }),
              let end = endpoint(address: address, fingerprint: fingerprint) else { return nil }
        return Link(url: end.url, key: key, fingerprint: end.pin)
    }

    /// The address and pin both kinds of code share: `https://host[:port]`
    /// (or loopback `http://`, never pinned) and the fingerprint as lowercase
    /// hex. Nil when either is unusable.
    nonisolated static func endpoint(address: String, fingerprint: String?) -> (url: URL, pin: String?)? {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if !address.contains("://") { address = "https://" + address }
        guard let parsed = URLComponents(string: address),
              let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parsed.host, !host.isEmpty else { return nil }
        // Plain HTTP only to this Mac: a development server with `tls off`.
        if scheme == "http", !["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) { return nil }
        var pin: String?
        if let fingerprint, !fingerprint.trimmingCharacters(in: .whitespaces).isEmpty {
            let hex = fingerprint.lowercased().filter { $0 != ":" && !$0.isWhitespace }
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
            pin = hex
        }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = parsed.port
        guard let url = clean.url else { return nil }
        return (url, scheme == "http" ? nil : pin)
    }

    /// `host:port` as people read it, IPv6 in brackets.
    nonisolated static func hostText(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let shown = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(shown):\($0)" } ?? shown
    }

    /// A fingerprint in pairs, `ab:cd:…`, for comparing by eye.
    nonisolated static func pairs(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: min(2, hex.count - i))])
        }.joined(separator: ":")
    }

    /// `copper-cloud://host:port/#<fragment>[&fp=…]`, or the loopback
    /// `http://` form.
    nonisolated static func codeText(_ url: URL, _ fragment: String, _ fingerprint: String?) -> String {
        var fragment = fragment
        if let fingerprint { fragment += "&fp=\(fingerprint)" }
        if url.scheme == "http" { return "\(url.absoluteString)/#\(fragment)" }
        return "copper-cloud://\(hostText(url))/#\(fragment)"
    }

    /// Reach the instance with the pin before keeping anything: `/healthz`
    /// must answer through a certificate that matches the fingerprint, and
    /// the instance key must be accepted. Then the link is kept. A link to
    /// another instance signs the account here out first — accounts belong
    /// to one instance.
    func connect(_ link: Link) async throws {
        let probeTrust = CloudTrust(pin: link.fingerprint)
        let probe = Cloud.makeSession(probeTrust)
        defer { probe.finishTasksAndInvalidate() }
        do {
            var health = URLRequest(url: link.url.appending(path: "healthz"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            health.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await probe.data(for: health)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "health", message: "The server answered, but not as a Copper Cloud instance")
            }
            // The key: any /v1 path is behind the instance gate, and /auth/me
            // without a session tells the two refusals apart.
            var gate = URLRequest(url: link.url.appending(path: "v1/auth/me"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            gate.setValue(link.key, forHTTPHeaderField: "X-Copper-Instance")
            let (data, answer) = try await probe.data(for: gate)
            if let http = answer as? HTTPURLResponse, http.statusCode == 401,
               Cloud.failure(from: data, status: 401).code == "instance_key" {
                throw Failure(status: 401, code: "instance_key", message: "The instance refused this key — copy the link code again")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            if Cloud.lacksFingerprint(error, pinned: link.fingerprint != nil, https: link.url.scheme == "https") {
                throw Failure(status: 0, code: "tls", message: Cloud.incompleteLinkCode)
            }
            throw Cloud.transportFailure(error, trust: probeTrust)
        }
        if let old = self.link, old.url != link.url || old.key != link.key { forgetAccount() }
        self.link = link
        trust = probeTrust.fresh()
        session.finishTasksAndInvalidate()
        session = Cloud.makeSession(trust)
        reachable = true
        save()
        changed()
        CloudLog.note("Connected to \(link.host)")
        Task { await loadInfo(force: true) }
    }

    /// What `POST /v1/auth/pair` answers — and `POST /v1/auth/sso/{id}`,
    /// which adds `created`.
    struct Paired: Decodable {
        struct User: Decodable {
            var id: UUID
            var email: String
            var displayName: String?
            enum CodingKeys: String, CodingKey { case id, email, displayName = "display_name" }
        }
        struct Device: Decodable {
            var id: UUID
            var name: String?
        }
        var token: String
        var user: User
        var device: Device?
        /// What this Mac sends as `X-Copper-Instance` from now on: the
        /// instance key (an open instance) or an access key minted for it.
        var gateKey: String
        /// Single sign-on only: the account was made just now.
        var created: Bool?
        enum CodingKeys: String, CodingKey { case token, user, device, gateKey = "gate_key", created }
    }

    /// Link this Mac and sign it in with a pairing code, in one step. The
    /// instance is reached exactly as `connect` reaches it — `/healthz`
    /// through the code's pinned certificate — then `POST /v1/auth/pair`
    /// without the instance gate (the code is the credential). The answer's
    /// link (address, `gate_key`, fingerprint), account and token are kept
    /// in one write, and the rest follows as after a sign-in.
    ///
    /// A code without a fingerprint is trusted the way a link code without
    /// one is: by the Mac's own roots. When they refuse the certificate the
    /// failure is `untrusted`, carrying the fingerprint the server showed
    /// (`Failure.seen`) — pass it back as `trusting` once a person has
    /// compared it, and from then on this instance is pinned to it.
    func pair(_ code: PairingCode, trusting confirmed: String? = nil) async throws {
        let pin = code.fingerprint ?? confirmed.flatMap { Cloud.endpoint(address: code.url.absoluteString, fingerprint: $0)?.pin }
        if code.fingerprint == nil, confirmed != nil, pin == nil {
            throw Failure(status: 0, code: "fingerprint", message: "That fingerprint isn't 64 hex characters")
        }
        let probeTrust = CloudTrust(pin: pin)
        let probe = Cloud.makeSession(probeTrust)
        defer { probe.finishTasksAndInvalidate() }
        let answer: Paired
        do {
            var health = URLRequest(url: code.url.appending(path: "healthz"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            health.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await probe.data(for: health)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "health", message: "The server answered, but not as a Copper Cloud instance")
            }
            var request = URLRequest(url: code.url.appending(path: "v1/auth/pair"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code.code,
                "device": ["id": deviceId.uuidString.lowercased(), "name": deviceName],
            ])
            let (data, reply) = try await probe.data(for: request)
            guard let status = (reply as? HTTPURLResponse)?.statusCode else {
                throw Failure(status: 0, code: "network", message: "No HTTP answer")
            }
            guard (200..<300).contains(status) else { throw Cloud.pairFailure(Cloud.failure(from: data, status: status)) }
            do {
                answer = try JSONDecoder().decode(Paired.self, from: data)
            } catch {
                throw Failure(status: status, code: "decode", message: "The server's answer to the pairing code didn't read: \(error.localizedDescription)")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Cloud.probeFailure(error, url: code.url, pin: pin, trust: probeTrust, carrying: "the pairing code has")
        }
        try await adoptSignedIn(answer, url: code.url, pin: pin, trust: probeTrust) { link, account in
            "Paired with \(link.host) — signed in as \(account.email)"
        }
    }

    /// How pairing and single sign-on both end: the server's answer — the
    /// link (address, `gate_key` as the key, the pin it was reached by), the
    /// account and the session token — kept in one write (`adoptPaired`),
    /// then the session asked who it is, as after a sign-in. The device id
    /// is the one the server answered with.
    func adoptSignedIn(_ answer: Paired, url: URL, pin: String?, trust: CloudTrust, note: (Link, Account) -> String) async throws {
        let key = answer.gateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw Failure(status: 0, code: "decode", message: "The server signed this Mac in but sent no instance credential")
        }
        let link = Link(url: url, key: key, fingerprint: pin)
        let account = Account(userId: answer.user.id, email: answer.user.email,
                              displayName: answer.user.displayName ?? answer.user.email, deviceId: answer.device?.id ?? deviceId)
        adoptPaired(link: link, trust: trust, token: answer.token, account: account)
        CloudLog.note(note(link, account))
        _ = try? await me()
    }

    /// A request on a probe session that failed before the server answered.
    /// Without a pin, a certificate the Mac's roots refuse is `untrusted`,
    /// carrying the fingerprint the server showed (`Failure.seen`) for a
    /// person to compare and trust on first use; `carrying` says what came
    /// without a fingerprint ("the pairing code has").
    nonisolated static func probeFailure(_ error: Error, url: URL, pin: String?, trust: CloudTrust, carrying: String) -> Failure {
        if pin == nil, url.scheme == "https", let seen = trust.seen, Cloud.isCertificateRefusal(error) {
            return Failure(status: 0, code: "untrusted",
                           message: "This instance's certificate isn't one this Mac trusts, and \(carrying) no fingerprint to pin it by. Compare its fingerprint with `copper-cloud doctor` on the server before trusting it.",
                           seen: seen)
        }
        return Cloud.transportFailure(error, trust: trust)
    }

    /// A probe session pinned the way `connect` and `pair` pin theirs: to
    /// `pin`, or to the Mac's own roots without one.
    nonisolated static func probeSession(pin: String?) -> (URLSession, CloudTrust) {
        let trust = CloudTrust(pin: pin)
        return (makeSession(trust), trust)
    }

    /// The link, the account and the token from a pairing, kept in one write
    /// with one `didChange` — so nothing ever sees the new instance without
    /// its account or the other way round. A session this Copper had before
    /// is ended on its own instance through its own session.
    private func adoptPaired(link: Link, trust newTrust: CloudTrust, token: String, account: Account) {
        if let old = self.link, let previous = saved.token, previous != token {
            // Started before the old session is let go, so it is allowed to finish.
            session.dataTask(with: Cloud.logoutRequest(link: old, token: previous)).resume()
        }
        events?.cancel()
        events = nil
        self.link = link
        self.account = account
        saved.token = token
        trust = newTrust.fresh()
        session.finishTasksAndInvalidate()
        session = Cloud.makeSession(trust)
        reachable = true
        save()
        startEvents()
        changed()
        Task { await loadInfo(force: true) }
    }

    /// The pairing refusals, in words.
    nonisolated static func pairFailure(_ failure: Failure) -> Failure {
        var failure = failure
        switch (failure.status, failure.code) {
        case (_, "pairing_code"):
            failure.message = "That pairing code doesn't work any more — it was used already, revoked, or is past its 10 minutes. Make a new one on the other Mac."
        case (_, "account_disabled"):
            failure.message = "The account that made this code is disabled on this instance — ask its admin"
        case (429, _), (_, "rate_limited"):
            failure.message = "Too many tries — wait a minute and try again"
        case (404, _), (401, "instance_key"):
            failure.message = "This instance doesn't take pairing codes yet — update copper-cloud, or connect with a link code and sign in"
        case (403, _):
            if failure.message.isEmpty || failure.message == "forbidden" { failure.message = "The instance refused to pair this Mac — ask its admin" }
        default:
            break
        }
        return failure
    }

    nonisolated static let incompleteLinkCode = "This link code is incomplete — copy the whole code from `copper-cloud link-code` and paste it again"

    /// A link code with no fingerprint, to an instance whose certificate this
    /// Mac doesn't know: what `copper-cloud link-code` prints always carries
    /// the fingerprint, so the code was cut short — not "the server's
    /// certificate isn't trusted" and the system's paragraph about it.
    nonisolated static func lacksFingerprint(_ error: Error, pinned: Bool, https: Bool) -> Bool {
        guard !pinned, https else { return false }
        switch (error as? URLError)?.code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot: return true
        default: return false
        }
    }

    /// A TLS failure that means "the certificate wasn't trusted", as opposed
    /// to the network not being there.
    nonisolated static func isCertificateRefusal(_ error: Error) -> Bool {
        switch (error as? URLError)?.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed: return true
        default: return false
        }
    }

    /// Sign out, forget the instance, stop syncing. The server is told about
    /// the sign-out if it can be reached; nothing waits for it.
    func disconnect() {
        if let link, let token = saved.token {
            let request = Cloud.logoutRequest(link: link, token: token)
            let session = self.session
            Task.detached { _ = try? await session.data(for: request) }
        }
        forgetAccount()
        link = nil
        forgetInfo()
        reachable = false
        trust = CloudTrust(pin: nil)
        session.finishTasksAndInvalidate()
        session = Cloud.makeSession(trust)
        save()
        changed()
        CloudLog.note("Disconnected")
    }

    /// `/healthz` through the pinned session: is the instance there? Sets
    /// `reachable`; never signs anyone in or out.
    @discardableResult
    func ping() async -> Bool {
        guard let link else { return false }
        var request = URLRequest(url: link.url.appending(path: "healthz"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let ok = ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
        setReachable(ok)
        return ok
    }

    // MARK: - what the instance can do

    /// `GET /v1/info` → `version`, kept as `serverVersion` for this link.
    /// Asked once per link unless `force` (a reconnect, a fresh link); a
    /// failure keeps what was known. Never posts `didChange` — nothing about
    /// the link or the account changed, only what it is known to offer.
    @discardableResult
    func loadInfo(force: Bool = false) async -> String? {
        guard let link else { return nil }
        if infoFor != link.url { forgetInfo() }
        if !force, infoFor == link.url, serverVersion != nil { return serverVersion }
        guard let answer = try? await request("GET", "/v1/info"), self.link?.url == link.url else { return serverVersion }
        let object = (try? JSONSerialization.jsonObject(with: answer.0)) as? [String: Any]
        let version = (object?["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        infoFor = link.url
        if let object {
            historyLimits = CloudHistory.Limits(info: object)
            features = Cloud.features(in: object)
        }
        if let version, !version.isEmpty, version != serverVersion {
            serverVersion = version
            // A version is the better witness: what a 404 suggested goes.
            lacking = []
        }
        return serverVersion
    }

    /// True or false once known; nil while the instance hasn't said (no
    /// `/v1/info` answer yet, and no telling refusal either).
    func supports(_ feature: Feature) -> Bool? {
        if lacking.contains(feature) { return false }
        guard let serverVersion else { return nil }
        return Cloud.version(serverVersion, atLeast: feature.since)
    }

    /// The instance answered a feature's route with a bare `404 not_found`
    /// while its version was unknown: it predates it.
    func lacks(_ feature: Feature) {
        guard let link else { return }
        if infoFor != link.url { forgetInfo(); infoFor = link.url }
        lacking.insert(feature)
    }

    /// The history limits for this link, asking `/v1/info` once if they
    /// aren't known yet; copper-cloud's defaults if it doesn't answer.
    func limitsForHistory() async -> CloudHistory.Limits {
        if historyLimits == nil, infoFor != link?.url { await loadInfo() }
        return historyLimits ?? .standard
    }

    /// Whether history can be deleted on the cloud (`DELETE
    /// /v1/sync/history`, CloudHistoryDelete); nil until `/v1/info` answers.
    var deletesHistory: Bool? { features.map { $0.contains(CloudHistoryDelete.feature) } }

    /// `features` in a `/v1/info` answer; none listed is none at all.
    nonisolated static func features(in info: [String: Any]) -> Set<String> {
        Set((info["features"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    private func forgetInfo() {
        infoFor = nil
        historyLimits = nil
        features = nil
        if serverVersion != nil { serverVersion = nil }
        if !lacking.isEmpty { lacking = [] }
    }

    /// `"0.10.1"` against `"0.3.0"`, number by number; a pre-release or
    /// build suffix (`-rc.1`, `+abc`) is ignored, a missing part is 0.
    nonisolated static func version(_ text: String, atLeast minimum: String) -> Bool {
        func numbers(_ value: String) -> [Int] {
            let core = value.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
                .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
            return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let have = numbers(text), want = numbers(minimum)
        for index in 0..<max(have.count, want.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < want.count ? want[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    // MARK: - account (CloudAuth.swift does the asking)

    /// Keep a fresh sign-in. A session it replaces is ended on the server.
    func adopt(token: String, account: Account) {
        if let link, let previous = saved.token, previous != token {
            let request = Cloud.logoutRequest(link: link, token: previous)
            let session = self.session
            Task.detached { _ = try? await session.data(for: request) }
        }
        saved.token = token
        self.account = account
        save()
        startEvents()
        changed()
    }

    /// The account's name or email changed on the server.
    func refresh(account: Account) {
        guard self.account != nil, self.account != account else { return }
        self.account = account
        save()
        changed()
    }

    /// Signed out here: the token and the account go, the event stream stops.
    func forgetAccount() {
        let had = saved.token != nil || account != nil
        events?.cancel()
        events = nil
        saved.token = nil
        account = nil
        if had { save(); changed() }
    }

    static func logoutRequest(link: Link, token: String) -> URLRequest {
        var request = URLRequest(url: link.url.appending(path: "v1/auth/logout"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(link.key, forHTTPHeaderField: "X-Copper-Instance")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - asking

    /// One request to the instance: the instance key, the bearer token once
    /// signed in, a JSON body, a 15 s limit, the pinned session. A GET is
    /// tried up to three times when the network or a gateway fails it;
    /// nothing else is ever repeated. A non-2xx answer throws the server's
    /// own `{error, message}`; a 401 `session` signs this Copper out.
    /// `body` is JSON already encoded, sent as it is (history entries are
    /// measured before they go — CloudHistory).
    func request(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, query: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let link else { throw Failure(status: 0, code: "not_linked", message: "Copper isn't connected to a cloud") }
        var request = try makeRequest(method, path, query: query, link: link)
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let idempotent = method.uppercased() == "GET"
        var attempt = 0
        while true {
            attempt += 1
            let session = self.session
            let trust = self.trust
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw Failure(status: 0, code: "network", message: "No HTTP answer")
                }
                setReachable(true)
                answers += 1
                if (200..<300).contains(http.statusCode) { return (data, http) }
                if idempotent, attempt < 3, [502, 503, 504].contains(http.statusCode) {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
                    continue
                }
                var failure = Cloud.failure(from: data, status: http.statusCode)
                if http.statusCode == 409 { failure.body = data }
                if http.statusCode == 401, failure.code == "session" || (failure.code == "unauthorized" && path.hasPrefix("/v1/auth/me")) {
                    CloudLog.note("The server ended this session — signed out")
                    forgetAccount()
                }
                throw failure
            } catch let failure as Failure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = Cloud.transportFailure(error, trust: trust)
                if failure.code == "network" { setReachable(false) }
                if idempotent, attempt < 3, failure.code == "network", !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
                    continue
                }
                throw failure
            }
        }
    }

    /// `request`, decoded with a plain `JSONDecoder` (no key conversion: the
    /// server speaks snake_case, so give the type CodingKeys).
    func requestJSON<T: Decodable>(_ method: String, _ path: String, json: Any? = nil, query: [String: String] = [:]) async throws -> T {
        let (data, response) = try await request(method, path, json: json, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure(status: response.statusCode, code: "decode", message: "The server's answer to \(method) \(path) didn't read: \(error.localizedDescription)")
        }
    }

    /// A WebSocket to the instance on the pinned session: `wss://host/path`
    /// (`ws://` for a loopback development link), with the key and token in
    /// headers and the token in `?token=` too. Call `connect()` on it;
    /// reconnecting is the caller's business (`onClose`).
    func socket(path: String, query: [String: String] = [:]) -> CloudSocket {
        var query = query
        if let token = saved.token { query["token"] = token }
        guard let link, var request = try? makeRequest("GET", path, query: query, link: link),
              var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return CloudSocket(session: session, request: nil)
        }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        request.url = parts.url
        request.timeoutInterval = 30
        return CloudSocket(session: session, request: request)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String], link: Link) throws -> URLRequest {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var parts = URLComponents(url: link.url.appending(path: clean), resolvingAgainstBaseURL: false) else {
            throw Failure(status: 0, code: "bad_path", message: "Not a path: \(path)")
        }
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = parts.url else { throw Failure(status: 0, code: "bad_path", message: "Not a path: \(path)") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method.uppercased()
        request.setValue(link.key, forHTTPHeaderField: "X-Copper-Instance")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        if let token = saved.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func setReachable(_ value: Bool) {
        guard reachable != value else { return }
        reachable = value
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Cloud.didChange, object: self)
    }

    /// `{"error": code, "message": text}`, or the status line when the body
    /// is not that.
    nonisolated static func failure(from data: Data, status: Int) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["error"] as? String ?? "http_\(status)"
        var message = object?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        if message.isEmpty || message == "unauthorized" || message == "conflict" {
            message = Cloud.explain(code: code, status: status, fallback: message)
        }
        return Failure(status: status, code: code, message: message)
    }

    /// The server's short codes, in words for the settings page.
    nonisolated static func explain(code: String, status: Int, fallback: String) -> String {
        switch code {
        case "instance_key": return "The instance refused this key"
        case "session": return "Signed out — the session ended"
        case "credentials": return "Wrong email or password"
        case "rate_limited": return "Too many tries — wait a minute"
        case "conflict": return "Changed elsewhere first"
        default: return fallback.isEmpty ? "HTTP \(status)" : fallback
        }
    }

    nonisolated static func transportFailure(_ error: Error, trust: CloudTrust) -> Failure {
        if trust.mismatched {
            return Failure(status: 0, code: "fingerprint", message: "The server's certificate doesn't match the link code's fingerprint — refused")
        }
        let url = error as? URLError
        switch url?.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return Failure(status: 0, code: "tls", message: "The server's certificate isn't trusted (\(url?.localizedDescription ?? "TLS"))")
        case .timedOut: return Failure(status: 0, code: "network", message: "The server didn't answer in time")
        case .cannotFindHost, .dnsLookupFailed: return Failure(status: 0, code: "network", message: "No such host")
        case .cannotConnectToHost: return Failure(status: 0, code: "network", message: "Nothing is listening there")
        case .notConnectedToInternet, .networkConnectionLost: return Failure(status: 0, code: "network", message: "Offline")
        default: return Failure(status: 0, code: "network", message: error.localizedDescription)
        }
    }

    nonisolated private static func makeSession(_ trust: CloudTrust) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    // MARK: - events

    /// `GET /v1/sync/events`, held open while signed in, each event posted as
    /// `Cloud.event`. Reconnects after 1, 2, 4 … 30 s (with jitter).
    private func startEvents() {
        events?.cancel()
        guard link != nil, saved.token != nil else { return }
        events = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled {
                guard let self, let link = self.link, self.saved.token != nil,
                      var request = try? self.makeRequest("GET", "/v1/sync/events", query: [:], link: link) else { return }
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 120
                let session = self.session
                let trust = self.trust
                let outcome = await CloudEvents.read(session: session, request: request) { data in
                    Task { @MainActor in Cloud.shared.deliver(data) }
                }
                if Task.isCancelled { return }
                switch outcome {
                case .opened:
                    delay = 1
                case .refused(let status, let data):
                    let failure = Cloud.failure(from: data, status: status)
                    if status == 401 {
                        if failure.code == "session" { CloudLog.note("The server ended this session — signed out"); self.forgetAccount() }
                        return
                    }
                    CloudLog.note("Events refused: \(failure.message)")
                case .failed(let error):
                    let failure = Cloud.transportFailure(error, trust: trust)
                    if failure.code == "network" { self.setReachable(false) }
                }
                let wait = delay * Double.random(in: 0.7...1.3)
                delay = min(30, delay * 2)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func deliver(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if event["type"] as? String == "open" {
            setReachable(true)
            // Back after a gap: the instance may have been upgraded meanwhile.
            Task { await loadInfo(force: true) }
        }
        NotificationCenter.default.post(name: Cloud.event, object: self, userInfo: ["event": event])
    }
}

// MARK: - the event stream

/// Server-sent events, read byte by byte so blank lines (the end of an
/// event) are seen: `AsyncBytes.lines` folds them away.
enum CloudEvents {
    enum Outcome {
        case opened
        case refused(Int, Data)
        case failed(Error)
    }

    static func read(session: URLSession, request: URLRequest, emit: @escaping (Data) -> Void) async -> Outcome {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(URLError(.badServerResponse)) }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 4096 { break }
                }
                return .refused(http.statusCode, body)
            }
            emit(Data(#"{"type":"open"}"#.utf8))
            var line: [UInt8] = []
            var name = ""
            var payload: [String] = []
            func dispatch() {
                defer { name = ""; payload = [] }
                guard !payload.isEmpty else { return }
                var data = Data(payload.joined(separator: "\n").utf8)
                // Events whose data has no `type` get the event name as one.
                if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if object["type"] == nil, !name.isEmpty { object["type"] = name }
                    data = (try? JSONSerialization.data(withJSONObject: object)) ?? data
                    emit(data)
                }
            }
            for try await byte in bytes {
                if Task.isCancelled { break }
                if byte == 0x0A {
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll(keepingCapacity: true)
                    if text.isEmpty { dispatch(); continue }
                    if text.hasPrefix(":") { continue }
                    let field = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = String(field[0])
                    var value = field.count > 1 ? String(field[1]) : ""
                    if value.hasPrefix(" ") { value.removeFirst() }
                    if key == "event" { name = value } else if key == "data" { payload.append(value) }
                } else if byte != 0x0D {
                    line.append(byte)
                    if line.count > 1_000_000 { line.removeAll() }
                }
            }
            dispatch()
            return .opened
        } catch {
            return .failed(error)
        }
    }
}

// MARK: - pinning

/// The pinned session's delegate. With a fingerprint, the server is trusted
/// if and only if the SHA-256 of its leaf certificate's DER is that
/// fingerprint — the system's own trust is not consulted, which is what lets
/// a self-signed instance work, and what stops anything else from standing
/// in for it. Without one, the system decides (an ACME certificate).
final class CloudTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let pin: String?
    private let lock = NSLock()
    private var lastMismatch: Date?
    private var lastSeen: String?

    /// The fingerprint of the last leaf certificate a server showed this
    /// session, trusted or not — what a person compares before trusting an
    /// instance on first use.
    var seen: String? { lock.withLock { lastSeen } }

    init(pin: String?) {
        self.pin = pin?.lowercased()
    }

    /// A delegate with the same pin and a clean slate.
    func fresh() -> CloudTrust { CloudTrust(pin: pin) }

    /// A certificate was refused for not matching the pin, just now — what
    /// a failure that follows is really about.
    var mismatched: Bool { lock.withLock { lastMismatch.map { Date().timeIntervalSince($0) < 30 } ?? false } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = decide(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = decide(challenge)
        completionHandler(disposition, credential)
    }

    func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first
        let shown = leaf.map(CloudTrust.fingerprint(of:))
        if let shown { lock.withLock { lastSeen = shown } }
        guard let pin else { return (.performDefaultHandling, nil) }
        guard let shown else {
            lock.withLock { lastMismatch = Date() }
            return (.cancelAuthenticationChallenge, nil)
        }
        if shown == pin {
            return (.useCredential, URLCredential(trust: serverTrust))
        }
        lock.withLock { lastMismatch = Date() }
        return (.cancelAuthenticationChallenge, nil)
    }

    /// SHA-256 of a certificate's DER, lowercase hex.
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
