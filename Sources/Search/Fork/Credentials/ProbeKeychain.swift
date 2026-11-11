import Foundation
import Security

/// A test world's stand-in for the keychain: Copper's own passwords and
/// passkeys kept in a 0600 JSON file inside the world's folder instead of
/// the macOS keychain, so a probe can save, list, fill, show, import and
/// export them without a keychain read, write or dialog ever reaching the
/// person at the Mac.
///
/// Honoured only in a named probe world (`SEARCH_PROBE=<name>`) with the
/// bench switched on, and only when asked for — `defaults write
/// com.collinrijock.copper.test.<name> probe.keychain -string file` (or
/// `SEARCH_PROBE_KEYCHAIN=file`). The browser somebody uses never reads
/// either. `Vault` and `PasskeyStore` ask `active` first and hand every call
/// here while it is on.
enum ProbeKeychain {
    /// Decided once, at the first keychain call of the run.
    nonisolated static let active: Bool = {
        guard let world = Store.world else { return false }
        let suite = Store.settings // the world's own suite
        let asked = ProcessInfo.processInfo.environment["SEARCH_PROBE_KEYCHAIN"] ?? suite.string(forKey: "probe.keychain")
        return decide(testing: Store.testing, world: world, bench: suite.bool(forKey: "bench"), asked: asked)
    }()

    /// The rule, on its own: a test run, in a named world, with the bench
    /// on, that asked for the file. Anything less is the real keychain.
    nonisolated static func decide(testing: Bool, world: String?, bench: Bool, asked: String?) -> Bool {
        guard testing, let world, !world.isEmpty, bench else { return false }
        return asked?.lowercased() == "file"
    }

    /// What Show / Copy / Forget-a-passkey's Touch ID answers in this world:
    /// yes unless the bench said no (`passwords prove no`).
    nonisolated(unsafe) static var proves = true

    struct Item: Codable, Equatable {
        var host: String
        var user: String
        var password: String
        var used: Double?
    }

    struct Passkey: Codable, Equatable {
        var account: String
        var data: Data
    }

    private struct Disk: Codable {
        var passwords: [Item] = []
        var passkeys: [Passkey] = []
    }

    nonisolated static var file: URL { Store.file("probe-keychain.json") }

    private nonisolated static let lock = NSLock()

    private nonisolated static func read() -> Disk {
        guard let data = try? Data(contentsOf: file) else { return Disk() }
        return (try? JSONDecoder().decode(Disk.self, from: data)) ?? Disk()
    }

    private nonisolated static func write(_ disk: Disk) {
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - passwords, in Vault's shapes

    /// Rows as the keychain would list them: server, account and the
    /// "last used" comment — never the secret.
    nonisolated static func rows(server: String?) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return read().passwords
            .filter { server == nil || $0.host == server }
            .map { item in
                var row: [String: Any] = [kSecAttrServer as String: item.host, kSecAttrAccount as String: item.user]
                if let used = item.used { row[kSecAttrComment as String] = String(used) }
                return row
            }
    }

    nonisolated static func secret(host: String, user: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return read().passwords.first { $0.host == host && $0.user == user }?.password
    }

    nonisolated static func save(host: String, user: String, password: String, used: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        if let at = disk.passwords.firstIndex(where: { $0.host == host && $0.user == user }) {
            disk.passwords[at].password = password
            if let used { disk.passwords[at].used = used.timeIntervalSince1970 }
        } else {
            disk.passwords.append(Item(host: host, user: user, password: password, used: used?.timeIntervalSince1970))
        }
        write(disk)
        return true
    }

    nonisolated static func touch(host: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        guard let at = disk.passwords.firstIndex(where: { $0.host == host && $0.user == user }) else { return }
        disk.passwords[at].used = Date().timeIntervalSince1970
        write(disk)
    }

    nonisolated static func forget(host: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        disk.passwords.removeAll { $0.host == host && $0.user == user }
        write(disk)
    }

    /// Every password, for the bench's `passwords wipe`.
    nonisolated static func wipePasswords() {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        disk.passwords = []
        write(disk)
    }

    // MARK: - passkeys, in PasskeyStore's shapes

    nonisolated static func passkeyAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return read().passkeys.map(\.account)
    }

    nonisolated static func passkey(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return read().passkeys.first { $0.account == account }?.data
    }

    nonisolated static func savePasskey(_ account: String, _ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        if let at = disk.passkeys.firstIndex(where: { $0.account == account }) {
            disk.passkeys[at].data = data
        } else {
            disk.passkeys.append(Passkey(account: account, data: data))
        }
        write(disk)
        return true
    }

    nonisolated static func forgetPasskey(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        var disk = read()
        disk.passkeys.removeAll { $0.account == account }
        write(disk)
    }
}
