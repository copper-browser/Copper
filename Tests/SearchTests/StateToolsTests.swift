import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Search

// The pure parts of the agent's browser-state tools (Fork/MCP/StateTools.swift,
// FileChooser.swift, NetLog.swift): which paths an upload takes, which
// cookies are a tab's site's, where a PDF goes and how it is paged, how
// requests are listed, and how a space is named.

@Test func uploadTakesOnlyAbsolutePathsThatExist() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hc-upload-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)

    #expect(try FileChooser.checked([file.path], directories: false).map(\.path) == [file.path])
    #expect(throws: Tools.Failure.self) { try FileChooser.checked(["a.txt"], directories: false) }
    #expect(throws: Tools.Failure.self) { try FileChooser.checked([folder.appendingPathComponent("nope").path], directories: false) }
    #expect(throws: Tools.Failure.self) { try FileChooser.checked([folder.path], directories: false) }
    #expect(try FileChooser.checked([folder.path], directories: true).count == 1)
}

@Test func cookiesBelongToTheHostAndItsParents() {
    #expect(CookieRules.matches(".example.com", host: "shop.example.com"))
    #expect(CookieRules.matches("example.com", host: "example.com"))
    #expect(!CookieRules.matches("example.com", host: "notexample.com"))
    #expect(!CookieRules.matches("shop.example.com", host: "example.com"))

    #expect(CookieRules.mayScope("example.com", host: "shop.example.com"))
    #expect(CookieRules.mayScope("127.0.0.1", host: "127.0.0.1"))
    #expect(CookieRules.mayScope("localhost", host: "localhost"))
    #expect(!CookieRules.mayScope("com", host: "example.com"))
    #expect(!CookieRules.mayScope("other.com", host: "example.com"))
    #expect(!CookieRules.mayScope("0.0.1", host: "127.0.0.1"))
}

@Test func aPdfGoesWhereItIsToldOrIntoDownloadsWithoutOverwriting() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hc-pdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let named = try StateTools.destination(nil, title: "Report: Q3/Q4", in: folder)
    #expect(named.lastPathComponent == "Report- Q3-Q4.pdf")
    try Data().write(to: named)
    #expect(try StateTools.destination(nil, title: "Report: Q3/Q4", in: folder).lastPathComponent == "Report- Q3-Q4 2.pdf")
    #expect(try StateTools.destination("out", title: "x", in: folder).lastPathComponent == "out.pdf")
    #expect(try StateTools.destination(folder.appendingPathComponent("abs.pdf").path, title: "x", in: folder).path == folder.appendingPathComponent("abs.pdf").path)
    #expect(throws: Tools.Failure.self) { try StateTools.destination("/no/such/folder/x.pdf", title: "x", in: folder) }
}

@Test func aTallPdfIsCutIntoLetterPages() throws {
    // One 612 × 2400 pt sheet, as WebKit draws a long page.
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 2400)
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 10, y: 10, width: 100, height: 2300))
    context.endPDFPage()
    context.closePDF()

    let paged = StateTools.paged(data as Data)
    #expect(paged.pages == 4) // 792 pt pages: 2400 / 792 → 4
    #expect(PDFDocument(data: paged.data)?.pageCount == 4)
    #expect(paged.data.prefix(5) == Data("%PDF-".utf8))
}

@Test func networkLinesLeaveOutStaticAssetsThatLoaded() {
    let entries = [
        NetLog.Entry(id: 1, method: "GET", url: "https://a.test/", kind: "document", status: 200),
        NetLog.Entry(id: 2, method: "GET", url: "https://a.test/logo.png", kind: "image", status: 200),
        NetLog.Entry(id: 3, method: "GET", url: "https://a.test/missing.css", kind: "stylesheet", status: 404),
        NetLog.Entry(id: 4, method: "POST", url: "https://a.test/api", kind: "fetch", status: nil),
        NetLog.Entry(id: 5, method: "GET", url: "https://b.test/x", kind: "xhr", status: nil, error: "offline"),
    ]
    let lines = NetLog.lines(entries, includeStatic: false, limit: 100)
    #expect(lines == [
        "[GET] https://a.test/ => [200] (document)",
        "[GET] https://a.test/missing.css => [404] (stylesheet)",
        "[POST] https://a.test/api => pending (fetch)",
        "[GET] https://b.test/x => failed: offline (xhr)",
    ])
    #expect(NetLog.lines(entries, includeStatic: true, limit: 100).count == 5)
    #expect(NetLog.lines(entries, includeStatic: true, limit: 2).count == 2)
    #expect(NetLog.kind(3) == "document" && NetLog.kind(5) == "fetch" && NetLog.kind(12) == "xhr" && NetLog.kind(-1) == "other")
}

@Test func aSpaceIsNamedByIndexNameOrId() {
    let a = Space(name: "Work"), b = Space(name: "Home"), c = Space(name: "work")
    #expect(StateTools.pick("1", in: [a, b])?.id == b.id)
    #expect(StateTools.pick("home", in: [a, b])?.id == b.id)
    #expect(StateTools.pick("work", in: [a, b, c]) == nil) // two by that name
    #expect(StateTools.pick(String(a.id.uuidString.prefix(8)), in: [a, b, c])?.id == a.id)
}
