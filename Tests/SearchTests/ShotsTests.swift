import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Search

// browser_take_screenshot's arithmetic and words (Fork/MCP/Shots.swift):
// the arguments it takes and refuses, the rectangle it pictures, the size
// cap, the answer's sentence and where a picture saved in a folder goes.
// Copper for Linux and Windows answer with the same words, so these strings
// are the contract. The drawing itself is checked end to end on grid.html.

private typealias Shots = Tools.Shots

private func refusal(_ args: [String: Any]) -> String? {
    do { _ = try Shots.parse(args); return nil } catch { return error.localizedDescription }
}

@Test func shotsTakeTheOldCallsAsBefore() throws {
    #expect(try Shots.parse([:]) == Shots.Ask())
    let full = try Shots.parse(["fullPage": true, "type": "jpeg"])
    #expect(full.subject == .view && full.fullPage && full.jpeg && full.scale == 1 && full.padding == 0)
    #expect(try Shots.parse(["ref": "f2:e7"]).subject == .ref("f2:e7"))
    #expect(try Shots.parse(["type": "png", "ref": ""]).subject == .view)
}

@Test func shotsReadTheNewArguments() throws {
    let element = try Shots.parse(["selector": "#box-b", "frame": "f2", "padding": 10, "scale": 1.5])
    #expect(element.subject == .selector("#box-b", frame: "f2"))
    #expect(element.padding == 10 && element.scale == 1.5)
    let region = try Shots.parse(["region": ["x": 100, "y": 100.5, "width": 200, "height": 100], "scale": 4])
    #expect(region.subject == .region(CGRect(x: 100, y: 100.5, width: 200, height: 100)))
    #expect(region.scale == 4)
}

@Test func shotsRefuseWithTheContractsWords() {
    #expect(refusal(["ref": "e1", "region": ["x": 0, "y": 0, "width": 1, "height": 1]]) == "give one of ref, selector or region")
    #expect(refusal(["ref": "e1", "selector": "#a"]) == "give one of ref, selector or region")
    #expect(refusal(["scale": 9]) == "scale must be from 1 to 4")
    #expect(refusal(["scale": 0.5]) == "scale must be from 1 to 4")
    #expect(refusal(["scale": true]) == "scale must be from 1 to 4")
    #expect(refusal(["padding": -1]) == "padding must be 0 or more")
    #expect(refusal(["padding": "4"]) == "padding must be 0 or more")
    #expect(refusal(["filename": "rel/x.png"]) == "filename must be an absolute path or start with ~/")
    #expect(refusal(["region": ["x": 0, "y": 0, "width": 0, "height": 10]]) == "region width and height must be more than 0")
    #expect(refusal(["region": ["x": 0, "y": 0, "width": 10]]) == "region needs x, y, width and height: numbers in CSS pixels")
    #expect(refusal(["region": "0,0,10,10"]) == "region needs x, y, width and height: numbers in CSS pixels")
    #expect(refusal(["scale": 1]) == nil && refusal(["scale": 4]) == nil && refusal(["padding": 0]) == nil)
}

@Test func shotsTakeAViewportAndAColorScheme() throws {
    // copper shot --size 390x844 --scheme dark (kept out of the listed schema).
    let ask = try Shots.parse(["viewport": ["width": 390, "height": 844], "colorScheme": "dark", "fullPage": true])
    #expect(ask.viewport == CGSize(width: 390, height: 844) && ask.dark == true && ask.fullPage)
    #expect(try Shots.parse(["colorScheme": "light"]).dark == false)
    #expect(try Shots.parse([:]).viewport == nil && Shots.parse([:]).dark == nil)
    #expect(refusal(["viewport": ["width": 50, "height": 844]]) == "viewport needs width and height: CSS pixels from 100 to 8000")
    #expect(refusal(["viewport": ["width": 390]]) == "viewport needs width and height: CSS pixels from 100 to 8000")
    #expect(refusal(["colorScheme": "sepia"]) == "colorScheme must be light or dark")
}

@Test func shotsTakeHomeAndAbsolutePaths() throws {
    let home = NSHomeDirectory()
    #expect(try Shots.absolute("~/Desktop/shot.png") == home + "/Desktop/shot.png")
    #expect(try Shots.absolute("~/Desktop/") == home + "/Desktop/")
    #expect(try Shots.absolute("/tmp/a.png") == "/tmp/a.png")
    #expect(try Shots.parse(["filename": "~/x.png"]).filename == home + "/x.png")
}

@Test func shotsPadThenClampTheirRectangle() {
    let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(Shots.area(CGRect(x: 100, y: 100, width: 200, height: 100), padding: 0, within: viewport) == CGRect(x: 100, y: 100, width: 200, height: 100))
    #expect(Shots.area(CGRect(x: 100, y: 100, width: 200, height: 100), padding: 10, within: viewport) == CGRect(x: 90, y: 90, width: 220, height: 120))
    // Padding past an edge is cut there; a rectangle half out keeps its inside.
    #expect(Shots.area(CGRect(x: 0, y: 5, width: 50, height: 50), padding: 10, within: viewport) == CGRect(x: 0, y: 0, width: 60, height: 65))
    #expect(Shots.area(CGRect(x: 950, y: 750, width: 100, height: 100), padding: 0, within: viewport) == CGRect(x: 950, y: 750, width: 50, height: 50))
    // Nothing left: the caller's "outside the viewport / page".
    #expect(Shots.area(CGRect(x: 5000, y: 5000, width: 10, height: 10), padding: 0, within: viewport) == nil)
    #expect(Shots.area(CGRect(x: 1000, y: 0, width: 10, height: 10), padding: 0, within: viewport) == nil)
}

@Test func shotsSnapToWholePoints() {
    #expect(Shots.snapped(CGRect(x: 400.5, y: 10.2, width: 240, height: 120.4)) == CGRect(x: 401, y: 10, width: 240, height: 121))
    #expect(Shots.snapped(CGRect(x: 3, y: 3, width: 0.2, height: 0.2)) == CGRect(x: 3, y: 3, width: 1, height: 1))
}

@Test func shotsGrowToWholePixelsBeforeTheyAreCut() {
    // Retina (2 pixels a point) at scale 1: half a snapshot point per view point, so even sides.
    #expect(Shots.whole(CGRect(x: 0, y: 0, width: 1641, height: 1282), k: 0.5) == CGRect(x: 0, y: 0, width: 1642, height: 1282))
    // Scale 2 on Retina, or any whole scale at 1×: already whole.
    #expect(Shots.whole(CGRect(x: 10, y: 20, width: 241, height: 121), k: 1) == CGRect(x: 10, y: 20, width: 241, height: 121))
    #expect(Shots.whole(CGRect(x: 0, y: 0, width: 101, height: 7), k: 3) == CGRect(x: 0, y: 0, width: 101, height: 7))
    // Scale 3 on Retina: 1.5 snapshot points a view point.
    #expect(Shots.whole(CGRect(x: 0, y: 0, width: 101, height: 80), k: 1.5) == CGRect(x: 0, y: 0, width: 102, height: 80))
    // Scale 1.5 on Retina (0.75): a multiple of 4.
    #expect(Shots.whole(CGRect(x: 0, y: 0, width: 101, height: 81), k: 0.75)?.size == CGSize(width: 104, height: 84))
    // Nothing whole within reach: the caller scales instead.
    #expect(Shots.whole(CGRect(x: 0, y: 0, width: 101, height: 81), k: 1.23) == nil)
}

@Test func shotsSizeIsTheCSSSizeTimesTheScale() {
    #expect(Shots.size(css: CGSize(width: 420, height: 220), scale: 2) == Shots.Size(width: 840, height: 440, scale: 2, cap: nil))
    #expect(Shots.size(css: CGSize(width: 600, height: 80), scale: 3) == Shots.Size(width: 1800, height: 240, scale: 3, cap: nil))
    #expect(Shots.size(css: CGSize(width: 101, height: 52.39), scale: 1.5) == Shots.Size(width: 152, height: 79, scale: 1.5, cap: nil))
    #expect(Shots.size(css: CGSize(width: 0.2, height: 0.2), scale: 1).width == 1)
}

@Test func shotsLowerTheScaleUnderTheCap() {
    // 1641×3200 at 4 is 12800 px tall but 84 megapixels: the pixel cap binds.
    let page = Shots.size(css: CGSize(width: 1641, height: 3200), scale: 4)
    #expect(page.cap == .pixels)
    #expect(page.scale == 3.49)
    #expect(page.width * page.height <= Shots.maxPixels && page.height <= Shots.maxSide)
    // A tall narrow strip passes the side first.
    let strip = Shots.size(css: CGSize(width: 300, height: 6912), scale: 4)
    #expect(strip.cap == .side)
    #expect(strip.scale == 2.37)
    #expect(strip.height <= Shots.maxSide)
    // The largest hundredth that fits.
    #expect(Shots.pixels(CGSize(width: 300, height: 6912), scale: 2.38).height > Shots.maxSide)
    // A full page past the side at scale 1 comes down too.
    #expect(Shots.size(css: CGSize(width: 1000, height: 20000), scale: 1).scale == 0.81)
}

@Test func shotsPrintTheirNumbersShort() {
    #expect(Shots.number(1) == "1")
    #expect(Shots.number(1.5) == "1.5")
    #expect(Shots.number(2.37) == "2.37")
    #expect(Shots.number(1.234) == "1.23")
    #expect(Shots.number(10) == "10")
    #expect(Shots.number(100.5) == "100.5")
    #expect(Shots.number(-0.001) == "0")
}

@Test func shotsAnswerWithOneSentenceFirst() throws {
    let page = "### Page\n- URL: about:blank"
    let view = Shots.Size(width: 2880, height: 1800, scale: 2, cap: nil)
    #expect(Shots.answer(try Shots.parse(["scale": 2]), size: view, saved: "/Users/x/Desktop/shot.png", page: page)
        == "Screenshot 2880×1800 PNG at scale 2 of the viewport. Saved to /Users/x/Desktop/shot.png. ### Page\n- URL: about:blank")
    let one = Shots.Size(width: 240, height: 120, scale: 1, cap: nil)
    #expect(Shots.answer(try Shots.parse(["fullPage": true]), size: one, page: page).hasPrefix("Screenshot 240×120 PNG at scale 1 of the whole page. ### Page"))
    #expect(Shots.answer(try Shots.parse(["ref": "f2:e7", "type": "jpeg"]), size: one, page: page).hasPrefix("Screenshot 240×120 JPEG at scale 1 of f2:e7. "))
    #expect(Shots.answer(try Shots.parse(["selector": "#box-b"]), size: one, page: page).hasPrefix("Screenshot 240×120 PNG at scale 1 of #box-b. "))
    let region = try Shots.parse(["region": ["x": 100, "y": 100, "width": 200, "height": 100], "padding": 10, "scale": 1.5])
    #expect(Shots.answer(region, size: Shots.Size(width: 330, height: 180, scale: 1.5, cap: nil), page: page)
        .hasPrefix("Screenshot 330×180 PNG at scale 1.5 of the region 100,100 200×100. ### Page"))
}

@Test func shotsAnswerTheirNotesInOrder() throws {
    let ask = try Shots.parse(["fullPage": true, "scale": 4])
    let lowered = Shots.Size(width: 711, height: 16384, scale: 2.37, cap: .side)
    #expect(Shots.answer(ask, size: lowered, failed: ("/x/y.png", "You don't have permission."), upscaled: 2, page: "P")
        == "Screenshot 711×16384 PNG at scale 2.37 of the whole page. Couldn't save to /x/y.png: You don't have permission. Scale lowered from 4 to 2.37 to stay under 16384 px. Upscaled: this page renders at most at scale 2 here. P")
    let pixels = Shots.Size(width: 4086, height: 7968, scale: 2.49, cap: .pixels)
    #expect(Shots.answer(ask, size: pixels, page: "P").contains("Scale lowered from 4 to 2.49 to stay under 64 megapixels. P"))
}

@Test func shotsSendTheModelASmallerImageThanTheFileKeeps() {
    // Saved above scale 1: the same area at scale 1 in the answer, the HD picture in the file.
    let hd = Shots.size(css: CGSize(width: 420, height: 220), scale: 2)
    #expect(Shots.inline(css: CGSize(width: 420, height: 220), picture: hd, saved: true) == Shots.Size(width: 420, height: 220, scale: 1, cap: nil))
    let odd = Shots.size(css: CGSize(width: 101, height: 52.39), scale: 1.5)
    #expect(Shots.inline(css: CGSize(width: 101, height: 52.39), picture: odd, saved: true) == Shots.Size(width: 101, height: 52, scale: 1, cap: nil))
    // Not saved, or the save failed, or already scale 1: the picture itself (the CLI writes it then).
    #expect(Shots.inline(css: CGSize(width: 420, height: 220), picture: hd, saved: false) == nil)
    let one = Shots.size(css: CGSize(width: 1641, height: 1282), scale: 1)
    #expect(Shots.inline(css: CGSize(width: 1641, height: 1282), picture: one, saved: true) == nil)
    // A picture whose scale-1 size is its own size is sent as it is.
    let barely = Shots.size(css: CGSize(width: 100, height: 100), scale: 1.004)
    #expect(Shots.inline(css: CGSize(width: 100, height: 100), picture: barely, saved: true) == nil)
}

@Test func shotsKeepTheAnswersImageUnder8000Pixels() {
    // The whole of a 20000 px page: 16200 px in the file (the 16384 cap), 8000 in the answer.
    let css = CGSize(width: 1641, height: 20000)
    let page = Shots.size(css: css, scale: 1)
    #expect(page == Shots.Size(width: 1329, height: 16200, scale: 0.81, cap: .side))
    #expect(Shots.inline(css: css, picture: page, saved: false) == Shots.Size(width: 656, height: 8000, scale: 0.4, cap: nil))
    #expect(Shots.inline(css: css, picture: page, saved: true) == Shots.Size(width: 656, height: 8000, scale: 0.4, cap: nil))
    // Saved at scale 4: down to scale 1 first, then under 8000.
    let strip = CGSize(width: 300, height: 12000)
    let tall = Shots.size(css: strip, scale: 4)
    #expect(tall.height <= Shots.maxSide)
    #expect(Shots.inline(css: strip, picture: tall, saved: true) == Shots.Size(width: 198, height: 7920, scale: 0.66, cap: nil))
    // A wide one is held by its width, the aspect kept.
    let wide = CGSize(width: 9000, height: 400)
    #expect(Shots.inline(css: wide, picture: Shots.size(css: wide, scale: 1), saved: false) == Shots.Size(width: 7920, height: 352, scale: 0.88, cap: nil))
    // Always the largest hundredth that fits, whatever the rounding.
    for height in stride(from: 8001.0, through: 16384, by: 37.3) {
        let css = CGSize(width: 1003, height: height)
        guard let got = Shots.inline(css: css, picture: Shots.size(css: css, scale: 1), saved: false) else {
            Issue.record("\(height): sent as it is"); continue
        }
        #expect(max(got.width, got.height) <= Shots.maxInline)
        let next = Shots.pixels(css, scale: (got.scale * 100 + 1).rounded() / 100)
        #expect(max(next.width, next.height) > Shots.maxInline, "\(height): \(got.scale) is not the largest")
    }
    // Up to 8000 it goes as it is.
    let fits = CGSize(width: 1641, height: 8000)
    #expect(Shots.inline(css: fits, picture: Shots.size(css: fits, scale: 1), saved: false) == nil)
}

@Test func shotsSayWhenTheImageHereIsNotThePicture() throws {
    let region = try Shots.parse(["region": ["x": 100, "y": 100, "width": 420, "height": 220], "scale": 2, "filename": "/tmp/c3.png"])
    let hd = Shots.Size(width: 840, height: 440, scale: 2, cap: nil)
    let small = Shots.Size(width: 420, height: 220, scale: 1, cap: nil)
    #expect(Shots.answer(region, size: hd, saved: "/tmp/c3.png", inline: small, page: "P")
        == "Screenshot 840×440 PNG at scale 2 of the region 100,100 420×220. Saved to /tmp/c3.png. The image here is 420×220 at scale 1; the file has the full picture. P")
    // Nothing saved: said before the notes, with what to do for the full picture.
    let page = try Shots.parse(["fullPage": true])
    let lowered = Shots.Size(width: 1329, height: 16200, scale: 0.81, cap: .side)
    let capped = Shots.Size(width: 656, height: 8000, scale: 0.4, cap: nil)
    #expect(Shots.answer(page, size: lowered, inline: capped, page: "P")
        == "Screenshot 1329×16200 PNG at scale 0.81 of the whole page. The image here is 656×8000 at scale 0.4; pass filename to keep the full picture. Scale lowered from 1 to 0.81 to stay under 16384 px. P")
    #expect(Shots.answer(page, size: lowered, failed: ("/x/y.png", "no room"), inline: capped, page: "P")
        .hasPrefix("Screenshot 1329×16200 PNG at scale 0.81 of the whole page. Couldn't save to /x/y.png: no room. The image here is 656×8000 at scale 0.4; pass filename to keep the full picture. Scale lowered"))
    // The same image as the picture: no sentence.
    #expect(!Shots.answer(region, size: hd, saved: "/tmp/c3.png", page: "P").contains("The image here"))
}

/// RGBA bytes of a PNG/JPEG, as 8-bit sRGB.
private func decoded(_ data: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, bytes)
}

@Test func shotsDrawTheirPictureDownSmoothly() throws {
    // A scale-4 picture of one-pixel lines four pixels apart drawn down to
    // scale 1: each pixel the average of the four it covers (3 white, 1 black),
    // not some of them picked (white, or black, in stripes). Same format as asked.
    let lines = try Tools.Page.bitmap(width: 840, height: 440, opaque: false) { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 840, height: 440))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: 840, by: 4) { context.fill(CGRect(x: x, y: 0, width: 1, height: 440)) }
    }
    for jpeg in [false, true] {
        let picture = try Tools.Page.Picture(lines, size: Shots.Size(width: 840, height: 440, scale: 4, cap: nil), css: CGSize(width: 210, height: 110), jpeg: jpeg)
        let data = try Tools.Page.drawnDown(picture, to: Shots.Size(width: 210, height: 110, scale: 1, cap: nil), jpeg: jpeg)
        #expect(data.starts(with: jpeg ? [0xFF, 0xD8] : [0x89, 0x50, 0x4E, 0x47]))
        let got = try decoded(data)
        #expect(got.width == 210 && got.height == 110)
        let row = (2..<208).map { Int(got.bytes[(55 * 210 + $0) * 4]) }
        #expect(row.allSatisfy { abs($0 - 191) <= (jpeg ? 12 : 6) }, "\(row.min()!)–\(row.max()!), want 191")
    }
}

@Test func shotsNameAPictureInAFolder() {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 11:06:40 UTC
    #expect(Shots.name(jpeg: false, at: date, in: utc) == "copper-20261118-110640.png")
    #expect(Shots.name(jpeg: true, at: date, in: utc) == "copper-20261118-110640.jpg")
    #expect(Shots.destination("/tmp/shots", folder: true, jpeg: false, at: date, in: utc) == "/tmp/shots/copper-20261118-110640.png")
    #expect(Shots.destination("/tmp/new/", folder: false, jpeg: true, at: date, in: utc) == "/tmp/new/copper-20261118-110640.jpg")
    #expect(Shots.destination("/tmp/a.png", folder: false, jpeg: true, at: date, in: utc) == "/tmp/a.png")
    // A second picture in the same second gets -2.
    let taken: Set<String> = ["/tmp/shots/copper-20261118-110640.png"]
    #expect(Shots.destination("/tmp/shots", folder: true, jpeg: false, at: date, in: utc, taken: { taken.contains($0) }) == "/tmp/shots/copper-20261118-110640-2.png")
}

@Test func shotsSaveIntoFoldersTheyMake() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    // A missing parent is made.
    let file = root.appendingPathComponent("deep/er/a.png").path
    #expect(try Shots.save(bytes, to: file, jpeg: false) == file)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == bytes)
    // An existing folder gets a new name in it; a trailing / makes the folder.
    let named = try Shots.save(bytes, to: root.path, jpeg: true)
    #expect(named.hasPrefix(root.path + "/copper-") && named.hasSuffix(".jpg"))
    let made = try Shots.save(bytes, to: root.path + "/fresh/", jpeg: false)
    #expect(made.hasPrefix(root.path + "/fresh/copper-") && made.hasSuffix(".png"))
    #expect(FileManager.default.fileExists(atPath: made))
}

@Test func shotsEncodeAtExactlyTheirSize() throws {
    // WebKit's picture a pixel off (it sizes in whole points) comes out at the size asked.
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 841, height: 439, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 841, height: 439))
    let image = try #require(context.makeImage())
    for jpeg in [false, true] {
        let data = try Tools.Page.encode(image, width: 840, height: 440, jpeg: jpeg)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let back = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(back.width == 840 && back.height == 440)
    }
}

@MainActor @Test func shotsSayWhatIsPicturedInTheTimeline() {
    #expect(Drive.words(for: "browser_take_screenshot", [:]).0 == "Taking a screenshot")
    #expect(Drive.words(for: "browser_take_screenshot", ["fullPage": true]).0 == "Taking a full-page screenshot")
    #expect(Drive.words(for: "browser_take_screenshot", ["selector": "#box-b"]).0 == "Taking a screenshot of '#box-b'")
    #expect(Drive.words(for: "browser_take_screenshot", ["region": ["x": 1]]).0 == "Taking a screenshot of a region")
}

@Test func theCLIKeepsTheFileTheAppSaved() {
    // `copper shot` doesn't write a second copy of what the app saved; for a folder it prints the name the app made.
    let page = " ### Page\n- URL: about:blank"
    #expect(CLI.savedShot(["Screenshot 1×1 PNG at scale 1 of the viewport. Saved to /tmp/a b.png." + page], asked: "/tmp/a b.png") == "/tmp/a b.png")
    let made = "Screenshot 1×1 JPEG at scale 1 of the viewport. Saved to /tmp/shots/copper-20261118-110640-2.jpg." + page
    #expect(CLI.savedShot([made], asked: "/tmp/shots") == "/tmp/shots/copper-20261118-110640-2.jpg")
    #expect(CLI.savedShot([made], asked: "/tmp/shots/") == "/tmp/shots/copper-20261118-110640-2.jpg")
    #expect(CLI.savedShot(["Screenshot 1×1 PNG at scale 1 of the viewport. Couldn't save to /tmp/a.png: no room." + page], asked: "/tmp/a.png") == nil)
    #expect(CLI.savedShot([made], asked: "/tmp/other") == nil)
}
