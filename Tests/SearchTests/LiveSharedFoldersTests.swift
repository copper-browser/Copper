import Foundation
import Testing
@testable import Search

// Live folders' GitHub reading (Fork/LiveFolders.swift) and shared folders'
// invite and merge (Fork/SharedFolders.swift): the pure parts.

// MARK: - live folders

private let searchAnswer = """
{"total_count":2,"incomplete_results":false,"items":[
 {"html_url":"https://github.com/copper-browser/Copper/pull/219","title":"Live folders","number":219,"updated_at":"2026-11-25T20:00:00Z",
  "draft":false,"user":{"login":"collinrijock"},"repository_url":"https://api.github.com/repos/copper-browser/Copper"},
 {"html_url":"https://github.com/acme/site/pull/7","title":"Fix the header","number":7,"updated_at":"2026-11-24T10:00:00Z",
  "draft":true,"user":{"login":"sam"},"repository_url":"https://api.github.com/repos/acme/site"}]}
"""

@Test func searchAnswerReads() throws {
    let items = try GitHubPulls.parse(Data(searchAnswer.utf8), review: true)
    #expect(items.count == 2)
    #expect(items[0].repo == "copper-browser/Copper")
    #expect(items[0].number == 219 && items[0].author == "collinrijock" && items[0].review && !items[0].mine)
    #expect(items[1].draft && items[1].repo == "acme/site")
    #expect(throws: (any Error).self) { try GitHubPulls.parse(Data("{\"message\":\"Bad credentials\"}".utf8)) }
}

@Test func repoFromPageWhenNoAPIAddress() {
    #expect(GitHubPulls.repo(nil, html: "https://github.com/a/b/pull/3") == "a/b")
    #expect(GitHubPulls.repo("https://api.github.com/repos/x/y", html: "") == "x/y")
}

private func item(_ n: Int, _ updated: String, review: Bool = false, mine: Bool = false) -> LiveItem {
    LiveItem(url: "https://github.com/a/b/pull/\(n)", title: "PR \(n)", repo: "a/b", number: n, author: "me", updated: updated, review: review, mine: mine)
}

@Test func reviewsFirstAndOnce() {
    let merged = GitHubPulls.merge(reviews: [item(1, "2026-11-20"), item(2, "2026-11-22")].map { var i = $0; i.review = true; return i },
                                   mine: [item(2, "2026-11-22", mine: true), item(3, "2026-11-25", mine: true)])
    #expect(merged.map(\.number) == [2, 1, 3])
    #expect(merged[0].review && merged[0].mine)
}

@Test func aTabShowsItsPullRequest() {
    let pr = "https://github.com/a/b/pull/12"
    #expect(GitHubPulls.shows(pr, pr))
    #expect(GitHubPulls.shows(pr + "/files", pr))
    #expect(GitHubPulls.shows(pr + "#discussion_r1", pr))
    #expect(!GitHubPulls.shows("https://github.com/a/b/pull/123", pr))
}

@Test func firstFillIsQuietThenChangesLightUp() {
    var folder = LiveFolder(space: UUID())
    folder = LiveFolders.fill(folder, with: [item(1, "t1"), item(2, "t1")], at: 1)
    #expect(folder.unreadCount == 0)
    // #2 changed, #3 is new, #1 left.
    folder = LiveFolders.fill(folder, with: [item(2, "t2"), item(3, "t1")], at: 2)
    #expect(folder.items.map(\.number) == [2, 3])
    #expect(folder.unread(folder.items[0]) && folder.unread(folder.items[1]))
    #expect(folder.seen["https://github.com/a/b/pull/1"] == nil)
    #expect(folder.problem == nil && folder.refreshed == 2)
}

// MARK: - shared folders: the invite

@Test func inviteLinkAndWordsRoundTrip() throws {
    let key = SyncPhrase.fresh()
    let invite = FolderInvite(key: key, name: "Reading List")
    #expect(invite.link.hasPrefix("copper://folder/join?k="))
    let back = try FolderInvite.parse("Join my folder: \(invite.link) — see you")
    #expect(back.key == key && back.name == "Reading List")
    let spoken = try FolderInvite.parse(invite.words.joined(separator: " "))
    #expect(spoken.key == key && spoken.name == nil)
}

@Test func badInvitesAreRefused() {
    #expect(throws: FolderInvite.Problem.notInvite) { try FolderInvite.parse("hello there") }
    #expect(throws: FolderInvite.Problem.notInvite) { try FolderInvite.parse("copper://folder/join?k=short") }
    var words = FolderInvite(key: SyncPhrase.fresh(), name: nil).words
    // The last word's low 8 bits are the checksum: flip one and only the checksum is wrong.
    let last = SyncPhrase.words.firstIndex(of: words[23])!
    words[23] = SyncPhrase.words[last ^ 1]
    #expect(throws: FolderInvite.Problem.phrase(.checksum)) { try FolderInvite.parse(words.joined(separator: " ")) }
}

// MARK: - shared folders: the merge

private func shared(_ u: String, _ f: String = "", _ i: Double = 1) -> String {
    SyncRecords.encode(SharedLink(u: u, t: u, f: f, i: i))
}

@Test func threeWayMerge() {
    let name = SyncRecords.encode(["n": "Reading"])
    let base = ["name": name, "ln:a": shared("https://a"), "ln:b": shared("https://b")]
    // Here: b deleted, c added. There: a moved into a subfolder, d added.
    let local = ["name": name, "ln:a": shared("https://a"), "ln:c": shared("https://c")]
    let remote = ["name": name, "ln:a": shared("https://a", "Deep"), "ln:b": shared("https://b"), "ln:d": shared("https://d")]
    let plan = SharedPlan.plan(local: local, base: base, remote: remote)
    #expect(Set(plan.ops.map(\.k)) == ["ln:b", "ln:c"])
    #expect(plan.ops.first { $0.k == "ln:b" }?.v == nil)
    #expect(Set(plan.apply.map(\.key)) == ["ln:a", "ln:d"])
    #expect(plan.base["ln:b"] == nil && plan.base["ln:c"] != nil && plan.base["ln:a"] == shared("https://a", "Deep"))
    #expect(plan.held.isEmpty)
}

@Test func bothChangedThisSideWinsAndNothingComesBackAgain() {
    let base = ["ln:a": shared("https://a")]
    let plan = SharedPlan.plan(local: ["ln:a": shared("https://a", "Mine")], base: base, remote: ["ln:a": shared("https://a", "Theirs")])
    #expect(plan.ops.map(\.k) == ["ln:a"] && plan.apply.isEmpty)
    // The next cycle, with both sides agreeing: nothing to do.
    let next = SharedPlan.plan(local: ["ln:a": shared("https://a", "Mine")], base: plan.base, remote: ["ln:a": shared("https://a", "Mine")])
    #expect(next.ops.isEmpty && next.apply.isEmpty)
}

@Test func theNameNeverReadsAsDeletedWhileFilesAreOnTheirWay() {
    let name = SyncRecords.encode(["n": "Reading 2"])
    let plan = SharedPlan.plan(local: ["name": name], base: ["name": name], remote: [:])
    #expect(plan.ops.isEmpty && plan.apply.isEmpty && plan.base["name"] == name)
}

@Test func aFlattenedFolderIsHeldNotDeletedForEveryone() {
    var base: [String: String] = [:]
    for n in 0..<6 { base["ln:\(n)"] = shared("https://\(n)") }
    let plan = SharedPlan.plan(local: ["ln:0": shared("https://0")], base: base, remote: base)
    #expect(plan.ops.isEmpty && plan.held.count == 5 && plan.base == base)
    let through = SharedPlan.plan(local: ["ln:0": shared("https://0")], base: base, remote: base, letThrough: true)
    #expect(through.ops.count == 5 && through.ops.allSatisfy { $0.v == nil })
    // Three at once is a person tidying.
    let tidy = SharedPlan.plan(local: base.filter { !["ln:1", "ln:2", "ln:3"].contains($0.key) }, base: base, remote: base)
    #expect(tidy.ops.count == 3 && tidy.held.isEmpty)
}

/// Two Macs, one directory: each plans against its own base, writes its
/// ops as a log, and both replicas end with the same folder.
@Test func twoMacsConverge() {
    var replicaA = SyncReplica(), replicaB = SyncReplica()
    var clockA = SyncClock(device: "A"), clockB = SyncClock(device: "B")
    var seqA = 0, seqB = 0
    func live(_ r: SyncReplica) -> [String: String] { r.live { $0 == "name" || $0.hasPrefix("ln:") } }
    func send(_ ops: [SyncOp], clock: inout SyncClock, device: String, seq: inout Int, to replicas: inout [SyncReplica]) {
        guard !ops.isEmpty else { return }
        seq += 1
        let file = SyncFile.log(device: device, seq: seq, ops: ops.map { SyncOp(k: $0.k, h: clock.tick(), v: $0.v) })
        for i in replicas.indices { replicas[i].ingest(log: file) }
    }
    let name = SyncRecords.encode(["n": "Trip"])
    // A shares two links.
    var localA = ["name": name, "ln:1": shared("https://one"), "ln:2": shared("https://two")]
    var planA = SharedPlan.plan(local: localA, base: [:], remote: live(replicaA))
    var both = [replicaA, replicaB]
    send(planA.ops, clock: &clockA, device: "A", seq: &seqA, to: &both)
    (replicaA, replicaB) = (both[0], both[1])
    var baseA = planA.base
    // B joins: everything comes in.
    var planB = SharedPlan.plan(local: ["name": SyncRecords.encode(["n": "Trip"])], base: ["name": name], remote: live(replicaB))
    #expect(Set(planB.apply.map(\.key)) == ["ln:1", "ln:2"])
    var localB = live(replicaB)
    var baseB = planB.base
    // At once: A removes one, B adds one.
    localA["ln:2"] = nil
    localB["ln:3"] = shared("https://three", "", 3)
    planA = SharedPlan.plan(local: localA, base: baseA, remote: live(replicaA))
    planB = SharedPlan.plan(local: localB, base: baseB, remote: live(replicaB))
    both = [replicaA, replicaB]
    send(planA.ops, clock: &clockA, device: "A", seq: &seqA, to: &both)
    send(planB.ops, clock: &clockB, device: "B", seq: &seqB, to: &both)
    (replicaA, replicaB) = (both[0], both[1])
    baseA = planA.base
    baseB = planB.base
    // The next cycle brings each the other's change.
    planA = SharedPlan.plan(local: localA, base: baseA, remote: live(replicaA))
    planB = SharedPlan.plan(local: localB, base: baseB, remote: live(replicaB))
    for change in planA.apply { localA[change.key] = change.value }
    for change in planB.apply { localB[change.key] = change.value }
    #expect(localA == localB)
    #expect(Set(localA.keys) == ["name", "ln:1", "ln:3"])
    #expect(live(replicaA) == live(replicaB))
}

// MARK: - shared folders: the directory

@Test func theDirectoryIsFoundByItsChain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-find-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = SyncKeys(entropy: SyncPhrase.fresh())
    let made = try SharedFolders.makeDirectory(in: root.appendingPathComponent("Copper Shared"), named: "Trip", chain: keys.chain, scope: keys.scope("folder"))
    #expect(made.lastPathComponent == "Trip")
    let second = try SharedFolders.makeDirectory(in: root.appendingPathComponent("Copper Shared"), named: "Trip", chain: "OTHER", scope: "S")
    #expect(second.lastPathComponent == "Trip 2")
    // /var and /private/var are the same folder; a listing says the second.
    func real(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().path }
    #expect(real(SharedFolders.find(chain: keys.chain, name: "Trip", in: root)) == real(made))
    // Without the name, or under the name iCloud gave a folder shared with you.
    #expect(real(SharedFolders.find(chain: keys.chain, name: nil, in: root)) == real(made))
    #expect(SharedFolders.find(chain: "NOPE", name: "Trip", in: root) == nil)
    #expect(SharedFolders.safeName("../a/b:c") == "-a-b-c")
    #expect(SharedFolders.safeName("  ") == "Shared Folder")
}
