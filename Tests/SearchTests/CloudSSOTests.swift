import Foundation
import Network
import Testing
@testable import Search

// Copper Cloud single sign-on (Fork/Cloud/CloudSSO.swift): the join link,
// discovery, the authorization address, PKCE and copper://cloud/join as
// pure checks (the same ones `./bench cloud selftest` runs), then the parts
// that talk — the loopback listener taking the browser's redirect, and the
// two requests against a pretend copper-cloud on this Mac. Nothing here
// signs this Mac in: keeping the answer is the pairing path's
// (`Cloud.adoptSignedIn`), and a test must not write a world's cloud.json.

@Suite("Cloud single sign-on")
struct CloudSSOTests {
    @Test(arguments: CloudSSO.selfTest().map(\.0))
    func selfCheck(_ name: String) {
        let ok = CloudSSO.selfTest().first { $0.0 == name }?.1
        #expect(ok == true, "\(name)")
    }

    @Test func joinLinkFromCopperURL() throws {
        let fp = String(repeating: "0f", count: 32)
        let link = "copper-cloud://100.57.251.123:443/#sso=google&fp=\(fp)"
        let encoded = try #require(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try #require(URL(string: "copper://cloud/join?code=\(encoded)"))
        let code = try #require(CloudJoin.code(in: url))
        guard case .sso(let sso)? = Cloud.parseCode(code) else {
            Issue.record("not a join link: \(code)")
            return
        }
        #expect(sso.fingerprint == fp)
        #expect(sso.provider == "google")
        #expect(sso.link == link)
    }

    @Test func pairingAndLinkCodesStillRead() {
        let fp = String(repeating: "ab", count: 32)
        if case .link? = Cloud.parseCode("copper-cloud://h:443/#k=key&fp=\(fp)") {} else { Issue.record("link code") }
        if case .pairing? = Cloud.parseCode("copper-cloud://h:443/#p=cp_\(String(repeating: "a", count: 20))&fp=\(fp)") {} else { Issue.record("pairing code") }
    }

    @MainActor @Test func loopbackTakesTheRedirectWithItsState() async throws {
        let loopback = CloudLoopback()
        let port = try await loopback.open(expecting: "st-42")
        #expect(port > 0)
        let base = "http://127.0.0.1:\(port)"

        // A stray request and another sign-in's redirect don't end the wait.
        let stray = try await Self.get(base + "/favicon.ico")
        #expect(stray.status == 404)
        let other = try await Self.get(base + "/?code=nope&state=someone-else")
        #expect(other.status == 400)

        // The browser coming back: it waits for its page while Copper finishes.
        let browser = Task.detached { try await Self.get(base + "/?code=4%2F0AbCd&state=st-42&scope=email") }
        let (arrival, reply) = try await loopback.callback()
        #expect(arrival == .code("4/0AbCd"))
        reply(CloudLoopback.page(ok: true, heading: "You're signed in — return to Copper", line: "You can close this tab."))
        let page = try await browser.value
        #expect(page.status == 200)
        #expect(page.body.contains("You&#39;re signed in") || page.body.contains("You're signed in"))
        loopback.close()
        #expect(loopback.closed)
    }

    @MainActor @Test func loopbackClosedEndsTheWait() async throws {
        let loopback = CloudLoopback()
        _ = try await loopback.open(expecting: "s")
        let waiting = Task { @MainActor in
            do { _ = try await loopback.callback(); return false } catch is CancellationError { return true } catch { return false }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        loopback.close()
        #expect(await waiting.value)
    }

    @MainActor @Test func loopbackAnswersAProviderRefusal() async throws {
        let loopback = CloudLoopback()
        let port = try await loopback.open(expecting: "s")
        let browser = Task.detached { try await Self.get("http://127.0.0.1:\(port)/?error=access_denied&state=s") }
        let (arrival, reply) = try await loopback.callback()
        #expect(arrival == .refused("access_denied", nil))
        reply(CloudLoopback.page(ok: false, heading: "Copper couldn't sign you in", line: "Cancelled."))
        #expect(try await browser.value.status == 400)
        loopback.close()
    }

    @MainActor @Test func discoveryAndExchangeAgainstAPretendCloud() async throws {
        let cloud = PretendCloud()
        let port = try await cloud.start()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))

        let found = try await Cloud.discoverSSO(url: url, pin: nil)
        let provider = try #require(found.usable.first)
        #expect(provider.name == "Google")
        #expect(provider.domainHint == "Use your @exowatt.com account")

        let device = ["id": "6f1c2a8e-0000-4000-8000-000000000001", "name": "Test Mac"]
        let answer = try await Cloud.exchangeSSO(url: url, pin: nil, provider: provider, code: "good", verifier: "v" + String(repeating: "x", count: 42),
                                                 redirect: "http://127.0.0.1:53682/", device: device)
        #expect(answer.user.email == "farce@exowatt.com")
        #expect(answer.gateKey == "ck_gate")
        #expect(answer.created == true)
        #expect(answer.device?.id.uuidString.lowercased() == device["id"])
        let sent = try #require(cloud.lastBody)
        #expect(sent["code"] as? String == "good")
        #expect(sent["code_verifier"] as? String == "v" + String(repeating: "x", count: 42))
        #expect(sent["redirect_uri"] as? String == "http://127.0.0.1:53682/")
        #expect((sent["device"] as? [String: String]) == device)
        #expect(cloud.lastGate == nil, "no instance gate header on SSO requests")

        do {
            _ = try await Cloud.exchangeSSO(url: url, pin: nil, provider: provider, code: "gmail", verifier: "v", redirect: "http://127.0.0.1:1/", device: device)
            Issue.record("a personal account was let in")
        } catch let failure as Cloud.Failure {
            #expect(failure.code == "sso_domain")
            #expect(failure.message == "Use your @exowatt.com account")
        }
        cloud.stop()
    }

    @MainActor @Test func anOldCloudOffersNone() async throws {
        let cloud = PretendCloud(old: true)
        let port = try await cloud.start()
        let found = try await Cloud.discoverSSO(url: try #require(URL(string: "http://127.0.0.1:\(port)")), pin: nil)
        #expect(found == .none)
        cloud.stop()
    }

    /// The whole of it, end to end: `CloudSSO.start` against a pretend
    /// copper-cloud whose pretend provider is a closure here (it reads the
    /// authorization address and sends the browser straight back with a
    /// code), then the answer kept as a pairing keeps it — linked with the
    /// gate key, signed in, the session used. It writes a world's
    /// cloud.json, so it runs only in a world of its own and cleans up:
    ///
    ///     COPPER_SSO_E2E=1 SEARCH_PROBE=ssotest swift test --filter CloudSSOTests
    @MainActor @Test(.enabled(if: CloudSSOTests.ownWorld))
    func wholeFlowAgainstAPretendCloud() async throws {
        #expect(!Cloud.shared.isLinked, "the world must start unlinked")
        let pretend = PretendCloud()
        let port = try await pretend.start()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        var asked: [String: String] = [:]
        let flow = CloudSSO.shared
        flow.start(CloudSSO.Target(url: url, pin: nil, provider: "google"), sync: false, open: { authorize in
            let items = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for item in items { asked[item.name] = item.value ?? "" }
            pretend.challenge = asked["code_challenge"]
            guard let back = asked["redirect_uri"], let state = asked["state"] else { return false }
            Task.detached { _ = try? await URLSession.shared.data(from: URL(string: back + "?code=good&state=" + state)!) }
            return true
        })
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !flow.busy { break }
        }
        #expect(flow.phase == .idle, "\(flow.phase)")
        #expect(asked["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(asked["response_type"] == "code" && asked["prompt"] == "select_account" && asked["hd"] == "exowatt.com")
        #expect(asked["code_challenge_method"] == "S256")
        #expect(asked["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true && asked["redirect_uri"]?.hasSuffix("/") == true)
        #expect(pretend.verified, "the verifier sent matches the challenge")
        #expect(Cloud.shared.isSignedIn)
        #expect(Cloud.shared.link?.key == "ck_gate")
        #expect(Cloud.shared.link?.url == url)
        #expect(Cloud.shared.account?.email == "farce@exowatt.com")
        // The session is the one handed back, through the gate key.
        let deadline2 = Date().addingTimeInterval(5)
        while pretend.meGate == nil, Date() < deadline2 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(pretend.meGate == "ck_gate")
        #expect(pretend.meToken == "Bearer cs_session")

        Cloud.shared.disconnect()
        pretend.stop()
        if let world = Store.world, world == CloudSSOTests.world { try? FileManager.default.removeItem(at: Store.folder) }
    }

    static let world = (ProcessInfo.processInfo.environment["SEARCH_PROBE"] ?? "").lowercased()
    static let ownWorld = ProcessInfo.processInfo.environment["COPPER_SSO_E2E"] != nil
        && !["", "1", "test", "dev"].contains(world)

    /// A GET the way a browser would make it, without following anything.
    static func get(_ address: String) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }
}

/// copper-cloud's two single sign-on routes, as the contract has them, on
/// 127.0.0.1 over plain HTTP (allowed to this Mac only).
@MainActor
private final class PretendCloud {
    private let old: Bool
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private(set) var lastBody: [String: Any]?
    private(set) var lastGate: String?
    /// What the pretend provider was asked for, and whether the verifier fit it.
    var challenge: String?
    private(set) var verified = false
    private(set) var meGate: String?
    private(set) var meToken: String?

    init(old: Bool = false) { self.old = old }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak listener] state in
                MainActor.assumeIsolated {
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener?.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = Connection(connection) { [weak self] request, answer in
            MainActor.assumeIsolated { answer(self?.respond(request) ?? HTTPResponse(status: 500, body: Data())) }
        } gone: { [weak self] id in
            MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
        }
        connections[wrapped.id] = wrapped
        wrapped.open()
    }

    private func respond(_ request: HTTPRequest) -> HTTPResponse {
        if old { return HTTPResponse(status: 404, json: ["error": "not_found", "message": "not found"]) }
        switch (request.method, request.path) {
        case ("GET", "/v1/auth/sso"):
            return HTTPResponse(status: 200, json: [
                "enabled": true, "password_signin": true,
                "providers": [["id": "google", "kind": "google", "name": "Google",
                               "client_id": "123-abc.apps.googleusercontent.com",
                               "authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth",
                               "scopes": ["openid", "email", "profile"], "domains": ["exowatt.com"], "hd": "exowatt.com"]],
            ])
        case ("POST", "/v1/auth/sso/google"):
            lastGate = request.headers["x-copper-instance"]
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            lastBody = body
            guard body["code"] as? String == "good" else {
                return HTTPResponse(status: 403, json: ["error": "sso_domain", "message": "Sign in with an exowatt.com account"])
            }
            if let challenge {
                verified = CloudSSO.challenge(body["code_verifier"] as? String ?? "") == challenge
                guard verified else { return HTTPResponse(status: 401, json: ["error": "sso_failed", "message": "bad verifier"]) }
            }
            let device = body["device"] as? [String: String] ?? [:]
            return HTTPResponse(status: 200, json: [
                "token": "cs_session", "gate_key": "ck_gate", "created": true,
                "user": ["id": "0b9c8f3e-1111-4000-8000-000000000002", "email": "farce@exowatt.com", "display_name": "Felipe Arce",
                         "created_at": "2026-10-19T00:00:00Z"],
                "device": ["id": device["id"] ?? "", "name": device["name"] ?? ""],
            ])
        case ("GET", "/v1/auth/me"):
            meGate = request.headers["x-copper-instance"]
            meToken = request.headers["authorization"]
            return HTTPResponse(status: 200, json: [
                "user": ["id": "0b9c8f3e-1111-4000-8000-000000000002", "email": "farce@exowatt.com", "display_name": "Felipe Arce"],
            ])
        default:
            return HTTPResponse(status: 404, json: ["error": "not_found", "message": "not found"])
        }
    }
}
