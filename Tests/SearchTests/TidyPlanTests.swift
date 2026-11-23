import Foundation
import Testing
@testable import Search

// Tidy (Fork/Tidy.swift): how the model's answer is read, the by-site
// fallback, and the row Undo puts back.
@Suite struct TidyPlanTests {
    func json(_ text: String) -> [String: Any] { Router.json(in: text) }

    @Test func readsTheModelsFolders() {
        let reply = json(#"Sure: {"folders":[{"name":"Trip to Lisbon","tabs":[0,2]},{"name":"Reading","tabs":[1,3]}]}"#)
        #expect(TidyPlan.parse(reply, count: 5, existing: []) == [
            .init(name: "Trip to Lisbon", tabs: [0, 2]),
            .init(name: "Reading", tabs: [1, 3]),
        ])
    }

    @Test func dropsBadIndexesRepeatsAndLoneNewFolders() {
        // 9 is out of range, 0 is taken by the first folder, "Solo" keeps one
        // tab and is new, so it goes and its tab stays loose.
        let reply = json(#"{"folders":[{"name":"Work","tabs":[0,1,9]},{"name":"Other","tabs":[0,2,3]},{"name":"Solo","tabs":[4]}]}"#)
        #expect(TidyPlan.parse(reply, count: 5, existing: []) == [
            .init(name: "Work", tabs: [0, 1]),
            .init(name: "Other", tabs: [2, 3]),
        ])
    }

    @Test func reusesAnExistingFolderEvenForOneTab() {
        let reply = json(#"{"folders":[{"name":"daily","tabs":[2]},{"name":"buildrfi","tabs":[0,1]}]}"#)
        #expect(TidyPlan.parse(reply, count: 3, existing: ["Daily", "Misc › BuildrFi"]) == [
            .init(name: "Daily", tabs: [2]),
            .init(name: "Misc › BuildrFi", tabs: [0, 1]),
        ])
    }

    @Test func newNamesCannotNestAndStayShort() {
        let reply = json(#"{"folders":[{"name":"A › B","tabs":[0,1]},{"name":"\#(String(repeating: "x", count: 60))","tabs":[2,3]}]}"#)
        let plan = TidyPlan.parse(reply, count: 4, existing: [])
        #expect(plan.map(\.name) == ["A - B", String(repeating: "x", count: 32)])
    }

    @Test func nothingUsableIsNothing() {
        #expect(TidyPlan.parse(json("no idea"), count: 4, existing: []).isEmpty)
        #expect(TidyPlan.parse(json(#"{"folders":"nope"}"#), count: 4, existing: []).isEmpty)
        #expect(TidyPlan.parse(json(#"{"folders":[{"name":"","tabs":[0,1]}]}"#), count: 4, existing: []).isEmpty)
    }

    @Test func atMostSixFolders() {
        let many = (0..<8).map { #"{"name":"F\#($0)","tabs":[\#($0 * 2),\#($0 * 2 + 1)]}"# }.joined(separator: ",")
        #expect(TidyPlan.parse(json(#"{"folders":[\#(many)]}"#), count: 16, existing: []).count == 6)
    }

    @Test func bySiteNeedsTwoAndNamesTheSite() {
        let hosts = ["github.com", "news.ycombinator.com", "gist.github.com", "apple.com", "", "bbc.co.uk", "bbc.co.uk"]
        #expect(TidyPlan.bySite(hosts: hosts, existing: []) == [
            .init(name: "Github", tabs: [0, 2]),
            .init(name: "Bbc", tabs: [5, 6]),
        ])
        // An existing folder of the site's name takes them.
        #expect(TidyPlan.bySite(hosts: hosts, existing: ["GitHub"]).first == .init(name: "GitHub", tabs: [0, 2]))
    }

    @Test func hostDropsWWW() {
        #expect(TidyPlan.host(URL(string: "https://www.Apple.com/mac")) == "apple.com")
        #expect(TidyPlan.host(nil) == "")
    }

    @Test func questionHoldsTitlesAndHostsOnly() throws {
        let text = TidyPlan.question(titles: ["Inbox", String(repeating: "t", count: 300)], hosts: ["mail.google.com", "x.com"], existing: ["Work"])
        let body = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tabs = try #require(body["tabs"] as? [[String: Any]])
        #expect(Set(body.keys) == ["existing", "tabs"])
        #expect(tabs.map { Set($0.keys) } == [["i", "title", "host"], ["i", "title", "host"]])
        #expect((tabs[1]["title"] as? String)?.count == 100)
    }

    @Test func undoPutsTheRowBackExactly() {
        // pins p, then Saved s1, then Today t1…t5; t2 and t4 were filed into
        // a folder at the foot of Saved, t5 into another.
        let before = ["p", "s1", "t1", "t2", "t3", "t4", "t5"]
        let after = ["p", "s1", "t2", "t4", "t5", "t1", "t3"]
        let moved = [("t2", 3), ("t4", 5), ("t5", 6)].map { (id: $0.0, at: $0.1) }
        #expect(TidyPlan.restored(after, moved: moved) == before)
    }

    @Test func undoCopesWithTabsClosedOrOpenedSince() {
        let moved = [("t2", 2), ("t4", 4)].map { (id: $0.0, at: $0.1) }
        // t4 closed since: only t2 goes back.
        #expect(TidyPlan.restored(["s1", "t2", "t1", "t3"], moved: moved) == ["s1", "t1", "t2", "t3"])
        // a new tab n opened at the top of Today: everything is still there once.
        let out = TidyPlan.restored(["s1", "t2", "t4", "n", "t1", "t3"], moved: moved)
        #expect(out.sorted() == ["n", "s1", "t1", "t2", "t3", "t4"])
        #expect(out.firstIndex(of: "t2") == 2 && out.firstIndex(of: "t4") == 4)
    }
}
