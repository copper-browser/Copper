import Foundation

// The parts of tab sharing that are arithmetic and bookkeeping, kept apart
// from WebKit and AppKit so `swift test --filter TabShare` can hold them to
// their word (Tests/SearchTests/TabShareRulesTests.swift).
enum TabShareRules {
    /// Chrome's ceiling for a tab capture's frame rate, and ours.
    static let maxFPS = 30.0
    /// Bigger than this and every frame costs more than a call can use.
    static let maxWidth = 1920
    static let maxHeight = 1200

    // MARK: - what the page asked for

    /// One constraint as a page writes it — `1280`, `{ max: 1280 }`,
    /// `{ ideal: 1280 }`, `{ exact: 1280 }` — read as a ceiling. A page
    /// that names only `min` gets no ceiling from it.
    static func ceiling(_ value: Any?) -> Double? {
        if let number = number(value) { return number }
        guard let range = value as? [String: Any] else { return nil }
        for key in ["exact", "max", "ideal"] {
            if let number = number(range[key]) { return number }
        }
        return nil
    }

    /// A number as WebKit hands one over (an NSNumber) — never a boolean,
    /// which bridges to 1 or 0 if it is let through.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    struct Want: Equatable {
        var width: Int?
        var height: Int?
        var fps: Double?
    }

    /// `video` as the page script hands it over: `true`, or a dictionary of
    /// plain constraint values (TabShareScript `plain`).
    static func want(from video: Any?) -> Want {
        guard let video = video as? [String: Any] else { return Want() }
        func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        return Want(width: positive(ceiling(video["width"])).map { Int($0.rounded()) },
                    height: positive(ceiling(video["height"])).map { Int($0.rounded()) },
                    fps: positive(ceiling(video["frameRate"])))
    }

    /// The surface the page would like offered first — Chrome's
    /// `displaySurface` hint (`"browser"`, `"window"`, `"monitor"`), plain or
    /// as `{ ideal: … }` — as the picker row to highlight among `rows` (the
    /// tabs, then a window, then the screen). A hint for a tab with no tab to
    /// offer, or no hint, is the first row.
    static func highlight(for video: Any?, rows: Int, tabs: Int) -> Int {
        let hint = video as? [String: Any]
        let surface = (hint?["displaySurface"] as? String)
            ?? ((hint?["displaySurface"] as? [String: Any]).flatMap { $0["exact"] as? String ?? $0["ideal"] as? String })
        switch surface {
        case "monitor": return max(0, rows - 1)
        case "window": return max(0, rows - 2)
        default: return tabs > 0 ? 0 : max(0, rows - 2)
        }
    }

    /// The frame rate a share runs at: what the page asked for, never more
    /// than 30 nor less than one a second.
    static func fps(_ want: Want) -> Double {
        min(maxFPS, max(1, want.fps ?? maxFPS))
    }

    /// The picture's size in pixels for a page laid out `points` wide and
    /// tall: Retina detail (two pixels a point) up to 1920×1200, shrunk —
    /// never stretched — to fit what the page asked for, keeping the page's
    /// shape, in even numbers (video encoders want them).
    static func pixels(for points: CGSize, want: Want = Want()) -> (width: Int, height: Int) {
        guard points.width >= 1, points.height >= 1 else { return (2, 2) }
        var width = points.width * 2
        var height = points.height * 2
        var limit = min(Double(maxWidth) / width, Double(maxHeight) / height, 1)
        if let w = want.width, w > 0 { limit = min(limit, Double(w) / width) }
        if let h = want.height, h > 0 { limit = min(limit, Double(h) / height) }
        width *= limit
        height *= limit
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded(.down)) * 2) }
        return (even(width), even(height))
    }

    /// The part of the page to picture so WebKit's picture comes out exactly
    /// `pixels`: WebKit sizes it from the rect's shape and drops fractions,
    /// so the rect is a hair taller than the picture's shape — trimmed by
    /// under two points on one edge, never stretched.
    static func snapshotRect(bounds: CGSize, pixels: (width: Int, height: Int)) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let width = Double(pixels.width), height = Double(pixels.height) + 0.5
        let scale = max(width / Double(bounds.width), height / Double(bounds.height))
        return CGRect(x: 0, y: 0, width: min(Double(bounds.width), width / scale), height: min(Double(bounds.height), height / scale))
    }

    // MARK: - which frame, which document

    /// The frame a message or WebKit's request came from, and the document
    /// in it: WKFrameInfo's private `_handle.frameID` and
    /// `_documentIdentifier` (TabShare.frame(of:), read only where this
    /// WebKit has them — the document's since macOS 15.4). What a page is
    /// handed — an ask's answer, a share's pictures — belongs to the one
    /// document in the one frame that asked: not its parent, not a sibling
    /// of the same origin, not the next page loaded in the same frame.
    struct FrameKey: Equatable {
        var frame: UInt64?
        var document: String?

        /// The same frame and document as far as both sides can tell: a part
        /// one side doesn't know (an older WebKit) is no evidence either way,
        /// and the origin and the web view still have to agree.
        func same(_ other: FrameKey) -> Bool {
            if let mine = frame, let theirs = other.frame, mine != theirs { return false }
            if let mine = document, let theirs = other.document, mine != theirs { return false }
            return true
        }

        /// The same frame now holding another document: the one this was
        /// bound to has gone (navigated, reloaded), and so has its share.
        func replaced(by other: FrameKey) -> Bool {
            guard let mine = frame, mine == other.frame, let was = document, let now = other.document else { return false }
            return was != now
        }
    }

    // MARK: - matching WebKit's request to the page's ask

    /// The page's note that a getDisplayMedia call is on its way, as far as
    /// matching it goes.
    struct AskKey: Equatable {
        let id: String
        let view: ObjectIdentifier
        let origin: String
        var frame = FrameKey()
        let at: Date
    }

    /// WebKit's request names the web view, the frame and its origin; the ask
    /// it belongs to is the oldest unmatched one from that very frame and
    /// document, in that origin. Failing that, one from another frame of the
    /// same site in the same page — a page calling the getDisplayMedia of an
    /// about:blank frame it made, whose wrapper asks from there; frames of one
    /// origin can reach into each other anyway, and the share is bound to the
    /// frame that asked. Never another origin's: a cross-origin frame inside
    /// the call page can post an ask straight to the handler, and must never
    /// be handed the tab you pick for the page. Never across opaque origins
    /// (sandboxed frames, data: URLs), which all spell alike and are each
    /// their own. Never the last document's in the same frame. No ask, no
    /// tab: the picker offers a window or the screen.
    static func match(_ asks: [AskKey], view: ObjectIdentifier, origin: String, frame: FrameKey = FrameKey()) -> AskKey? {
        let mine = asks.filter { $0.view == view && $0.origin == origin }.sorted { $0.at < $1.at }
        if let exact = mine.first(where: { $0.frame.same(frame) }) { return exact }
        guard !opaque(origin) else { return nil }
        return mine.first { ask in ask.frame.frame == nil || frame.frame == nil || ask.frame.frame != frame.frame }
    }

    /// An origin with no scheme or no host to it — how an opaque origin
    /// (a sandboxed frame, a data: URL) or a file reads once spelt
    /// `scheme://host`: no other frame is the same site as it.
    static func opaque(_ origin: String) -> Bool {
        guard let split = origin.range(of: "://") else { return true }
        return origin[..<split.lowerBound].isEmpty || origin[split.upperBound...].isEmpty
    }

    /// Who the picker and the bar name: the site of the frame that asked — the
    /// one its pictures would go to — and, when that frame sits inside another
    /// site's page, that site as well. A call embedded in a page is not the
    /// page, and the picker must not say it is.
    static func names(frame: String, top: String) -> (host: String, within: String?) {
        let frame = frame.lowercased(), top = top.lowercased()
        if frame.isEmpty { return (top, nil) }
        if top.isEmpty || frame == top { return (frame, nil) }
        return (frame, top)
    }

    /// `scheme://host[:port]`, the way the page's and WebKit's origins are compared.
    static func origin(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host.lowercased())" + (port > 0 && !standard ? ":\(port)" : "")
    }

    // MARK: - the picker's list

    /// A tab as the picker lists it.
    struct Candidate: Equatable, Identifiable {
        let id: UUID
        let title: String
        let host: String
        /// The space's name, for tabs of a space the window is not showing.
        let space: String?
        var isCaller = false
        var isBlank = false
        var isPrivate = false
    }

    /// The tabs to offer: never a blank tab (there is nothing to show) or a
    /// private one (it keeps nothing, and is no one else's to see), and the
    /// calling tab only when the page asked to be offered itself — Chrome's
    /// `selfBrowserSurface: "include"` / `preferCurrentTab` — first, then.
    /// The window's own space first, in its order, then each other space.
    static func offer(_ tabs: [Candidate], includeCaller: Bool) -> [Candidate] {
        var seen = Set<UUID>()
        var mine = tabs.filter { $0.space == nil && !$0.isBlank && !$0.isPrivate && seen.insert($0.id).inserted }
        let others = tabs.filter { $0.space != nil && !$0.isBlank && !$0.isPrivate && seen.insert($0.id).inserted && !$0.isCaller }
        if includeCaller {
            if let at = mine.firstIndex(where: \.isCaller) { mine.insert(mine.remove(at: at), at: 0) }
        } else {
            mine.removeAll(where: \.isCaller)
        }
        return mine + others
    }

    /// Typed letters narrow the list: every word somewhere in the title or the host.
    static func filter(_ tabs: [Candidate], _ query: String) -> [Candidate] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return tabs }
        return tabs.filter { tab in
            let text = (tab.title + " " + tab.host).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// ↑ and ↓ over `count` rows, stopping at the ends.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, index + delta))
    }

    // MARK: - frames

    /// Send a picture when it differs from the last one sent, and the same
    /// picture again once a second, so a still slide is not mistaken for a
    /// stalled source by the call on the other end.
    static func publishes(changed: Bool, sinceLast: TimeInterval) -> Bool {
        changed || sinceLast >= 1
    }

    /// Take a picture only for a page that wants one: one is waiting, or the
    /// page asked a moment ago (it asks again as soon as a picture reaches
    /// it). A page that stops asking — frozen, throttled, gone — costs no
    /// snapshots and no JPEGs until it asks again or its share ends.
    static func pictures(waiting: Int, sinceAsked: TimeInterval) -> Bool {
        waiting > 0 || sinceAsked < 0.25
    }

    /// Asks for the next picture a share keeps waiting at once. The page's
    /// script keeps one; anything past this is a page asking over and over,
    /// and the oldest is told "nothing new" (it asks again).
    static let maxWaiting = 2

    /// A page that stopped asking for pictures has gone (closed, navigated,
    /// frozen) — after this long its share ends.
    static let quietLimit: TimeInterval = 12
    /// A page asks for its first picture the moment it is handed its share;
    /// one that hasn't in this long was gone by then (it navigated while the
    /// picker was up), and the share it never collected ends.
    static let firstAskLimit: TimeInterval = 5

    /// Whether a share is over for want of asking.
    static func quiet(sinceAsked: TimeInterval, everAsked: Bool) -> Bool {
        sinceAsked > (everAsked ? quietLimit : firstAskLimit)
    }
}
