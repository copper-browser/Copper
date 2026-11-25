import Foundation
import Testing
@testable import Search

// Ardia parity polish: the rules under What's New, the translate offer and
// the auto-float (Fork/UpdateNews.swift, Fork/Translate.swift, Float.swift).
// End to end: docs/fixtures/ardia-polish-e2e.sh.

@Test func whatsNewOnlyAfterAnUpdate() {
    #expect(UpdateNews.due(seen: "1.0.20261120.120", current: "1.0.20261125.130"))
    #expect(!UpdateNews.due(seen: nil, current: "1.0.20261125.130")) // first install
    #expect(!UpdateNews.due(seen: "1.0.20261125.130", current: "1.0.20261125.130")) // a relaunch
    #expect(!UpdateNews.due(seen: "1.0.20261125.130", current: "1.0.20261120.120")) // a downgrade
    #expect(!UpdateNews.due(seen: "1.0", current: "dev"))
}

@Test func translateOffersOnlyForLanguagesTheMacDoesNotRead() {
    let mac = ["en-US", "fr-FR"]
    #expect(PageTranslate.reads(Locale.Language(identifier: "en-GB"), preferred: mac))
    #expect(PageTranslate.reads(Locale.Language(identifier: "fr"), preferred: mac))
    #expect(!PageTranslate.reads(Locale.Language(identifier: "de"), preferred: mac))
    #expect(!PageTranslate.reads(Locale.Language(identifier: "ja-JP"), preferred: mac))
}

@Test func floatingOnItsOwnTakesOnlyAVideoYouCanHear() {
    #expect(Isolate.on(strict: true).contains("var strict = true;"))
    #expect(Isolate.on().contains("var strict = false;"))
    #expect(Isolate.on(strict: true).contains("v.muted || v.volume === 0"))
}
