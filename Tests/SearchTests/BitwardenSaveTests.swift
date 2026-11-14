import Foundation
import Testing
@testable import Search

// Fork (vault-save): what `copper bitwarden save -|note -` and the
// browser_vault_* tools accept, which saved item they change, and that no
// value they were sent comes back in an error (Fork/Credentials/BitwardenSave.swift).

private func item(_ id: String, user: String, uri: String, type: Int = 1, fields: [Bitwarden.Field] = []) -> Bitwarden.Item {
    Bitwarden.Item(id: id, type: type, name: id, folderId: nil, username: user,
                   uris: [Bitwarden.URI(uri: uri, match: nil)], hasTOTP: false, fields: fields)
}

private func fails(_ body: () throws -> Any, saying words: String) -> Bool {
    do { _ = try body(); return false } catch { return (error as? Bitwarden.Failure)?.message.contains(words) == true }
}

@Test func saveTakesURLOrHostAndKeepsOnlyTheSite() throws {
    let draft = try Bitwarden.loginDraft([
        "url": " https://www.PubAdHub.com/login?token=abc ", "username": " me@x.com ", "password": " p@ss ",
    ])
    #expect(draft.host == "www.pubadhub.com")
    #expect(draft.uri == "https://www.pubadhub.com")
    #expect(draft.name == "pubadhub.com")
    #expect(draft.username == "me@x.com")
    #expect(draft.password == " p@ss ") // as typed
    #expect(draft.totp == nil && draft.notes == nil && draft.folder == nil)

    let bare = try Bitwarden.loginDraft(["host": "example.com", "username": "u", "password": "p", "name": "Mine", "folder": "Work"])
    #expect(bare.uri == "https://example.com" && bare.name == "Mine" && bare.folder == "Work")
    #expect(Bitwarden.site("http://localhost:8080/x")?.uri == "http://localhost:8080")
}

@Test func saveRefusesWhatIsMissingOrWrong() {
    #expect(fails({ try Bitwarden.loginDraft(["username": "u", "password": "p"]) }, saying: "url (or host) is required"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "ftp://x.com", "username": "u", "password": "p"]) }, saying: "web address"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "nodot", "username": "u", "password": "p"]) }, saying: "web address"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "https://me:pw@x.com", "username": "u", "password": "p"]) }, saying: "web address"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "x.com", "password": "p"]) }, saying: "username is required"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "x.com", "username": "u", "password": ""]) }, saying: "password is required"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "x.com", "username": "u", "password": 42]) }, saying: "password is required"))
    #expect(fails({ try Bitwarden.loginDraft(["url": "x.com", "username": "u", "password": "p", "totp": "not base32!"]) }, saying: "totp must be"))
}

@Test func totpSeedsAreCheckedAndCleaned() throws {
    #expect(Bitwarden.normalizedTOTP("jbsw y3dp ehpk 3pxp") == "JBSWY3DPEHPK3PXP")
    let uri = "otpauth://totp/X:me?secret=JBSWY3DPEHPK3PXP&issuer=X"
    #expect(Bitwarden.normalizedTOTP(uri) == uri)
    #expect(Bitwarden.normalizedTOTP("otpauth://hotp/X?secret=JBSWY3DPEHPK3PXP") == nil)
    #expect(Bitwarden.normalizedTOTP("123456") == nil)
    let draft = try Bitwarden.loginDraft(["url": "x.com", "username": "u", "password": "p", "totp": "jbsw-y3dp-ehpk-3pxp"])
    #expect(draft.totp == "JBSWY3DPEHPK3PXP")
}

@Test func noteNeedsANameAndText() throws {
    let note = try Bitwarden.noteDraft(["name": " Google backup codes ", "text": "1111 2222\n3333 4444\n"])
    #expect(note == Bitwarden.NoteDraft(name: "Google backup codes", text: "1111 2222\n3333 4444\n", folder: nil))
    #expect(fails({ try Bitwarden.noteDraft(["text": "x"]) }, saying: "name is required"))
    #expect(fails({ try Bitwarden.noteDraft(["name": "n", "text": " \n"]) }, saying: "text is required"))
    #expect(fails({ try Bitwarden.noteDraft(["name": "n", "text": String(repeating: "x", count: 10_001)]) }, saying: "longer than"))
}

@MainActor @Test func saveFindsTheSameSiteAndUserNotAnother() {
    let items = [
        item("other-user", user: "you@x.com", uri: "https://pubadhub.com"),
        item("note", user: "me@x.com", uri: "https://pubadhub.com", type: 2),
        item("mine", user: "Me@X.com", uri: "https://www.pubadhub.com/login"),
        item("elsewhere", user: "me@x.com", uri: "https://example.com"),
    ]
    #expect(Bitwarden.existingLogin(in: items, host: "pubadhub.com", username: "me@x.com")?.id == "mine")
    #expect(Bitwarden.existingLogin(in: items, host: "app.pubadhub.com", username: "me@x.com")?.id == "mine")
    #expect(Bitwarden.existingLogin(in: items, host: "pubadhub.com", username: "nobody") == nil)
    #expect(Bitwarden.existingLogin(in: items, host: "other.com", username: "me@x.com") == nil)
}

@Test func agentsChangeOnlySharedItems() {
    let plain = item("a", user: "u", uri: "x.com")
    let denied = item("b", user: "u", uri: "x.com", fields: [Bitwarden.Field(name: "copper-agent", value: " Deny ")])
    #expect(!Bitwarden.agentMayChange(plain, folder: nil, shareAll: false, allowed: []))
    #expect(!Bitwarden.agentMayChange(plain, folder: "Personal", shareAll: false, allowed: []))
    #expect(Bitwarden.agentMayChange(plain, folder: " agents ", shareAll: false, allowed: []))
    #expect(Bitwarden.agentMayChange(plain, folder: nil, shareAll: true, allowed: []))
    #expect(Bitwarden.agentMayChange(plain, folder: nil, shareAll: false, allowed: ["bw:a"]))
    #expect(!Bitwarden.agentMayChange(denied, folder: "Agents", shareAll: true, allowed: ["bw:b"]))
}

@MainActor @Test func errorsNeverCarryTheValuesSent() {
    let line = Bitwarden.sanitize("bad item p@ssw0rd JBSWY3DPEHPK3PXP\nsecond line", hiding: ["p@ssw0rd", "JBSWY3DPEHPK3PXP"])
    #expect(line == "bad item … …")
    #expect(!line.contains("p@ssw0rd"))
}
