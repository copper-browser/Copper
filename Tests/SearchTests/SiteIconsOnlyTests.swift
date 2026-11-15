import Testing
@testable import Search

// Collin (2026-11-15): tabs and pins always wear the site's icon (a globe
// until it lands), never a letter — the "Tabs show: Letters / Site icons"
// choice is gone, and so is its synced setting.

@Test func theLettersChoiceNoLongerSyncs() {
    #expect(CloudSettingsKeys.filter(["glyph": "letters", "look": "dark"]) == ["look": "dark"])
    #expect(!CloudSettingsKeys.allowed.contains("glyph"))
}

@Test func settingsSearchHasNoTabsShowRow() {
    #expect(!SettingsIndex.entries.contains { $0.anchor == "tabs.glyph" })
}
