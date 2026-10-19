import AppKit
import Foundation

// Pairing codes (spec §7.2, §7.5): a Copper already signed in mints a
// single-use code, good for ten minutes, that links another Mac to the same
// instance AND signs it in as the same person — no link code, no password.
//
//   POST   /v1/auth/pairing {device_name?}   → {id, code, link, expires_at}   (signed in)
//   GET    /v1/auth/pairing                  → my unused, unexpired codes     (signed in)
//   DELETE /v1/auth/pairing/{id}             → revoke an unused one           (signed in)
//   POST   /v1/auth/pair {code, device}      → {token, user, device, gate_key} (no gate header)
//
// The receiving side is `Cloud.pair` (Cloud.swift: it touches the kept link,
// token and session in one write). This file is the minting side, and
// `CloudPairing`, the one code this Copper is showing — shared by the Cloud
// page's "Pair another Mac" card, the ⌘K command and `./bench cloud
// pairing-code`, so all three see the same code and the same countdown.
// A minted code is never written to disk and never logged.

extension Cloud {
    /// What `POST /v1/auth/pairing` answers: the code once, and the whole
    /// `copper-cloud://…#p=…&fp=…` the other Mac pastes.
    struct MintedPairing: Equatable {
        var id: UUID
        /// `cp_…` — the credential. Shown, copied, never kept.
        var code: String
        /// The pairing code whole, as the other Mac pastes it.
        var link: String
        var createdAt: Date
        var expiresAt: Date
        var deviceName: String?
    }

    /// One of my open pairing codes (`GET /v1/auth/pairing`) — never the
    /// code itself, which the server only has the hash of.
    struct PairingInfo: Equatable {
        var id: UUID
        var deviceName: String?
        var createdAt: Date?
        var expiresAt: Date
        var usedAt: Date?
    }

    private struct MintedWire: Decodable {
        var id: UUID
        var code: String
        var link: String
        var created_at: String?
        var expires_at: String
        var device_name: String?
    }

    private struct InfoWire: Decodable {
        var id: UUID
        var device_name: String?
        var created_at: String?
        var expires_at: String
        var used_at: String?
    }

    /// Mint a pairing code for another Mac. `deviceName` is what that Mac is
    /// called if it doesn't say (Copper always does). The link shown is the
    /// server's, which knows the address other Macs reach it by; when it
    /// carries no fingerprint but this Mac pins one, this Mac's pin is added,
    /// so the other one doesn't have to trust the certificate on sight.
    func mintPairingCode(deviceName: String? = nil) async throws -> MintedPairing {
        guard isSignedIn, let link else { throw Failure(status: 0, code: "not_signed_in", message: "Sign in first — a pairing code signs the other Mac in as you") }
        var body: [String: Any] = [:]
        if let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { body["device_name"] = name }
        let wire: MintedWire
        do {
            wire = try await requestJSON("POST", "/v1/auth/pairing", json: body)
        } catch let failure as Failure {
            throw Cloud.mintFailure(failure)
        }
        guard let expires = CloudSync.date(wire.expires_at) else {
            throw Failure(status: 200, code: "decode", message: "The server's pairing code has no expiry Copper can read")
        }
        var shown = wire.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .pairing(var parsed)? = Cloud.parseCode(shown), parsed.code == wire.code {
            if parsed.fingerprint == nil, parsed.url.scheme == "https", let pin = link.fingerprint {
                parsed.fingerprint = pin
                shown = parsed.link
            }
        } else {
            // Not one this Copper reads: build it from the address this Mac uses.
            shown = PairingCode(url: link.url, code: wire.code, fingerprint: link.fingerprint).link
        }
        CloudLog.note("Pairing code made — good once, until \(expires.formatted(date: .omitted, time: .shortened))")
        return MintedPairing(id: wire.id, code: wire.code, link: shown,
                             createdAt: wire.created_at.flatMap(CloudSync.date) ?? Date(),
                             expiresAt: expires, deviceName: wire.device_name)
    }

    /// My pairing codes still waiting to be used, newest first.
    func pairingCodes() async throws -> [PairingInfo] {
        guard isSignedIn else { throw Failure(status: 0, code: "not_signed_in", message: "Not signed in") }
        let rows: [InfoWire]
        do {
            rows = try await requestJSON("GET", "/v1/auth/pairing")
        } catch let failure as Failure {
            throw Cloud.mintFailure(failure)
        }
        return rows.compactMap { row in
            guard let expires = CloudSync.date(row.expires_at) else { return nil }
            return PairingInfo(id: row.id, deviceName: row.device_name, createdAt: row.created_at.flatMap(CloudSync.date),
                               expiresAt: expires, usedAt: row.used_at.flatMap(CloudSync.date))
        }
    }

    /// Revoke a pairing code nobody has used yet. A 404 means it was used,
    /// had expired, or was revoked already.
    func revokePairingCode(_ id: UUID) async throws {
        guard isSignedIn else { throw Failure(status: 0, code: "not_signed_in", message: "Not signed in") }
        do {
            _ = try await request("DELETE", "/v1/auth/pairing/\(id.uuidString.lowercased())")
            CloudLog.note("Pairing code revoked")
        } catch var failure as Failure {
            if failure.status == 404 { failure.message = "That code is gone already — used, expired or revoked" }
            throw failure
        }
    }

    nonisolated static func mintFailure(_ failure: Failure) -> Failure {
        var failure = failure
        switch (failure.status, failure.code) {
        case (404, _), (405, _):
            failure.message = "This instance doesn't make pairing codes yet — update copper-cloud"
        case (429, _), (_, "rate_limited"):
            failure.message = "Too many tries — wait a minute and try again"
        default:
            break
        }
        return failure
    }
}

/// The pairing code this Copper is showing, if any: made, copied, counted
/// down, revoked, and noticed when the other Mac uses it.
@MainActor
final class CloudPairing: ObservableObject {
    static let shared = CloudPairing()

    /// How long a code lasts (the server's `PAIRING_TTL_MINUTES`). The real
    /// expiry is the server's `expires_at`; this only draws the bar.
    nonisolated static let lifetime: TimeInterval = 600

    enum Outcome: Equatable {
        /// Another Mac signed in with it.
        case used(Date)
        case revoked
    }

    @Published private(set) var current: Cloud.MintedPairing?
    /// What became of `current` — it stays shown, with this said about it.
    @Published private(set) var outcome: Outcome?
    @Published private(set) var working = false
    @Published private(set) var copied = false
    @Published var problem: String?

    /// The account the code belongs to; a different one (or none) drops it.
    private var owner: UUID?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudPairing.shared.cloudChanged() }
        }
    }

    /// The code, while it can still be used.
    var live: Cloud.MintedPairing? {
        guard let current, outcome == nil, current.expiresAt > Date() else { return nil }
        return current
    }

    private func cloudChanged() {
        guard current != nil || problem != nil else { return }
        if Cloud.shared.account?.userId != owner { forget() }
    }

    private func forget() {
        current = nil
        outcome = nil
        problem = nil
        copied = false
        owner = nil
    }

    /// Make a fresh code. The one shown before, if still open, is revoked
    /// first — one code at a time on this page.
    @discardableResult
    func mint() async throws -> Cloud.MintedPairing {
        working = true
        defer { working = false }
        problem = nil
        if let open = live { try? await Cloud.shared.revokePairingCode(open.id) }
        do {
            let minted = try await Cloud.shared.mintPairingCode(deviceName: nil)
            current = minted
            outcome = nil
            copied = false
            owner = Cloud.shared.account?.userId
            return minted
        } catch {
            problem = error.localizedDescription
            throw error
        }
    }

    /// The card's button and the ⌘K command: mint without waiting.
    func make() {
        guard !working else { return }
        Task { try? await mint() }
    }

    /// ⌘K › Pair another Mac with Copper Cloud: the Cloud page, with a code
    /// on it (a new one unless one is showing still).
    func open(in browser: Browser) {
        browser.openSettings(.cloud)
        if live == nil { make() }
    }

    func revoke() async {
        guard let current, outcome == nil else { return }
        working = true
        defer { working = false }
        do {
            try await Cloud.shared.revokePairingCode(current.id)
            outcome = .revoked
            problem = nil
        } catch let failure as Cloud.Failure where failure.status == 404 {
            // Used or expired meanwhile: find out which, for the card.
            await check()
            if outcome == nil { outcome = .revoked }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Ask the server whether the code is still open; when it is gone
    /// before its time (and wasn't revoked here), another Mac used it.
    func check() async {
        guard let current, outcome == nil, current.expiresAt > Date() else { return }
        guard let open = try? await Cloud.shared.pairingCodes() else { return }
        guard self.current?.id == current.id, outcome == nil else { return }
        if let mine = open.first(where: { $0.id == current.id }) {
            if let used = mine.usedAt { outcome = .used(used); CloudLog.note("Pairing code used — another Mac is signed in") }
        } else if current.expiresAt > Date().addingTimeInterval(1) {
            outcome = .used(Date())
            CloudLog.note("Pairing code used — another Mac is signed in")
            Task { await CloudSync.shared.refreshDevices() }
        }
    }

    func copy() {
        guard let current else { return }
        SettingsActions.copy(current.link)
        copied = true
        let id = current.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.current?.id == id { self?.copied = false }
        }
    }

    /// The receiving side, as the page and the bench run it: pair, then
    /// "Turn on sync" with `domains` — the switches this Mac had before, or
    /// everything — so one paste ends with this Mac syncing.
    static func pairAndSync(_ code: Cloud.PairingCode, trusting: String? = nil, domains: Set<CloudSync.Domain>? = nil) async throws {
        try await Cloud.shared.pair(code, trusting: trusting)
        await syncAfterSignIn(domains)
    }

    /// What follows a sign-in that linked this Mac in one step — a pairing
    /// code, or single sign-on (CloudSSO.swift): "Turn on sync" with
    /// `domains`, or the switches this Mac had before, or everything.
    static func syncAfterSignIn(_ domains: Set<CloudSync.Domain>? = nil) async {
        let sync = CloudSync.shared
        let chosen = domains ?? (sync.enabled.isEmpty ? Set(CloudSync.Domain.allCases) : sync.enabled)
        guard !chosen.isEmpty else { return }
        await sync.turnOn(chosen)
    }

    /// `m:ss` left, for the countdown.
    nonisolated static func left(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
