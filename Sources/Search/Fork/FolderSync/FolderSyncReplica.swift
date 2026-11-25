import Foundation

// What the sync folder holds, merged: every record's latest write. Pure — no
// browser, no files — so the bench and `swift test` can run it with made-up
// devices (FolderSyncChecks.swift).
//
// Each Mac only ever creates files, under fresh random names, and never
// changes one, so the service carrying the folder never sees a conflict:
//   log       a batch of one device's changes; `seq` counts up per device
//   snapshot  a device's whole replica, and the seqs it covers per device
//
// A record is `key → (h: hybrid logical clock, v: value or nil for deleted,
// o: the device and seq that wrote it)`. The later clock wins, per record;
// merging is commutative, associative and idempotent, so Macs agree whatever
// order files arrive in, and a file read twice changes nothing. The proven
// format is Ardia's (docs/sync.md there); Copper keeps Copper Cloud's own
// document rules on top (FolderSync.swift).

/// A hybrid logical clock: `wall(ms, base 36, 9 digits).counter(4).device`.
/// Fixed width, so comparing two as strings compares the clocks, and the
/// device breaks ties. A clock never goes below the newest it has seen.
struct SyncClock: Codable, Equatable {
    var wall: Int64 = 0
    var count = 0
    var device: String

    init(device: String) { self.device = device }

    mutating func tick(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        if now > wall { wall = now; count = 0 } else { count += 1 }
        return SyncClock.stamp(wall: wall, count: count, device: device)
    }

    mutating func observe(_ stamp: String) {
        guard let parsed = SyncClock.parse(stamp) else { return }
        let (w, c) = parsed
        if w > wall || (w == wall && c > count) { wall = w; count = c }
    }

    static func stamp(wall: Int64, count: Int, device: String) -> String {
        pad(String(wall, radix: 36), 9) + "." + pad(String(count, radix: 36), 4) + "." + device
    }

    static func parse(_ stamp: String) -> (Int64, Int)? {
        let parts = stamp.split(separator: ".", maxSplits: 2)
        guard parts.count == 3, let w = Int64(parts[0], radix: 36), let c = Int(parts[1], radix: 36) else { return nil }
        return (w, c)
    }

    /// When a stamp was made, in ms.
    static func wall(_ stamp: String) -> Int64 { parse(stamp)?.0 ?? 0 }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}

struct SyncRecord: Codable, Equatable {
    var h: String
    /// Canonical JSON (sorted keys), or nil: deleted.
    var v: String?
    /// "<device>:<seq>" — the log that wrote it.
    var o: String

    var origin: (device: String, seq: Int)? {
        guard let colon = o.lastIndex(of: ":"), let seq = Int(o[o.index(after: colon)...]) else { return nil }
        return (String(o[..<colon]), seq)
    }
}

struct SyncOp: Codable, Equatable {
    var k: String
    var h: String
    var v: String?
}

/// One sealed file's contents.
struct SyncFile: Codable, Equatable {
    var v = 1
    var kind: String
    var device: String
    var at: Double
    // a log
    var seq: Int? = nil
    var ops: [SyncOp]? = nil
    // a snapshot
    var vv: [String: Int]? = nil
    var records: [String: SyncRecord]? = nil

    static func log(device: String, seq: Int, ops: [SyncOp], at: Date = Date()) -> SyncFile {
        SyncFile(kind: "log", device: device, at: at.timeIntervalSince1970 * 1000, seq: seq, ops: ops)
    }
}

struct SyncReplica: Codable, Equatable {
    var records: [String: SyncRecord] = [:]
    /// Per device, the highest seq such that every log of that device up to
    /// it is in. Seqs that came in out of order wait in `extra`.
    var vv: [String: Int] = [:]
    var extra: [String: [Int]] = [:]

    /// Whether the log (device, seq) is already in.
    func has(_ device: String, _ seq: Int) -> Bool {
        seq <= (vv[device] ?? 0) || (extra[device]?.contains(seq) ?? false)
    }

    /// Some device's logs arrived past a gap: an older write may still come.
    var gaps: Bool { extra.values.contains { !$0.isEmpty } }

    /// Last writer wins. True when `record` changed what this replica says.
    @discardableResult
    mutating func merge(_ key: String, _ record: SyncRecord) -> Bool {
        if let have = records[key], have.h >= record.h { return false }
        let before = records[key]?.v
        records[key] = record
        return before != record.v
    }

    /// A log, once. Returns the keys whose value changed.
    @discardableResult
    mutating func ingest(log file: SyncFile) -> Set<String> {
        guard file.kind == "log", let seq = file.seq, !has(file.device, seq) else { return [] }
        var changed = Set<String>()
        for op in file.ops ?? [] {
            if merge(op.k, SyncRecord(h: op.h, v: op.v, o: "\(file.device):\(seq)")) { changed.insert(op.k) }
        }
        note(file.device, seq)
        return changed
    }

    private mutating func note(_ device: String, _ seq: Int) {
        var waiting = Set(extra[device] ?? [])
        waiting.insert(seq)
        var top = vv[device] ?? 0
        while waiting.contains(top + 1) { top += 1; waiting.remove(top) }
        vv[device] = top
        let left = waiting.filter { $0 > top }.sorted()
        extra[device] = left.isEmpty ? nil : left
    }

    /// A snapshot. A record whose writing log is already in here, for a key
    /// this replica no longer has, is a deletion already applied (its
    /// tombstone since collected): skipped, so an old snapshot put back
    /// brings nothing back. A record here whose log the snapshot covers but
    /// which it doesn't hold was deleted, and its tombstone collected:
    /// dropped. Returns the keys whose value changed.
    @discardableResult
    mutating func ingest(snapshot file: SyncFile) -> Set<String> {
        guard file.kind == "snapshot", let covers = file.vv, let incoming = file.records else { return [] }
        var changed = Set<String>()
        for (key, record) in incoming {
            if records[key] == nil, let o = record.origin, has(o.device, o.seq) { continue }
            if merge(key, record) { changed.insert(key) }
        }
        for (key, record) in records where incoming[key] == nil {
            guard let o = record.origin, o.seq <= (covers[o.device] ?? 0) else { continue }
            records[key] = nil
            if record.v != nil { changed.insert(key) }
        }
        for (device, top) in covers where top > (vv[device] ?? 0) {
            vv[device] = top
            var waiting = Set((extra[device] ?? []).filter { $0 > top })
            var at = top
            while waiting.contains(at + 1) { at += 1; waiting.remove(at) }
            vv[device] = at
            extra[device] = waiting.isEmpty ? nil : waiting.sorted()
        }
        return changed
    }

    /// The live values whose keys pass `filter`.
    func live(_ filter: (String) -> Bool) -> [String: String] {
        var out: [String: String] = [:]
        for (key, record) in records where filter(key) { if let v = record.v { out[key] = v } }
        return out
    }

    /// What a snapshot keeps: tombstones younger than 45 days (90 while a
    /// gap means an older write may still arrive) and history younger than
    /// 90 days.
    func kept(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: SyncRecord] {
        let day: Int64 = 86_400_000
        let tombstones = now - (gaps ? 90 : 45) * day
        let history = now - 90 * day
        return records.filter { key, record in
            let at = SyncClock.wall(record.h)
            if record.v == nil { return at >= tombstones }
            if key.hasPrefix("h:") { return at >= history }
            return true
        }
    }
}
