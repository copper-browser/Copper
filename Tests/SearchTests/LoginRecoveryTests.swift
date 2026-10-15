import Foundation
#if canImport(Testing) && !COPPER_STANDALONE_CHECK
import Testing
@testable import Search
#endif

// Also compiled directly by docs/fixtures/login-recovery-unit.sh on Macs
// whose Command Line Tools ship no Testing module. The same checks run,
// with no network, window, password vault or real browser state involved.
private func check(_ condition: @autoclosure () -> Bool) {
    #if canImport(Testing) && !COPPER_STANDALONE_CHECK
    #expect(condition())
    #else
    precondition(condition())
    #endif
}

#if canImport(Testing) && !COPPER_STANDALONE_CHECK
@Test
#endif
func crashRecoveryStopsAndStaysStopped() {
    let start = Date(timeIntervalSince1970: 1_000)
    var recovery = CrashRecovery()
    check(recovery.permitsRecovery(at: start))
    check(recovery.permitsRecovery(at: start.addingTimeInterval(1)))
    check(!recovery.permitsRecovery(at: start.addingTimeInterval(2)))
    check(recovery.halted)
    // A later health check or manual retry must not reopen the automatic
    // loop, even after the rolling minute has expired.
    check(!recovery.permitsRecovery(at: start.addingTimeInterval(120)))
    recovery.reset()
    check(!recovery.halted)
    check(recovery.permitsRecovery(at: start.addingTimeInterval(121)))
    // Each tab owns its own budget.
    var other = CrashRecovery()
    check(other.permitsRecovery(at: start))
}

#if canImport(Testing) && !COPPER_STANDALONE_CHECK
@Test
#endif
func isolatedProcessDeathsStillRecover() {
    let start = Date(timeIntervalSince1970: 1_000)
    var recovery = CrashRecovery()
    check(recovery.permitsRecovery(at: start))
    check(recovery.permitsRecovery(at: start.addingTimeInterval(59)))
    // Exactly sixty seconds old is outside the window.
    check(recovery.permitsRecovery(at: start.addingTimeInterval(60)))
    check(recovery.permitsRecovery(at: start.addingTimeInterval(120)))
    check(!recovery.halted)
}

// Public Chrome manifest key, not a credential. Used to recognise an
// unpacked iCloud Passwords copy whose id is now local-… and name localized.
private let iCloudPublicKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAk4xPYZla5XqlDN0PPiLCQAYRqdaR06jSl3sntEE5jHoe7XldFqhsdBSp4L8mozwjCwi6z5YtEpTV1L2k4WYmDuiwoH7YKGlQD/YbC8QMcPvGLWOr8WYfXWtECKv0Nx7Tahk8nCIDWgJVm8YmPIDhPv4o5VVrq6aUveCKvTOskHWFyRzSTC2VKpzIVX7F65UzqqOmqLfMpo6lfaLcKSC7G6oQLA/wS7hcGZEwZ11si6XWR4o/hDuUSt6zdacy/sc7H80eH3lMnEmvb6HoB7+KvxfGIU7dqRmhA/w/X0qkiIJYeoo4tZrNxBj7TTLz9hnHUbMRwJqsoIU+pkoprgFWDQIDAQAB"

#if canImport(Testing) && !COPPER_STANDALONE_CHECK
@Test
#endif
func onlyKnownIncompatibleExtensionsAreBlocked() throws {
    let policy = ExtensionCompatibility.self
    check(policy.reason(id: policy.iCloudPasswords) == policy.iCloudReason)
    check(policy.reason(id: policy.iCloudPasswords.uppercased()) == policy.iCloudReason)
    check(policy.reason(id: "local-12345678", manifestKey: iCloudPublicKey) == policy.iCloudReason)
    // 1Password and other extensions are not swept into the block.
    check(policy.reason(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa") == nil)
    check(policy.reason(id: "local-example", manifestKey: Data("unrelated public key".utf8).base64EncodedString()) == nil)
    check(policy.reason(id: "local-example", manifestKey: "not base64!") == nil)
    check(policy.reason(id: "local-example", manifestKey: "") == nil)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let manifest = folder.appendingPathComponent("manifest.json")
    check(policy.reason(id: policy.iCloudPasswords, folder: folder) == policy.iCloudReason) // missing file
    check(policy.reason(id: "local-example", folder: folder) == nil)
    try JSONSerialization.data(withJSONObject: ["name": "Localized name", "key": iCloudPublicKey]).write(to: manifest)
    check(policy.reason(id: "local-example", folder: folder) == policy.iCloudReason)
    try JSONSerialization.data(withJSONObject: ["name": "iCloud Passwords", "permissions": ["nativeMessaging"]]).write(to: manifest)
    check(policy.reason(id: "local-example", folder: folder) == nil) // names and permissions aren't identities
    try Data("broken json".utf8).write(to: manifest)
    check(policy.reason(id: "local-example", folder: folder) == nil)
    check(policy.Refused(reason: policy.iCloudReason).localizedDescription == policy.iCloudReason)
}
