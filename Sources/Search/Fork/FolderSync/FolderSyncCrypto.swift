import CryptoKit
import Foundation
import Security

// Keys, names and the sealed file format of iCloud sync (docs/icloud-sync.md).
//
// From the phrase's 256 bits, HKDF-SHA256 (salt "copper-sync/v1") derives:
//   file-key  ChaChaPoly, seals every file
//   name-key  HMAC-SHA256, names the folders: the chain is HMAC("chain"),
//             a scope HMAC("scope/<id>"), each cut to 128 bits, base32
// The phrase already carries 256 bits, so nothing is stretched.
//
// A file is "CPS1" | nonce (12) | ciphertext | tag (16), its associated data
// "CPS1<chain>/<scope>/<file>", so it can't be renamed, moved or cut short
// without failing to open. Inside: length (u32 BE) | UTF-8 JSON | zeros up
// to the next 1 KiB, so its size says little and nothing is compressed.

struct SyncKeys {
    static let magic = Data("CPS1".utf8)
    static let suffix = "cps"
    static let pad = 1024

    private let file: SymmetricKey
    private let name: SymmetricKey

    init(entropy: Data) {
        let root = SymmetricKey(data: entropy)
        let salt = Data("copper-sync/v1".utf8)
        file = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: Data("file-key".utf8), outputByteCount: 32)
        name = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: Data("name-key".utf8), outputByteCount: 32)
    }

    /// The folder this phrase's files live in, under the sync folder.
    var chain: String { tag("chain") }

    /// A scope's folder under the chain.
    func scope(_ id: String) -> String { tag("scope/\(id)") }

    private func tag(_ text: String) -> String {
        SyncKeys.base32(Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: name)).prefix(16))
    }

    /// A fresh file name: 128 random bits, base32, and the extension.
    static func freshName() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base32(Data(bytes)) + "." + suffix
    }

    enum Failure: Error, Equatable { case notOurs, tampered, short }

    private static func aad(chain: String, scope: String, file: String) -> Data {
        magic + Data("\(chain)/\(scope)/\(file)".utf8)
    }

    func seal(_ json: Data, chain: String, scope: String, file: String) throws -> Data {
        var plain = Data()
        var length = UInt32(json.count).bigEndian
        plain.append(Data(bytes: &length, count: 4))
        plain.append(json)
        let padded = (plain.count + SyncKeys.pad - 1) / SyncKeys.pad * SyncKeys.pad
        plain.append(Data(count: padded - plain.count))
        let box = try ChaChaPoly.seal(plain, using: self.file, nonce: ChaChaPoly.Nonce(),
                                      authenticating: SyncKeys.aad(chain: chain, scope: scope, file: file))
        return SyncKeys.magic + box.combined
    }

    func open(_ sealed: Data, chain: String, scope: String, file: String) throws -> Data {
        guard sealed.count >= 4 + 12 + 16 + 4 else { throw Failure.short }
        guard sealed.prefix(4) == SyncKeys.magic else { throw Failure.notOurs }
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(4))
            plain = try ChaChaPoly.open(box, using: self.file, authenticating: SyncKeys.aad(chain: chain, scope: scope, file: file))
        } catch {
            throw Failure.tampered
        }
        let bytes = [UInt8](plain.prefix(4)) + [0, 0, 0, 0]
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard plain.count >= 4, length <= plain.count - 4 else { throw Failure.tampered }
        return Data(plain.dropFirst(4).prefix(length))
    }

    /// RFC 4648 base32, lower case, no padding.
    static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// A chain or scope folder's name: 26 base32 letters.
    static func isTag(_ name: String) -> Bool {
        name.count == 26 && name.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
    }
}

// MARK: - where the phrase is kept on this Mac

/// The phrase's entropy, in the login keychain (`Copper Sync Key`, this
/// device only, never iCloud Keychain). A test world keeps it in a 0600 file
/// in its own folder instead, so no keychain prompt ever reaches a probe.
enum SyncKeyStore {
    static let service = "Copper Sync Key"
    static let account = "folder-sync"

    static var testFile: URL { Store.file("folder-sync.key") }

    static func save(_ entropy: Data) -> Bool {
        if Store.testing {
            let file = testFile
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            do { try entropy.base64EncodedData().write(to: file) } catch { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: entropy]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = query
        fresh[kSecValueData as String] = entropy
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked // not synchronizable: never iCloud Keychain
        fresh[kSecAttrLabel as String] = service
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> Data? {
        if Store.testing {
            return (try? Data(contentsOf: testFile)).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    static func forget() {
        if Store.testing {
            try? FileManager.default.removeItem(at: testFile)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
