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
        #expect(store.write(jpeg, size: CGSize(width: 1280, height: 800), ground: .white, for: url))
        let bytes = try #require(try? Data(contentsOf: store.file(for: url)))
        #expect(bytes.count <= 150 * 1024)
        let kept = try #require(store.read(for: url))
        #expect(kept.image.size == CGSize(width: 1280, height: 800))
        let ground = try #require(kept.ground?.usingColorSpace(.sRGB))
        #expect(ground.redComponent > 0.99 && ground.greenComponent > 0.99 && ground.blueComponent > 0.99)
        // Another address has no picture; removed, this one has none either.
        #expect(store.read(for: URL(string: "https://example.com/other")!) == nil)
        store.remove(for: url)
        #expect(store.read(for: url) == nil)
    }

    @Test("Past the cap, the pictures used longest ago go first")
    func evictsOldest() throws {
        var store = CoverStore(folder: folder())
        defer { store.removeAll() }
        let urls = (0..<3).map { URL(string: "https://example.com/\($0)")! }
        let one = picture(400, 300)
        for (i, url) in urls.enumerated() {
            #expect(store.write(one, size: CGSize(width: 400, height: 300), ground: nil, for: url))
            // Oldest first: 0 an hour ago, 1 half an hour ago, 2 now.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 2) * 1800)],
                                                  ofItemAtPath: store.file(for: url).path)
        }
        // Reading 0 makes it the newest.
        #expect(store.read(for: urls[0]) != nil)
        let each = try #require(try? Data(contentsOf: store.file(for: urls[1]))).count
        store.cap = each * 2 + each / 2
        store.evict()
        #expect(FileManager.default.fileExists(atPath: store.file(for: urls[0]).path))
        #expect(!FileManager.default.fileExists(atPath: store.file(for: urls[1]).path))
        #expect(FileManager.default.fileExists(atPath: store.file(for: urls[2]).path))
    }

    @Test("Not a picture: nothing is written")
    func refusesGarbage() {
        let store = CoverStore(folder: folder())
        defer { store.removeAll() }
        #expect(!store.write(Data("not a jpeg".utf8), size: .zero, ground: nil, for: URL(string: "https://example.com")!))
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
