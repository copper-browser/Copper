import Foundation
import Testing
@testable import Search

// Fork (ready-pages): when a navigation's answer may go out (Arrival.verdict).

private func look(landed: Bool = true, failed: Bool = false, loading: Bool = false, state: String = "complete", title: String = "Example",
                  still: TimeInterval = 1, elapsed: TimeInterval = 2) -> Arrival.Look {
    Arrival.Look(landed: landed, failed: failed, loading: loading, state: state, title: title, still: still, elapsed: elapsed)
}

@Test func aNavigationWaitsForItsNewPage() {
    // Still on the page being left: wait, whatever that page looks like.
    #expect(Arrival.verdict(look(landed: false, loading: true)) == .wait)
    #expect(Arrival.verdict(look(landed: false, loading: false, elapsed: 0.4)) == .wait)
    // Nothing loading and nothing landed a second on: no navigation is coming.
    #expect(Arrival.verdict(look(landed: false, loading: false, elapsed: 1.2)) == .ready)
    // Landed, but not loaded yet.
    #expect(Arrival.verdict(look(state: "loading")) == .wait)
    #expect(Arrival.verdict(look(state: "interactive")) == .wait)
    #expect(Arrival.verdict(look(state: "")) == .wait)
    #expect(Arrival.verdict(look(loading: true)) == .wait)
    // Loaded and titled: ready after a short still beat.
    #expect(Arrival.verdict(look(still: 0.1)) == .wait)
    #expect(Arrival.verdict(look(still: 0.3)) == .ready)
    // No title yet: give the page's script a moment to name it, then go anyway (JSON, text).
    #expect(Arrival.verdict(look(title: "  ", still: 0.5)) == .wait)
    #expect(Arrival.verdict(look(title: "", still: 1.1)) == .ready)
    // The cap always wins, and says so.
    #expect(Arrival.verdict(look(landed: false, loading: true, elapsed: 12)) == .late)
    #expect(Arrival.verdict(look(state: "loading", elapsed: 12.5)) == .late)
}

@Test func aFailedNavigationAnswersAtOnceAndIsNeverReadAsAPage() {
    // The old page is still complete and titled, but the new one failed: done now, no still beat.
    #expect(Arrival.verdict(look(landed: true, failed: true, still: 0)) == .ready)
    #expect(Arrival.verdict(look(landed: false, failed: true, loading: true, elapsed: 0.2)) == .wait)
    let said = Arrival.unloaded("No connection.", asked: "https://example.com/next")
    #expect(said.hasPrefix("The page did not load (https://example.com/next): No connection."))
    #expect(said.contains("Nothing from it can be read"))
}

@Test func aNavigationThatHasNotCommittedIsNeverReadAsThePageBefore() {
    let nav = Tools.Nav()
    #expect(!nav.committed && !nav.uncommitted(loading: false))
    nav.asked = Date()
    #expect(nav.uncommitted(loading: true))   // asked, still loading, nothing landed: reads refused
    #expect(!nav.uncommitted(loading: false)) // refused or cancelled: nothing is coming
    nav.landed = nav.asked.addingTimeInterval(0.1)
    #expect(nav.committed && !nav.uncommitted(loading: true))
    let said = Arrival.uncommitted("https://example.com/next")
    #expect(said.hasPrefix("The page (https://example.com/next) has not arrived") && said.contains("Nothing was read"))
}

@Test func aCancelledAskIsTakenBackOnce() {
    let nav = Tools.Nav()
    nav.landed = Date(timeIntervalSince1970: 100)
    let link = nav.ask(at: Date(timeIntervalSince1970: 200)) // a link the policy then cancels (another app, a ⌘-click tab)
    #expect(nav.uncommitted(loading: true) && nav.asks == 1)
    nav.unask(link)
    #expect(!nav.uncommitted(loading: true) && nav.asks == 0) // a load in flight before it is not waited on for it
    nav.unask(link)
    #expect(nav.asks == 0 && nav.asked == .distantPast)       // once only
}

@Test func aLateCancelNeverTakesBackANewerAsk() {
    let nav = Tools.Nav()
    nav.landed = Date(timeIntervalSince1970: 100)
    let first = nav.ask(at: Date(timeIntervalSince1970: 200))
    let second = nav.ask(at: Date(timeIntervalSince1970: 201)) // a newer navigation before the first one's answer
    nav.unask(first)                                            // the first one's policy answers "cancel", late
    #expect(nav.asked == second && nav.asks == 2 && nav.uncommitted(loading: true))
    nav.unask(second)
    #expect(nav.asked == first && nav.asks == 1)
}

@Test func anInputOrReadIsStaleOnceANavigationStartedOrLandedSinceItsCheck() {
    let nav = Tools.Nav()
    nav.land(at: Date(timeIntervalSince1970: 100))
    let checked = nav.gen
    #expect(nav.still(checked, loading: false))
    let asked = nav.ask(at: Date(timeIntervalSince1970: 200)) // a redirect starts after the check
    #expect(!nav.still(checked, loading: true))
    nav.land(at: Date(timeIntervalSince1970: 201))              // and commits before the input: nothing pending, still stale
    #expect(!nav.uncommitted(loading: false) && !nav.still(checked, loading: false))
    // A fresh check on the new document stands; a cancelled ask still moved the generation.
    let again = nav.gen
    #expect(nav.still(again, loading: false))
    let cancelled = nav.ask(at: Date(timeIntervalSince1970: 300))
    nav.unask(cancelled)
    #expect(!nav.still(again, loading: false) && asked < cancelled)
}
