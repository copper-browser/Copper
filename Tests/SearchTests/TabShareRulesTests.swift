import Foundation
import Testing
@testable import Search

// Tab sharing's arithmetic and bookkeeping (Fork/TabShare/TabShareRules.swift):
// what a page's constraints mean, how big a picture is, which ask WebKit's
// request belongs to, and which tabs the picker offers.

// MARK: - constraints

@Test func aConstraintIsReadAsACeilingWhicheverWayThePageWritesIt() {
    #expect(TabShareRules.ceiling(1280) == 1280)
    #expect(TabShareRules.ceiling(NSNumber(value: 720)) == 720)
    #expect(TabShareRules.ceiling(["max": 1280]) == 1280)
    #expect(TabShareRules.ceiling(["ideal": 960]) == 960)
    #expect(TabShareRules.ceiling(["exact": 640, "max": 1280]) == 640)
    #expect(TabShareRules.ceiling(["min": 640]) == nil)
    #expect(TabShareRules.ceiling(NSNumber(value: true)) == nil)
    #expect(TabShareRules.ceiling(nil) == nil)
    #expect(TabShareRules.ceiling("1280") == nil)
}

@Test func thePagesVideoConstraintsBecomeAWant() {
    #expect(TabShareRules.want(from: true) == TabShareRules.Want())
    #expect(TabShareRules.want(from: nil) == TabShareRules.Want())
    let want = TabShareRules.want(from: ["width": ["max": 1280], "height": 720.4, "frameRate": ["ideal": 15]])
    #expect(want == TabShareRules.Want(width: 1280, height: 720, fps: 15))
    // Nonsense is no constraint at all.
    #expect(TabShareRules.want(from: ["width": -5, "frameRate": 0]) == TabShareRules.Want())
}

@Test func thePaceIsWhatThePageAskedForBetweenOneAndThirty() {
    #expect(TabShareRules.fps(.init()) == 30)
    #expect(TabShareRules.fps(.init(fps: 60)) == 30)
    #expect(TabShareRules.fps(.init(fps: 5)) == 5)
    #expect(TabShareRules.fps(.init(fps: 0.2)) == 1)
}

// MARK: - picture size

@Test func aRetinaPageIsCappedAt1920WideKeepingItsShape() {
    let size = TabShareRules.pixels(for: CGSize(width: 1440, height: 848))
    #expect(size.width == 1920)
    #expect(size.height == 1130)
    #expect(abs(Double(size.width) / Double(size.height) - 1440.0 / 848.0) < 0.01)
}

@Test func aSmallPageIsSharedAtRetinaDetailAndNeverStretched() {
    let size = TabShareRules.pixels(for: CGSize(width: 640, height: 360))
    #expect(size.width == 1280 && size.height == 720)
}

@Test func aTallPageIsCappedByHeight() {
    let size = TabShareRules.pixels(for: CGSize(width: 800, height: 1400))
    #expect(size.height <= TabShareRules.maxHeight)
    #expect(size.width < size.height)
}

@Test func whatThePageAskedForShrinksThePictureAndKeepsItsShape() {
    let size = TabShareRules.pixels(for: CGSize(width: 1440, height: 848), want: .init(width: 1280, height: 720))
    #expect(size.width == 1222 && size.height == 720)
    let wide = TabShareRules.pixels(for: CGSize(width: 1440, height: 848), want: .init(width: 1280))
    #expect(wide.width == 1280)
}

@Test func picturesAreEvenSizedForVideoEncoders() {
    for width in stride(from: 301.0, through: 1999, by: 97) {
        let size = TabShareRules.pixels(for: CGSize(width: width, height: width * 0.6173))
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }
    #expect(TabShareRules.pixels(for: .zero) == (2, 2))
}

/// WebKit's own arithmetic (WKWebView takeSnapshotWithConfiguration, macOS):
/// the width asked for, and the height from the rect's shape, both truncated.
private func webKitPicture(_ rect: CGRect, width: Int) -> (Int, Int) {
    let scale = Double(width) / Double(rect.width)
    return (width, Int(scale * Double(rect.height)))
}

@Test func thePictureComesBackExactlyTheSizeAskedFor() {
    for (page, want) in [(CGSize(width: 1440, height: 848), TabShareRules.Want(width: 1280, height: 720)),
                         (CGSize(width: 1440, height: 848), TabShareRules.Want()),
                         (CGSize(width: 1280, height: 777), TabShareRules.Want()),
                         (CGSize(width: 1001, height: 1403), TabShareRules.Want(width: 640)),
                         (CGSize(width: 333, height: 211), TabShareRules.Want())] {
        let pixels = TabShareRules.pixels(for: page, want: want)
        let rect = TabShareRules.snapshotRect(bounds: page, pixels: pixels)
        #expect(rect.width <= page.width && rect.height <= page.height)
        #expect(page.width - rect.width < 2 && page.height - rect.height < 2)
        let made = webKitPicture(rect, width: pixels.width)
        #expect(made.0 == pixels.width && made.1 == pixels.height, "\(page) → \(pixels) → \(made)")
    }
}

// MARK: - matching WebKit's request to the page's ask

@Test func webKitsRequestFindsTheOldestAskFromTheSameViewAndOrigin() {
    // Kept alive for the whole test: a freed object's address — its
    // ObjectIdentifier — can be handed to the next one.
    let objects = [NSObject(), NSObject(), NSObject()]
    let view = ObjectIdentifier(objects[0]), other = ObjectIdentifier(objects[1]), stranger = ObjectIdentifier(objects[2])
    let now = Date()
    let asks = [
        TabShareRules.AskKey(id: "other-view", view: other, origin: "https://meet.google.com", at: now.addingTimeInterval(-5)),
        TabShareRules.AskKey(id: "frame", view: view, origin: "https://frame.example", at: now.addingTimeInterval(-3)),
        TabShareRules.AskKey(id: "newer", view: view, origin: "https://meet.google.com", at: now),
        TabShareRules.AskKey(id: "older", view: view, origin: "https://meet.google.com", at: now.addingTimeInterval(-1)),
    ]
    #expect(TabShareRules.match(asks, view: view, origin: "https://meet.google.com")?.id == "older")
    #expect(TabShareRules.match(asks, view: view, origin: "https://frame.example")?.id == "frame")
    // Another origin's ask is never handed this frame's request.
    #expect(TabShareRules.match(asks, view: view, origin: "https://elsewhere") == nil)
    #expect(TabShareRules.match(asks, view: stranger, origin: "https://meet.google.com") == nil)
}

/// The hole this closes: a cross-origin frame inside the call page posts an
/// ask straight to the handler, and the top page's getDisplayMedia comes
/// without one of its own (it reached WebKit's function some way the wrapper
/// never saw — a fresh about:blank frame's, which no user script reaches).
/// The frame's ask used to be matched, and the tab you picked for the page
/// went to the frame.
@Test func anAskFromAnotherOriginInTheSamePageIsNeverMatched() {
    let objects = [NSObject()]
    let view = ObjectIdentifier(objects[0])
    let planted = TabShareRules.AskKey(id: "planted", view: view, origin: "https://ads.example",
                                       frame: .init(frame: 9, document: "ad-doc"), at: Date().addingTimeInterval(-2))
    #expect(TabShareRules.match([planted], view: view, origin: "https://meet.google.com", frame: .init(frame: 1, document: "meet-doc")) == nil)
}

@Test func webKitsRequestFindsTheAskOfTheVeryFrameAndDocument() {
    let objects = [NSObject()]
    let view = ObjectIdentifier(objects[0])
    let now = Date()
    let sibling = TabShareRules.AskKey(id: "sibling", view: view, origin: "https://meet.google.com",
                                       frame: .init(frame: 7, document: "b"), at: now.addingTimeInterval(-3))
    let earlier = TabShareRules.AskKey(id: "earlier-document", view: view, origin: "https://meet.google.com",
                                       frame: .init(frame: 1, document: "old"), at: now.addingTimeInterval(-2))
    let mine = TabShareRules.AskKey(id: "mine", view: view, origin: "https://meet.google.com",
                                    frame: .init(frame: 1, document: "new"), at: now)
    let asks = [sibling, earlier, mine]
    // The frame's own ask comes first, before an older one of a same-origin
    // sibling and the frame's last document's.
    #expect(TabShareRules.match(asks, view: view, origin: "https://meet.google.com", frame: .init(frame: 1, document: "new"))?.id == "mine")
    // A WebKit that cannot name the document still tells the frames apart.
    #expect(TabShareRules.match(asks, view: view, origin: "https://meet.google.com", frame: .init(frame: 7))?.id == "sibling")
    // One that can name neither falls back to view and origin, oldest first.
    #expect(TabShareRules.match(asks, view: view, origin: "https://meet.google.com")?.id == "sibling")
}

/// A page calling the getDisplayMedia of an about:blank frame it made: the
/// wrapper asks from that frame, WebKit's request names the page's. Same
/// site, so it is matched — but never the last document's ask in the very
/// frame that is asking, and never across opaque origins.
@Test func anotherFrameOfTheSameSiteIsMatchedButNeverAStaleDocumentOrAnOpaqueOrigin() {
    let objects = [NSObject()]
    let view = ObjectIdentifier(objects[0])
    let now = Date()
    let helper = TabShareRules.AskKey(id: "helper", view: view, origin: "https://meet.google.com",
                                      frame: .init(frame: 12, document: "blank"), at: now)
    #expect(TabShareRules.match([helper], view: view, origin: "https://meet.google.com", frame: .init(frame: 1, document: "page"))?.id == "helper")
    let stale = TabShareRules.AskKey(id: "stale", view: view, origin: "https://meet.google.com",
                                     frame: .init(frame: 1, document: "before-reload"), at: now)
    #expect(TabShareRules.match([stale], view: view, origin: "https://meet.google.com", frame: .init(frame: 1, document: "page")) == nil)
    let sandboxed = TabShareRules.AskKey(id: "sandboxed", view: view, origin: "://", frame: .init(frame: 30, document: "x"), at: now)
    #expect(TabShareRules.match([sandboxed], view: view, origin: "://", frame: .init(frame: 31, document: "y")) == nil)
    #expect(TabShareRules.match([sandboxed], view: view, origin: "://", frame: .init(frame: 30, document: "x"))?.id == "sandboxed")
    #expect(TabShareRules.opaque("://") && TabShareRules.opaque("file://") && TabShareRules.opaque("nonsense"))
    #expect(!TabShareRules.opaque("https://meet.google.com") && !TabShareRules.opaque("http://127.0.0.1:8080"))
}

@Test func aFrameKeyIsTheSameFrameAndDocumentAsFarAsBothSidesKnow() {
    let key = TabShareRules.FrameKey(frame: 3, document: "doc")
    #expect(key.same(.init(frame: 3, document: "doc")))
    #expect(!key.same(.init(frame: 4, document: "doc")))
    #expect(!key.same(.init(frame: 3, document: "next")))
    #expect(key.same(.init(frame: 3)))
    #expect(key.same(.init()))
    // A new document in the same frame: the share bound to the old one is over.
    #expect(key.replaced(by: .init(frame: 3, document: "next")))
    #expect(!key.replaced(by: .init(frame: 3, document: "doc")))
    #expect(!key.replaced(by: .init(frame: 4, document: "next")))
    #expect(!key.replaced(by: .init(frame: 3)))
    #expect(!TabShareRules.FrameKey(frame: 3).replaced(by: .init(frame: 3, document: "next")))
}

@Test func thePickerNamesTheFrameThatWouldGetThePictures() {
    #expect(TabShareRules.names(frame: "meet.google.com", top: "meet.google.com") == ("meet.google.com", nil))
    #expect(TabShareRules.names(frame: "Widget.Example", top: "news.example") == ("widget.example", "news.example"))
    #expect(TabShareRules.names(frame: "", top: "news.example") == ("news.example", nil))
    #expect(TabShareRules.names(frame: "widget.example", top: "") == ("widget.example", nil))
}

@Test func originsAreSpeltOneWay() {
    #expect(TabShareRules.origin(scheme: "HTTPS", host: "Meet.Google.com", port: 443) == "https://meet.google.com")
    #expect(TabShareRules.origin(scheme: "http", host: "localhost", port: 80) == "http://localhost")
    #expect(TabShareRules.origin(scheme: "http", host: "localhost", port: 8765) == "http://localhost:8765")
    #expect(TabShareRules.origin(scheme: "https", host: "zoom.us", port: 0) == "https://zoom.us")
}

// MARK: - the picker's list

private func tab(_ title: String, space: String? = nil, caller: Bool = false, blank: Bool = false, shy: Bool = false,
                 minutesAgo: Double? = nil) -> TabShareRules.Candidate {
    TabShareRules.Candidate(id: UUID(), title: title, host: title.lowercased() + ".com", space: space,
                            isCaller: caller, isBlank: blank, isPrivate: shy,
                            seen: minutesAgo.map { Date(timeIntervalSinceReferenceDate: 800_000_000 - $0 * 60) } ?? .distantPast)
}

/// The rows as words, for comparing: `screen`, `window`, a tab's title, `all N`
/// (`all N open`) and `- title` for a tab in the full list.
private func words(_ rows: [TabShareRules.Row], _ tabs: [TabShareRules.Candidate]) -> [String] {
    let titles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
    return rows.map { row in
        switch row {
        case .screen: return "screen"
        case .window: return "window"
        case .tab(let id): return titles[id] ?? "?"
        case .listed(let id): return "- " + (titles[id] ?? "?")
        case .all(let count, let open): return "all \(count)" + (open ? " open" : "")
        }
    }
}

@Test func thePickerLeavesOutTheCallerBlankTabsAndPrivateOnes() {
    let tabs = [tab("Meet", caller: true), tab("Slides"), tab("", blank: true), tab("Bank", shy: true), tab("Docs")]
    #expect(TabShareRules.offer(tabs, includeCaller: false).map(\.title) == ["Slides", "Docs"])
}

@Test func aPageThatAsksToBeOfferedItselfComesFirst() {
    let tabs = [tab("Slides"), tab("Meet", caller: true), tab("Docs")]
    #expect(TabShareRules.offer(tabs, includeCaller: true).map(\.title) == ["Meet", "Slides", "Docs"])
}

@Test func otherSpacesTabsFollowThisWindowsOwn() {
    let shared = tab("Slides")
    let tabs = [tab("Notes", space: "Work"), shared, tab("Meet", caller: true), tab("Mail", space: "Home"), shared]
    #expect(TabShareRules.offer(tabs, includeCaller: false).map(\.title) == ["Slides", "Notes", "Mail"])
}

@Test func typingNarrowsTheTabsByEveryWord() {
    let tabs = [tab("Quarterly slides"), tab("Slides draft"), tab("Inbox")]
    #expect(TabShareRules.filter(tabs, "slides").map(\.title) == ["Quarterly slides", "Slides draft"])
    #expect(TabShareRules.filter(tabs, "SLIDES quart").map(\.title) == ["Quarterly slides"])
    #expect(TabShareRules.filter(tabs, "inbox.com").map(\.title) == ["Inbox"])
    #expect(TabShareRules.filter(tabs, "  ").count == 3)
}

@Test func thePagesDisplaySurfaceHintPicksTheFirstRow() {
    // Entire screen, a window, then the tabs.
    let tabs = [tab("Slides"), tab("Docs")]
    #expect(TabShareRules.highlight(for: ["displaySurface": "monitor"], tabs: tabs) == 0)
    #expect(TabShareRules.highlight(for: ["displaySurface": ["ideal": "monitor"]], tabs: tabs) == 0)
    #expect(TabShareRules.highlight(for: ["displaySurface": "window"], tabs: tabs) == 1)
    #expect(TabShareRules.highlight(for: ["displaySurface": ["exact": "window"]], tabs: tabs) == 1)
    #expect(TabShareRules.highlight(for: ["displaySurface": "browser"], tabs: tabs) == 2)
    // A tab asked for with no tab to offer: a window.
    #expect(TabShareRules.highlight(for: ["displaySurface": "browser"], tabs: []) == 1)
}

/// No hint: Return opens macOS's picker for the screen — the usual share,
/// and never a page handed to the call by a stray Return. A page that asked
/// to be offered itself gets This tab.
@Test func withNoHintReturnSharesTheScreenOrThisTabWhenThePageAskedForItself() {
    #expect(TabShareRules.highlight(for: true, tabs: [tab("Slides"), tab("Docs")]) == 0)
    #expect(TabShareRules.highlight(for: nil, tabs: []) == 0)
    let mine = TabShareRules.offer([tab("Slides"), tab("Meet", caller: true)], includeCaller: true)
    #expect(TabShareRules.highlight(for: true, tabs: mine) == 2)
    #expect(TabShareRules.rows(mine, query: "", expanded: false)[2] == .tab(mine[0].id))
    #expect(mine[0].isCaller)
    // A hint still wins.
    #expect(TabShareRules.highlight(for: ["displaySurface": "monitor"], tabs: mine) == 0)
}

@Test func theLatestTabsComeFirstFromEverySpaceAndTheCallerAheadOfThem() {
    let tabs = [tab("Mail", minutesAgo: 300), tab("Slides", minutesAgo: 2), tab("Notes", space: "Work", minutesAgo: 1),
                tab("Old"), tab("Meet", caller: true, minutesAgo: 5), tab("Maps", space: "Home", minutesAgo: 30)]
    #expect(TabShareRules.byRecency(tabs).map(\.title) == ["Meet", "Notes", "Slides", "Maps", "Mail", "Old"])
    // Never seen, or seen at once: the list's own order.
    let even = [tab("A"), tab("B"), tab("C")]
    #expect(TabShareRules.byRecency(even).map(\.title) == ["A", "B", "C"])
}

@Test func theScreenAndAWindowAlwaysLeadAndOnlyTheLatestFewTabsShowUntilAllTabsIsOpened() {
    // Ten tabs over two spaces, the latest scattered among them.
    let tabs = [tab("a", minutesAgo: 90), tab("b", minutesAgo: 3), tab("c", minutesAgo: 80), tab("d", minutesAgo: 1),
                tab("e", minutesAgo: 70), tab("f", space: "Work", minutesAgo: 2), tab("g", space: "Work", minutesAgo: 60),
                tab("h", space: "Work", minutesAgo: 4), tab("i", space: "Work", minutesAgo: 50), tab("j", space: "Work")]
    let closed = TabShareRules.rows(tabs, query: "", expanded: false, recent: 4)
    #expect(words(closed, tabs) == ["screen", "window", "d", "f", "b", "h", "all 10"])
    let open = TabShareRules.rows(tabs, query: "", expanded: true, recent: 4)
    #expect(words(open, tabs) == ["screen", "window", "d", "f", "b", "h", "all 10 open",
                                 "- a", "- b", "- c", "- d", "- e", "- f", "- g", "- h", "- i", "- j"])
    // Opening it changes nothing above it: the highlight on All tabs stays there.
    #expect(Array(open.prefix(6)) == Array(closed.prefix(6)))
    // The default few.
    #expect(TabShareRules.rows(tabs, query: "", expanded: false).count == 2 + TabShareRules.recentCount + 1)
    #expect((6...8).contains(TabShareRules.recentCount))
}

@Test func aFewTabsAreAllListedWithNoAllTabsRow() {
    let tabs = [tab("Slides", minutesAgo: 9), tab("Docs", minutesAgo: 1)]
    #expect(words(TabShareRules.rows(tabs, query: "", expanded: false), tabs) == ["screen", "window", "Docs", "Slides"])
    #expect(words(TabShareRules.rows(tabs, query: "", expanded: true), tabs) == ["screen", "window", "Docs", "Slides"])
}

@Test func aPageThatCannotBeHandedATabGetsTheScreenAndAWindowAlone() {
    #expect(TabShareRules.rows([], query: "", expanded: false) == [.screen, .window])
    #expect(TabShareRules.rows([], query: "", expanded: true) == [.screen, .window])
}

@Test func typingSearchesEveryTabInEverySpaceLatestFirst() {
    var tabs = (0..<40).map { tab("Filler \($0)", space: $0 % 2 == 0 ? nil : "Work", minutesAgo: Double($0)) }
    tabs += [tab("Meet notes", space: "Home", minutesAgo: 500), tab("Weekly meeting", minutesAgo: 600),
             tab("Meet recording", space: "Work", minutesAgo: 45)]
    let found = TabShareRules.rows(tabs, query: "meet", expanded: false)
    #expect(words(found, tabs) == ["screen", "window", "Meet recording", "Meet notes", "Weekly meeting"])
    // All tabs open or not, typing lists the matches alone.
    #expect(TabShareRules.rows(tabs, query: "meet", expanded: true) == found)
    // Return takes the first match; nothing found, the screen.
    #expect(TabShareRules.firstTab(in: found) == 2)
    #expect(TabShareRules.rows(tabs, query: "zzz", expanded: false) == [.screen, .window])
    #expect(TabShareRules.firstTab(in: [.screen, .window]) == 0)
    // Spaces alone are no search.
    #expect(TabShareRules.rows(tabs, query: "  ", expanded: false) == TabShareRules.rows(tabs, query: "", expanded: false))
}

@Test func theArrowsStopAtTheEnds() {
    #expect(TabShareRules.step(0, by: -1, count: 3) == 0)
    #expect(TabShareRules.step(1, by: 1, count: 3) == 2)
    #expect(TabShareRules.step(2, by: 1, count: 3) == 2)
    #expect(TabShareRules.step(5, by: 0, count: 0) == 0)
}

@Test func leftAndRightGoBetweenTheScreenAndAWindowAndNowhereElse() {
    #expect(TabShareRules.across(0, by: 1) == 1)
    #expect(TabShareRules.across(1, by: 1) == 1)
    #expect(TabShareRules.across(1, by: -1) == 0)
    #expect(TabShareRules.across(0, by: -1) == 0)
    // On a tab, ← and → leave the highlight where it is.
    #expect(TabShareRules.across(4, by: -1) == 4)
    #expect(TabShareRules.across(2, by: 1) == 2)
}

// MARK: - frames

@Test func aStillPageIsResentOnceASecondAndAMovingOneEveryTime() {
    #expect(TabShareRules.publishes(changed: true, sinceLast: 0.01))
    #expect(!TabShareRules.publishes(changed: false, sinceLast: 0.5))
    #expect(TabShareRules.publishes(changed: false, sinceLast: 1.0))
}

@Test func picturesAreTakenOnlyForAPageThatIsAsking() {
    #expect(TabShareRules.pictures(waiting: 1, sinceAsked: 30))
    #expect(TabShareRules.pictures(waiting: 0, sinceAsked: 0.01))
    // Stopped asking (frozen, throttled, gone): no snapshot, no JPEG.
    #expect(!TabShareRules.pictures(waiting: 0, sinceAsked: 0.5))
    #expect(!TabShareRules.pictures(waiting: 0, sinceAsked: 11))
}

@Test func aShareEndsWhenItsPageStopsAskingAndSoonerWhenItNeverAsked() {
    #expect(!TabShareRules.quiet(sinceAsked: 4, everAsked: false))
    #expect(TabShareRules.quiet(sinceAsked: 6, everAsked: false))
    #expect(!TabShareRules.quiet(sinceAsked: 6, everAsked: true))
    #expect(TabShareRules.quiet(sinceAsked: 13, everAsked: true))
    #expect(TabShareRules.maxWaiting >= 1)
}

@Test func theTimingSpreadKeepsTheLastFewSecondsAndReadsTheirMiddleAndSlowTenth() {
    var spread = TabShareRules.Spread()
    #expect(spread.report == ["p50": 0, "p90": 0, "max": 0])
    // A tick every 33 ms, then macOS slows Copper and they come every 165 ms.
    for _ in 0..<TabShareRules.Spread.kept { spread.add(33.3) }
    #expect(spread.percentile(0.5) == 33.3 && spread.percentile(1) == 33.3)
    for _ in 0..<(TabShareRules.Spread.kept / 2 + 1) { spread.add(165.04) }
    #expect(spread.values.count == TabShareRules.Spread.kept)
    #expect(spread.percentile(0.5) == 165)
    #expect(spread.percentile(0.9) == 165 && spread.report["max"] == 165)
    #expect(spread.percentile(0) == 33.3)
}

@MainActor @Test func nothingIsHeldForThePaceWhileNothingIsShared() {
    let share = TabShare.shared
    #expect(share.shares.isEmpty)
    #expect(!share.holdingPace)
    share.holdsPace = false
    share.holdsPace = true
    #expect(!share.holdingPace)
}
