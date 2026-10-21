import Foundation
import Testing
@testable import Search

// Fork (vault-popup): the Accounts popup's list (Fork/Credentials/VaultPopup.swift)
// — this page's accounts first, then by name, narrowed by every word.

private func login(_ name: String, _ user: String, _ host: String, sites: [String] = [], id: String? = nil) -> Credential {
    Credential(id: .bitwarden(id ?? name + user), source: .bitwarden, host: host, user: user,
               sites: sites.isEmpty ? ["https://\(host)/"] : sites, name: name, hasTOTP: false,
               used: nil, folder: nil, agentHint: .none)
}

@Test func vaultListPutsThisPageFirstThenSortsByName() {
    let apple = login("Apple ID", "me@x.test", "apple.com")
    let github = login("GitHub", "me", "github.com")
    let bank = login("Bank", "me", "bank.test")
    let rows = VaultPopup.rows([github, apple, bank], here: [apple.id], needle: "")
    #expect(rows.map(\.name) == ["Apple ID", "Bank", "GitHub"])
    let others = VaultPopup.rows([github, apple, bank], here: [github.id], needle: "")
    #expect(others.map(\.name) == ["GitHub", "Apple ID", "Bank"])
}

@Test func vaultSearchNeedsEveryWordAnywhere() {
    let work = login("Exowatt Google", "crijock@exowatt.com", "google.com")
    let home = login("Google", "collin@gmail.test", "google.com")
    let asc = login("App Store Connect", "me", "apple.com", sites: ["https://appstoreconnect.apple.com/"])
    let all = [work, home, asc]
    #expect(VaultPopup.rows(all, here: [], needle: "google exowatt").map(\.name) == ["Exowatt Google"])
    #expect(VaultPopup.rows(all, here: [], needle: "APPSTORECONNECT").map(\.name) == ["App Store Connect"])
    #expect(VaultPopup.rows(all, here: [], needle: "  ").count == 3)
    #expect(VaultPopup.rows(all, here: [], needle: "nothing-like-it").isEmpty)
}

@Test func vaultOpensOnlyWebAddresses() {
    #expect(VaultPopup.site(of: login("A", "", "a.test", sites: ["androidapp://com.a"]))?.absoluteString == "https://a.test")
    #expect(VaultPopup.site(of: login("B", "", "b.test", sites: ["b.test/login"]))?.host() == "b.test")
    #expect(VaultPopup.site(of: login("C", "", "", sites: ["javascript:alert(1)"])) == nil)
}

@Test func vaultLabelFallsBackToTheSite() {
    #expect(VaultPopup.label(login("", "me", "a.test")) == "a.test")
    #expect(VaultPopup.label(login("me", "me", "a.test")) == "a.test")
    #expect(VaultPopup.label(login("Work", "me", "a.test")) == "Work")
}
