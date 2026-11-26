import AppKit
import Security
import SwiftUI

// What live folders and shared folders both lean on: a secret kept in the
// login keychain (a GitHub token, a shared folder's key), and a small panel
// for their sheets — the sidebar may be folded away, so a sheet can't hang
// off it.

/// A secret in the login keychain, this Mac only, never iCloud Keychain. A
/// test world keeps it in a 0600 file in its own folder instead, so no
/// keychain prompt ever reaches a probe.
enum FolderSecrets {
    private static func testFile(_ service: String, _ account: String) -> URL {
        let safe = (service + "-" + account).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return Store.file("secrets/\(String(safe)).key")
    }

    @discardableResult
    static func save(_ secret: Data, service: String, account: String) -> Bool {
        if Store.testing {
            let file = testFile(service, account)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            do { try secret.base64EncodedData().write(to: file) } catch { return false }
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = query
        fresh[kSecValueData as String] = secret
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked // not synchronizable: never iCloud Keychain
        fresh[kSecAttrLabel as String] = service
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String, account: String) -> Data? {
        if Store.testing {
            return (try? Data(contentsOf: testFile(service, account))).flatMap { Data(base64Encoded: $0) }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func forget(service: String, account: String) {
        if Store.testing {
            try? FileManager.default.removeItem(at: testFile(service, account))
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

/// One small floating panel at a time, holding a SwiftUI sheet.
@MainActor
enum FolderPanel {
    private(set) static var panel: NSPanel?

    static func show<V: View>(_ title: String, _ view: V) {
        panel?.close()
        let host = NSHostingController(rootView: view.frame(width: 440).padding(20).background(Palette.ground))
        let made = NSPanel(contentViewController: host)
        made.title = title
        made.styleMask = [.titled, .closable]
        made.isReleasedWhenClosed = false
        made.level = .floating
        made.center()
        made.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = made
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}
