import CryptoKit
import Foundation

/// Some Chrome extensions depend on privileged browser integration that
/// WKWebExtension cannot provide. Keep known crashers out before WebKit sees
/// their scripts, rather than trying to recover every page they take down.
enum ExtensionCompatibility {
    static let iCloudPasswords = "pejdijmoenmkgeppbflobdenhhabjlaj"
    static let iCloudReason = "iCloud Passwords is incompatible with Copper and can crash sign-in pages. It stays off; use Settings › Passwords to import a passwords CSV, or use a supported password manager. Your extension data has not been deleted."

    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// An unpacked copy gets a local id, but Chrome's public manifest key
    /// still identifies it. Names are localized and can be changed, so they
    /// are not a safe compatibility check.
    static func reason(id: String, manifestKey: String? = nil) -> String? {
        if id.lowercased() == iCloudPasswords { return iCloudReason }
        guard let manifestKey, let key = Data(base64Encoded: manifestKey), !key.isEmpty else { return nil }
        let letters = Array("abcdefghijklmnop")
        let derived = SHA256.hash(data: key).prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 15)]] }
        return String(derived) == iCloudPasswords ? iCloudReason : nil
    }

    static func reason(id: String, folder: URL) -> String? {
        if let known = reason(id: id) { return known }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return reason(id: id, manifestKey: manifest["key"] as? String)
    }
}
