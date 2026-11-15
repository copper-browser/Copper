import Foundation
import Testing
@testable import Search

// The Move-in sheet's rules (Fork/Flow/FlowState.swift): which source is
// selected and read after the list is refreshed, when an activation re-checks,
// which scan may land, and the event log the sheet regression reads.

private func sources(_ pairs: (String, Bool)...) -> [FlowCandidate] {
    pairs.map { FlowCandidate(id: $0.0, readable: $0.1) }
}

@Suite("Flow sheet: reconcile")
struct FlowReconcileTests {
    @Test("Locked Chrome and readable Arc: Arc is picked and read once")
    func onlyReadableIsPicked() {
        let list = sources(("Chrome", false), ("Arc", true))
        let first = FlowMachine.reconcile(sources: list, selected: nil, previewed: nil, busy: false)
        #expect(first == .init(selected: "Arc", scan: "Arc"))
        // The same list again, Arc's counts on screen: nothing to do.
        let again = FlowMachine.reconcile(sources: list, selected: "Arc", previewed: "Arc", busy: false)
        #expect(again == .init(selected: "Arc", scan: nil))
    }

    @Test("Two readable sources: nothing is picked for the person")
    func twoReadableWaits() {
        let list = sources(("Chrome", true), ("Arc", true))
        #expect(FlowMachine.reconcile(sources: list, selected: nil, previewed: nil, busy: false) == .init(selected: nil, scan: nil))
    }

    @Test("A refresh keeps the selection, and reads it only if another's counts are showing")
    func keepsSelection() {
        let list = sources(("Chrome", true), ("Arc", true))
        #expect(FlowMachine.reconcile(sources: list, selected: "Chrome", previewed: "Chrome", busy: false) == .init(selected: "Chrome", scan: nil))
        #expect(FlowMachine.reconcile(sources: list, selected: "Chrome", previewed: nil, busy: false) == .init(selected: "Chrome", scan: "Chrome"))
    }

    @Test("Chrome unlocking while Arc is selected does not switch")
    func unlockDoesNotSwitch() {
        let list = sources(("Chrome", true), ("Arc", true))
        let decision = FlowMachine.reconcile(sources: list, selected: "Arc", previewed: "Arc", busy: false)
        #expect(decision.selected == "Arc")
        #expect(decision.scan == nil)
        #expect(!decision.resetPreview)
    }

    @Test("Chrome unlocking when it is the only source selects and reads it")
    func unlockOnlySource() {
        let before = FlowMachine.reconcile(sources: sources(("Chrome", false)), selected: nil, previewed: nil, busy: false)
        #expect(before == .init(selected: nil, scan: nil))
        let after = FlowMachine.reconcile(sources: sources(("Chrome", true)), selected: nil, previewed: nil, busy: false)
        #expect(after == .init(selected: "Chrome", scan: "Chrome"))
    }

    @Test("The selected source getting locked goes back to the picker")
    func lockedSelectionResets() {
        let list = sources(("Chrome", false), ("Arc", false))
        let decision = FlowMachine.reconcile(sources: list, selected: "Chrome", previewed: "Chrome", busy: false)
        #expect(decision.selected == nil)
        #expect(decision.scan == nil)
        #expect(decision.resetPreview)
    }

    @Test("The selected source going away falls back to the only other one")
    func goneSelectionFallsBack() {
        let decision = FlowMachine.reconcile(sources: sources(("Arc", true)), selected: "Chrome", previewed: "Chrome", busy: false)
        #expect(decision == .init(selected: "Arc", scan: "Arc", resetPreview: true))
    }

    @Test("Nothing changes under a running move")
    func busyChangesNothing() {
        let decision = FlowMachine.reconcile(sources: sources(("Arc", false)), selected: "Chrome", previewed: "Chrome", busy: true)
        #expect(decision == .init(selected: "Chrome", scan: nil))
    }

    @Test("Equal lists are not republished")
    func changed() {
        #expect(!FlowMachine.changed(sources(("Chrome", false)), sources(("Chrome", false))))
        #expect(FlowMachine.changed(sources(("Chrome", false)), sources(("Chrome", true))))
        #expect(FlowMachine.changed(sources(("Chrome", true)), sources(("Chrome", true), ("Arc", true))))
    }

    @Test("Activation re-checks only while open and something is locked")
    func activation() {
        #expect(FlowMachine.recheckOnActivation(sources: sources(("Chrome", false), ("Arc", true)), open: true))
        #expect(!FlowMachine.recheckOnActivation(sources: sources(("Chrome", false)), open: false))
        #expect(!FlowMachine.recheckOnActivation(sources: sources(("Chrome", true), ("Arc", true)), open: true))
        #expect(!FlowMachine.recheckOnActivation(sources: [], open: true))
    }
}

@Suite("Flow sheet: scan ticket")
struct FlowTicketTests {
    @Test("Only the newest ticket for the selected source lands")
    func newestWins() {
        var ticket = FlowScanTicket()
        let first = ticket.issue(for: "Chrome")
        let second = ticket.issue(for: "Chrome")
        #expect(!ticket.accepts(first, for: "Chrome", selected: "Chrome"))
        #expect(ticket.accepts(second, for: "Chrome", selected: "Chrome"))
    }

    @Test("A read for a source the person left is dropped")
    func leftSourceDropped() {
        var ticket = FlowScanTicket()
        let chrome = ticket.issue(for: "Chrome")
        let arc = ticket.issue(for: "Arc")
        #expect(!ticket.accepts(chrome, for: "Chrome", selected: "Arc"))
        #expect(ticket.accepts(arc, for: "Arc", selected: "Arc"))
        #expect(!ticket.accepts(arc, for: "Arc", selected: "Chrome"))
    }

    @Test("Closing the sheet cancels the read in flight")
    func cancel() {
        var ticket = FlowScanTicket()
        let number = ticket.issue(for: "Arc")
        ticket.cancel()
        #expect(!ticket.accepts(number, for: "Arc", selected: "Arc"))
        #expect(ticket.source == nil)
    }
}

@Suite("Flow sheet: event log")
struct FlowEventsTests {
    @Test("Present then dismiss, twice, never overlaps")
    func sequential() {
        var log = FlowEvents()
        for at in 0..<2 {
            log.record("open", at: Double(at))
            log.record("present", at: Double(at))
            log.record("close", at: Double(at))
            log.record("dismiss", at: Double(at))
        }
        #expect(!log.overlapping)
        #expect(log.count("present") == 2)
        #expect(log.count("dismiss") == 2)
    }

    @Test("Two presents without a dismiss is overlapping")
    func twoSheets() {
        var log = FlowEvents()
        log.record("present", at: 0)
        log.record("present", at: 1)
        #expect(log.overlapping)
    }

    @Test("Scans are counted per open")
    func scansPerOpen() {
        var log = FlowEvents()
        log.record("open", at: 0)
        log.record("scan", "Arc auto", at: 0)
        log.record("open", at: 1)
        log.record("scan", "Arc auto", at: 1)
        #expect(log.scansPerOpen == 1)
        log.record("scan", "Arc auto", at: 2)
        #expect(log.scansPerOpen == 2)
    }

    @Test("The log keeps the newest entries only")
    func limit() {
        var log = FlowEvents()
        for i in 0..<(FlowEvents.limit + 50) { log.record("refresh", "\(i)", at: Double(i)) }
        #expect(log.entries.count == FlowEvents.limit)
        #expect(log.entries.first?.detail == "50")
    }
}

@Suite("Flow sheet: the done step")
struct FlowDoneLinesTests {
    @Test("The done step lists exactly the switches that were on: kinds the browser had none of never show up as 'none to bring'")
    func doneMatchesToggles() {
        // An Arc read: 3 tabs, nothing else counted. Its sheet shows three
        // switches (tabs, sign-ins, site data); the rest fold into one line.
        let tab = FlowModel.Tab(url: URL(string: "https://example.com")!, title: "Example")
        let haul = FlowModel.Haul(spaces: [FlowModel.Space(name: "Home", tabs: [tab, tab, tab])])
        let choice = FlowModel.Choice().fitted(to: haul)
        let toggled = FlowStep.steps(for: choice).map(\.category)
        #expect(toggled == [.tabs, .cookies, .localStorage])
        // The move runs only those (Flow.move), so the done step's lines are
        // the summary of the same three.
        var facts = FlowSummary.Facts(source: "Arc")
        facts.tabsChosen = choice.tabs; facts.tabsAdded = 3; facts.spacesMade = 1
        facts.bookmarksChosen = choice.bookmarks; facts.historyChosen = choice.history
        facts.passwordsChosen = choice.passwords; facts.passkeysChosen = choice.passkeys
        facts.cookiesChosen = choice.cookies; facts.storageChosen = choice.localStorage
        facts.extensionsChosen = choice.extensions
        #expect(FlowSummary.lines(facts).map(\.category) == toggled)
    }

    @Test("Kinds a browser has none of fold into one sentence")
    func keepsNone() {
        #expect(FlowSheet.keepsNone("Arc", ["Bookmarks", "History", "Passwords"]) == "Nothing else to bring from this Arc profile: no bookmarks, history or passwords.")
        #expect(FlowSheet.keepsNone("Arc", ["Extensions"]) == "Nothing else to bring from this Arc profile: no extensions.")
        #expect(FlowSheet.keepsNone(nil, ["History", "Passkeys"]) == "Nothing else to bring from this browser: no history or passkeys.")
    }
}
