import WebKit

// Copper's own side of every page, and the frames of a page for agents.
//
// A world of its own. What Copper puts into a page to work it — the forms
// script (Forms.swift), the agent's helper (`__copper`, Page.swift), Jev's
// (`__jevFast`, Ultrafast.swift), the trail — runs in a WKContentWorld the
// page's scripts can't see into: a page that defines `window.__copper`
// itself, or posts to the forms handler, is talking to nobody. The DOM is
// shared; the JavaScript isn't. Only `browser_evaluate` runs in the page's
// world, because the page's own values are what it is for; the passkey
// authenticator and the console recorder live there too, as they replace
// things the page calls.
//
// Frames. The forms script runs in every frame and names its document
// (`doc`) on each message, so Copper knows the frames a page has and can run
// the helper in any of them (WKFrameInfo). A snapshot shows each frame's
// content under its <iframe>, refs prefixed with the frame's number
// (`f2:e7`); every tool that takes a ref acts in that frame.

extension WKContentWorld {
    static let copper = WKContentWorld.world(name: "CopperAgent")
}

extension Tools {
@MainActor
enum Frames {
    struct Entry {
        var info: WKFrameInfo
        /// As refs name it: f1, f2 … in the order heard, never reused in a tab.
        let number: Int
        /// Its forms script has seen a sign-in or a code box in it.
        var signIn = false
    }

    private final class Book {
        var known: [String: Entry] = [:]
        var next = 1
    }

    private static let books = NSMapTable<WKWebView, Book>.weakToStrongObjects()

    private static func book(_ web: WKWebView) -> Book {
        if let book = books.object(forKey: web) { return book }
        let book = Book()
        books.setObject(book, forKey: web)
        return book
    }

    /// FormRelay: a document's forms script said something. An embedded
    /// frame's is remembered under its document's name.
    static func heard(_ message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, let web = message.webView, let body = message.body as? [String: Any],
              let doc = body["doc"] as? String, !doc.isEmpty
        else { return }
        let book = book(web)
        if book.known[doc] == nil {
            // A page that makes frames without end keeps the newest.
            if book.known.count >= 200, let oldest = book.known.min(by: { $0.value.number < $1.value.number }) { book.known[oldest.key] = nil }
            book.known[doc] = Entry(info: message.frameInfo, number: book.next)
            book.next += 1
        }
        book.known[doc]?.info = message.frameInfo
        if let kind = body["kind"] as? String, kind == "form" || kind == "otp" { book.known[doc]?.signIn = true }
    }

    /// Browser.didCommit: a new document in the main frame has none of the old one's frames.
    static func reset(_ web: WKWebView) { books.object(forKey: web)?.known = [:] }

    /// The frames heard from, newest first, and no more than a page plausibly shows.
    static func all(_ web: WKWebView) -> [(doc: String, entry: Entry)] {
        book(web).known.sorted { $0.value.number > $1.value.number }.prefix(40).map { ($0.key, $0.value) }
    }

    /// The frames still on the page: each asked whether the document in it
    /// is the one heard from (a frame that navigated answers as another).
    /// `wanted` narrows which are worth the asking.
    static func live(_ web: WKWebView, where wanted: (Entry) -> Bool = { _ in true }) async -> [Entry] {
        let book = book(web)
        var out: [Entry] = []
        for (doc, entry) in all(web) where wanted(entry) {
            let said = try? await Page.raw(web, "window.__officeForms ? window.__officeForms.doc : ''", counted: false, in: entry.info) as? String
            if said == doc { out.append(entry) } else { book.known[doc] = nil }
        }
        return out.sorted { $0.number < $1.number }
    }

    /// `f3:e7` → (3, "e7"); a ref with no frame → nil.
    nonisolated static func split(_ ref: String) -> (frame: Int, ref: String)? {
        guard ref.hasPrefix("f"), let colon = ref.firstIndex(of: ":"), let number = Int(ref[ref.index(after: ref.startIndex)..<colon]) else { return nil }
        return (number, String(ref[ref.index(after: colon)...]))
    }

    /// The frame an agent named: `f3`, or the `f3:` of a ref.
    static func frame(_ number: Int, in web: WKWebView) throws -> Entry {
        guard let entry = book(web).known.values.first(where: { $0.number == number }) else {
            throw Tools.Failure(text: "frame f\(number) is not on the page any more. Take a fresh browser_snapshot — frames and refs change when the page does.")
        }
        return entry
    }

    /// `f2` → 2.
    nonisolated static func number(_ raw: String) throws -> Int {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard name.hasPrefix("f"), let number = Int(name.dropFirst()) else {
            throw Tools.Failure(text: "frame must be a frame from browser_snapshot, like f2 (the [frame=f2] on an iframe line)")
        }
        return number
    }

    static func frame(named raw: String, in web: WKWebView) throws -> Entry { try frame(number(raw), in: web) }

    // MARK: - a snapshot with its frames in it

    /// One frame's part of a snapshot: its text, and where its own frames go.
    struct Part {
        let number: Int
        let text: String
        let marks: [[String: Any]]
    }

    /// Every frame's part, by its place on the page (`where()`: its index
    /// among its parent's frames, at each level from the top). A frame that
    /// no longer answers as the document it was heard from is forgotten.
    static func parts(_ web: WKWebView, interactive: Bool, limit: Int) async -> [[Int]: Part] {
        let book = book(web)
        var out: [[Int]: Part] = [:]
        await withTaskGroup(of: (String, Int, [String: Any]?).self) { group in
            for (doc, entry) in all(web) {
                // On the main actor, said out loud: WebKit's calls assert it (see Probe.call).
                group.addTask { @MainActor in
                    let script = "({ doc: window.__copper.doc(), at: window.__copper.where(), shot: window.__copper.snapshot('', \(interactive), \(limit), 'f\(entry.number):') })"
                    return (doc, entry.number, try? await Page.js(web, script, in: entry.info) as? [String: Any])
                }
            }
            for await (doc, number, said) in group {
                guard let said, said["doc"] as? String == doc,
                      let at = (said["at"] as? [NSNumber])?.map(\.intValue), !at.isEmpty,
                      let shot = said["shot"] as? [String: Any], let text = shot["text"] as? String
                else { book.known[doc] = nil; continue }
                out[at] = Part(number: number, text: text, marks: shot["frames"] as? [[String: Any]] ?? [])
            }
        }
        return out
    }

    /// `text` with each frame's part put under its iframe line, indented,
    /// the line marked `[frame=fN]`. `marks`: which lines are iframes and
    /// which of the document's frames each is; `path`: where `text`'s own
    /// document is.
    nonisolated static func stitch(_ text: String, _ marks: [[String: Any]], at path: [Int] = [], _ parts: [[Int]: Part]) -> String {
        var lines = text.components(separatedBy: "\n")
        func line(_ mark: [String: Any]) -> Int { (mark["line"] as? NSNumber)?.intValue ?? -1 }
        // Bottom up, so a line's index still holds after what goes in below it.
        for mark in marks.sorted(by: { line($0) > line($1) }) {
            guard let at = (mark["at"] as? NSNumber)?.intValue, lines.indices.contains(line(mark)), let part = parts[path + [at]] else { continue }
            let row = line(mark)
            let indent = String(lines[row].prefix { $0 == " " }) + "  "
            lines[row] += " [frame=f\(part.number)]"
            let inner = stitch(part.text, part.marks, at: path + [at], parts)
            lines.insert(contentsOf: inner.components(separatedBy: "\n").filter { !$0.isEmpty }.map { indent + $0 }, at: row + 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - where a frame is on the page

    /// How far a frame's own viewport is from the page's, in CSS pixels —
    /// what turns a box inside the frame into a place to click. `path` is
    /// the frame's place now (`rect()` says it); `point` is the spot in the
    /// frame about to be used: each frame on the way up brings it into view
    /// and, with `hit`, checks nothing covers it there.
    static func offset(_ path: [Int], in web: WKWebView, point: CGPoint, hit: Bool) async throws -> CGPoint {
        var path = path, point = point, total = CGPoint.zero
        while let at = path.popLast() {
            var parent: WKFrameInfo?
            if !path.isEmpty {
                // The frame around it: the one that says it is at the rest of the path.
                for entry in await live(web) where parent == nil {
                    if let its = try? await Page.js(web, "window.__copper.where()", in: entry.info) as? [NSNumber], its.map(\.intValue) == path { parent = entry.info }
                }
                guard parent != nil else { throw Tools.Failure(text: "the frame around this one is not on the page any more. Take a fresh browser_snapshot.") }
            }
            let said = try await Page.js(web, "window.__copper.frameBox(\(at), \(point.x), \(point.y), \(hit))", in: parent) as? [String: Any]
            guard let x = (said?["x"] as? NSNumber)?.doubleValue, let y = (said?["y"] as? NSNumber)?.doubleValue else {
                let why = said?["error"] as? String ?? "its frame was not found"
                let next = said?["cover"] != nil
                    ? "Close or dismiss what covers it first (find its button with browser_snapshot), then try again."
                    : "Take a fresh browser_snapshot — frames and refs change when the page does."
                throw Tools.Failure(text: "\(why). \(next)")
            }
            total.x += x; total.y += y
            point.x += x; point.y += y
        }
        return total
    }
}
}
