import AppKit
import Foundation
import Testing
@testable import Search

// Fork (covers, hill-climb r5): a page's last picture kept on disk
// (Fork/Covers.swift), ⌃'s warming guess (Fork/SpaceWarm.swift
// `ControlIntent`), big pins that may sleep (Fork/PinsAwake.swift) and the
// agent's colour by app (Fork/MCP/Hands.swift).

@Suite("Covers: save, load, evict")
struct CoverStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("covers-test-\(UUID().uuidString)", isDirectory: true)
    }

    /// A noisy picture `w`×`h` pixels, as a high-quality JPEG: big enough
    /// that it has to be made smaller to fit.
    private func picture(_ w: Int, _ h: Int, seed: UInt32 = 1) -> Data {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var x = seed
        for _ in 0..<4000 {
            x = x &* 1_664_525 &+ 1_013_904_223
            let r = CGFloat(x % 255) / 255
            context.setFillColor(CGColor(red: r, green: 1 - r, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: Int(x >> 8) % w, y: Int(x >> 16) % h, width: 6, height: 3))
        }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 1.0])!
    }

    @Test("A Retina picture comes back at its size in points, with its ground, in at most 150 KB")
    func roundTrip() throws {
        let store = CoverStore(folder: folder())
        defer { store.removeAll() }
        let url = URL(string: "https://example.com/inbox")!
        let jpeg = picture(2560, 1600)
        #expect(jpeg.count > 150 * 1024)
        #expect(store.write(jpeg, size: CGSize(width: 1280, height: 800), ground: .white, for: url, jar: "default"))
        let bytes = try #require(try? Data(contentsOf: store.file(for: url, jar: "default")))
        #expect(bytes.count <= 150 * 1024)
        let kept = try #require(store.read(for: url, jar: "default"))
        #expect(kept.image.size == CGSize(width: 1280, height: 800))
        let ground = try #require(kept.ground?.usingColorSpace(.sRGB))
        #expect(ground.redComponent > 0.99 && ground.greenComponent > 0.99 && ground.blueComponent > 0.99)
        // Another address has no picture; removed, this one has none either.
        #expect(store.read(for: URL(string: "https://example.com/other")!, jar: "default") == nil)
        store.remove(for: url, jar: "default")
        #expect(store.read(for: url, jar: "default") == nil)
    }

    @Test("Past the cap, the pictures used longest ago go first")
    func evictsOldest() throws {
        var store = CoverStore(folder: folder())
        defer { store.removeAll() }
        let urls = (0..<3).map { URL(string: "https://example.com/\($0)")! }
        let one = picture(400, 300)
        for (i, url) in urls.enumerated() {
            #expect(store.write(one, size: CGSize(width: 400, height: 300), ground: nil, for: url, jar: "default"))
            // Oldest first: 0 an hour ago, 1 half an hour ago, 2 now.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 2) * 1800)],
                                                  ofItemAtPath: store.file(for: url, jar: "default").path)
        }
        // Reading 0 makes it the newest.
        #expect(store.read(for: urls[0], jar: "default") != nil)
        let each = try #require(try? Data(contentsOf: store.file(for: urls[1], jar: "default"))).count
        store.cap = each * 2 + each / 2
        store.evict()
        #expect(FileManager.default.fileExists(atPath: store.file(for: urls[0], jar: "default").path))
        #expect(!FileManager.default.fileExists(atPath: store.file(for: urls[1], jar: "default").path))
        #expect(FileManager.default.fileExists(atPath: store.file(for: urls[2], jar: "default").path))
    }

    @Test("Two profiles on one address: each sees only its own picture, after a relaunch too; unscoped files go")
    func scopedByJar() throws {
        let place = folder()
        let url = URL(string: "https://mail.example.com/inbox")!
        let first = CoverStore(folder: place)
        defer { first.removeAll() }
        #expect(first.write(picture(400, 300, seed: 1), size: CGSize(width: 400, height: 300), ground: nil, for: url, jar: "default"))
        #expect(first.file(for: url, jar: "default") != first.file(for: url, jar: "work"))
        #expect(first.read(for: url, jar: "work") == nil)
        // An old-style file (no jar in the name) for the same address.
        let legacy = place.appendingPathComponent(String(repeating: "ab", count: 16) + ".jpg")
        try Data(contentsOf: first.file(for: url, jar: "default")).write(to: legacy)
        // Relaunch: a new store on the same folder.
        let again = CoverStore(folder: place)
        #expect(again.read(for: url, jar: "work") == nil)
        #expect(again.read(for: url, jar: "default") != nil)
        again.purgeUnscoped()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: again.file(for: url, jar: "default").path))
        // Closing in one profile leaves the other's.
        #expect(again.write(picture(400, 300, seed: 2), size: CGSize(width: 400, height: 300), ground: nil, for: url, jar: "work"))
        again.remove(for: url, jar: "work")
        #expect(again.read(for: url, jar: "default") != nil)
    }

    @Test("Not a picture: nothing is written")
    func refusesGarbage() {
        let store = CoverStore(folder: folder())
        defer { store.removeAll() }
        #expect(!store.write(Data("not a jpeg".utf8), size: .zero, ground: nil, for: URL(string: "https://example.com")!, jar: "default"))
    }
}

@Suite("⌃ warms the spaces either side at once, never from a text field")
struct ControlIntentTests {
    @Test("⌃A in a text field loads no page")
    func controlAInFieldWarmsNothing() {
        var intent = ControlIntent()
        #expect(intent.flags(control: true, typing: true, walking: false, roomy: true) == .none)
        #expect(intent.key(space: ControlIntent.spaceKey("a", keyCode: 0, option: false)) == .none)
        #expect(intent.flags(control: false, typing: false, walking: false, roomy: true) == .none)
    }

    @Test("⌃ down warms at once; ⌃2 keeps the guess, ⌃A or ⌃⇥ takes it back")
    func warmThenCancel() {
        var intent = ControlIntent()
        #expect(intent.flags(control: true, typing: false, walking: false, roomy: true) == .warm)
        // ⌥ joining ⌃ (⌃⌥→) is not a second ⌃.
        #expect(intent.flags(control: true, typing: false, walking: false, roomy: true) == .none)
        #expect(intent.key(space: ControlIntent.spaceKey("2", keyCode: 19, option: false)) == .none)
        #expect(intent.key(space: ControlIntent.spaceKey("", keyCode: 124, option: true)) == .none)
        #expect(intent.key(space: ControlIntent.spaceKey("a", keyCode: 0, option: false)) == .cancel)
        // Taken back once.
        #expect(intent.key(space: ControlIntent.spaceKey("\t", keyCode: 48, option: false)) == .none)
        _ = intent.flags(control: false, typing: false, walking: false, roomy: true)
        #expect(intent.flags(control: true, typing: false, walking: false, roomy: true) == .warm)
        #expect(intent.key(space: ControlIntent.spaceKey("\t", keyCode: 48, option: false)) == .cancel)
    }

    @Test("No room, or a tab walk under way: no guess")
    func noRoomNoGuess() {
        var intent = ControlIntent()
        #expect(intent.flags(control: true, typing: false, walking: false, roomy: false) == .none)
        _ = intent.flags(control: false, typing: false, walking: false, roomy: true)
        #expect(intent.flags(control: true, typing: false, walking: true, roomy: true) == .none)
    }

    @Test("Space keys: ⌃1–9 and ⌃⌥←/→ only")
    func spaceKeys() {
        #expect(ControlIntent.spaceKey("1", keyCode: 18, option: false))
        #expect(ControlIntent.spaceKey("9", keyCode: 25, option: false))
        #expect(!ControlIntent.spaceKey("0", keyCode: 29, option: false))
        #expect(!ControlIntent.spaceKey("", keyCode: 123, option: false)) // ⌃← alone is the Mac's
        #expect(ControlIntent.spaceKey("", keyCode: 123, option: true))
        #expect(!ControlIntent.spaceKey("e", keyCode: 14, option: false))
    }
}

@Suite("Big pins may sleep — on unless you turn it off")
struct BigPinsTests {
    private let mb: UInt64 = 1_048_576

    @Test("On by default: nothing stored is on; a stored off stays off")
    func defaultOn() {
        #expect(PinsAwake.bigPinsSleep(stored: nil))
        #expect(!PinsAwake.bigPinsSleep(stored: false))
        #expect(PinsAwake.bigPinsSleep(stored: true))
    }

    @Test("Off: a pin never dozes, however big or long left")
    func offNever() {
        #expect(!PinRule.mayDoze(on: false, hidden: 99 * 3600, bytes: 4000 * mb, after: 7200, least: 300 * mb))
        #expect(!PinRule.mayUnload(pinned: true, .sleep))
    }

    @Test("On: over 300 MB and two hours unlooked-at, and only then")
    func onBigAndLeft() {
        #expect(PinRule.mayDoze(on: true, hidden: 7200, bytes: 300 * mb, after: 7200, least: 300 * mb))
        #expect(!PinRule.mayDoze(on: true, hidden: 7199, bytes: 900 * mb, after: 7200, least: 300 * mb))
        #expect(!PinRule.mayDoze(on: true, hidden: 9 * 3600, bytes: 299 * mb, after: 7200, least: 300 * mb))
        #expect(PinRule.mayUnload(pinned: true, .doze))
    }
}

@Suite("Big pins at launch: asleep stays asleep, under its picture")
@MainActor
struct BigPinsLaunchTests {
    private let mb: UInt64 = 1_048_576

    private func rule(on: Bool = true, covered: Bool = true, dozed: Bool = false, hidden: TimeInterval = 0, bytes: UInt64 = 0) -> Bool {
        PinRule.asleepAtLaunch(on: on, covered: covered, dozed: dozed, hidden: hidden, bytes: bytes, after: 7200, least: 300 * mb)
    }

    @Test("Dozed, or big and left two hours, with a picture: stays asleep; recent or small: loads")
    func launchRule() {
        #expect(rule(dozed: true))
        #expect(rule(hidden: 3 * 3600, bytes: 900 * mb))
        #expect(!rule(hidden: 60, bytes: 900 * mb))
        #expect(!rule(hidden: 9 * 3600, bytes: 100 * mb))
        #expect(!rule(covered: false, dozed: true))
    }

    @Test("Setting off: every pin loads, whatever the session said")
    func offLoads() {
        #expect(!rule(on: false, dozed: true))
        #expect(!rule(on: false, hidden: 9 * 3600, bytes: 900 * mb))
    }

    @Test("Weight and dozed go into the session and come back")
    func persists() throws {
        var entry = Session.Entry(url: "https://mail.example.com/", title: "Mail", pin: "M")
        entry.mb = 1200
        entry.dozed = true
        entry.seen = 1_000
        let back = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))
        #expect(back.mb == 1200 && back.dozed == true && back.seen == 1_000)
        // An older file has neither: it reads, and nothing stays asleep for it.
        let old = try JSONDecoder().decode(Session.Entry.self, from: Data(#"{"url":"https://a.example/","title":"A"}"#.utf8))
        #expect(old.mb == nil && old.dozed == nil)
    }

    @Test("A restored pin marked asleep is left for you, keeps its weight and its last look")
    func restoredPin() {
        let tab = Tab()
        let url = URL(string: "https://mail.example.com/")!
        tab.restore(url: url, title: "Mail")
        tab.pin = "M"
        let seen = Date().addingTimeInterval(-3 * 3600)
        tab.restorePin(seen: seen, weighed: 900 * mb, dozed: true)
        #expect(tab.dozed && tab.asleep && tab.weighed == 900 * mb)
        #expect(abs(tab.touched.timeIntervalSince(seen)) < 0.001)
        #expect(!PinsAwake.needsPage(tab))
        // Not dozed: the background loader takes it, as today.
        let other = Tab()
        other.restore(url: url, title: "Mail")
        other.pin = "M"
        other.restorePin(seen: seen, weighed: nil, dozed: false)
        #expect(PinsAwake.needsPage(other))
    }

    @Test("A private tab has no jar and never keeps a picture")
    func privateNever() {
        let shy = Tab(shy: true)
        #expect(shy.jar == nil)
        #expect(!Covers.keeps(shy))
    }
}

@Suite("An agent's colour is its app's, not its session's")
@MainActor
struct AgentColourTests {
    @Test("Two Claude Code sessions share one seed; another app has its own")
    func seedIsTheApp() {
        var one = Drive.Who.Said(), two = Drive.Who.Said(), other = Drive.Who.Said()
        one.harness = "Claude Code"; one.session = "11111111-aaaa"; one.project = "copper"
        two.harness = "Claude Code"; two.session = "22222222-bbbb"; two.project = "scrawl"
        other.harness = "Codex"; other.session = "33333333-cccc"
        let a = Drive.Who.from(one, mcpSession: nil, fallbackName: "")
        let b = Drive.Who.from(two, mcpSession: nil, fallbackName: "")
        let c = Drive.Who.from(other, mcpSession: nil, fallbackName: "")
        #expect(a.key != b.key)
        #expect(a.seed == b.seed)
        #expect(a.seed != c.seed)
    }
}
