import Foundation

// Who hears a page's getUserMedia({ audio }) — WebKit, or Copper's own
// microphone (PageMic.swift) — and which microphone that is. Kept apart from
// WebKit and AVFoundation so `swift test --filter PageMic` can hold it to its
// word (Tests/SearchTests/PageMicRulesTests.swift). docs/capture.md › Two
// pages, one microphone.
enum PageMicRules {
    enum Route: String, Equatable {
        /// WebKit's own capture, as before.
        case webkit
        /// Copper's microphone, bridged into the page: WebKit never starts a
        /// capture, so it never pauses the call in another tab.
        case copper
    }

    /// WebKit lets one page capture at a time: a page it starts the
    /// microphone for pauses capture in every other page
    /// (WebProcessProxy::muteCaptureInPagesExcept), and no preference or
    /// private API turns that off. So a page that asks for the microphone
    /// alone, in its main frame, while another page is capturing anything,
    /// is served Copper's own microphone instead — once the site is allowed
    /// it, as ever (CaptureDesk). Everything else is WebKit's: no other page
    /// capturing, a request that wants the camera too (WebKit would pause
    /// the call for the camera anyway), a frame (the site that is asked about
    /// is the page's), a page already capturing through WebKit itself (it
    /// is the one WebKit lets capture), macOS not allowing Copper the
    /// microphone (WebKit asks macOS and says so), and headless runs.
    static func route(mainFrame: Bool, audio: Bool, video: Bool, othersCapturing: Bool, selfCapturing: Bool,
                      macOSAllows: Bool, headless: Bool) -> Route {
        guard mainFrame, audio, !video, othersCapturing, !selfCapturing, macOSAllows, !headless else { return .webkit }
        return .copper
    }

    /// The input the page chose, by the name WebKit gave it (a page's device
    /// ids are WebKit's own, salted per site; its labels are the devices'
    /// names): that device when Copper finds one by that name, else nil —
    /// the Mac's default input.
    static func device(named label: String?, among names: [String]) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        if let exact = names.first(where: { $0 == label }) { return exact }
        return names.first { $0.caseInsensitiveCompare(label) == .orderedSame }
    }

    /// Copper's microphone, as the page hears it.
    static let rate = 16_000.0
    static let channels = 1

    /// A page that has asked for no sound this long has stopped listening
    /// (its track was let go without stop(), its page hung): the microphone
    /// is closed.
    static let quietSeconds: TimeInterval = 12

    static func quiet(sinceAsked: TimeInterval) -> Bool { sinceAsked > quietSeconds }

    /// The words for the track's label: the device's name, or the default's.
    static func label(device: String?, fallback: String?) -> String {
        if let device, !device.isEmpty { return device }
        if let fallback, !fallback.isEmpty { return fallback }
        return "Microphone"
    }
}
