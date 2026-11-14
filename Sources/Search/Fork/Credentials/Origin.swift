import Foundation
import WebKit

// Fork (form-origin): a saved login belongs to an origin — scheme, host and
// port, as a document's `location.origin` says it — and what Copper fills
// without a person choosing (an agent's sign-in) goes only where that origin
// is. The list a person picks from stays wider (the site and its subdomains,
// `Credentials.candidates`): they see the address and choose the row; the
// fill is still pinned to the frame it was chosen for (Tab.FormTarget).

extension Credentials {
    /// `https://example.com`, `http://127.0.0.1:8795` — as `location.origin`
    /// writes it. Nil for an address with no host (a file, about:blank).
    nonisolated static func origin(of url: URL) -> String? {
        origin(scheme: url.scheme, host: url.host, port: url.port)
    }

    static func origin(of origin: WKSecurityOrigin) -> String? {
        self.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    nonisolated static func origin(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty, var host = host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let usual = ["http": 80, "https": 443][scheme]
        guard let port, port != 0, port != usual else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Whether a login's saved address (`site`: a URL, or a bare host as the
    /// keychain keeps it) is this origin. A leading `www.` is the same site
    /// either way, as everywhere else here; nothing else is: not another
    /// subdomain, not another port, not http for https.
    ///
    /// Fork (origin-save): a bare host says no scheme or port, so it is
    /// https on its usual port (or the port written after it). Only a
    /// loopback host — a server on this Mac — takes the page's scheme and
    /// port. A login saved from an http page or another port keeps them
    /// (`Vault.save(…, origin:)`) and reads as a URL here.
    nonisolated static func saved(_ site: String, isFor origin: String) -> Bool {
        func plain(_ origin: String) -> String { origin.replacingOccurrences(of: "://www.", with: "://") }
        let raw = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let there = URL(string: origin) else { return false }
        if raw.contains("://") {
            guard let url = URL(string: raw), let mine = self.origin(of: url) else { return false }
            return plain(mine) == plain(origin)
        }
        guard let url = URL(string: "https://\(raw)"), let host = url.host else { return false }
        let local = loopback(host)
        guard let mine = self.origin(scheme: local ? there.scheme : "https", host: host, port: url.port ?? (local ? there.port : nil)) else { return false }
        return plain(mine) == plain(origin)
    }

    /// localhost, *.localhost, 127.0.0.0/8 and ::1: this Mac.
    nonisolated static func loopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    /// Fork (agent-autofill): an autofill item — a login whose custom field
    /// is asked for — by its autofill id (`op:<id>` or a bare Bitwarden id):
    /// whether one of its addresses is this origin, as `owns` asks of a login.
    static func owns(autofillID id: String, origin: String) -> Bool {
        if id.hasPrefix("op:") {
            let raw = String(id.dropFirst(3))
            guard let item = OnePassword.shared.cachedItems.first(where: { $0.id == raw }) else { return false }
            return item.urls.contains { saved($0, isFor: origin) }
        }
        guard let item = Bitwarden.shared.cachedItems.first(where: { $0.id == id }) else { return false }
        return item.uris.contains { ($0.match ?? 0) != 5 && saved($0.uri, isFor: origin) }
    }

    /// Whether an agent may fill `credential` into a document of `origin`:
    /// one of its saved addresses is that origin, and none says never there.
    static func owns(_ credential: Credential, origin: String) -> Bool {
        // Bitwarden's "never" on an address holds here too.
        if case .bitwarden(let id) = credential.id { return owns(autofillID: id, origin: origin) }
        return credential.sites.contains { saved($0, isFor: origin) }
    }
}
