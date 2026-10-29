import Foundation
import Testing
@testable import Search

// Copper Cloud's spaces document only says what this Mac changed by hand
// (CloudMerge.intended), and the brake holds a publish or an apply that
// takes too much away at once (CloudMerge.losses). The incident they answer:
// 2026-10-28, a device whose live state had no folders "won" the merge and
// unfiled all 36 of the Exowatt space's Saved tabs on every Mac.

private let exowatt = Space(name: "Exowatt")
private let apps = CloudDocs.Folder(id: UUID(), name: "Exowatt › Apps", hue: nil, space: exowatt.id, slot: nil)
private let docs = CloudDocs.Folder(id: UUID(), name: "Exowatt › Docs & HR", hue: nil, space: exowatt.id, slot: nil)
private let tools = CloudDocs.Folder(id: UUID(), name: "Exowatt › Tools", hue: nil, space: exowatt.id, slot: nil)

private func kept(_ n: Int, in folder: UUID?) -> CloudDocs.KeptTab {
    let url = "https://site\(n).exowatt.com/"
    return CloudDocs.KeptTab(key: "\(exowatt.id.uuidString.lowercased())|saved|site\(n).exowatt.com|\(url)",
                             space: exowatt.id, url: url, title: "Site \(n)", pinned: false, pin: nil, group: folder)
}

/// 36 Saved tabs, twelve in each folder — the document every Mac had.
private let filed: CloudDocs.Spaces = {
    let folders = [apps, docs, tools]
    let tabs = (0..<36).map { kept($0, in: folders[$0 / 12].id) }.sorted { $0.key < $1.key }
    return CloudDocs.Spaces(spaces: [exowatt], tabs: tabs, groups: folders)
}()

/// The drifted device: the same tabs, filed nowhere, and no folders at all.
private let drifted: CloudDocs.Spaces = {
    var doc = filed
    for i in doc.tabs.indices { doc.tabs[i].group = nil }
    doc.groups = []
    return doc
}()

@Test func driftedDeviceSendsNothingAndUnfilesNothing() {
    let out = CloudMerge.intended(drifted, base: filed, tabs: [], folders: [])
    #expect(out == filed)
    #expect(!CloudMerge.losses(from: filed, to: out).big)
    // On the server, and on a receiver that merges it in: every tab still filed.
    let server = CloudMerge.spaces(base: filed, local: out, server: filed)
    #expect(server.tabs.allSatisfy { $0.group != nil })
    #expect(CloudMerge.spaces(base: filed, local: filed, server: server) == filed)
}

@Test func withoutIntentsTheOldMergeWouldHaveUnfiledThemAll() {
    // What happened: the drifted copy taken as this Mac's word.
    let server = CloudMerge.spaces(base: filed, local: drifted, server: filed)
    #expect(server.tabs.allSatisfy { $0.group == nil })
    #expect(CloudMerge.losses(from: filed, to: server).big)
}

@Test func oneUnfiledByHandIsSent() {
    var local = filed
    local.tabs[0].group = nil
    let out = CloudMerge.intended(local, base: filed, tabs: [local.tabs[0].key], folders: [])
    #expect(out.tabs[0].group == nil)
    #expect(out.tabs.dropFirst().allSatisfy { $0.group != nil })
    let losses = CloudMerge.losses(from: filed, to: out)
    #expect(losses.unfiled == [local.tabs[0].key])
    #expect(!losses.big)
    #expect(CloudMerge.spaces(base: filed, local: out, server: filed).tabs[0].group == nil)
}

@Test func elevenUnfiledByHandAreHeld() {
    var local = filed
    for i in 0..<11 { local.tabs[i].group = nil }
    let out = CloudMerge.intended(local, base: filed, tabs: Set(local.tabs.prefix(11).map(\.key)), folders: [])
    let losses = CloudMerge.losses(from: filed, to: out)
    #expect(losses.unfiled.count == 11)
    #expect(losses.big)
    // Ten is still fine.
    #expect(!CloudMerge.Losses(unfiled: Array(losses.unfiled.prefix(10))).big)
}

@Test func anotherDeviceUnfilingEverythingIsHeldHere() {
    // An older build elsewhere publishes the drifted copy; this Mac has
    // changed nothing, so its own copy is the base.
    let local = CloudMerge.intended(filed, base: filed, tabs: [], folders: [])
    let merged = CloudMerge.spaces(base: filed, local: local, server: drifted)
    let losses = CloudMerge.losses(from: local, to: merged)
    #expect(losses.unfiled.count == 36)
    #expect(losses.folders.count == 3)
    #expect(losses.big)
    #expect(CloudSync.Hold.incoming(losses, version: 7, payload: Data()).text.hasPrefix("Another device unfiled 36 tabs"))
}

@Test func keptTabsAndFoldersMissingHereStayUnlessRemovedHere() {
    var local = filed
    let gone = local.tabs.removeFirst()
    local.groups = [docs, tools]
    // Missing without a word from the person: the base's stand.
    let kept = CloudMerge.intended(local, base: filed, tabs: [], folders: [])
    #expect(kept.tabs.contains { $0.key == gone.key })
    #expect(kept.groups?.contains { $0.id == apps.id } == true)
    // Removed here by hand, and the folder dissolved: gone from what is sent.
    let removed = CloudMerge.intended(local, base: filed, tabs: [gone.key], folders: [apps.id])
    #expect(!removed.tabs.contains { $0.key == gone.key })
    #expect(removed.groups?.contains { $0.id == apps.id } == false)
    let losses = CloudMerge.losses(from: filed, to: removed)
    #expect(losses.removed == [gone.key])
    #expect(losses.folders == [apps.id]) // still held tabs: the brake asks
}

@Test func newTabsGoAsTheyAre() {
    var local = drifted
    let fresh = kept(99, in: nil)
    local.tabs.append(fresh)
    let out = CloudMerge.intended(local, base: filed, tabs: [], folders: [])
    #expect(out.tabs.contains(fresh))
    #expect(CloudMerge.intended(local, base: nil, tabs: [], folders: []) == local) // no base: all new
}
