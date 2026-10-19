import AppKit
import CryptoKit
import Foundation
import Network
import Security

// Single sign-on (copper-cloud ≥ 0.9.0): "Continue with Google" links this
// Mac to an instance and signs it in with a company account — no link code,
// no password. The native-app loopback flow (RFC 8252) with PKCE (RFC 7636):
//
//   GET  /v1/auth/sso              → {enabled, password_signin, providers[]}  (no gate, no auth)
//   …the system browser signs in at the provider and comes back to
//        http://127.0.0.1:<port>/?code=…&state=…                (a listener here, for one redirect)
//   POST /v1/auth/sso/{provider}   {code, code_verifier, redirect_uri, device}
//                                  → what /v1/auth/pair answers, plus `created`
//
// The provider's client secret never comes here: the server trades the code
// and the verifier at the provider's token endpoint and checks the ID token
// (the email's domain, verified). Both requests go through a session pinned
// the way pairing pins one — the join link's `fp`, or the linked instance's
// — and the answer is kept exactly as a pairing's is (`Cloud.adoptSignedIn`),
// then sync turns on as after a pairing (`CloudPairing.syncAfterSignIn`).
//
// Where it starts: a join link pasted in Settings › Cloud
// (`copper-cloud://HOST:PORT/#sso=google&fp=HEX`), the sign-in step of a
// linked instance whose `GET /v1/auth/sso` lists providers, or
// `copper://cloud/join?code=…` from the instance's `/start` page, which opens
// Settings › Cloud and starts at once (`CloudJoin`). The code, the verifier
// and the state are never written down or logged. See docs/cloud.md, Single
// sign-on.

extension Cloud {
    /// `GET /v1/auth/sso`: whether the instance signs people in through a
    /// company account, and with which providers.
    struct SSODiscovery: Equatable, Decodable {
        struct Provider: Equatable, Decodable, Identifiable {
            var id: String
            /// `google` or `oidc`.
            var kind: String
            /// What the button says: "Continue with <name>".
            var name: String
            var clientId: String
            var authorizationEndpoint: String
            var scopes: [String]
            /// Email domains that may sign in (`exowatt.com`).
            var domains: [String]
            /// Google's hosted-domain hint, when there is exactly one domain.
            var hd: String?

            enum CodingKeys: String, CodingKey {
                case id, kind, name, scopes, domains, hd
                case clientId = "client_id"
                case authorizationEndpoint = "authorization_endpoint"
            }

            init(id: String, kind: String = "google", name: String, clientId: String, authorizationEndpoint: String,
                 scopes: [String] = ["openid", "email", "profile"], domains: [String] = [], hd: String? = nil) {
                self.id = id
                self.kind = kind
                self.name = name
                self.clientId = clientId
                self.authorizationEndpoint = authorizationEndpoint
                self.scopes = scopes
                self.domains = domains
                self.hd = hd
            }

            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: CodingKeys.self)
                id = try box.decode(String.self, forKey: .id)
                kind = try box.decodeIfPresent(String.self, forKey: .kind) ?? "oidc"
                let named = try box.decodeIfPresent(String.self, forKey: .name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                name = named.isEmpty ? CloudSSO.guessName(id) : named
                clientId = try box.decode(String.self, forKey: .clientId)
                authorizationEndpoint = try box.decode(String.self, forKey: .authorizationEndpoint)
                scopes = try box.decodeIfPresent([String].self, forKey: .scopes) ?? []
                domains = (try box.decodeIfPresent([String].self, forKey: .domains) ?? [])
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                let hint = try box.decodeIfPresent(String.self, forKey: .hd)?.trimmingCharacters(in: .whitespaces) ?? ""
                hd = hint.isEmpty ? nil : hint
            }

            /// "Use your @exowatt.com account", or nil when any domain goes.
            var domainHint: String? { CloudSSO.domainHint(domains) }
        }

        var enabled: Bool
        var passwordSignin: Bool
        var providers: [Provider]

        enum CodingKeys: String, CodingKey {
            case enabled, providers
            case passwordSignin = "password_signin"
        }

        init(enabled: Bool, passwordSignin: Bool = true, providers: [Provider]) {
            self.enabled = enabled
            self.passwordSignin = passwordSignin
            self.providers = providers
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            passwordSignin = try box.decodeIfPresent(Bool.self, forKey: .passwordSignin) ?? true
            providers = try box.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        }

        /// What an old copper-cloud (a 404) or one with SSO off amounts to.
        static let none = SSODiscovery(enabled: false, providers: [])

        /// The providers a person can use: none while SSO is off.
        var usable: [Provider] { enabled ? providers.filter { Cloud.isProviderId($0.id) } : [] }
    }

    /// Ask the instance at `url` which sign-ins it offers, through a session
    /// pinned to `pin`. An instance from before single sign-on (404) offers
    /// none. Without a pin, a certificate this Mac's roots refuse is
    /// `untrusted`, with the one it showed in `Failure.seen`.
    nonisolated static func discoverSSO(url: URL, pin: String?) async throws -> SSODiscovery {
        let (probe, trust) = probeSession(pin: pin)
        defer { probe.finishTasksAndInvalidate() }
        var request = URLRequest(url: url.appending(path: "v1/auth/sso"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let status: Int
        do {
            let (body, response) = try await probe.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: "network", message: "No HTTP answer") }
            data = body
            status = http.statusCode
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw probeFailure(error, url: url, pin: pin, trust: trust, carrying: "the join link has")
        }
        if status == 404 { return .none }
        guard (200..<300).contains(status) else { throw ssoFailure(failure(from: data, status: status), provider: nil) }
        do {
            return try JSONDecoder().decode(SSODiscovery.self, from: data)
        } catch {
            throw Failure(status: status, code: "decode", message: "The cloud's single sign-on settings didn't read: \(error.localizedDescription)")
        }
    }

    /// Trade the provider's code for a session: `POST /v1/auth/sso/{id}`,
    /// without the instance gate, through a session pinned to `pin`. The
    /// answer is checked for the instance credential before it is handed
    /// back, so a sign-in the browser is told about is one that will keep.
    nonisolated static func exchangeSSO(url: URL, pin: String?, provider: SSODiscovery.Provider, code: String, verifier: String,
                                        redirect: String, device: [String: String]) async throws -> Paired {
        guard isProviderId(provider.id) else { throw Failure(status: 0, code: "sso_provider", message: "The cloud named a sign-in Copper can't use") }
        let (probe, trust) = probeSession(pin: pin)
        defer { probe.finishTasksAndInvalidate() }
        var request = URLRequest(url: url.appending(path: "v1/auth/sso").appending(path: provider.id),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "redirect_uri": redirect, "device": device,
        ])
        let data: Data
        let status: Int
        do {
            let (body, response) = try await probe.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: "network", message: "No HTTP answer") }
            data = body
            status = http.statusCode
        } catch let failure as Failure {
            throw failure
        } catch {
            throw probeFailure(error, url: url, pin: pin, trust: trust, carrying: "the join link has")
        }
        guard (200..<300).contains(status) else { throw ssoFailure(failure(from: data, status: status), provider: provider) }
        let answer: Paired
        do {
            answer = try JSONDecoder().decode(Paired.self, from: data)
        } catch {
            throw Failure(status: status, code: "decode", message: "The cloud's answer to the sign-in didn't read: \(error.localizedDescription)")
        }
        let key = answer.gateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw Failure(status: status, code: "decode", message: "The cloud signed you in but sent no instance credential")
        }
        return answer
    }

    /// The server's single sign-on refusals, in plain words. `provider` is
    /// the one being used, for its name and its domains.
    nonisolated static func ssoFailure(_ failure: Failure, provider: SSODiscovery.Provider?) -> Failure {
        var failure = failure
        let name = provider?.name ?? "the provider"
        switch (failure.status, failure.code) {
        case (_, "sso_domain"):
            if let hint = provider?.domainHint { failure.message = hint }
            else if failure.message.isEmpty || failure.message == "forbidden" { failure.message = "That account's domain isn't allowed on this cloud — use your work account" }
        case (_, "sso_disabled"):
            failure.message = "Single sign-on is turned off on this cloud — ask its admin"
        case (_, "sso_no_account"):
            failure.message = "There's no account for that email on this cloud, and it doesn't create them — ask its admin to add you"
        case (_, "account_disabled"):
            failure.message = "Your account on this cloud is disabled — ask its admin"
        case (_, "sso_failed"):
            failure.message = "\(name.prefix(1).uppercased() + name.dropFirst()) didn't confirm the sign-in — try again"
        case (_, "bad_redirect"):
            failure.message = "The cloud refused Copper's way back from the browser — update Copper, or tell the cloud's admin"
        case (429, _), (_, "rate_limited"):
            failure.message = "Too many tries — wait a minute and try again"
        case (404, _):
            failure.message = "This cloud doesn't offer single sign-on — update copper-cloud, or ask its admin for a link code"
        default:
            break
        }
        return failure
    }
}

/// One single sign-on at a time, for the whole app: Settings › Cloud's
/// buttons, `copper://cloud/join` and `./bench cloud sso` all start, show
/// and cancel this one.
@MainActor
final class CloudSSO: ObservableObject {
    static let shared = CloudSSO()

    /// How long the browser has to come back.
    nonisolated static let timeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        /// Asking the instance, opening the browser.
        case starting
        /// The browser is open at the provider (its name).
        case waiting(String)
        /// The browser came back; the cloud is signing this Mac in.
        case finishing
        case failed(String)
    }

    /// Where a sign-in goes: the instance, how it is pinned, and which of
    /// its providers (nil: the first it lists).
    struct Target: Equatable {
        var url: URL
        var pin: String?
        var provider: String?

        init(url: URL, pin: String?, provider: String?) {
            self.url = url
            self.pin = pin
            self.provider = provider
        }

        init(_ code: Cloud.SSOCode) {
            self.init(url: code.url, pin: code.fingerprint, provider: code.provider)
        }

        init(_ link: Cloud.Link, provider: String?) {
            self.init(url: link.url, pin: link.fingerprint, provider: provider)
        }

        /// Same instance, whichever provider.
        func reaches(_ other: Target) -> Bool { CloudSSO.sameInstance(url, other.url) }
    }

    /// Two addresses for one instance: the scheme and `host[:port]`, with
    /// `:443` the same as none (`CanvasJoinLink.normalize`).
    nonisolated static func sameInstance(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && CanvasJoinLink.normalize(Cloud.hostText(a)) == CanvasJoinLink.normalize(Cloud.hostText(b))
    }

    /// A code `copper://cloud/join` brought, for Settings › Cloud to show.
    struct Offer: Equatable {
        let id = UUID()
        let text: String
        let code: Cloud.Code
    }

    @Published private(set) var phase: Phase = .idle
    /// The sign-in under way, or the last one.
    @Published private(set) var target: Target?
    /// `untrusted`: the fingerprint the instance showed, to compare and trust.
    @Published private(set) var seen: String?
    /// What each instance said it offers, by address. Known after the first answer.
    @Published private(set) var discovered: [URL: Cloud.SSODiscovery] = [:]
    @Published private(set) var offer: Offer?

    private var flow: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var loopback: CloudLoopback?
    private var timedOut = false
    private var asking: Set<URL> = []
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Signed in where the join link points, however it happened:
                // it has done its work. (Signed in elsewhere, the page keeps
                // saying the link is for another instance.)
                let sso = CloudSSO.shared, cloud = Cloud.shared
                if let offer = sso.offer, cloud.isSignedIn, let link = cloud.link, CloudSSO.sameInstance(link.url, offer.code.url) {
                    sso.offer = nil
                }
            }
        }
    }

    var busy: Bool {
        switch phase {
        case .starting, .waiting, .finishing: return true
        case .idle, .failed: return false
        }
    }

    /// The problem to show beside `target`, if the last attempt there failed.
    func problem(for target: Target) -> String? {
        guard let current = self.target, current.reaches(target), case .failed(let text) = phase else { return nil }
        return text
    }

    /// Whether a sign-in to `target` is under way.
    func running(_ target: Target) -> Bool {
        guard let current = self.target, current.reaches(target) else { return false }
        return busy
    }

    func clearProblem() {
        if case .failed = phase { phase = .idle }
        seen = nil
    }

    // MARK: - what the instance offers

    /// The providers the linked instance offers, once asked (`discover`).
    func providers(for link: Cloud.Link?) -> [Cloud.SSODiscovery.Provider] {
        guard let link else { return [] }
        return discovered[link.url]?.usable ?? []
    }

    /// Ask the instance which sign-ins it offers, once per address unless
    /// `force`. Nil when it couldn't be asked; an old instance is `.none`.
    @discardableResult
    func discover(url: URL, pin: String?, force: Bool = false) async -> Cloud.SSODiscovery? {
        if !force, let known = discovered[url] { return known }
        guard !asking.contains(url) else { return discovered[url] }
        asking.insert(url)
        defer { asking.remove(url) }
        guard let answer = try? await Cloud.discoverSSO(url: url, pin: pin) else { return discovered[url] }
        discovered[url] = answer
        return answer
    }

    // MARK: - join links

    /// A join link from `copper://cloud/join`, shown in Settings › Cloud.
    func show(_ text: String, _ code: Cloud.Code) {
        offer = Offer(text: text, code: code)
    }

    func dismissOffer() { offer = nil }

    // MARK: - the flow

    /// Sign in to `target` through its single sign-on. `trusting` is a
    /// fingerprint a person compared and accepted for an instance with no
    /// pin; `domains` the sync switches to turn on after (nil: as pairing
    /// does); `open` what shows the provider's page (the system browser —
    /// the bench hands its own). Cancels a sign-in already under way.
    func start(_ target: Target, trusting: String? = nil, domains: Set<CloudSync.Domain>? = nil, sync: Bool = true,
               in browser: Browser? = nil, open: ((URL) -> Bool)? = nil) {
        stop()
        self.target = target
        seen = nil
        timedOut = false
        phase = .starting
        let opener = open ?? { NSWorkspace.shared.open($0) }
        flow = Task { @MainActor [weak self, weak browser] in
            await self?.run(target, trusting: trusting, domains: domains, sync: sync, browser: browser, open: opener)
        }
    }

    /// Stop waiting: the listener closes, nothing is sent.
    func cancel() {
        guard busy else { return }
        stop()
        phase = .idle
        CloudLog.note("Single sign-on cancelled")
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        flow?.cancel()
        flow = nil
        loopback?.close()
        loopback = nil
    }

    private func run(_ target: Target, trusting: String?, domains: Set<CloudSync.Domain>?, sync: Bool,
                     browser: Browser?, open: @escaping (URL) -> Bool) async {
        let loopback = CloudLoopback()
        self.loopback = loopback
        arm()
        do {
            let pin = try Self.pin(target, trusting: trusting)
            let discovery = try await Cloud.discoverSSO(url: target.url, pin: pin)
            discovered[target.url] = discovery
            let provider = try Self.pick(discovery, id: target.provider, host: Cloud.hostText(target.url))
            try Task.checkCancellation()

            let verifier = Self.verifier()
            let state = Self.random(16)
            let port = try await loopback.open(expecting: state)
            let redirect = Self.redirect(port: port)
            guard let authorize = Self.authorizeURL(provider, redirect: redirect, state: state, challenge: Self.challenge(verifier)) else {
                throw Cloud.Failure(status: 0, code: "sso_provider", message: "The cloud's sign-in address for \(provider.name) isn't one Copper can open")
            }
            try Task.checkCancellation()
            guard open(authorize) else {
                throw Cloud.Failure(status: 0, code: "browser", message: "Copper couldn't open your browser to sign in")
            }
            phase = .waiting(provider.name)
            CloudLog.note("Single sign-on: waiting for \(provider.name) in the browser")

            let (arrival, reply) = try await loopback.callback()
            timer?.cancel()
            phase = .finishing
            switch arrival {
            case .refused(let error, let detail):
                let text = Self.refusal(error, detail, provider: provider.name)
                reply(CloudLoopback.page(ok: false, heading: "Copper couldn't sign you in", line: Self.sentence(text) + " Return to Copper to try again."))
                Self.bringForward(browser)
                throw Cloud.Failure(status: 0, code: "sso_refused", message: text)
            case .code(let code):
                let answer: Cloud.Paired
                do {
                    answer = try await Cloud.exchangeSSO(url: target.url, pin: pin, provider: provider, code: code, verifier: verifier,
                                                         redirect: redirect, device: Self.device())
                } catch {
                    let text = (error as? Cloud.Failure)?.message ?? error.localizedDescription
                    reply(CloudLoopback.page(ok: false, heading: "Copper couldn't sign you in", line: Self.sentence(text) + " Return to Copper to try again."))
                    Self.bringForward(browser)
                    throw error
                }
                reply(CloudLoopback.page(ok: true, heading: "You're signed in — return to Copper",
                                         line: "Copper is signed in to \(Cloud.hostText(target.url)) as \(answer.user.email). You can close this tab."))
                Self.bringForward(browser)
                try await Cloud.shared.adoptSignedIn(answer, url: target.url, pin: pin, trust: CloudTrust(pin: pin)) { link, account in
                    "Signed in to \(link.host) with \(provider.name) as \(account.email)\(answer.created == true ? " (new account)" : "")"
                }
                offer = nil
                loopback.close()
                if self.loopback === loopback { self.loopback = nil }
                phase = .idle
                if sync { await CloudPairing.syncAfterSignIn(domains) }
                return
            }
        } catch {
            // Cancelled: by Cancel (the phase is already idle), by a new
            // sign-in (which owns the phase now) or by the five minutes.
            if Task.isCancelled || error is CancellationError {
                if timedOut {
                    phase = .failed("Nothing came back from the browser in 5 minutes — try again")
                    CloudLog.note("Single sign-on timed out")
                }
            } else if let failure = error as? Cloud.Failure {
                if failure.code == "untrusted" { seen = failure.seen }
                phase = .failed(failure.message)
                CloudLog.note("Single sign-on failed: \(failure.message)")
            } else {
                phase = .failed(error.localizedDescription)
                CloudLog.note("Single sign-on failed: \(error.localizedDescription)")
            }
        }
        loopback.close()
        if self.loopback === loopback { self.loopback = nil }
    }

    /// Five minutes from the press to the browser coming back. Once it
    /// has, the cloud's own answer has its own 30 seconds.
    private func arm() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CloudSSO.timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.phase {
            case .starting, .waiting: break
            default: return
            }
            self.timedOut = true
            self.flow?.cancel()
            self.loopback?.close()
        }
    }

    // MARK: - the parts, pure

    /// The pin a sign-in goes through: the target's, or one a person trusted.
    nonisolated static func pin(_ target: Target, trusting: String?) throws -> String? {
        if let pin = target.pin { return pin }
        guard let trusting else { return nil }
        guard let pin = Cloud.endpoint(address: target.url.absoluteString, fingerprint: trusting)?.pin else {
            throw Cloud.Failure(status: 0, code: "fingerprint", message: "That fingerprint isn't 64 hex characters")
        }
        return pin
    }

    /// The provider to use: the one the link names, or the first offered.
    nonisolated static func pick(_ discovery: Cloud.SSODiscovery, id: String?, host: String) throws -> Cloud.SSODiscovery.Provider {
        let usable = discovery.usable
        guard !usable.isEmpty else {
            throw Cloud.Failure(status: 0, code: "sso_disabled", message: "Single sign-on isn't set up on \(host) yet — ask its admin")
        }
        guard let id else { return usable[0] }
        guard let provider = usable.first(where: { $0.id == id }) ?? usable.first(where: { $0.id.lowercased() == id.lowercased() }) else {
            throw Cloud.Failure(status: 0, code: "sso_provider", message: "This join link is for a sign-in \(host) doesn't offer any more — ask its admin for a new link")
        }
        return provider
    }

    /// `http://127.0.0.1:<port>/` — the address the provider sends the browser back to.
    nonisolated static func redirect(port: UInt16) -> String { "http://127.0.0.1:\(port)/" }

    /// The provider's authorization page for this attempt: its endpoint
    /// (anything already in its query kept), then `client_id`,
    /// `response_type=code`, `scope`, `redirect_uri`, `state`, the S256
    /// `code_challenge`, `prompt=select_account` and Google's `hd`. Nil for
    /// an endpoint that isn't HTTPS (plain HTTP only on this Mac, for tests).
    nonisolated static func authorizeURL(_ provider: Cloud.SSODiscovery.Provider, redirect: String, state: String, challenge: String) -> URL? {
        guard var parts = URLComponents(string: provider.authorizationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        guard scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return nil }
        let scopes = provider.scopes.isEmpty ? ["openid", "email", "profile"] : provider.scopes
        var items: [(String, String)] = [
            ("client_id", provider.clientId),
            ("response_type", "code"),
            ("scope", scopes.joined(separator: " ")),
            ("redirect_uri", redirect),
            ("state", state),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("prompt", "select_account"),
        ]
        if let hd = provider.hd, !hd.isEmpty { items.append(("hd", hd)) }
        let ours = Set(items.map(\.0))
        let kept = (parts.percentEncodedQuery ?? "").split(separator: "&").filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return !name.isEmpty && !ours.contains(name.removingPercentEncoding ?? name)
        }.map(String.init)
        let added = items.map { "\(escape($0.0))=\(escape($0.1))" }
        parts.percentEncodedQuery = (kept + added).joined(separator: "&")
        return parts.url
    }

    /// Percent-encoded for a query value: only RFC 3986's unreserved
    /// characters stay as they are.
    nonisolated static func escape(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// A PKCE verifier: 32 random bytes, base64url — 43 characters.
    nonisolated static func verifier() -> String { random(32) }

    /// The S256 challenge for a verifier (RFC 7636 §4.2).
    nonisolated static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `count` random bytes, base64url without padding.
    nonisolated static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64url(Data(bytes))
    }

    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// "Use your @exowatt.com account" — or "@a.com or @b.com", "@a.com,
    /// @b.com or @c.com". Nil with no domains.
    nonisolated static func domainHint(_ domains: [String]) -> String? {
        let named = domains.map { "@" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }.filter { $0.count > 1 }
        guard let last = named.last else { return nil }
        let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " or " + last
        return "Use your \(list) account"
    }

    /// A provider's name from its id, until the instance says (`google` → Google).
    nonisolated static func guessName(_ id: String) -> String {
        switch id.lowercased() {
        case "google": return "Google"
        case "microsoft", "azure", "entra": return "Microsoft"
        case "okta": return "Okta"
        case "github": return "GitHub"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    /// What the provider said instead of a code, in words.
    nonisolated static func refusal(_ error: String, _ detail: String?, provider: String) -> String {
        switch error {
        case "access_denied": return "Signing in with \(provider) was cancelled."
        case "interaction_required", "login_required", "account_selection_required", "consent_required":
            return "\(provider) needs you to finish signing in in the browser — try again."
        default:
            let said = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(provider) refused the sign-in (\(said.isEmpty ? error : String(said.prefix(160))))."
        }
    }

    /// A message as a sentence: with its full stop.
    nonisolated static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// The device as the server is told about it.
    private static func device() -> [String: String] {
        ["id": Cloud.shared.deviceId.uuidString.lowercased(), "name": Cloud.shared.deviceName]
    }

    /// Copper in front again, on the window the sign-in started from.
    private static func bringForward(_ browser: Browser?) {
        if let browser, let window = Windows.window(of: browser) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // NSApp is nil outside the app (a test run).
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// MARK: - the loopback listener

/// The end of the sign-in on this Mac: an HTTP listener on 127.0.0.1, on a
/// port the system picks, that takes one redirect — the one carrying this
/// attempt's `state` — and answers it with a page once Copper knows how the
/// sign-in went. Requests with another `state` are turned away and the wait
/// goes on, so another page on this Mac can't end it. Closed after one
/// redirect, on cancel and on timeout.
@MainActor
final class CloudLoopback {
    enum Arrival: Equatable {
        case code(String)
        /// `error` (and `error_description`) instead of a code.
        case refused(String, String?)
    }

    /// What `CloudLoopback.parse` makes of one request.
    enum Request: Equatable {
        case arrival(Arrival)
        /// The callback, but not this attempt's.
        case wrongState
        /// Anything else: a favicon, a stray path.
        case other
    }

    typealias Reply = (HTTPResponse) -> Void

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var expected = ""
    private var opening: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<(Arrival, Reply), Error>?
    private var arrived: (Arrival, Reply)?
    /// The answer the browser is waiting for, until it is given.
    private var owed: Reply?
    private var taken = false
    private(set) var closed = false
    private(set) var port: UInt16?

    /// Listen, and wait for the port.
    func open(expecting state: String) async throws -> UInt16 {
        guard !closed else { throw CancellationError() }
        expected = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Cloud.Failure(status: 0, code: "loopback", message: "Copper couldn't listen for the sign-in on this Mac — try again")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let waiting = self.opening else { return }
                    switch state {
                    case .ready:
                        self.opening = nil
                        if let port = listener?.port?.rawValue, port != 0 {
                            self.port = port
                            waiting.resume(returning: port)
                        } else {
                            waiting.resume(throwing: Cloud.Failure(status: 0, code: "loopback", message: "Copper couldn't listen for the sign-in on this Mac — try again"))
                        }
                    case .failed:
                        self.opening = nil
                        waiting.resume(throwing: Cloud.Failure(status: 0, code: "loopback", message: "Copper couldn't listen for the sign-in on this Mac — try again"))
                    case .cancelled:
                        self.opening = nil
                        waiting.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    /// The redirect, when it comes, and how to answer the browser. Throws
    /// `CancellationError` when closed (cancel, timeout) first.
    func callback() async throws -> (Arrival, Reply) {
        if let arrived { self.arrived = nil; return arrived }
        guard !closed else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if closed { continuation.resume(throwing: CancellationError()) } else { waiter = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    /// Stop listening. A browser still owed an answer gets one; the
    /// connections close a moment later, so a reply on its way gets out.
    func close() {
        guard !closed else { return }
        closed = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if let opening { self.opening = nil; opening.resume(throwing: CancellationError()) }
        if let waiter { self.waiter = nil; waiter.resume(throwing: CancellationError()) }
        if let owed {
            self.owed = nil
            owed(Self.page(ok: false, heading: "Copper stopped waiting", line: "The sign-in was cancelled in Copper. Return to Copper to start again."))
        }
        let open = connections
        connections = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for connection in open.values { connection.close() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = Connection(connection) { [weak self] request, answer in
            MainActor.assumeIsolated {
                guard let self else { answer(HTTPResponse(status: 503, body: Data())); return }
                self.handle(request, answer: answer)
            }
        } gone: { [weak self] id in
            MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
        }
        connections[wrapped.id] = wrapped
        wrapped.open()
    }

    private func handle(_ request: HTTPRequest, answer: @escaping Reply) {
        guard request.method == "GET" else { answer(HTTPResponse(status: 405, body: Data())); return }
        switch Self.parse(request.path, state: expected) {
        case .other:
            answer(HTTPResponse(status: 404, body: Data()))
        case .wrongState:
            answer(Self.page(ok: false, heading: "Not this sign-in", line: "Copper is waiting for a different sign-in. Start again from Copper.", status: 400))
        case .arrival(let arrival):
            guard !taken, !closed else {
                answer(Self.page(ok: true, heading: "This sign-in is finished", line: "Return to Copper. You can close this tab."))
                return
            }
            taken = true
            owed = answer
            let reply: Reply = { [weak self] response in
                guard let self, let owed = self.owed else { return }
                self.owed = nil
                owed(response)
            }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: (arrival, reply))
            } else {
                arrived = (arrival, reply)
            }
        }
    }

    /// One request's target (`/?code=…&state=…`) read against the state
    /// this attempt sent. Only the root path is the callback.
    nonisolated static func parse(_ target: String, state expected: String) -> Request {
        guard let parts = URLComponents(string: "http://127.0.0.1" + (target.hasPrefix("/") ? target : "/" + target)) else { return .other }
        guard parts.path == "/" || parts.path.isEmpty else { return .other }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let code = value("code"), error = value("error")
        guard code != nil || error != nil else { return .other }
        guard let state = value("state"), !expected.isEmpty, Self.same(state, expected) else { return .wrongState }
        if let error, !error.isEmpty { return .arrival(.refused(error, value("error_description"))) }
        guard let code, !code.isEmpty else { return .wrongState }
        return .arrival(.code(code))
    }

    /// Constant-time string comparison, for the state.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    /// The page the browser shows when it comes back: one heading, one line,
    /// in the browser's own light or dark.
    nonisolated static func page(ok: Bool, heading: String, line: String, status: Int? = nil) -> HTTPResponse {
        let mark = ok ? "#2f9e6b" : "#c2410c"
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>\(html(heading)) · Copper</title><style>:root{color-scheme:light dark}\
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;background:Canvas;color:CanvasText}\
        main{max-width:30rem;padding:2rem}i{display:block;width:10px;height:10px;border-radius:50%;background:\(mark);margin-bottom:14px}\
        h1{font-size:1.3rem;font-weight:600;margin:0 0 .35rem}p{margin:0;opacity:.72}</style></head>\
        <body><main><i></i><h1>\(html(heading))</h1><p>\(html(line))</p></main></body></html>
        """
        var response = HTTPResponse(status: status ?? (ok ? 200 : 400), body: Data(html.utf8))
        response.contentType = "text/html; charset=utf-8"
        return response
    }

    nonisolated static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - copper://cloud/join

/// `copper://cloud/join?code=<percent-encoded copper-cloud://…>` — the
/// instance's `/start` page's *Open in Copper*. Opens Settings › Cloud with
/// the code; a join link (`#sso=`) starts the sign-in at once, so the person
/// is one click from the provider's page. Never switches instance or
/// account without a press: a code for another instance than the one this
/// Mac is linked to waits on the page for one.
@MainActor
enum CloudJoin {
    /// The code in a `copper://cloud/join` link, as it would be pasted; nil
    /// for any other address. `code` is the last parameter, and everything
    /// after `code=` is the code — so a link encoded only in part (`%23sso=…&fp=…`,
    /// or a `#` left as it is) keeps its fingerprint rather than losing it
    /// to a parameter of its own, which would drop the pin.
    nonisolated static func code(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "copper", url.host()?.lowercased() == "cloud" else { return nil }
        let path = url.path(percentEncoded: false).split(separator: "/").map { $0.lowercased() }
        guard path == ["join"], let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        let start: String.Index
        if query.hasPrefix("code=") { start = query.index(query.startIndex, offsetBy: 5) }
        else if let at = query.range(of: "&code=") { start = at.upperBound }
        else { return nil }
        var text = String(query[start...]).removingPercentEncoding ?? ""
        if !text.contains("#"), let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty {
            text += "#" + fragment
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// True when `url` was a cloud join link and has been taken.
    static func handle(_ url: URL, in browser: Browser) -> Bool {
        guard url.scheme?.lowercased() == "copper", url.host()?.lowercased() == "cloud" else { return false }
        CanvasUI.openCloudSettings(in: browser)
        guard let text = code(in: url), let parsed = Cloud.parseCode(text) else {
            browser.announce("That Copper Cloud link is incomplete — open it again from the page that gave it")
            return true
        }
        let cloud = Cloud.shared
        let same = cloud.link.map { CloudSSO.sameInstance($0.url, parsed.url) } ?? false
        if same, cloud.isSignedIn, let account = cloud.account {
            browser.announce("Already signed in to \(parsed.host) as \(account.email)")
            return true
        }
        switch parsed {
        case .sso(let code) where !cloud.isLinked || same:
            CloudSSO.shared.show(text, parsed)
            // Linked to that instance already: its own pin is the one to keep.
            let pin = same ? (cloud.link?.fingerprint ?? code.fingerprint) : code.fingerprint
            CloudSSO.shared.start(CloudSSO.Target(url: cloud.link?.url ?? code.url, pin: pin, provider: code.provider), in: browser)
            CloudLog.note("Join link from \(code.host): single sign-on started")
        case _ where same:
            browser.announce("Already connected to \(parsed.host) — sign in on the Cloud page")
        default:
            // Not linked: the Connect field takes it. Linked elsewhere: the
            // page says so, and nothing changes without a press.
            CloudSSO.shared.show(text, parsed)
        }
        return true
    }

    /// The pure part, for `cloud selftest` and the unit tests.
    nonisolated static func selfTest() -> [(String, Bool)] {
        let fp = String(repeating: "cd", count: 32)
        let link = "copper-cloud://100.57.251.123:443/#sso=google&fp=\(fp)"
        let encoded = link.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? link
        func code(_ text: String) -> String? { URL(string: text).flatMap(CloudJoin.code(in:)) }
        var checks: [(String, Bool)] = []
        checks.append(("join: percent-encoded code", code("copper://cloud/join?code=\(encoded)") == link))
        checks.append(("join: unencoded # put back", code("copper://cloud/join?code=copper-cloud://100.57.251.123:443/#sso=google&fp=\(fp)") == link))
        checks.append(("join: only # encoded keeps the pin", code("copper://cloud/join?code=copper-cloud://100.57.251.123:443/%23sso=google&fp=\(fp)") == link))
        checks.append(("join: code after another parameter", code("copper://cloud/join?from=start&code=\(encoded)") == link))
        checks.append(("join: ACME link without fp", code("copper://cloud/join?code=copper-cloud%3A%2F%2Fcopper.dev.exowatt.com%2F%23sso%3Dgoogle") == "copper-cloud://copper.dev.exowatt.com/#sso=google"))
        checks.append(("join: other copper links are not joins", code("copper://canvas/join/tok?cloud=x") == nil && code("copper://cloud/other?code=x") == nil))
        checks.append(("join: no code", code("copper://cloud/join") == nil))
        if case .sso(let sso)? = code("copper://cloud/join?code=\(encoded)").flatMap({ Cloud.parseCode($0) }) {
            checks.append(("join: reads as a join link", sso.provider == "google" && sso.fingerprint == fp && sso.url.absoluteString == "https://100.57.251.123:443"))
        } else {
            checks.append(("join: reads as a join link", false))
        }
        return checks
    }
}

// MARK: - self-checks

extension CloudSSO {
    /// The pure parts — join links, discovery, the authorization address,
    /// PKCE, the callback and the refusals in words — for `cloud selftest`
    /// and the unit tests (Tests/SearchTests/CloudSSOTests.swift).
    nonisolated static func selfTest() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let fp = String(repeating: "ab", count: 32)

        // Join links.
        if case .sso(let code)? = Cloud.parseCode("copper-cloud://100.57.251.123:443/#sso=google&fp=\(fp)") {
            checks.append(("sso: join link with fp", code.url.absoluteString == "https://100.57.251.123:443" && code.provider == "google" && code.fingerprint == fp))
            checks.append(("sso: round trip", Cloud.parseCode(code.link) == .sso(code)))
        } else {
            checks.append(("sso: join link with fp", false))
        }
        if case .sso(let code)? = Cloud.parseCode(" copper-cloud://copper.dev.exowatt.com/#sso=google\n") {
            checks.append(("sso: ACME join link, no fp", code.url.absoluteString == "https://copper.dev.exowatt.com" && code.fingerprint == nil))
        } else {
            checks.append(("sso: ACME join link, no fp", false))
        }
        if case .sso(let code)? = Cloud.parseCode("copper-cloud://h:1/#sso=Google&fp=" + Array(repeating: "AB", count: 32).joined(separator: ":")) {
            checks.append(("sso: colon fp, provider kept as given", code.fingerprint == fp && code.provider == "Google"))
        } else {
            checks.append(("sso: colon fp, provider kept as given", false))
        }
        if case .sso(let code)? = Cloud.parseCode("http://127.0.0.1:8443/#sso=google") {
            checks.append(("sso: loopback http", code.url.scheme == "http" && code.fingerprint == nil))
        } else {
            checks.append(("sso: loopback http", false))
        }
        checks.append(("sso: short fp refused", Cloud.parseCode("copper-cloud://h:1/#sso=google&fp=12") == nil))
        checks.append(("sso: plain http off-loopback refused", Cloud.parseCode("http://evil.example.com/#sso=google") == nil))
        checks.append(("sso: provider can't leave its path", Cloud.parseCode("copper-cloud://h:1/#sso=../admin") == nil
            && Cloud.parseCode("copper-cloud://h:1/#sso=a%2Fb") == nil && Cloud.parseCode("copper-cloud://h:1/#sso=") == nil))
        checks.append(("sso: not a link code", Cloud.parseLinkCode("copper-cloud://h:1/#sso=google") == nil))
        if case .link? = Cloud.parseCode("copper-cloud://h:1/#k=key&sso=google") {
            checks.append(("sso: a key wins (a link code)", true))
        } else {
            checks.append(("sso: a key wins (a link code)", false))
        }

        // Discovery.
        let body = Data("""
        {"enabled": true, "password_signin": false,
         "providers": [{"id": "google", "kind": "google", "name": "Google",
           "client_id": "123-abc.apps.googleusercontent.com",
           "authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth",
           "scopes": ["openid", "email", "profile"], "domains": ["exowatt.com"], "hd": "exowatt.com"}]}
        """.utf8)
        let found = try? JSONDecoder().decode(Cloud.SSODiscovery.self, from: body)
        checks.append(("sso: discovery reads", found?.enabled == true && found?.passwordSignin == false && found?.usable.first?.clientId == "123-abc.apps.googleusercontent.com"
            && found?.usable.first?.hd == "exowatt.com" && found?.usable.first?.domains == ["exowatt.com"]))
        let off = try? JSONDecoder().decode(Cloud.SSODiscovery.self, from: Data(#"{"enabled": false, "password_signin": true, "providers": []}"#.utf8))
        checks.append(("sso: off reads as none", off?.usable.isEmpty == true && off?.passwordSignin == true))
        let disabledButListed = Cloud.SSODiscovery(enabled: false, providers: found?.providers ?? [])
        checks.append(("sso: providers hidden while off", disabledButListed.usable.isEmpty))
        let bare = try? JSONDecoder().decode(Cloud.SSODiscovery.self, from: Data(#"{"enabled": true, "providers": [{"id": "okta", "client_id": "c", "authorization_endpoint": "https://o.example.com/authorize"}]}"#.utf8))
        checks.append(("sso: missing name, kind, scopes", bare?.usable.first?.name == "Okta" && bare?.usable.first?.kind == "oidc" && bare?.passwordSignin == true))

        // The provider to use.
        if let found {
            checks.append(("sso: pick by id", (try? pick(found, id: "google", host: "h"))?.id == "google"))
            checks.append(("sso: pick the first", (try? pick(found, id: nil, host: "h"))?.id == "google"))
            checks.append(("sso: unknown provider refused", (try? pick(found, id: "okta", host: "h")) == nil))
        }
        checks.append(("sso: none offered refused", (try? pick(.none, id: nil, host: "h")) == nil))

        // The authorization address.
        let provider = Cloud.SSODiscovery.Provider(id: "google", name: "Google", clientId: "123-abc.apps.googleusercontent.com",
                                                   authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                                                   domains: ["exowatt.com"], hd: "exowatt.com")
        let redirect = redirect(port: 53682)
        let url = authorizeURL(provider, redirect: redirect, state: "st-1", challenge: "ch_1")
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        checks.append(("sso: authorize host", url?.host() == "accounts.google.com" && url?.path() == "/o/oauth2/v2/auth" && url?.scheme == "https"))
        checks.append(("sso: authorize parameters", item("client_id") == provider.clientId && item("response_type") == "code"
            && item("scope") == "openid email profile" && item("redirect_uri") == "http://127.0.0.1:53682/" && item("state") == "st-1"
            && item("code_challenge") == "ch_1" && item("code_challenge_method") == "S256" && item("prompt") == "select_account" && item("hd") == "exowatt.com"))
        checks.append(("sso: redirect escaped", url?.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F") == true
            && url?.absoluteString.contains("scope=openid%20email%20profile") == true))
        var noHD = provider
        noHD.hd = nil
        checks.append(("sso: no hd without one", authorizeURL(noHD, redirect: redirect, state: "s", challenge: "c")?.absoluteString.contains("hd=") == false))
        var kept = provider
        kept.authorizationEndpoint = "https://login.example.com/authorize?tenant=t1&prompt=none"
        let keptItems = authorizeURL(kept, redirect: redirect, state: "s", challenge: "c").flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        checks.append(("sso: endpoint query kept, ours win", keptItems.contains { $0.name == "tenant" && $0.value == "t1" }
            && keptItems.filter { $0.name == "prompt" }.map(\.value) == ["select_account"]))
        var plain = provider
        plain.authorizationEndpoint = "http://accounts.example.com/auth"
        checks.append(("sso: plain http provider refused", authorizeURL(plain, redirect: redirect, state: "s", challenge: "c") == nil))
        plain.authorizationEndpoint = "http://127.0.0.1:9/authorize"
        checks.append(("sso: loopback http provider (tests)", authorizeURL(plain, redirect: redirect, state: "s", challenge: "c") != nil))

        // PKCE (RFC 7636 appendix B).
        checks.append(("sso: S256 challenge", challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        let v = verifier()
        checks.append(("sso: verifier shape", v.count == 43 && v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && v != verifier()))

        // The callback.
        checks.append(("sso: callback code", CloudLoopback.parse("/?code=4%2F0Ab&state=st-1&scope=email", state: "st-1") == .arrival(.code("4/0Ab"))))
        checks.append(("sso: callback refused", CloudLoopback.parse("/?error=access_denied&state=st-1", state: "st-1") == .arrival(.refused("access_denied", nil))))
        checks.append(("sso: callback wrong state", CloudLoopback.parse("/?code=x&state=other", state: "st-1") == .wrongState
            && CloudLoopback.parse("/?code=x", state: "st-1") == .wrongState))
        checks.append(("sso: other requests ignored", CloudLoopback.parse("/favicon.ico", state: "st-1") == .other
            && CloudLoopback.parse("/", state: "st-1") == .other && CloudLoopback.parse("/x?code=1&state=st-1", state: "st-1") == .other))
        checks.append(("sso: page escapes", String(decoding: CloudLoopback.page(ok: false, heading: "<b>", line: "a&b").body, as: UTF8.self).contains("&lt;b&gt;")))

        // Refusals in words.
        let domain = Cloud.ssoFailure(Cloud.Failure(status: 403, code: "sso_domain", message: "only exowatt.com"), provider: provider)
        checks.append(("sso: sso_domain names the domain", domain.message == "Use your @exowatt.com account"))
        var two = provider
        two.domains = ["a.com", "b.com", "c.com"]
        checks.append(("sso: several domains", domainHint(two.domains) == "Use your @a.com, @b.com or @c.com account" && domainHint(["a.com", "b.com"]) == "Use your @a.com or @b.com account"))
        checks.append(("sso: no domains, the server's words", Cloud.ssoFailure(Cloud.Failure(status: 403, code: "sso_domain", message: "Use your work account"), provider: noDomains(provider)).message == "Use your work account"))
        checks.append(("sso: other refusals", Cloud.ssoFailure(Cloud.Failure(status: 404, code: "sso_disabled", message: ""), provider: provider).message.contains("turned off")
            && Cloud.ssoFailure(Cloud.Failure(status: 403, code: "sso_no_account", message: ""), provider: provider).message.contains("admin")
            && Cloud.ssoFailure(Cloud.Failure(status: 401, code: "sso_failed", message: ""), provider: provider).message.hasPrefix("Google")))
        checks.append(("sso: refusal from the provider", refusal("access_denied", nil, provider: "Google").contains("cancelled")))
        checks.append(("sso: state compared exactly", CloudLoopback.same("abc", "abc") && !CloudLoopback.same("abc", "abd") && !CloudLoopback.same("abc", "ab")))
        checks.append(("sso: same instance, :443 or not", sameInstance(URL(string: "https://h:443")!, URL(string: "https://H")!)
            && !sameInstance(URL(string: "https://h:8443")!, URL(string: "https://h")!)))
        return checks + CloudJoin.selfTest()
    }

    private nonisolated static func noDomains(_ provider: Cloud.SSODiscovery.Provider) -> Cloud.SSODiscovery.Provider {
        var provider = provider
        provider.domains = []
        return provider
    }
}
