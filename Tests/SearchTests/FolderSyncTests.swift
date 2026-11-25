import CryptoKit
import Foundation
import Testing
@testable import Search

// iCloud sync's pure parts (Fork/FolderSync/): the phrase, the sealed files,
// the replica's merge, and Copper Cloud's documents as records.

private func hex(_ text: String) -> Data {
    var out = Data()
    var at = text.startIndex
    while at < text.endIndex {
        let next = text.index(at, offsetBy: 2)
        out.append(UInt8(text[at..<next], radix: 16)!)
        at = next
    }
    return out
}

// MARK: - phrase

@Test func wordlistIsBIP39English() {
    #expect(SyncPhrase.words.count == 2048)
    #expect(Set(SyncPhrase.words).count == 2048)
    let digest = SHA256.hash(data: Data((SyncPhrase.words.joined(separator: "\n") + "\n").utf8))
    #expect(digest.map { String(format: "%02x", $0) }.joined() == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
}

/// Trezor's BIP-39 reference vectors (python-mnemonic vectors.json), the 256-bit ones.
@Test func phraseMatchesReferenceVectors() throws {
    let vectors = [
        ("0000000000000000000000000000000000000000000000000000000000000000",
         "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"),
        ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
         "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"),
        ("8080808080808080808080808080808080808080808080808080808080808080",
         "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
         "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"),
    ]
    for (entropy, phrase) in vectors {
        #expect(SyncPhrase.words(for: hex(entropy)).joined(separator: " ") == phrase)
        #expect(try SyncPhrase.entropy(from: phrase) == hex(entropy))
    }
}

@Test func phraseReadsLeniently() throws {
    let entropy = SyncPhrase.fresh()
    let words = SyncPhrase.words(for: entropy)
    let numbered = words.enumerated().map { "\($0.offset + 1). \($0.element.uppercased())" }.joined(separator: "\n")
    #expect(try SyncPhrase.entropy(from: numbered) == entropy)
    let short = words.map { String($0.prefix(4)) }.joined(separator: ", ")
    #expect(try SyncPhrase.entropy(from: short) == entropy)
}

@Test func phraseRefusesWhatIsWrong() {
    let words = SyncPhrase.words(for: SyncPhrase.fresh())
    #expect(throws: SyncPhrase.Problem.count(23)) { try SyncPhrase.entropy(from: words.dropLast().joined(separator: " ")) }
    #expect(throws: SyncPhrase.Problem.word("qwerty")) { try SyncPhrase.entropy(from: (words.dropLast() + ["qwerty"]).joined(separator: " ")) }
    // Swapping two different words breaks the checksum (or, rarely, not: try a few).
    var caught = 0
    for i in 0..<8 {
        var swapped = words
        swapped.swapAt(i, 23 - i)
        if swapped == words { continue }
        if (try? SyncPhrase.entropy(from: swapped.joined(separator: " "))) == nil { caught += 1 }
    }
    #expect(caught >= 5)
}

// MARK: - sealed files

@Test func sealedFilesOpenOnlyWhereTheyWereWritten() throws {
    let keys = SyncKeys(entropy: SyncPhrase.fresh())
    let json = Data(#"{"hello":"world"}"#.utf8)
    let sealed = try keys.seal(json, chain: keys.chain, scope: "s", file: "a.cps")
    #expect(sealed.prefix(4) == SyncKeys.magic)
    #expect((sealed.count - 4 - 12 - 16) % SyncKeys.pad == 0)
    #expect(try keys.open(sealed, chain: keys.chain, scope: "s", file: "a.cps") == json)
    // Renamed, moved, another phrase, a byte flipped, cut short: nothing opens.
    #expect(throws: SyncKeys.Failure.tampered) { try keys.open(sealed, chain: keys.chain, scope: "s", file: "b.cps") }
    #expect(throws: SyncKeys.Failure.tampered) { try keys.open(sealed, chain: keys.chain, scope: "t", file: "a.cps") }
    let other = SyncKeys(entropy: SyncPhrase.fresh())
    #expect(throws: SyncKeys.Failure.tampered) { try other.open(sealed, chain: keys.chain, scope: "s", file: "a.cps") }
    var flipped = sealed
    flipped[40] ^= 1
    #expect(throws: SyncKeys.Failure.tampered) { try keys.open(flipped, chain: keys.chain, scope: "s", file: "a.cps") }
    #expect(throws: SyncKeys.Failure.tampered) { try keys.open(sealed.prefix(sealed.count - 1), chain: keys.chain, scope: "s", file: "a.cps") }
    #expect(throws: SyncKeys.Failure.short) { try keys.open(sealed.prefix(10), chain: keys.chain, scope: "s", file: "a.cps") }
    #expect(throws: SyncKeys.Failure.notOurs) { try keys.open(Data(repeating: 7, count: 100), chain: keys.chain, scope: "s", file: "a.cps") }
}

@Test func namesComeFromThePhraseAndSayNothing() {
    let entropy = SyncPhrase.fresh()
    let a = SyncKeys(entropy: entropy), b = SyncKeys(entropy: entropy), c = SyncKeys(entropy: SyncPhrase.fresh())
    #expect(a.chain == b.chain && a.scope("main") == b.scope("main"))
    #expect(a.chain != c.chain && a.chain != a.scope("main"))
    #expect(SyncKeys.isTag(a.chain) && SyncKeys.isTag(a.scope("main")))
    #expect(SyncKeys.freshName().hasSuffix(".cps") && SyncKeys.freshName() != SyncKeys.freshName())
    #expect(SyncKeys.base32(Data("foobar".utf8)) == "mzxw6ytboi") // RFC 4648 §10
}

// MARK: - clock and replica

@Test func clockStampsSortAsTheyHappen() {
    var clock = SyncClock(device: "aaaa")
    let one = clock.tick(now: 1_000), two = clock.tick(now: 1_000), three = clock.tick(now: 999)
    #expect(one < two && two < three)
    clock.observe(SyncClock.stamp(wall: 5_000, count: 3, device: "bbbb"))
    #expect(clock.tick(now: 10) > SyncClock.stamp(wall: 5_000, count: 3, device: "bbbb"))
    #expect(SyncClock.wall(one) == 1_000)
}

/// Three devices' logs, read in every order, twice over: the same replica.
@Test func replicasAgreeWhateverOrderFilesArriveIn() {
    var clocks = ["a", "b", "c"].map { SyncClock(device: $0) }
    var logs: [SyncFile] = []
    var now: Int64 = 1_000
    for seq in 1...3 {
        for d in 0..<3 {
            now += Int64.random(in: 0...2)
            let ops = [
                SyncOp(k: "bm:shared", h: clocks[d].tick(now: now), v: "\"\(clocks[d].device)\(seq)\""),
                SyncOp(k: "bm:\(clocks[d].device)\(seq)", h: clocks[d].tick(now: now), v: seq == 2 && d == 1 ? nil : "1"),
            ]
            logs.append(.log(device: clocks[d].device, seq: seq, ops: ops))
        }
    }
    var reference = SyncReplica()
    for log in logs { reference.ingest(log: log) }
    for _ in 0..<50 {
        var replica = SyncReplica()
        for log in (logs + logs).shuffled() { replica.ingest(log: log) }
        #expect(replica.records == reference.records)
        #expect(replica.vv == ["a": 3, "b": 3, "c": 3] && !replica.gaps)
    }
}

@Test func outOfOrderLogsWaitForTheirGap() {
    var replica = SyncReplica()
    replica.ingest(log: .log(device: "a", seq: 2, ops: [SyncOp(k: "x", h: "2", v: "2")]))
    #expect(replica.vv["a"] == 0 && replica.gaps)
    #expect(replica.ingest(log: .log(device: "a", seq: 2, ops: [SyncOp(k: "x", h: "2", v: "2")])).isEmpty)
    replica.ingest(log: .log(device: "a", seq: 1, ops: [SyncOp(k: "x", h: "1", v: "1")]))
    #expect(replica.vv["a"] == 2 && !replica.gaps && replica.records["x"]?.v == "2")
}

/// A snapshot never brings back what was deleted, and a deletion it covers
/// clears the record even once the tombstone is gone.
@Test func snapshotsKeepDeletionsDeleted() {
    var writer = SyncReplica()
    writer.ingest(log: .log(device: "a", seq: 1, ops: [SyncOp(k: "x", h: "1", v: "1"), SyncOp(k: "y", h: "1", v: "1")]))
    let old = SyncFile(kind: "snapshot", device: "a", at: 0, vv: writer.vv, records: writer.records)
    writer.ingest(log: .log(device: "a", seq: 2, ops: [SyncOp(k: "x", h: "2", v: nil)]))
    // A reader that saw the deletion, then the old snapshot: x stays gone.
    var reader = SyncReplica()
    reader.ingest(log: .log(device: "a", seq: 1, ops: [SyncOp(k: "x", h: "1", v: "1"), SyncOp(k: "y", h: "1", v: "1")]))
    reader.ingest(log: .log(device: "a", seq: 2, ops: [SyncOp(k: "x", h: "2", v: nil)]))
    reader.records["x"] = nil // its tombstone collected
    reader.ingest(snapshot: old)
    #expect(reader.records["x"] == nil && reader.records["y"]?.v == "1")
    // A reader that only had seq 1, then a snapshot after the deletion with
    // the tombstone collected: x goes.
    var late = SyncReplica()
    late.ingest(log: .log(device: "a", seq: 1, ops: [SyncOp(k: "x", h: "1", v: "1"), SyncOp(k: "y", h: "1", v: "1")]))
    var compacted = writer.records
    compacted["x"] = nil
    late.ingest(snapshot: SyncFile(kind: "snapshot", device: "a", at: 0, vv: writer.vv, records: compacted))
    #expect(late.records["x"] == nil && late.records["y"]?.v == "1" && late.vv["a"] == 2)
    // And a log the snapshot covers changes nothing.
    #expect(late.ingest(log: .log(device: "a", seq: 2, ops: [SyncOp(k: "x", h: "2", v: nil)])).isEmpty)
}

@Test func snapshotsDropOldTombstonesAndHistory() {
    let day: Int64 = 86_400_000, now: Int64 = 200 * day
    var replica = SyncReplica()
    replica.records = [
        "bm:old-gone": SyncRecord(h: SyncClock.stamp(wall: now - 50 * day, count: 0, device: "a"), v: nil, o: "a:1"),
        "bm:new-gone": SyncRecord(h: SyncClock.stamp(wall: now - 10 * day, count: 0, device: "a"), v: nil, o: "a:1"),
        "h:old": SyncRecord(h: SyncClock.stamp(wall: now - 100 * day, count: 0, device: "a"), v: "1", o: "a:1"),
        "bm:old": SyncRecord(h: SyncClock.stamp(wall: now - 100 * day, count: 0, device: "a"), v: "1", o: "a:1"),
    ]
    #expect(Set(replica.kept(now: now).keys) == ["bm:new-gone", "bm:old"])
}

// MARK: - documents as records

@Test func documentsSurviveTheTripThroughRecords() {
    let work = Space(name: "Work"), home = Space(name: "Home")
    let folder = CloudDocs.Folder(id: UUID(), name: "Docs", hue: 0.3, space: work.id, slot: nil)
    let tabs = [
        CloudDocs.KeptTab(key: "\(work.id)|saved|a.com|https://a.com/", space: work.id, url: "https://a.com/", title: "A", pinned: false, pin: nil, group: folder.id),
        CloudDocs.KeptTab(key: "\(home.id)|pin|b.com|https://b.com/", space: home.id, url: "https://b.com/", title: "B", pinned: true, pin: "B", group: nil),
    ].sorted { $0.key < $1.key }
    let spaces = CloudDocs.Spaces(spaces: [work, home], tabs: tabs, groups: [folder])
    #expect(SyncRecords.spaces(SyncRecords.records(spaces)) == spaces)

    let marks = CloudDocs.Bookmarks(roots: [
        Bookmark(title: "Folder", url: nil, children: [Bookmark(title: "One", url: "https://one.com/"), Bookmark(title: "Two", url: "https://two.com/")]),
        Bookmark(title: "Top", url: "https://top.com/"),
    ])
    #expect(SyncRecords.bookmarks(SyncRecords.records(marks)) == marks)

    let settings = CloudDocs.Settings(values: ["look": "dark", "shield": "true", "not.allowed": "x"])
    #expect(SyncRecords.settings(SyncRecords.records(settings)).values == ["look": "dark", "shield": "true"])
    #expect(SyncRecords.records(settings)["set:not.allowed"] == nil)
}

/// Two Macs filing different things: neither edit touches the other's record.
@Test func editsOnTwoMacsMergeRecordByRecord() {
    let space = Space(name: "Work")
    let base = CloudDocs.Spaces(spaces: [space], tabs: [], groups: [])
    func tab(_ host: String) -> CloudDocs.KeptTab {
        CloudDocs.KeptTab(key: "\(space.id)|saved|\(host)|https://\(host)/", space: space.id, url: "https://\(host)/", title: host, pinned: false, pin: nil, group: nil)
    }
    var a = base; a.tabs = [tab("a.com")]
    var b = base; b.tabs = [tab("b.com")]
    let before = SyncRecords.records(base)
    func diff(_ doc: CloudDocs.Spaces) -> [SyncOp] {
        SyncRecords.records(doc).filter { before[$0.key] != $0.value }.map { SyncOp(k: $0.key, h: "", v: $0.value) }
    }
    var replica = SyncReplica()
    var clock = SyncClock(device: "x")
    let stamp = { (ops: [SyncOp]) in ops.map { SyncOp(k: $0.k, h: clock.tick(), v: $0.v) } }
    replica.ingest(log: .log(device: "x", seq: 1, ops: stamp(before.map { SyncOp(k: $0.key, h: "", v: $0.value) })))
    replica.ingest(log: .log(device: "a", seq: 1, ops: stamp(diff(a))))
    replica.ingest(log: .log(device: "b", seq: 1, ops: stamp(diff(b))))
    #expect(Set(SyncRecords.spaces(replica.live(SyncRecords.of(.spaces))).tabs.map(\.url)) == ["https://a.com/", "https://b.com/"])
}
