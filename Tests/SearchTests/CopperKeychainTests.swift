import Foundation
import Security
import Testing
@testable import Search

// Fork/Credentials/CopperKeychain.swift: which keychain an item goes to, what
// a moved item takes along, and how the two keychains' lists are joined. The
// query shapes only — nothing here reads or writes a keychain.

@Suite struct CopperKeychainTests {
    private let app = "62D5L6T44Y.com.collinrijock.copper"

    @Test func theGroupIsTheAppsOwnWhenClaimed() {
        #expect(CopperKeychain.group(claimed: [app], application: app) == app)
        #expect(CopperKeychain.group(claimed: ["62D5L6T44Y.other", app], application: app) == app)
        // A pattern is what a profile allows, never a group to keep items in.
        #expect(CopperKeychain.group(claimed: ["62D5L6T44Y.*"], application: app) == nil)
        #expect(CopperKeychain.group(claimed: ["62D5L6T44Y.*", "62D5L6T44Y.shared"], application: app) == "62D5L6T44Y.shared")
        #expect(CopperKeychain.group(claimed: [], application: app) == nil)
        #expect(CopperKeychain.group(claimed: nil, application: nil) == nil)
    }

    @Test func anUnentitledProcessKeepsTheLoginKeychain() {
        // The test runner claims no keychain group, as an ad-hoc or development
        // build doesn't: every call is the plain SecItem call it stands for.
        #expect(CopperKeychain.group == nil)
    }

    @Test func modernAndLegacyQueries() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Copper Codes",
            kSecAttrAccount as String: "a",
        ]
        let modern = CopperKeychain.modern(query, group: app)
        #expect(modern[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(modern[kSecAttrAccessGroup as String] as? String == app)
        #expect(modern[kSecAttrService as String] as? String == "Copper Codes")

        let legacy = CopperKeychain.legacy(modern)
        #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(legacy[kSecAttrAccessGroup as String] == nil)
        #expect(legacy[kSecAttrAccount as String] as? String == "a")
    }

    @Test func aMovedItemTakesItsNamesNotTheKeychainsOwn() {
        let old: [String: Any] = [
            kSecAttrServer as String: "github.com",
            kSecAttrAccount as String: "me",
            kSecAttrLabel as String: "Copper",
            kSecAttrComment as String: "1764000000",
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrPort as String: 443,
            kSecAttrCreationDate as String: Date(),
            kSecAttrModificationDate as String: Date(),
            kSecAttrCreator as String: 0,
            kSecAttrAccessGroup as String: "",
            kSecValueData as String: Data("secret".utf8),
            kSecValuePersistentRef as String: Data([1, 2]),
        ]
        let carried = CopperKeychain.carried(old)
        #expect(Set(carried.keys) == Set([kSecAttrServer, kSecAttrAccount, kSecAttrLabel, kSecAttrComment,
                                          kSecAttrProtocol, kSecAttrPort].map { $0 as String }))
        #expect(carried[kSecValueData as String] == nil)
    }

    @Test func theOldCopyIsDeletedByExactlyWhatNamesIt() {
        let inet: [String: Any] = [
            kSecAttrServer as String: "github.com", kSecAttrAccount as String: "me", kSecAttrLabel as String: "Copper",
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrPort as String: 443, kSecAttrComment as String: "x",
        ]
        let gone = CopperKeychain.exactly(inet, internet: true)
        #expect(gone[kSecClass as String] as? String == kSecClassInternetPassword as String)
        #expect(gone[kSecAttrLabel as String] as? String == "Copper")
        #expect(gone[kSecAttrPort as String] as? Int == 443)
        #expect(gone[kSecAttrComment as String] == nil)

        let genp: [String: Any] = [kSecAttrService as String: "Copper Passkeys", kSecAttrAccount as String: "id", kSecAttrLabel as String: "x"]
        let one = CopperKeychain.exactly(genp, internet: false)
        #expect(one[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(Set(one.keys) == Set([kSecClass, kSecAttrService, kSecAttrAccount].map { $0 as String }))
    }

    @Test func aSavesOldCopyIsOnlyEverCoppers() {
        // An internet password named by site and account alone would reach
        // other apps' items in the login keychain: the label goes along.
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "github.com", kSecAttrAccount as String: "me",
        ]
        let old = CopperKeychain.oldCopy(identity, [kSecAttrLabel as String: "Copper", kSecValueData as String: Data()])
        #expect(old[kSecAttrLabel as String] as? String == "Copper")
        #expect(old[kSecValueData as String] == nil)
        // A generic password's service is Copper's already.
        let generic: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Copper Codes"]
        #expect(CopperKeychain.oldCopy(generic, [kSecAttrLabel as String: "x"])[kSecAttrLabel as String] == nil)
    }

    @Test func listsJoinBothKeychainsOnce() {
        let moved: [String: Any] = [kSecAttrServer as String: "a.com", kSecAttrAccount as String: "me", kSecAttrLabel as String: "Copper"]
        let stillOld: [String: Any] = [kSecAttrServer as String: "b.com", kSecAttrAccount as String: "me", kSecAttrLabel as String: "Copper"]
        let joined = CopperKeychain.merged([moved], [moved, stillOld])
        #expect(joined.count == 2)
        #expect(joined.map { $0[kSecAttrServer as String] as? String } == ["a.com", "b.com"])
        #expect(CopperKeychain.merged([], [stillOld]).count == 1)
    }

    @Test func vaultKnowsItsOwnLabels() {
        let shared = Store.world.map { "\(Fork.name) (\($0))" } ?? Fork.name
        #expect(Vault.isOurs(shared))
        #expect(Vault.isOurs(shared + " · Work"))
        #expect(!Vault.isOurs("Chrome Safe Storage"))
        #expect(!Vault.isOurs(shared + "x"))
    }
}
