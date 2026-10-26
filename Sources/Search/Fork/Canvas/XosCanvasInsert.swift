import AppKit
import Foundation
import ImageIO

// A click in Xos carries an expiring snapshot, never operations or a Copper credential.
// The destination belongs to the account using this Copper; the source cannot grant membership.
struct XosInsertLink {
    let source: URL
    let mode: String

    static func parse(_ url: URL) -> XosInsertLink? {
        guard url.scheme == "copper", url.host == "canvas", url.path == "/insert",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = parts.queryItems?.first(where: { $0.name == "source" })?.value,
              let source = URL(string: text), validSource(source) else { return nil }
        let mode = parts.queryItems?.first(where: { $0.name == "mode" })?.value ?? "choose"
        guard ["meeting", "personal", "room", "choose"].contains(mode) else { return nil }
        return XosInsertLink(source: source, mode: mode)
    }

    static func validSource(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "xos.apps.exowatt.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && url.path.range(of: #"^/api/whiteboard-exports/[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }
}

struct XosInsertSnapshot: Decodable {
    let version: Int
    let id: UUID
    let title: String
    let room: String
    let meetingID: String
    let meetingTitle: String
    let copperCanvasID: String
    let png: String
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case version, id, title, room, png, width, height
        case meetingID = "meeting_id", meetingTitle = "meeting_title", copperCanvasID = "copper_canvas_id"
    }

    // Image shapes accept geometry and image data only; titles belong to the picker.
    func shape(id: String) -> [String: Any] {
        ["id": id, "type": "image", "src": png, "w": 1000,
         "h": Double(height) / Double(width) * 1000,
         "naturalW": width, "naturalH": height]
    }

    func image() throws -> Data {
        guard version == 1, title.count <= 200, meetingID.count <= 200, meetingTitle.count <= 200,
              room.count <= 40, width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 16_777_216, png.hasPrefix("data:image/png;base64,"),
              let data = Data(base64Encoded: String(png.dropFirst(22))), data.count <= 8_000_000,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height
        else { throw XosCanvasInsert.Failure("This drawing is not a valid, bounded PNG snapshot.") }
        return data
    }
}

private final class XosNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
enum XosCanvasInsert {
    struct Failure: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
    private static var active = Set<URL>()

    /// Before CanvasLinks reads `insert` as a canvas id. Bad requests never fall through to a board.
    static func handle(_ url: URL, in browser: Browser) -> Bool {
        guard url.scheme == "copper", url.host == "canvas", url.path == "/insert" else { return false }
        guard let link = XosInsertLink.parse(url) else { browser.announce("This Xos drawing link is not valid."); return true }
        guard active.insert(link.source).inserted else { return true }
        Task {
            defer { active.remove(link.source) }
            do { try await receive(link, in: browser) }
            catch { browser.announce("Could not insert the drawing: \(error.localizedDescription)") }
        }
        return true
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: XosNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("The snapshot expired or is unavailable. Return to Xos and insert again.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 12_000_000 else { throw Failure("The drawing snapshot is too large.") }
            data.append(byte)
        }
        return data
    }

    private static var contextFile: URL { Store.file("canvas/xos-contexts.json") }
    private static func contexts() -> [String: String] {
        guard let data = try? Data(contentsOf: contextFile), let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }
    private static func contextKey(_ snapshot: XosInsertSnapshot) -> String {
        "\(Canvases.account ?? "local")|\(snapshot.room)|\(snapshot.meetingID)"
    }

    private static func choose(_ snapshot: XosInsertSnapshot, mode: String, in browser: Browser) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Insert drawing into Copper"
        alert.informativeText = "\(snapshot.title)\nChoose where to keep this snapshot. It becomes a movable image on that canvas."
        alert.addButton(withTitle: "Insert drawing")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 30), pullsDown: false)
        var ids: [String] = []
        if !snapshot.meetingID.isEmpty { picker.addItem(withTitle: "Meeting: \(snapshot.meetingTitle) (new canvas)"); ids.append("new-meeting") }
        picker.addItem(withTitle: "New canvas: \(snapshot.title)"); ids.append("new")
        let entries = Canvases.shared.visible.filter { !$0.isShared || ["owner", "editor"].contains($0.role ?? "") }
            .sorted { $0.isPersonal && !$1.isPersonal || ($0.isPersonal == $1.isPersonal && $0.updatedAt > $1.updatedAt) }
        for entry in entries { picker.addItem(withTitle: entry.isPersonal ? "Personal · only you" : entry.name); ids.append(entry.id) }
        let mapped = contexts()[contextKey(snapshot)]
        let preferred = mode == "personal" ? Canvases.personalID : mode == "room" ? snapshot.copperCanvasID : mode == "meeting" ? mapped : nil
        if let preferred, let index = ids.firstIndex(of: preferred) { picker.selectItem(at: index) }
        else if mode == "personal", let index = ids.firstIndex(of: Canvases.personalID) { picker.selectItem(at: index) }
        alert.accessoryView = picker
        let response: NSApplication.ModalResponse
        if let window = Windows.window(of: browser) {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn, ids.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return ids[picker.indexOfSelectedItem]
    }

    private static func receive(_ link: XosInsertLink, in browser: Browser) async throws {
        let snapshot = try JSONDecoder().decode(XosInsertSnapshot.self, from: await fetch(link.source))
        _ = try snapshot.image()
        await Canvases.shared.refresh()
        guard let selected = await choose(snapshot, mode: link.mode, in: browser) else { return }
        let entry: Canvases.Entry
        if selected == "new" || selected == "new-meeting" {
            entry = try await Canvases.shared.create(named: selected == "new-meeting" ? snapshot.meetingTitle + " · Whiteboard" : snapshot.title)
        } else {
            guard let found = Canvases.shared.entry(selected), !found.isShared || ["owner", "editor"].contains(found.role ?? "") else {
                throw Failure("That canvas is no longer writable. Choose another canvas.")
            }
            entry = found
        }
        let host = try await CanvasTools.open(entry, in: browser, foreground: true)
        let shapeID = "xos-" + snapshot.id.uuidString.lowercased()
        let previous = try await host.read(["ids": [shapeID]])
        if (previous["shapes"] as? [Any] ?? []).isEmpty {
            let result = try await host.apply([["op": "add", "shape": snapshot.shape(id: shapeID)]], as: CanvasAgent.caller("Xos whiteboard"))
            guard (result["applied"] as? NSNumber)?.intValue == 1, (result["errors"] as? [Any] ?? []).isEmpty else {
                throw Failure("Copper did not accept the image. No success was reported to Xos.")
            }
        }
        await host.checkpoint()
        try await host.zoom(to: [shapeID])
        if selected == "new-meeting" {
            var values = contexts(); values[contextKey(snapshot)] = entry.id
            try? FileManager.default.createDirectory(at: contextFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(values).write(to: contextFile, options: .atomic)
        }
        var request = URLRequest(url: link.source.appendingPathComponent("receipt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["canvas_id": entry.id, "canvas_name": entry.name, "shape_id": shapeID])
        let session = URLSession(configuration: .ephemeral, delegate: XosNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, receipt) = try await session.data(for: request)
        browser.announce("Inserted drawing on \(entry.name)\((receipt as? HTTPURLResponse)?.statusCode == 200 ? "" : " — Xos could not confirm the receipt")")
    }
}
