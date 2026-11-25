import Foundation
import Testing
import WebKit
@testable import Search

// The blocker's lists (Fork/ShieldLists.swift): your own filters' forms, the
// regional pick, and every bundled list read back and compiled by this Mac's
// WebKit — the check that a refresh (tools/shield/refresh.py) is safe to ship.

private let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Search/Resources/shield")

private struct Index: Decodable { let lists: [ShieldLists.List] }
private let bundled: [ShieldLists.List] = {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { return [] }
    return (try? JSONDecoder().decode(Index.self, from: data))?.lists ?? []
}()

private func rules(_ json: String) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
}

@Suite("Shield lists")
struct ShieldListsTests {
    @Test("Your own filters: the forms people paste")
    func custom() {
        let made = ShieldLists.convert("""
        ! a comment
        [Adblock Plus 2.0]
        ||ads.example.com^
        ||t.example.net^$third-party
        0.0.0.0 bad.example.org
        tracker.example.io
        ##.banner
        news.example.com, other.example.org##div.popup
        @@||allowed.example^
        ||example.com/path/ad.js
        ~site.example##.x
        """)
        #expect(made.rules == 6)
        #expect(made.skipped == 3)
        let all = rules(made.json)
        let blocks = all.filter { ($0["action"] as? [String: Any])?["type"] as? String == "block" }
        #expect(blocks.count == 4)
        let first = blocks[0]["trigger"] as? [String: Any]
        let filter = first?["url-filter"] as? String ?? ""
        #expect(filter.contains("ads\\.example\\.com"))
        #expect(try! NSRegularExpression(pattern: filter).firstMatch(in: "https://cdn.ads.example.com/x.js", range: NSRange(location: 0, length: 32)) != nil)
        #expect((blocks[1]["trigger"] as? [String: Any])?["load-type"] as? [String] == ["third-party"])
        let hides = all.filter { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" }
        #expect(hides.count == 2)
        #expect((hides[1]["trigger"] as? [String: Any])?["if-domain"] as? [String] == ["*news.example.com", "*other.example.org"])
    }

    @Test("A list already in WebKit's JSON is taken as it is")
    func passthrough() {
        let json = #"[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]"#
        let made = ShieldLists.convert("\n" + json + "\n")
        #expect(made.json == json && made.rules == 1 && made.skipped == 0)
    }

    @Test("Regional lists follow the Mac's languages")
    func regional() {
        #expect(ShieldLists.languages(["de-CH", "en-US", "de", "pt-BR"]) == ["de", "en", "pt"])
        #expect(ShieldLists.regional(for: ["en"], in: bundled).isEmpty)
        #expect(ShieldLists.regional(for: ["de"], in: bundled).map(\.id) == ["deu-0"])
        #expect(ShieldLists.regional(for: ["fr", "ja"], in: bundled).map(\.id) == ["fra-0", "jpn-1"])
    }

    @Test("Every bundled list reads back, fits WebKit, and compiles")
    @MainActor
    func compiles() async throws {
        #expect(bundled.count >= 40)
        #expect(Set(bundled.map(\.group)).isSuperset(of: ["ads", "trackers", "cookies", "regional"]))
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("shield-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: place) }
        let store: WKContentRuleListStore = WKContentRuleListStore(url: place)
        var report: [String] = []
        for list in bundled {
            for file in list.files {
                let piece = ShieldLists.Piece(id: "t-\(file.sha)", title: list.title, kind: .ads, rules: file.rules,
                                              file: folder.appendingPathComponent(file.file), text: nil)
                let made = try #require(ShieldLists.read(piece), "\(file.file) didn't read")
                #expect(rules(made.json).count == file.rules, "\(file.file)")
                #expect(file.rules <= 150_000, "\(file.file)")
                let started = CFAbsoluteTimeGetCurrent()
                let error: String? = await withCheckedContinuation { done in
                    store.compileContentRuleList(forIdentifier: piece.id, encodedContentRuleList: made.json) { compiled, error in
                        done.resume(returning: compiled == nil ? (error?.localizedDescription ?? "no list") : nil)
                    }
                }
                #expect(error == nil, "\(file.file): \(error ?? "")")
                report.append("\(file.file) \(file.rules) rules \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
            }
        }
        print("shield compile: " + report.joined(separator: "; "))
    }
}
