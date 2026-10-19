import CryptoKit
import Foundation
import Security

// Copper's own passkeys.
//
// Apple gates WebKit's WebAuthn — Touch ID, iCloud passkeys, the Bluetooth
// cross-device route — behind a managed browser entitlement this build does
// not have. Upstream's answer was to hide `PublicKeyCredential` so sites fall
// back to a password. Ours is to be the authenticator: a P-256 key per site
// account, kept in the keychain under Copper's own label, used after Touch ID.
// Sites see a platform authenticator and a passkey that works everywhere
// Copper is signed in; they cannot tell it from the system one.
//
// This file is the store and the shapes. `Passkeys.swift` does the WebAuthn
// ceremonies (CBOR, authenticator data, signing) and the page-side polyfill;
// `Flow` imports Chrome's Google-Password-Manager passkeys into the same store.

enum PasskeyStore {
    /// One passkey: which site, which account, and the key that proves it.
    struct Credential: Identifiable, Hashable {
        /// The credential id sites remember — 16 random bytes at creation, or
        /// whatever the browser we imported from used.
        var id: Data
        /// The relying party id ("github.com"), the host or a registrable
        /// suffix of the origin that made it.
        var rpId: String
        /// `user.id` from the site — opaque bytes, handed back as userHandle.
        var userHandle: Data
        var userName: String
        var displayName: String
        /// The raw 32-byte P-256 scalar (`P256.Signing.PrivateKey.rawRepresentation`).
        var privateKey: Data
        /// Signature counter. Zero forever is what every synced passkey does
        /// now; we bump it anyway so a site that checks sees movement.
        var counter: UInt32 = 0
        var created = Date()
        var lastUsed: Date? = nil
        /// Where it came from: nil for one made here, "Chrome" / "Arc" for an
        /// import. Shown in Settings, never sent to a site.
        var origin: String? = nil

        var key: P256.Signing.PrivateKey? { try? P256.Signing.PrivateKey(rawRepresentation: privateKey) }
        var idText: String { id.base64URL }
        /// The label Settings shows: the account, or the display name, or the site.
        var label: String { userName.isEmpty ? (displayName.isEmpty ? rpId : displayName) : userName }
    }

    /// Every item of ours is tagged with this, the way `Vault` does, so a
    /// test run's passkeys never sit among the real ones.
    static let service = Store.world.map { "\(Fork.name) Passkeys (\($0))" } ?? "\(Fork.name) Passkeys"

    /// All passkeys, newest first.
    static func all() -> [Credential] {
        // macOS rejects a generic-password query that asks for both data and
        // attributes with MatchLimitAll. List the accounts first, then fetch
        // each item's bytes with a MatchLimitOne query.
        if ProbeKeychain.active {
            // A probe world's file stand-in (Fork/Credentials/ProbeKeychain.swift).
            return ProbeKeychain.passkeyAccounts()
                .compactMap { ProbeKeychain.passkey($0).flatMap { try? JSONDecoder().decode(Wire.self, from: $0).credential } }
                .sorted { $0.created > $1.created }
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String else { return nil }
            var value: CFTypeRef?
            let itemStatus = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &value)
            guard itemStatus == errSecSuccess, let data = value as? Data else { return nil }
            return try? JSONDecoder().decode(Wire.self, from: data).credential
        }.sorted { $0.created > $1.created }
    }

    /// Passkeys a site may use: its own rpId exactly. The caller has already
    /// checked that rpId is allowed for the origin asking.
    static func credentials(for rpId: String) -> [Credential] {
        all().filter { $0.rpId.caseInsensitiveCompare(rpId) == .orderedSame }
    }

    static func credential(id: Data) -> Credential? {
        all().first { $0.id == id }
    }

    /// Adds or replaces (same credential id) in one call.
    @discardableResult
    static func save(_ credential: Credential) -> Bool {
        guard let data = try? JSONEncoder().encode(Wire(credential)) else { return false }
        if ProbeKeychain.active { return ProbeKeychain.savePasskey(credential.idText, data) }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.idText,
        ]
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "\(credential.rpId) — \(credential.label)",
        ]
        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    /// One passkey was just used: bump the counter, note the time.
    static func touch(_ credential: Credential) {
        var used = credential
        used.counter &+= 1
        used.lastUsed = Date()
        save(used)
    }

    static func forget(id: Data) {
        if ProbeKeychain.active { return ProbeKeychain.forgetPasskey(id.base64URL) }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.base64URL,
        ] as CFDictionary)
    }

    /// A fresh passkey for a site: new key, new 16-byte id. The id is a
    /// random (version 4) UUID's bytes, so one saved to Bitwarden is the
    /// valid GUID the vault and its other clients expect (BitwardenPasskeys.vaultID).
    static func make(rpId: String, userHandle: Data, userName: String, displayName: String) -> Credential {
        let id = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        return Credential(id: id, rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName,
                          privateKey: P256.Signing.PrivateKey().rawRepresentation)
    }

    // MARK: - on disk

    /// The keychain item's bytes. Versioned so the shape can grow.
    private struct Wire: Codable {
        var v = 1
        var id: Data
        var rpId: String
        var userHandle: Data
        var userName: String
        var displayName: String
        var privateKey: Data
        var counter: UInt32
        var created: Date
        var lastUsed: Date?
        var origin: String?

        init(_ c: Credential) {
            id = c.id; rpId = c.rpId; userHandle = c.userHandle; userName = c.userName; displayName = c.displayName
            privateKey = c.privateKey; counter = c.counter; created = c.created; lastUsed = c.lastUsed; origin = c.origin
        }

        var credential: Credential {
            Credential(id: id, rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName,
                       privateKey: privateKey, counter: counter, created: created, lastUsed: lastUsed, origin: origin)
        }
    }
}

extension Data {
    /// WebAuthn's alphabet: base64 with `-` and `_`, no padding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
