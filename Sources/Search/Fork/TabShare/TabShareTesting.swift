import WebKit

// What a test world may do that Copper itself never does (Store.testing only):
// answer the share picker from the bench, keep a headless picker up for the
// bench to read instead of declining it, and — with SEARCH_SHARE_MOCK=1 at
// launch — use WebKit's mock capture devices, so a window or screen answer
// runs WebKit's real path to a stream without the system picker coming up
// on the screen of whoever is at the Mac.
@MainActor
enum TabShareTesting {
    /// Answers waiting for the next request, oldest first.
    private static var queued: [TabShare.Choice] = []

    static func queue(_ choice: TabShare.Choice) {
        guard Store.testing else { return }
        queued.append(choice)
    }

    static func takeAnswer() -> TabShare.Choice? {
        guard Store.testing, !queued.isEmpty else { return nil }
        return queued.removeFirst()
    }

    static var pending: Int { queued.count }

    /// A headless test world leaves the picker up for `bench share answer`.
    static var holds: Bool { Store.testing }

    /// SEARCH_SHARE_MOCK=1, test worlds only. WKPreferencesPrivate setters,
    /// called only where this WebKit has them.
    static let mock = Store.testing && ProcessInfo.processInfo.environment["SEARCH_SHARE_MOCK"] == "1"

    static func prepare(_ configuration: WKWebViewConfiguration) {
        guard mock else { return }
        let preferences = configuration.preferences
        for name in ["_setMockCaptureDevicesEnabled:", "_setMockCaptureDevicesPromptEnabled:"] {
            let selector = NSSelectorFromString(name)
            guard preferences.responds(to: selector) else { continue }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, true)
        }
    }
}
