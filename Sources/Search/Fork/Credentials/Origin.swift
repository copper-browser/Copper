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
    // shortcut: a bare host carries no scheme or port (keychain logins), so only the host is compared; record them at save (kSecAttrProtocol/kSecAttrPort) to tell http from https there too.
    nonisolated static func saved(_ site: String, isFor origin: String) -> Bool {
        func plain(_ origin: String) -> String { origin.replacingOccurrences(of: "://www.", with: "://") }
        let raw = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let there = URL(string: origin) else { return false }
        if raw.contains("://") {
            guard let url = URL(string: raw), let mine = self.origin(of: url) else { return false }
            return plain(mine) == plain(origin)
        }
        guard let url = URL(string: "https://\(raw)"), let mine = self.origin(scheme: there.scheme, host: url.host, port: url.port ?? there.port) else { return false }
        return plain(mine) == plain(origin)
    }

    /// Whether an agent may fill `credential` into a document of `origin`:
    /// one of its saved addresses is that origin, and none says never there.
    static func owns(_ credential: Credential, origin: String) -> Bool {
        if case .bitwarden(let id) = credential.id, let item = Bitwarden.shared.cachedItems.first(where: { $0.id == id }) {
            // Bitwarden's "never" on an address holds here too.
            return item.uris.contains { ($0.match ?? 0) != 5 && saved($0.uri, isFor: origin) }
        }
        return credential.sites.contains { saved($0, isFor: origin) }
    }
}
