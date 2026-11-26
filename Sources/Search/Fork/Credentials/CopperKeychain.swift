import Foundation
import Security

// Fork (exowatt signing): where Copper's own secrets live — passwords (Vault),
// passkeys (PasskeyStore), two-step keys (KeychainCodes), a shared folder's
// key, the GitHub token and the sync phrase (FolderSecrets, SyncKeyStore).
//
// The login keychain (the file keychain, "legacy" to Apple) guards each item
// with an access list tied to the signature that made it. A Copper signed
// differently — another certificate, another team — is a stranger to every
// item, so each read can ask for the keychain password, and a read waiting on
// that dialog blocks the thread that asked (a hang in SecItemCopyMatching ›
// SecKeychainItemCopyContent). The data-protection keychain asks nobody: an
// item belongs to an access group, and an app reads the groups its signature
// claims in `keychain-access-groups`, an entitlement only an Apple-signed
// provisioning profile grants (release/provisioning.py, docs/releasing.md).
//
// A release signed by Exowatt's team with its profile embedded claims
// "62D5L6T44Y.com.collinrijock.copper", and keeps everything there. Every other
// build (ad hoc, development, a release from before) claims no group and uses
// the login keychain exactly as before: asked for the data-protection keychain,
// it would only get errSecMissingEntitlement.
//
// Moving in, once per item. Reading every old item at launch would ask once
// per item, all at once, after the move to Exowatt's team. So an item moves the
// first time Copper reads its secret (one ask at most, as any re-signing costs):
// copied into the group, then deleted from the login keychain. Until then lists
// show both, and a save writes the group and drops the old copy. When a sweep at
// launch finds none of Copper's items left in the login keychain, it is never
// asked again.
enum CopperKeychain {
    /// The access group, when the running signature claims it. Fixed for the
    /// life of the process.
    nonisolated static let group: String? = {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
        let app = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
        return group(claimed: groups, application: app)
    }()

    /// The group to keep items in: the app's own (`<team>.<bundle id>`) when it
    /// is claimed, else the first one claimed outright. A pattern is never a
    /// group an item can be put in.
    nonisolated static func group(claimed: [String]?, application: String?) -> String? {
        let groups = (claimed ?? []).filter { !$0.isEmpty && !$0.contains("*") }
        if let application, groups.contains(application) { return application }
        return groups.first
    }

    /// New items: readable once the Mac has been unlocked since it started, so
    /// an agent driving Copper behind a locked screen still signs in; never
    /// synchronizable (no iCloud Keychain).
    nonisolated static let accessible = kSecAttrAccessibleAfterFirstUnlock

    // MARK: - queries (pure)

    /// A query or item for the group in the data-protection keychain.
    nonisolated static func modern(_ query: [String: Any], group: String) -> [String: Any] {
        var query = query
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessGroup as String] = group
        return query
    }

    /// The same query for the login keychain alone.
    nonisolated static func legacy(_ query: [String: Any]) -> [String: Any] {
        var query = query
        query[kSecUseDataProtectionKeychain as String] = false
        query[kSecAttrAccessGroup as String] = nil
        return query
    }

    /// What names and describes an item, and nothing the keychain keeps for
    /// itself (dates, the creator, references, its group): what a moved item
    /// takes along.
    nonisolated static let carriedKeys: [String] = [
        kSecAttrAccount, kSecAttrService, kSecAttrServer, kSecAttrSecurityDomain, kSecAttrProtocol,
        kSecAttrAuthenticationType, kSecAttrPort, kSecAttrPath, kSecAttrLabel, kSecAttrComment,
        kSecAttrDescription, kSecAttrGeneric,
    ].map { $0 as String }

    nonisolated static func carried(_ attributes: [String: Any]) -> [String: Any] {
        attributes.filter { carriedKeys.contains($0.key) }
    }

    /// The attributes that make an item the one it is (the keychain's own
    /// uniqueness keys for the class), plus an internet password's label, so a
    /// deletion of the old copy can only ever reach Copper's own item.
    nonisolated static func exactly(_ attributes: [String: Any], internet: Bool) -> [String: Any] {
        let keys: [CFString] = internet
            ? [kSecAttrAccount, kSecAttrSecurityDomain, kSecAttrServer, kSecAttrProtocol,
               kSecAttrAuthenticationType, kSecAttrPort, kSecAttrPath, kSecAttrLabel]
            : [kSecAttrAccount, kSecAttrService]
        var out: [String: Any] = [kSecClass as String: internet ? kSecClassInternetPassword : kSecClassGenericPassword]
        for key in keys { if let value = attributes[key as String] { out[key as String] = value } }
        return out
    }

    /// A list from both keychains: the group's rows, then the old rows no
    /// moved item already stands for.
    nonisolated static func merged(_ modern: [[String: Any]], _ legacy: [[String: Any]]) -> [[String: Any]] {
        func key(_ row: [String: Any]) -> String {
            [kSecAttrServer, kSecAttrService, kSecAttrAccount, kSecAttrSecurityDomain, kSecAttrProtocol, kSecAttrPort, kSecAttrPath, kSecAttrLabel]
                .map { row[$0 as String].map { "\($0)" } ?? "" }.joined(separator: "\u{1}")
        }
        let seen = Set(modern.map(key))
        return modern + legacy.filter { !seen.contains(key($0)) }
    }

    private nonisolated static func asks(_ query: [String: Any], for key: CFString) -> Bool {
        (query[key as String] as? Bool) == true
    }

    private nonisolated static func lists(_ query: [String: Any]) -> Bool {
        (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
    }

    // MARK: - the login keychain, until it is empty of ours

    private static let movedKey = "keychain.moved"

    /// Whether the login keychain may still hold items of Copper's.
    nonisolated static var legacyLeft: Bool { !Store.settings.bool(forKey: movedKey) }

    // MARK: - calls (each stands for the SecItem call of the same shape)

    /// SecItemCopyMatching. A list is both keychains' while old items are
    /// left; a secret not in the group yet is read from the login keychain
    /// and moved.
    nonisolated static func copyMatching(_ query: [String: Any], _ out: inout CFTypeRef?) -> OSStatus {
        guard let group else { return SecItemCopyMatching(query as CFDictionary, &out) }
        let status = SecItemCopyMatching(modern(query, group: group) as CFDictionary, &out)
        guard legacyLeft, status == errSecItemNotFound || (status == errSecSuccess && lists(query)) else { return status }
        if asks(query, for: kSecReturnData) { return move(query, group: group, &out) }
        var old: CFTypeRef?
        guard SecItemCopyMatching(legacy(query) as CFDictionary, &old) == errSecSuccess else { return status }
        if lists(query) {
            let mine = status == errSecSuccess ? (out as? [[String: Any]] ?? []) : []
            out = merged(mine, old as? [[String: Any]] ?? []) as CFArray
        } else {
            out = old
        }
        return errSecSuccess
    }

    /// The one item `query` names, out of the login keychain and into the
    /// group, answered in the shape the query asked for.
    private nonisolated static func move(_ query: [String: Any], group: String, _ out: inout CFTypeRef?) -> OSStatus {
        var ask = legacy(query)
        ask[kSecReturnAttributes as String] = true
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(ask as CFDictionary, &found)
        guard status == errSecSuccess, let item = found as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let itemClass = query[kSecClass as String] as? String else { return status }
        var fresh = carried(item)
        fresh[kSecClass as String] = itemClass
        fresh[kSecValueData as String] = data
        fresh[kSecAttrAccessible as String] = accessible
        let added = SecItemAdd(modern(fresh, group: group) as CFDictionary, nil)
        if added == errSecSuccess {
            SecItemDelete(legacy(exactly(item, internet: itemClass == kSecClassInternetPassword as String)) as CFDictionary)
        } else {
            NSLog("CopperKeychain: could not move an item into %@ (%d)", group, added)
        }
        out = asks(query, for: kSecReturnAttributes) ? item as CFDictionary : data as CFData
        return errSecSuccess
    }

    /// SecItemUpdate, and SecItemAdd when there is nothing to update:
    /// `identity` names the item, `fields` are written, `adding` only goes
    /// on a new one. In the group, the old copy (written over) goes.
    @discardableResult
    nonisolated static func save(_ identity: [String: Any], _ fields: [String: Any], adding: [String: Any] = [:]) -> Bool {
        guard let group else {
            let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            var fresh = identity.merging(fields) { _, new in new }.merging(adding) { old, _ in old }
            fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
        }
        var status = SecItemUpdate(modern(identity, group: group) as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var fresh = identity.merging(fields) { _, new in new }.merging(adding) { old, _ in old }
            fresh[kSecAttrAccessible as String] = accessible
            status = SecItemAdd(modern(fresh, group: group) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        if legacyLeft { SecItemDelete(legacy(oldCopy(identity, fields)) as CFDictionary) }
        return true
    }

    /// The old copy of what a save wrote: its identity, and for an internet
    /// password Copper's label too — the login keychain holds other apps'
    /// internet passwords for the same site and account.
    nonisolated static func oldCopy(_ identity: [String: Any], _ fields: [String: Any]) -> [String: Any] {
        var query = identity
        if (identity[kSecClass as String] as? String) == (kSecClassInternetPassword as String),
           query[kSecAttrLabel as String] == nil, let label = fields[kSecAttrLabel as String] {
            query[kSecAttrLabel as String] = label
        }
        return query
    }

    /// SecItemUpdate of attributes alone (no secret): the group's item, else
    /// the old one where it still is.
    @discardableResult
    nonisolated static func update(_ query: [String: Any], _ fields: [String: Any]) -> OSStatus {
        guard let group else { return SecItemUpdate(query as CFDictionary, fields as CFDictionary) }
        let status = SecItemUpdate(modern(query, group: group) as CFDictionary, fields as CFDictionary)
        guard status == errSecItemNotFound, legacyLeft else { return status }
        return SecItemUpdate(legacy(query) as CFDictionary, fields as CFDictionary)
    }

    /// SecItemDelete, from both while old items are left.
    @discardableResult
    nonisolated static func delete(_ query: [String: Any]) -> OSStatus {
        guard let group else { return SecItemDelete(query as CFDictionary) }
        let status = SecItemDelete(modern(query, group: group) as CFDictionary)
        guard legacyLeft else { return status }
        let old = SecItemDelete(legacy(query) as CFDictionary)
        return status == errSecSuccess ? status : old
    }

    // MARK: - the sweep

    /// Once a launch, in the background, while old items may be left: does
    /// the login keychain still hold any of Copper's? Names only — no secret
    /// is read, so nothing asks. None left, and it is never consulted again.
    /// Not in a test run: a release's launch check opens it in a throwaway
    /// world, and that never looks through the keychain of the Mac it runs on.
    static func sweepSoon() {
        guard let group, legacyLeft, !Store.testing, !ProbeKeychain.active else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            let left = oldItems()
            if left == 0 {
                Store.settings.set(true, forKey: movedKey)
                NSLog("CopperKeychain: every item is in %@; the login keychain is no longer read", group)
            } else {
                NSLog("CopperKeychain: %d items still in the login keychain; each moves to %@ when it is next used", left, group)
            }
        }
    }

    /// How many of Copper's items the login keychain still holds.
    private nonisolated static func oldItems() -> Int {
        func count(_ query: [String: Any], _ keep: ([String: Any]) -> Bool = { _ in true }) -> Int {
            var query = legacy(query)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return 0 }
            return (out as? [[String: Any]] ?? []).filter(keep).count
        }
        let services = [PasskeyStore.service, KeychainCodes.service, SyncKeyStore.service,
                        SharedFolders.service, LiveFolders.service]
        let generic = services.reduce(0) { sum, service in
            sum + count([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service])
        }
        let passwords = count([kSecClass as String: kSecClassInternetPassword]) { row in
            (row[kSecAttrLabel as String] as? String).map(Vault.isOurs) ?? false
        }
        return generic + passwords
    }
}
