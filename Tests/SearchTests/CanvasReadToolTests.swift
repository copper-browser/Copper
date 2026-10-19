import AppKit
import Testing
import WebKit
@testable import Search

// canvas_read's options reach the page as given (the page pages and narrows,
// canvas-app src/read-pages.ts); posters are scaled and cropped the way the page
// asked (Fork/Canvas/CanvasPosters.swift); the MCP socket takes pipelined
// requests in order (Fork/MCP/MCP.swift). docs/canvas.md, "Reading a big canvas".

@Test func canvasReadPassesItsOptionsThroughAndNothingElse() {
    let args: [String: Any] = [
        "id": "Roadmap", "reason": "look", "full": true, "overview": false, "frame": "fr01",
        "region": ["x": 0, "y": 0, "w": 10, "h": 10], "ids": ["a"], "types": ["web"], "query": "Budget",
        "limit": 50, "cursor": "cr1.abc", "inView": true, "tab": "1234",
    ]
    let opts = CanvasTools.readOptions(args)
    #expect(Set(opts.keys) == ["full", "overview", "frame", "region", "ids", "types", "query", "limit", "cursor"])
    #expect(opts["cursor"] as? String == "cr1.abc")
    #expect(opts["limit"] as? Int == 50)
    #expect(CanvasTools.readOptions(["cursor": NSNull(), "id": "x"]).isEmpty)
}

@Test func canvasReadSchemaAndWordsTellAgentsHowToReadABigCanvas() {
    let keys = Set(CanvasTools.readProperties.keys)
    #expect(keys == ["id", "full", "overview", "frame", "region", "ids", "types", "query", "limit", "cursor"])
    let types = ((CanvasTools.readProperties["types"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String]
    #expect(types == ["sticky", "text", "frame", "arrow", "image", "link", "web", "checklist", "timeline"])
    #expect(CanvasTools.readDescription.contains("overview:true"))
    #expect(CanvasTools.readDescription.contains("cursor"))
    #expect(CanvasTools.instructions.contains("overview:true first"))
    let read = CanvasTools.catalogue.first { $0["name"] as? String == "canvas_read" }
    let schema = read?["inputSchema"] as? [String: Any]
    #expect((schema?["properties"] as? [String: Any])?["reason"] != nil)
}

@Test func postersAreScaledToTheWidthAskedForAsJPEG() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
    let picture = try #require(context.makeImage())
    let (data, w, h) = try #require(CanvasPosters.jpeg(picture, width: 640))
    #expect(w == 640 && h == 400)
    #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    let (_, w2, h2) = try #require(CanvasPosters.jpeg(picture, width: 2000))
    #expect(w2 == 1280 && h2 == 800)
}

@MainActor @Test func posterRectsMustBeOnTheBoardsView() {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(CanvasPosters.rect(["x": 100, "y": 50, "w": 400, "h": 300], in: web) == CGRect(x: 100, y: 50, width: 400, height: 300))
    // Mostly off the view, tiny, or nonsense: no picture.
    #expect(CanvasPosters.rect(["x": 900, "y": 50, "w": 400, "h": 300], in: web) == nil)
    #expect(CanvasPosters.rect(["x": 0, "y": 0, "w": 4, "h": 300], in: web) == nil)
    #expect(CanvasPosters.rect(["x": "a", "y": 0, "w": 40, "h": 30], in: web) == nil)
    #expect(CanvasPosters.rect(nil, in: web) == nil)
    // A sliver over the edge is trimmed to the view.
    #expect(CanvasPosters.rect(["x": 10, "y": 10, "w": 1000, "h": 300], in: web) == CGRect(x: 10, y: 10, width: 990, height: 300))
}

@Test func pipelinedRequestsComeOffTheSocketInOrder() {
    let one = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
    let two = "POST /mcp HTTP/1.1\r\ncontent-length: 7\r\n\r\n{\"a\":1}"
    var buffer = Data((one + two + "POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n{\"b").utf8)
    let first = HTTPRequest.take(from: &buffer)
    let second = HTTPRequest.take(from: &buffer)
    #expect(first?.body == Data("{}".utf8))
    #expect(second?.body == Data("{\"a\":1}".utf8))
    // The third has only part of its body yet: it waits.
    #expect(HTTPRequest.take(from: &buffer) == nil)
    buffer.append(Data("\":22222}".utf8))
    #expect(HTTPRequest.take(from: &buffer)?.body == Data("{\"b\":22222}".utf8))
}

// canvas_screenshot waits for the page's pictures (`copperCanvas.settled`) and
// says what was still coming in when it gave up waiting.
@MainActor @Test func canvasScreenshotNamesWhatWasStillPending() {
    #expect(CanvasHost.pendingText(nil) == nil)
    #expect(CanvasHost.pendingText(["settled": true, "pending": ["images": 0, "frames": 0]]) == nil)
    #expect(CanvasHost.pendingText(["settled": false, "pending": ["images": 0, "frames": 0]]) == nil)
    #expect(CanvasHost.pendingText(["settled": false, "pending": ["images": 3, "frames": 1]]) == "3 images, 1 web frame")
    #expect(CanvasHost.pendingText(["settled": false, "pending": ["images": 1, "frames": 2]]) == "1 image, 2 web frames")
    #expect(CanvasHost.settleMs == 2500)
}
