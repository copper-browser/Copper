import Foundation
import Testing
@testable import Search

// First run and Move in: a fresh profile starts in the sidebar with the start
// card; an existing one is left alone. Move in's switches follow what the
// browser has, and its button names what it brings. The release notes on
// About fold to three lines; the gateway address ships empty.

@MainActor
@Suite("First run")
struct FirstRunTests {
    private func store() -> UserDefaults {
        let name = "firstrun-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func onlyANewProfileIsFresh() {
        #expect(Preferences.freshProfile(store()))
        for (key, value) in [("sidebar", false as Any), ("manner", "top"), ("welcomed", true), ("glyph", "icons")] {
            let s = store()
            s.set(value, forKey: key)
            #expect(!Preferences.freshProfile(s), "\(key) set means someone has been here")
        }
    }

    private func haul(tabs: Int, bookmarks: Int = 0, places: Int = 0, logins: Int = 0) -> FlowModel.Haul {
        var h = FlowModel.Haul()
        let url = URL(string: "https://example.com")!
        h.spaces = [FlowModel.Space(name: "Research", tabs: Array(repeating: FlowModel.Tab(url: url, title: "x"), count: tabs))]
        h.bookmarkCount = bookmarks
        h.placeCount = places
        h.loginCount = logins
        return h
    }

    @Test func emptyKindsAreOffAndTheButtonNamesThePayload() {
        let only = haul(tabs: 3)
        let fitted = FlowModel.Choice().fitted(to: only)
        #expect(fitted.tabs && !fitted.bookmarks && !fitted.history && !fitted.passwords && !fitted.passkeys && !fitted.extensions)
        // Sign-ins aren't counted before the move, so they stay as chosen.
        #expect(fitted.cookies)
        var tabsOnly = fitted
        tabsOnly.cookies = false
        tabsOnly.localStorage = false
        #expect(tabsOnly.button(for: only) == "Bring over 3 tabs")
        #expect(FlowModel.Choice().fitted(to: haul(tabs: 1, bookmarks: 120)).button(for: haul(tabs: 1, bookmarks: 120)) == "Bring over 1 tab and 120 bookmarks + sign-ins")
        // Sign-ins on with the tabs: the button says they come too.
        #expect(fitted.button(for: only) == "Bring over 3 tabs + sign-ins")
        let lots = haul(tabs: 2, bookmarks: 5, places: 9, logins: 4)
        #expect(FlowModel.Choice().fitted(to: lots).button(for: lots) == "Bring over 2 tabs, 5 bookmarks and more")
        // Nothing counted yet: every switch is the person's.
        #expect(FlowModel.Choice().fitted(to: nil) == FlowModel.Choice())
        #expect(FlowModel.Choice().button(for: nil) == "Bring it all over")
        var none = FlowModel.Choice()
        none.tabs = false; none.bookmarks = false; none.history = false; none.passwords = false
        none.cookies = false; none.localStorage = false; none.passkeys = false; none.extensions = false
        #expect(!none.anything)
    }

    @Test func oneSentenceNamesTheBrowsersFound() {
        #expect(MoveFrom.phrase([]) == "another browser")
        #expect(MoveFrom.phrase(["Arc"]) == "Arc")
        #expect(MoveFrom.phrase(["Arc", "Safari"]) == "Arc or Safari")
        #expect(MoveFrom.phrase(["Arc", "Chrome", "Safari"]) == "Arc, Chrome or Safari")
    }

    @Test func releaseNotesFoldToThreeLines() {
        let notes = "Tabs open faster. Move in names what it brings!\nSettings speaks plainly? A fourth thing. A fifth."
        #expect(UpdatesPage.bullets(notes) == ["Tabs open faster.", "Move in names what it brings!", "Settings speaks plainly?"])
        #expect(UpdatesPage.bullets("No full stop") == ["No full stop"])
        // One line each: a long sentence ends where its first thought does.
        #expect(UpdatesPage.bullets("A pin keeps its page: ⌘W takes you back. Sharing is quicker — six tabs first.") == ["A pin keeps its page.", "Sharing is quicker."])
    }

    @Test func noGatewayAddressUntilOneIsGiven() throws {
        #expect(Intelligence.Keys().routerURL.isEmpty)
        let old = try JSONDecoder().decode(Intelligence.Keys.self, from: Data(#"{"routerKey":"sk-x"}"#.utf8))
        #expect(old.routerURL == Intelligence.Keys.legacyRouterURL)
        let none = try JSONDecoder().decode(Intelligence.Keys.self, from: Data(#"{}"#.utf8))
        #expect(none.routerURL.isEmpty)
    }
}
