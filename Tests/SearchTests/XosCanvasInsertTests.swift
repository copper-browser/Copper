import Foundation
import Testing
@testable import Search

@Test func xosInsertOnlyAcceptsBoundedXosSnapshotSources() {
    let good = "https://xos.apps.exowatt.com/api/whiteboard-exports/" + String(repeating: "a", count: 43)
    func link(_ source: String, mode: String = "choose") -> URL {
        var parts = URLComponents(string: "copper://canvas/insert")!
        parts.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "mode", value: mode)]
        return parts.url!
    }
    #expect(XosInsertLink.parse(link(good))?.source.absoluteString == good)
    for bad in [good.replacingOccurrences(of: "https:", with: "http:"), good + "?key=secret", good + "#fragment", good.replacingOccurrences(of: "xos.apps", with: "xos.apps.evil"), "https://xos.apps.exowatt.com/api/devices", "file:///etc/passwd", "https://name:password@xos.apps.exowatt.com/api/whiteboard-exports/" + String(repeating: "a", count: 43)] {
        #expect(XosInsertLink.parse(link(bad)) == nil)
    }
    #expect(XosInsertLink.parse(link(good, mode: "run-ops")) == nil)
    for mode in ["meeting", "personal", "room", "choose"] { #expect(XosInsertLink.parse(link(good, mode: mode))?.mode == mode) }
}

@Test func xosInsertRefusesImageBombsAndArbitraryOperations() throws {
    let object: [String: Any] = ["version": 1, "id": UUID().uuidString, "title": "Sketch", "room": "zilker", "meeting_id": "", "meeting_title": "", "copper_canvas_id": "", "png": "data:image/png;base64,AAAA", "width": 1600, "height": 900, "ops": [["op": "clear", "confirm": true]]]
    let snapshot = try JSONDecoder().decode(XosInsertSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try snapshot.image() }
    var bomb = object; bomb["width"] = 100_000
    let huge = try JSONDecoder().decode(XosInsertSnapshot.self, from: JSONSerialization.data(withJSONObject: bomb))
    #expect(throws: (any Error).self) { try huge.image() }
}
