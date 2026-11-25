import Foundation
import Testing
@testable import Search

// Arc's Air Traffic Control rules and archive on a move in
// (Fork/Flow/FlowArcExtras.swift). The JSON is Arc's own shape, as two real
// Arc folders and Ardia's importer fixtures write it.

private func data(_ text: String) -> Data { Data(text.utf8) }
private func dest(_ outer: String, _ inner: String) -> String { #"{"\#(outer)": {"_0": \#(inner)}}"# }
private let recent = #"{"mostRecent": {}}"#
private func space(_ id: String) -> String { #"{"space": {"_0": "\#(id)"}}"# }
private func rule(_ to: String, _ style: String, _ text: String, parts: Int = 1) -> String {
    let part = #"{"id": "C", "componentType": {"urlMatch": {"_0": {"\#(style)": {}}, "_1": "\#(text)"}}}"#
    return #"{"id": "R", "destination": \#(to), "sourceComponents": [\#(Array(repeating: part, count: parts).joined(separator: ","))]}"#
}

private let routing = data(#"{"rules": [\#([
    rule(dest("space", recent), "contains", "meet.google.com"),
    rule(dest("space", space("S-WORK")), "contains", "jira.example/browse"),
    rule(dest("littleArc", recent), "contains", "https://www.docs.example/"),
    rule(dest("littleArc", space("S-PERSONAL")), "matches", "calendar.example"),
    rule(dest("space", space("S-DELETED")), "contains", "gone.example"),
    rule(dest("space", recent), "contains", "  "),
    rule(dest("space", recent), "startsWith", "x.example"),
    rule(dest("space", recent), "contains", "a.example", parts: 2),
    rule(dest("space", #"{"profile": {"_0": "P-1"}}"#), "contains", "profile.example"),
].joined(separator: ","))], "defaultDestination": \#(dest("littleArc", recent)), "version": 1}"#)

private func archived(_ at: Double, _ url: String, _ source: String, title: String? = nil, saved: String = "Saved") -> String {
    let custom = title.map { #""\#($0)""# } ?? "null"
    return #""A", {"archivedAt": \#(at), "reason": "manual", "source": \#(source), "sidebarItem": {"id": "A", "title": \#(custom), "data": {"tab": {"savedURL": "\#(url)", "savedTitle": "\#(saved)"}}}}"#
}

private let archive = data(#"{"version": 1, "items": [\#([
    archived(100, "https://old-news.example/", #"{"space": {"_0": "S-PERSONAL"}}"#),
    archived(300, "https://report.example/q3", #"{"space": {"_0": "S-WORK"}}"#, title: "Report", saved: "Q3 report"),
    archived(400, "https://little.example/", #"{"littleArc": {}}"#),
    archived(500, "file:///Users/someone/notes.txt", #"{"space": {"_0": "S-WORK"}}"#),
    #""B", {"archivedAt": 600, "reason": "manual", "source": {"unknown": {}}, "sidebarItem": {"id": "B", "data": {"list": {}}}}"#,
].joined(separator: ","))]}"#)

@Test @MainActor func arcRulesKeepTheirOrderAndLeaveOutWhatArcCantMean() {
    var read = FlowArcExtras.Read()
    FlowArcExtras.routing(routing, into: &read)
    #expect(read.rules.map(\.site) == ["*meet.google.com*", "*jira.example/browse*", "*docs.example*", "calendar.example", "*gone.example*"])
    #expect(read.rules.map(\.space) == [nil, "S-WORK", nil, "S-PERSONAL", "S-DELETED"])
    #expect(read.rules.map(\.little) == [false, false, true, true, false])
    #expect(read.skipped == 4) // blank text, unknown operator, two conditions, a profile
    #expect(read.fallback == nil) // Arc's own default (Little Arc, in front) is not carried
    var named = FlowArcExtras.Read()
    FlowArcExtras.routing(data(#"{"rules": [], "defaultDestination": \#(dest("space", space("S-WORK")))}"#), into: &named)
    #expect(named.fallback == FlowArcExtras.Rule(site: "", space: "S-WORK", little: false))
}

@Test @MainActor func arcTextBecomesASiteAirTrafficMatches() {
    func takes(_ text: String, exact: Bool = false, _ link: String) -> Bool {
        guard let site = FlowArcExtras.site(text, exact: exact) else { return false }
        return AirTraffic.site(site, matches: URL(string: link)!)
    }
    #expect(takes("meet.google.com", "https://meet.google.com/abc-def"))
    #expect(takes("google.com", "https://mail.google.com/"))
    #expect(takes("jira.example/browse", "https://www.jira.example/browse/X-1"))
    #expect(!takes("jira.example/browse", "https://jira.example/issues"))
    #expect(takes("https://www.docs.example/", "https://docs.example"))
    #expect(takes("Figma.com/file?x=1", "https://www.figma.com/file/abc"))
    #expect(takes("calendar.example", exact: true, "https://calendar.example/"))
    #expect(!takes("calendar.example", exact: true, "https://othercalendar.example/"))
    #expect(FlowArcExtras.site("www.", exact: false) == nil)
    #expect(FlowArcExtras.site(" / ", exact: true) == nil)
}

@Test @MainActor func arcArchiveIsWebTabsNewestFirstWithTheirSpace() {
    let tabs = FlowArcExtras.archive(archive)
    #expect(tabs.map(\.url.absoluteString) == ["https://little.example/", "https://report.example/q3", "https://old-news.example/"])
    #expect(tabs.map(\.space) == [nil, "S-WORK", "S-PERSONAL"])
    #expect(tabs.map(\.title) == ["Saved", "Report", "Saved"])
    #expect(FlowArcExtras.archive(data("[1]")).isEmpty)
}

@Test @MainActor func arcSpacesMapByTheMovesRegistry() {
    var work = FlowModel.Space(name: "Work")
    work.source = "S-WORK"
    work.tabs = [FlowModel.Tab(url: URL(string: "https://a.invalid/")!, title: "")]
    var personal = FlowModel.Space(name: "Personal")
    personal.source = "S-PERSONAL"
    let workID = UUID(), personalID = UUID()
    let registry = ["work": workID, "personal": personalID]
    let map = FlowArcExtras.spaces([work, personal], source: "Arc", registry: registry, alive: [workID])
    #expect(map == ["S-WORK": workID]) // Personal was deleted here

    var read = FlowArcExtras.Read()
    FlowArcExtras.routing(routing, into: &read)
    let rules = FlowArcExtras.rules(read, spaces: map)
    #expect(rules.map(\.site) == ["*meet.google.com*", "*jira.example/browse*", "*docs.example*"])
    #expect(rules.map(\.to) == [AirTraffic.Target(), AirTraffic.Target(space: workID, open: .tab), AirTraffic.Target(space: nil, open: .little)])
    #expect(rules.allSatisfy { $0.app == nil })
}

@Test @MainActor func archivedTabsFillOnlyTheRoomEachSpaceHasLeft() {
    let work = UUID(), front = UUID()
    let tabs = FlowArcExtras.archive(archive)
    let now = Date()
    let first = FlowArcExtras.cleaned(tabs, spaces: ["S-WORK": work], fallback: front, have: { _ in [] }, movedAt: now)
    #expect(first.map(\.space) == [front, work, front]) // Little Arc and an unmapped space go to the fallback
    #expect(first.map(\.when) == first.map(\.when).sorted(by: >)) // Arc's order, newest first
    #expect(first.allSatisfy { now.timeIntervalSince($0.when) < 1 }) // a week from the move, not Arc's dates
    #expect(Cleaned.pruned(first, now: now).count == 3)
    // A second move: every page is listed already, so nothing comes.
    let listed = Dictionary(grouping: first, by: \.space).mapValues { Set($0.map(\.url)) }
    #expect(FlowArcExtras.cleaned(tabs, spaces: ["S-WORK": work], fallback: front, have: { listed[$0] ?? [] }, movedAt: now).isEmpty)
    // A full space takes none; the 100 counts what is there already.
    let hundred = Set((0..<Cleaned.most).map { URL(string: "https://mine.example/\($0)")! })
    let full = FlowArcExtras.cleaned(tabs, spaces: ["S-WORK": work], fallback: front, have: { $0 == front ? hundred : [] }, movedAt: now)
    #expect(full.map(\.space) == [work])
    let many = (0..<150).map { FlowArcExtras.Archived(url: URL(string: "https://e.example/\($0 % 140)")!, title: "", space: "S-WORK") }
    let forty = Set((0..<40).map { URL(string: "https://mine.example/\($0)")! })
    let capped = FlowArcExtras.cleaned(many, spaces: ["S-WORK": work], fallback: front, have: { _ in forty }, movedAt: now)
    #expect(capped.count == 60)
    #expect(capped.first?.url.absoluteString == "https://e.example/0")
}

@Test @MainActor func arcSidebarKeepsEachSpacesId() throws {
    let sidebar = #"{"sidebar": {"containers": [{"spaces": ["S-WORK", {"id": "S-WORK", "title": "Work", "containerIDs": ["pinned", "P", "unpinned", "U"]}], "items": ["P", {"id": "P", "childrenIds": []}, "U", {"id": "U", "childrenIds": ["T"]}, "T", {"id": "T", "data": {"tab": {"savedURL": "https://a.invalid/"}}}]}]}}"#
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("arc-extras-\(UUID().uuidString).json")
    try data(sidebar).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let spaces = try FlowArc.read(sidebar: file)
    #expect(spaces.map(\.source) == ["S-WORK"])
    #expect(spaces.first?.tabs.count == 1)
}

@Test @MainActor func theTabsLineSaysWhatCameWithIt() {
    var f = FlowSummary.Facts(source: "Arc")
    f.tabsChosen = true
    f.windowsAreSpaces = true
    f.tabsAdded = 3
    f.spacesMade = 1
    f.rulesAdded = 2
    f.archivedAdded = 1
    #expect(FlowSummary.lines(f).map(\.plain) == ["✓ Tabs: 3 tabs in 1 space; 2 Air Traffic Control rules, 1 archived tab in Recently Cleaned"])
    f.tabsAdded = 0
    f.spacesMade = 0
    f.tabsSkipped = 3
    #expect(FlowSummary.lines(f).first?.ok == true)
}
