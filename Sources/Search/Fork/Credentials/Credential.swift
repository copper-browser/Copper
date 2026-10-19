import Foundation

/// A stable identifier for a saved sign-in, independent of the backend that
/// stores its secret. The string form is intentionally small enough to use in
/// settings and in the agent allow-list.
enum CredentialID: Hashable, Codable {
    case keychain(host: String, user: String)
    case bitwarden(String)
    /// A 1Password item, by its op item id.
    case onePassword(String)

    var string: String {
        switch self {
        case .keychain(let host, let user):
            return "kc:\(host)\u{1}\(user)"
        case .bitwarden(let id):
            return "bw:\(id)"
        case .onePassword(let id):
            return "op:\(id)"
        }
    }

    init?(string: String) {
        if string.hasPrefix("kc:") {
            let body = String(string.dropFirst(3))
            guard let separator = body.firstIndex(of: "\u{1}") else { return nil }
            let host = String(body[..<separator])
            let user = String(body[body.index(after: separator)...])
            guard !host.isEmpty, !user.isEmpty else { return nil }
            self = .keychain(host: host, user: user)
        } else if string.hasPrefix("bw:") {
            let id = String(string.dropFirst(3))
            guard !id.isEmpty else { return nil }
            self = .bitwarden(id)
        } else if string.hasPrefix("op:") {
            let id = String(string.dropFirst(3))
            guard !id.isEmpty else { return nil }
            self = .onePassword(id)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = Self(string: value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "Invalid credential id")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

struct Credential: Identifiable, Hashable {
    enum Source: Hashable {
        case keychain
        case bitwarden
        case onePassword

        /// How a person reads the source: "Bitwarden", "1Password", "keychain".
        var title: String {
            switch self {
            case .keychain: return "keychain"
            case .bitwarden: return "Bitwarden"
            case .onePassword: return "1Password"
            }
        }

        /// The picker's glyph for a row from this source.
        var symbol: String {
            switch self {
            case .keychain: return "key"
            case .bitwarden: return "shield"
            case .onePassword: return "1.circle"
            }
        }
    }

    enum AgentHint: Hashable {
        case none
        case allow
        case deny
    }

    let id: CredentialID
    let source: Source
    let host: String
    let user: String
    let sites: [String]
    let name: String
    let hasTOTP: Bool
    let used: Date?
    let folder: String?
    let agentHint: AgentHint
    /// A Bitwarden login that also holds a passkey (`fido2Credentials`);
    /// the picker says so, and Copper signs with it when the site asks.
    var hasPasskey = false

    var stableID: String { id.string }
}
