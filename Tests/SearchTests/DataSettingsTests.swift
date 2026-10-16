import Foundation
import Testing
@testable import Search

// Settings › Passwords, Privacy, Copper Cloud, Updates and About: the pure
// rules behind what those pages say and do. Nothing here touches the
// keychain, the network or a real file outside a temporary folder.

// MARK: - Send Feedback

@Test func feedbackOpensANewIssueOnCoppersOwnPage() {
    let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    let url = Feedback.url(version: "1.0.20261007.3", build: "202610071256", system: system)
    #expect(url.scheme == "https")
    #expect(url.host == "github.com")
    #expect(url.path == "/copper-browser/Copper/issues/new")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let title = items.first { $0.name == "title" }?.value ?? ""
    let body = items.first { $0.name == "body" }?.value ?? ""
    #expect(title == "Feedback on Copper 1.0.20261007.3")
    #expect(body.contains("Copper 1.0.20261007.3 · build 202610071256 · macOS 27.0"))
    #expect(body.hasPrefix("What happened, and what did you expect?"))
    // Nobody else's address anywhere in it.
    #expect(!url.absoluteString.contains("mailto"))
}

@Test func feedbackKeepsAPlusAPlus() {
    let url = Feedback.url(version: "1.0+dev", build: "1", system: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 2))
    #expect(url.absoluteString.contains("%2Bdev"))
    let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value
    #expect(title == "Feedback on Copper 1.0+dev")
    #expect(Feedback.macOS(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 2)) == "27.1.2")
    #expect(Feedback.macOS(OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)) == "26.5")
}

// MARK: - Passwords CSV: one header map for every export

@Test func safariChromeAndApplePasswordsHeadersMap() {
    let safari = PasswordCSV.columns(["Title", "URL", "Username", "Password", "Notes", "OTPAuth"])
    #expect(safari == PasswordCSV.Columns(url: 1, user: 2, password: 3, otp: 5, notes: 4))
    let chrome = PasswordCSV.columns(["name", "url", "username", "password", "note"])
    #expect(chrome == PasswordCSV.Columns(url: 1, user: 2, password: 3, otp: nil, notes: 4))
    let manager = PasswordCSV.columns(["folder", "name", "login_uri", "login_username", "login_password", "login_totp"])
    #expect(manager == PasswordCSV.Columns(url: 2, user: 3, password: 4, otp: 5, notes: nil))
    // Spaces and case in a header don't matter; a missing column does.
    #expect(PasswordCSV.columns([" Web Site ", "User Name", "PASSWORD"]) == PasswordCSV.Columns(url: 0, user: 1, password: 2, otp: nil, notes: nil))
    #expect(PasswordCSV.columns(["Title", "URL", "Username"]) == nil)
}

@Test func canonicalRewritesAnyHeaderToTheOneTheVaultReads() throws {
    let safari = "Title,URL,Username,Password,Notes,OTPAuth\r\n"
        + "Example,https://example.com/login,ada,\"pa,ss\",\"a note\",otpauth://totp/x?secret=AB\r\n"
        + "No site,,bob,secret,,\r\n"
        + "No password,https://b.test,carol,,,\r\n"
        + "\r\n"
    let plain = try #require(PasswordCSV.canonical(safari))
    #expect(plain == "url,username,password\nhttps://example.com/login,ada,\"pa,ss\"\n")
    let summary = PasswordCSV.summary(safari)
    #expect(summary == PasswordCSV.Summary(logins: 1, skipped: 2, withCodes: 1, withNotes: 1, understood: true))
    // What canonical writes, the header check takes.
    #expect(PasswordCSV.problem(with: plain) == nil)
    #expect(PasswordCSV.canonical("just,some\nwords,here") == nil)
    #expect(PasswordCSV.summary("just,some\nwords,here").understood == false)
}

@Test func parseReadsQuotesNewlinesAndLineEndings() {
    let rows = PasswordCSV.parse("a,\"b\nc\",\"d \"\"e\"\"\"\r\nx,y,z\r\n\r\nlast,row,here")
    #expect(rows == [["a", "b\nc", "d \"e\""], ["x", "y", "z"], ["last", "row", "here"]])
    #expect(PasswordCSV.parse("") == [])
}

/// Safari's own export as the Passwords app writes it: a byte-order mark,
/// CRLF, a quoted comma, a doubled quote, a newline inside a note, a code,
/// and two rows that can't be kept (no password; no site). Move in's Safari
/// and Chrome export paths read through these same calls.
private let safariPasswordsExport = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n"
    + "example.com (a@example.com),https://example.com/login,a@example.com,\"p,ss\"\"word\",\"line one\r\nline two\",otpauth://totp/x?secret=ABC\r\n"
    + "www.example.org,https://www.example.org/,bob,hunter2,,\r\n"
    + "nopass.example.com,https://nopass.example.com/,carol,,,\r\n"
    + "no site,,dave,secret,,\r\n"

@Test func csvSafariExportReadsAsMoveInNeedsIt() throws {
    let summary = PasswordCSV.summary(safariPasswordsExport)
    #expect(summary == PasswordCSV.Summary(logins: 2, skipped: 2, withCodes: 1, withNotes: 1, understood: true))
    #expect(PasswordCSV.accounts(safariPasswordsExport) == ["example.com\u{1}a@example.com", "example.org\u{1}bob"])
    let rows = PasswordCSV.parse(safariPasswordsExport)
    #expect(rows.count == 5)
    #expect(rows[0].first == "Title") // the mark is gone
    #expect(rows[1][3] == "p,ss\"word")
    #expect(rows[1][4] == "line one\r\nline two")
    let plain = try #require(PasswordCSV.canonical(safariPasswordsExport))
    #expect(PasswordCSV.parse(plain) == [["url", "username", "password"],
                                         ["https://example.com/login", "a@example.com", "p,ss\"word"],
                                         ["https://www.example.org/", "bob", "hunter2"]])
    #expect(PasswordCSV.problem(with: safariPasswordsExport) == nil)
    // A line of empty fields is not a row to skip.
    #expect(PasswordCSV.parse("url,username,password\n,,\nhttps://a.test,me,pw\n").count == 2)
}

@Test func csvHeaderVariantsOfEveryKnownExport() {
    let headers: [(String, Bool)] = [
        ("name,url,username,password,note", true),                                       // Chrome's (and Copper's export)
        ("Title,URL,Username,Password,Notes,OTPAuth", true),                             // Safari's and Apple Passwords'
        ("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes", true),       // a password manager's
        ("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp", true),
        ("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\"", true),
        ("Title,Web Site,User Name,Password", true),
        ("Title,Web Address,Email Address,Password", true),
        ("site,secret", false),
    ]
    for (header, understood) in headers {
        let columns = PasswordCSV.columns(PasswordCSV.parse(header).first ?? [])
        #expect((columns != nil) == understood, "\(header)")
    }
}

@Test func importSentenceSaysCodesStayBehind() {
    #expect(PasswordCSV.Outcome(kept: 3, skipped: 0, codes: 2).sentence == "3 passwords imported, with 2 two-step codes")
    #expect(PasswordCSV.Outcome(kept: 1, skipped: 1, codes: 1).sentence == "1 password imported, 1 skipped (no site or no password), with 1 two-step code")
}

// MARK: - Sites never asked

@Test func neverAskedCountsAndForgets() {
    #expect(NeverAsked.summary(1) == "1 site told to stop offering")
    #expect(NeverAsked.summary(4) == "4 sites told to stop offering")
    #expect(NeverAsked.forgotten(["a.test"]) == "a.test can offer to save again")
    #expect(NeverAsked.forgotten(["a.test", "b.test", "c.test", "d.test"]) == "Every site can offer to save again")
    #expect(NeverAsked.forgetAllFrom == 4)
    #expect(NeverAsked.ordered(["news.test", "Shop.test", "bank.test"]) == ["bank.test", "news.test", "Shop.test"])
}

// MARK: - Password manager and agent access copy

@Test func wrongMasterPasswordInWords() {
    #expect(Bitwarden.unlockMessage("Cryptography error, The decryption operation failed") == "Wrong master password — try again")
    #expect(Bitwarden.unlockMessage("Invalid master password.") == "Wrong master password — try again")
    #expect(Bitwarden.unlockMessage("You are not logged in.") == "You are not logged in.")
}

@Test func agentAccessTitlesDontRepeatTheSite() {
    #expect(AgentAccessTitle.text(name: "Localhost", user: "ada", host: "localhost") == "localhost")
    #expect(AgentAccessTitle.text(name: "ada@example.com", user: "ada@example.com", host: "example.com") == "example.com")
    #expect(AgentAccessTitle.text(name: "Example.com", user: "", host: "www.example.com") == "www.example.com")
    #expect(AgentAccessTitle.text(name: "", user: "ada", host: "a.test") == "a.test")
    #expect(AgentAccessTitle.text(name: "Work mail", user: "ada", host: "mail.test") == "Work mail · mail.test")
}

// MARK: - Copper Cloud

@Test func cloudSaysOfflineWhenAPassFailedEvenIfALaterStepHadNothingToSend() {
    // Server down: the pull failed, the history push had nothing to send.
    let down = CloudSync.settled(signedIn: true, failure: "offline", answered: false, before: .idle)
    #expect(down.state == .offline)
    #expect(down.stamp == false)
    #expect(down.state.text == "Can't reach the cloud — will retry")
    // Nothing went out at all: the status stays what it was, no new "last synced".
    let quiet = CloudSync.settled(signedIn: true, failure: nil, answered: false, before: .offline)
    #expect(quiet.state == .offline)
    #expect(quiet.stamp == false)
    // The server answered and nothing failed: up to date, stamped.
    let good = CloudSync.settled(signedIn: true, failure: nil, answered: true, before: .offline)
    #expect(good.state == .idle)
    #expect(good.stamp == true)
    #expect(CloudSync.settled(signedIn: true, failure: "Changed elsewhere first", answered: true, before: .idle).state == .error("Changed elsewhere first"))
    #expect(CloudSync.settled(signedIn: false, failure: "offline", answered: false, before: .idle).state == .idle)
    #expect(CloudSync.settled(signedIn: true, failure: nil, answered: false, before: .syncing).state == .idle)
}

@Test func aLinkCodeWithoutItsFingerprintIsCalledIncomplete() {
    let untrusted = URLError(.serverCertificateUntrusted)
    #expect(Cloud.lacksFingerprint(untrusted, pinned: false, https: true))
    #expect(Cloud.lacksFingerprint(URLError(.serverCertificateHasUnknownRoot), pinned: false, https: true))
    #expect(!Cloud.lacksFingerprint(untrusted, pinned: true, https: true))
    #expect(!Cloud.lacksFingerprint(untrusted, pinned: false, https: false))
    #expect(!Cloud.lacksFingerprint(URLError(.cannotConnectToHost), pinned: false, https: true))
    #expect(!Cloud.lacksFingerprint(URLError(.serverCertificateHasBadDate), pinned: false, https: true))
    #expect(Cloud.incompleteLinkCode.hasPrefix("This link code is incomplete"))
}

// MARK: - Updates

@Test func aReCutReleaseUnderTheSameVersionIsNotTheStagedOne() {
    let sha = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let staged = Updates.Staged(version: "1.0.99", path: "/tmp/x", sha256: sha, at: Date())
    func latest(_ version: String, _ sum: String?) -> Updates.Latest {
        Updates.Latest(version: version, releaseId: "r", commit: "c", publishedAt: "", sha256: sum, archiveUrl: nil, notes: nil)
    }
    #expect(Updates.stagedMatches(staged, latest("1.0.99", sha)))
    #expect(Updates.stagedMatches(staged, latest("1.0.99", sha.uppercased())))
    #expect(!Updates.stagedMatches(staged, latest("1.0.99", other)))
    #expect(!Updates.stagedMatches(staged, latest("1.0.100", sha)))
    #expect(Updates.stagedMatches(staged, latest("1.0.99", nil)))
}

@Test func homebrewIsOnlyTheCasksOwnInstall() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(Updates.caskPlace(URL(fileURLWithPath: "/Applications/Copper.app"), home: home))
    #expect(Updates.caskPlace(URL(fileURLWithPath: "/Users/someone/Applications/Copper.app"), home: home))
    #expect(!Updates.caskPlace(URL(fileURLWithPath: "/Users/someone/src/copper/build/Copper.app"), home: home))
}

// MARK: - Test seams are off outside a test world

@Test func probeSeamsAreOffOutsideATestWorld() {
    // The file keychain: only a test run, in a named world, with the bench on, that asked.
    #expect(!ProbeKeychain.decide(testing: false, world: nil, bench: true, asked: "file"))
    #expect(!ProbeKeychain.decide(testing: false, world: "w", bench: true, asked: "file"))
    #expect(!ProbeKeychain.decide(testing: true, world: "w", bench: false, asked: "file"))
    #expect(!ProbeKeychain.decide(testing: true, world: "w", bench: true, asked: nil))
    #expect(!ProbeKeychain.decide(testing: true, world: "", bench: true, asked: "file"))
    #expect(ProbeKeychain.decide(testing: true, world: "w", bench: true, asked: "FILE"))
    // The update log: the real one for the browser somebody uses, the world's own otherwise.
    let folder = URL(fileURLWithPath: "/tmp/Copper (w)")
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(Updates.logFile(world: nil, folder: folder, home: home).path == "/Users/someone/Library/Logs/Copper/update.log")
    #expect(Updates.logFile(world: "w", folder: folder, home: home).path == "/tmp/Copper (w)/update.log")
}

// MARK: - Announcements

@Test func announcementsStayLongEnoughToRead() {
    #expect(Announcements.seconds("Address copied") == 1.7)
    let long = "That CSV has no password column — export it again as a passwords CSV"
    #expect(Announcements.seconds(long) > 4)
    #expect(Announcements.seconds(String(repeating: "x", count: 500)) == 6)
}
