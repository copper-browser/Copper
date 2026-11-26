import Foundation
import Testing
@testable import Search

// Fork (ardia profiles): who sees what across profiles — Fork/Profiles.swift.

@Test("An extension runs where its profiles say; nil is every profile")
func extensionReach() {
    let everywhere = Installed(id: "a", name: "A", version: "1", enabled: true, fromStore: true, permissions: [])
    #expect(everywhere.reaches(nil) && everywhere.reaches("Work"))
    var work = everywhere
    work.profiles = ["Work"]
    #expect(work.reaches("Work") && !work.reaches(nil) && !work.reaches("Home"))
    var shared = everywhere
    shared.profiles = [""]
    #expect(shared.reaches(nil) && !shared.reaches("Work"))
    // Installing again: from another profile adds it; from Shared, everywhere.
    #expect(Installed.adding("Home", to: ["Work"]) == ["Work", "Home"])
    #expect(Installed.adding("Work", to: ["Work"]) == ["Work"])
    #expect(Installed.adding(nil, to: ["Work"]) == nil)
    #expect(Installed.adding("Work", to: nil) == nil)
    // A list from before profiles reads as every profile.
    let old = #"[{"id":"a","name":"A","version":"1","enabled":true,"fromStore":true,"permissions":[]}]"#
    let read = try? JSONDecoder().decode([Installed].self, from: Data(old.utf8))
    #expect(read?.first?.profiles == nil)
}

@Test("History: a profile's places are its own; Shared's are everyone's")
func historyReach() {
    #expect(History.sees(nil, nil) && History.sees(nil, "Work"))
    #expect(History.sees(["Work"], "Work") && !History.sees(["Work"], nil) && !History.sees(["Work"], "Home"))
    #expect(History.widened(["Work"], by: "Home") == ["Work", "Home"])
    #expect(History.widened(["Work"], by: "Work") == ["Work"])
    #expect(History.widened(["Work"], by: nil) == nil)
    #expect(History.widened(nil, by: "Work") == nil)
}

@Test("A profile's stores have fixed ids of their own")
func profileStoreIDs() {
    let jar = Spaces.storeID(forProfile: "Work")
    #expect(jar == Spaces.storeID(forProfile: "Work"))
    #expect(jar != Spaces.storeID(forProfile: "Home"))
    let extensions = Spaces.storeID(forProfile: "Work", kind: 0xC0FF_EE01)
    #expect(jar.uuidString.hasPrefix("C0FFEE00-") && extensions.uuidString.hasPrefix("C0FFEE01-"))
    #expect(jar.uuidString.dropFirst(8) == extensions.uuidString.dropFirst(8))
}

@Test("iCloud records say whose a place or an extension is, and nothing when it is Shared's")
func syncRecordProfiles() throws {
    let plain = SyncRecords.Ext(n: "uBlock")
    let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(!json.contains("\"p\""))
    let scoped = SyncRecords.Ext(n: "uBlock", p: ["Work"])
    #expect(try JSONDecoder().decode(SyncRecords.Ext.self, from: JSONEncoder().encode(scoped)).p == ["Work"])
    let place = SyncRecords.Place(u: "https://a.test/", t: "A", n: 1, l: 0)
    #expect(!String(decoding: try JSONEncoder().encode(place), as: UTF8.self).contains("\"p\""))
}
