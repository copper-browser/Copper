import SwiftUI
import WebKit

// Settings › Privacy › Clear browsing data. Upstream cleared one cookie jar
// — `Store.websites`, which is the jar of the space in front — so "Sign out
// of everything" left every other profile's space signed in, and History
// and Cookies went with one click and no way back. Here both ask first
// (Cache is harmless and stays one click), the question says what else goes
// (Copper Cloud's copy of history, while history syncs), and cookies and
// cache are cleared in every jar: the shared one and each space profile's.

/// What the Clear buttons are about to do, while their question is up.
@MainActor
final class PrivacyClear: ObservableObject {
    static let shared = PrivacyClear()

    enum Kind: String, CaseIterable { case history, cookies, cache }

    /// The question on screen (the bench can raise it for a picture).
    @Published var asking: Kind?

    /// Every cookie jar this Copper keeps: the shared one, then one per
    /// profile a space wears. A test world's are its own (`Store.probeStore`,
    /// `Spaces.store(forProfile:)` salted with the world).
    static var jars: [WKWebsiteDataStore] {
        let shared: WKWebsiteDataStore = Store.testing && !Store.ownContainer
            ? WKWebsiteDataStore(forIdentifier: Store.probeStore(1))
            : .default()
        return [shared] + Spaces.shared.profiles.map(Spaces.store(forProfile:))
    }

    /// The types removed from every jar, then `done` once, on the main actor.
    static func remove(_ types: Set<String>, done: @escaping @MainActor () -> Void) {
        let group = DispatchGroup()
        for jar in jars {
            group.enter()
            jar.removeData(ofTypes: types, modifiedSince: .distantPast) { group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done() } }
    }

    static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    /// History also goes from Copper Cloud while history syncs there.
    static var historyReachesCloud: Bool { CloudSync.shared.active(.history) }

    func title(_ kind: Kind) -> String {
        switch kind {
        case .history: return "Clear all history?"
        case .cookies: return "Sign out of every site?"
        case .cache: return "Clear the cache?"
        }
    }

    func message(_ kind: Kind) -> String {
        switch kind {
        case .history:
            return Self.historyReachesCloud
                ? "Every address you have been to goes from this Mac and from Copper Cloud, for every Mac signed in as you. This can't be undone."
                : "Every address you have been to goes from this Mac. Tabs, bookmarks and passwords stay. This can't be undone."
        case .cookies:
            let spaces = Spaces.shared.profiles.isEmpty ? "" : " — in every space and profile"
            return "Cookies and site data are deleted\(spaces), so every site asks you to sign in again. Saved passwords stay."
        case .cache:
            return "Pages load from the network again. Nothing you are signed in to changes."
        }
    }

    func confirm(_ kind: Kind, in browser: Browser) {
        asking = nil
        switch kind {
        case .history: browser.clearHistory()
        case .cookies: browser.clearSites()
        case .cache: browser.clearCache()
        }
    }
}

/// The three lines under Clear browsing data, each with its question.
struct ClearBrowsingDataLines: View {
    let browser: Browser
    @ObservedObject private var clear = PrivacyClear.shared

    var body: some View {
        Group {
            Line("History", "Every address you have been to") {
                Pill("Clear…") { clear.asking = .history }
                    .accessibilityLabel("Clear history")
            }
            .settingsAnchor("privacy.history")
            Rule()
            Line("Cookies and sign-ins", "Signs you out of every site, in every space") {
                Pill("Sign out of everything…") { clear.asking = .cookies }
            }
            .settingsAnchor("privacy.cookies")
            Rule()
            Line("Cache", "Only what was fetched to draw pages") {
                Pill("Clear") { browser.clearCache() }
                    .accessibilityLabel("Clear cache")
            }
            .settingsAnchor("privacy.cache")
        }
        .confirmationDialog(
            clear.asking.map(clear.title) ?? "",
            isPresented: Binding(get: { clear.asking != nil && clear.asking != .cache }, set: { if !$0 { clear.asking = nil } }),
            presenting: clear.asking
        ) { kind in
            Button(kind == .cookies ? "Sign Out of Everything" : "Clear History", role: .destructive) {
                clear.confirm(kind, in: browser)
            }
            Button("Cancel", role: .cancel) { clear.asking = nil }
        } message: { kind in
            Text(clear.message(kind))
        }
    }
}

/// `bench privacy …`: the questions raised for a picture, the clears made as
/// the confirmed buttons make them, and what each jar holds (hosts only).
@MainActor
enum PrivacyBench {
    static func handle(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "status"
        let word = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch op {
        case "status":
            return ["asking": PrivacyClear.shared.asking?.rawValue ?? NSNull(),
                    "jars": PrivacyClear.jars.count,
                    "profiles": Spaces.shared.profiles,
                    "shield": browser.prefs.shielded,
                    "historyReachesCloud": PrivacyClear.historyReachesCloud]
        case "ask":
            PrivacyClear.shared.asking = PrivacyClear.Kind(rawValue: word)
            return ["asking": PrivacyClear.shared.asking?.rawValue ?? NSNull()]
        case "clear":
            guard let kind = PrivacyClear.Kind(rawValue: word) else { return ["error": "privacy clear history|cookies|cache"] }
            PrivacyClear.shared.confirm(kind, in: browser)
            return ["cleared": kind.rawValue]
        case "capture": // Fork (page-capture): the camera and microphone desk — Fork/Capture/CaptureBench.swift
            return CaptureBench.handle(word, in: browser)
        default:
            return ["error": "privacy status|ask history|cookies|none|clear history|cookies|cache|capture …"]
        }
    }
}
