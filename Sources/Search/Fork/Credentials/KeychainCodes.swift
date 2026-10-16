import Foundation
import Security

/// Two-step codes for the passwords Copper keeps itself.
///
/// Bitwarden and 1Password items carry their authenticator key; a keychain
/// login did not, so a site's "enter the 6-digit code" step meant reaching
/// for a phone. The key (an `otpauth://totp/…` URI or the bare base32
/// secret) is kept beside the password: one generic-password item per
/// account under `Copper Codes`, readable only by Copper, never shown and
/// never logged. Listing them reads names only — the keychain is asked for a
/// key's bytes only when a code is actually wanted.
enum KeychainCodes {
    static let service = Store.world.map { "\(Fork.name) Codes (\($0))" } ?? "\(Fork.name) Codes"

    /// The item's account: host, U+0001, user — the same shape a keychain
    /// `CredentialID` carries.
    static func account(host: String, user: String) -> String { "\(host)\u{1}\(user)" }

    /// The setup key a person pasted, in the form kept: trimmed, an otpauth
    /// URI as given, a bare secret upper-cased without its spaces. Nil when
    /// it can't make a code — better refused at Save than at the sign-in.
    static func normalized(_ text: String) -> String? {
        var seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seed.lowercased().hasPrefix("otpauth://") {
            seed = seed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        }
        guard !seed.isEmpty, TOTP.code(from: seed) != nil else { return nil }
        return seed
    }

    /// Every account with a key, by `account(host:user:)`. Names only.
    static func accounts() -> Set<String> {
        if ProbeKeychain.active { return Set(probe().keys) }
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    static func has(host: String, user: String) -> Bool {
        accounts().contains(account(host: host, user: user))
    }

    /// The key itself, for the one account a code is wanted for.
    static func seed(host: String, user: String) -> String? {
        let name = account(host: host, user: user)
        if ProbeKeychain.active { return probe()[name] }
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The current code, or nil when there is no key or it can't make one.
    static func code(host: String, user: String) -> String? {
        seed(host: host, user: user).flatMap { TOTP.code(from: $0) }
    }

    /// Adds or replaces. `seed` is checked first; false for one that makes
    /// no code.
    @discardableResult
    static func save(_ text: String, host: String, user: String) -> Bool {
        guard let seed = normalized(text), let data = seed.data(using: .utf8) else { return false }
        let name = account(host: host, user: user)
        if ProbeKeychain.active {
            var all = probe()
            all[name] = seed
            return writeProbe(all)
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "\(host) — \(user) (two-step code)",
        ]
        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    static func forget(host: String, user: String) {
        let name = account(host: host, user: user)
        if ProbeKeychain.active {
            var all = probe()
            all[name] = nil
            writeProbe(all)
            return
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)
    }

    // MARK: - a probe world's stand-in

    /// Beside ProbeKeychain's file, in the same world and with the same
    /// 0600 permissions, so a test run never touches the real keychain.
    private static var probeFile: URL { Store.file("probe-codes.json") }

    private static func probe() -> [String: String] {
        guard let data = try? Data(contentsOf: probeFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    @discardableResult
    private static func writeProbe(_ all: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(all), (try? data.write(to: probeFile, options: .atomic)) != nil
        else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probeFile.path)
        return true
    }
}
