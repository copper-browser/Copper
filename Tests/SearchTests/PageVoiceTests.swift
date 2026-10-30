import Foundation
import Testing
@testable import Search

// Page voice (Fork/Voice/PageVoice.swift, docs/voice.md › On web pages): which
// sites may ask, and how a final's words get their times. Pure rules; no
// page, no model.

@Suite struct PageVoiceTests {
    @Test func onlyListedHostsMayAsk() {
        let sites = PageVoice.defaultSites
        #expect(PageVoice.allows(host: "rgs.apps.exowatt.com", sites: sites))
        #expect(PageVoice.allows(host: "RGS.Apps.Exowatt.com", sites: sites))
        #expect(PageVoice.allows(host: "apps.exowatt.com", sites: sites))
        #expect(!PageVoice.allows(host: "evilapps.exowatt.com", sites: sites))
        #expect(!PageVoice.allows(host: "rgs.apps.exowatt.com.evil.com", sites: sites))
        #expect(!PageVoice.allows(host: "exowatt.com", sites: sites))
        #expect(!PageVoice.allows(host: "", sites: sites))
        #expect(PageVoice.allows(host: "127.0.0.1", sites: ["127.0.0.1"]))
        #expect(!PageVoice.allows(host: "127.0.0.1", sites: []))
    }

    @Test func httpsOnlyButThisMac() {
        #expect(PageVoice.secure(scheme: "https", host: "rgs.apps.exowatt.com"))
        #expect(!PageVoice.secure(scheme: "http", host: "rgs.apps.exowatt.com"))
        #expect(PageVoice.secure(scheme: "http", host: "localhost"))
        #expect(PageVoice.secure(scheme: "http", host: "127.0.0.1"))
        #expect(!PageVoice.secure(scheme: "file", host: ""))
    }

    @Test func wordTimingsMustAgreeWithTheFinal() {
        #expect(PageVoice.agrees(5, "one two three four five"))
        #expect(PageVoice.agrees(4, "one two three four five"))
        #expect(!PageVoice.agrees(2, "one two three four five"))
        #expect(!PageVoice.agrees(0, "one"))
    }

    @Test func spreadWordsCoverThePhrase() {
        let words = PageVoice.spread("Hello there, Kevin.", from: 10, to: 12.7)
        #expect(words.count == 3)
        #expect(words.first?["start"] as? Double == 10)
        #expect(words.last?["end"] as? Double == 12)
        #expect(words.allSatisfy { $0["approx"] as? Bool == true })
        #expect(PageVoice.spread("  ", from: 0, to: 1).isEmpty)
    }

    @Test @MainActor func scriptCarriesTheSites() {
        let script = PageVoice.script
        #expect(script.contains("apps.exowatt.com"))
        #expect(!script.contains("__SITES__"))
        #expect(script.contains("copperPageVoice"))
    }
}
