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

    /// SEARCH_SHARE_MOCK=1, test worlds only — the camera and microphone's
    /// `capture.mock` by another name: Web.configuration's
    /// CapturePreferences.configure turns WebKit's stand-ins on for either.
    static var mock: Bool { CapturePreferences.mock }
}
