import Foundation
import WebKit

// Where an extension's own pages may go, and which tabs extensions see.
//
// An extension's page — its popup, a page it opened in a tab — is a web view
// built from `WKWebExtensionContext.webViewConfiguration`, and WebKit binds
// that configuration to the extension (`_requiredWebExtensionBaseURL`): a
// main-frame load anywhere else is dropped *after* the navigation delegate
// allowed it, with nothing said. Chrome lets the page go. So 1Password's
// Start setup page, whose Sign in does `window.location.href =
// "https://start.1password.com/signin/…"`, did nothing at all — no tab, no
// load, no error (its Create your account goes to 1password.com the same
// way). Such a load is handed to a web view that can show it instead: the
// tab becomes an ordinary tab at that address, a window it opens is an
// ordinary tab, and the popup opens it in a tab and closes, as a link in it
// already did.

@MainActor
enum ExtensionPages {
    /// The extension a view's configuration is bound to, if any.
    static func boundBase(of web: WKWebView) -> URL? {
        let configuration = web.configuration
        let key = "_requiredWebExtensionBaseURL"
        guard configuration.responds(to: NSSelectorFromString(key)) else { return nil }
        return configuration.value(forKey: key) as? URL
    }

    /// A main-frame load WebKit would drop in this view: a web address (or
    /// another extension's page) from a view bound to an extension. Anything
    /// else WebKit decides as it always did.
    static func refuses(_ url: URL, in web: WKWebView) -> Bool {
        guard #available(macOS 15.4, *), let base = boundBase(of: web), let scheme = url.scheme?.lowercased() else { return false }
        let elsewhere = scheme != base.scheme?.lowercased()
            || url.host()?.lowercased() != base.host()?.lowercased()
            || url.port != base.port
        guard elsewhere else { return false }
        return ["http", "https"].contains(scheme) || scheme == Extensions.scheme
    }

    /// The navigation hook (Browser.decidePolicyFor): an extension's page in
    /// a tab going somewhere its view can't — the tab is rebuilt at that
    /// address, in the same place in the row. True when it was taken.
    static func leave(_ action: WKNavigationAction, url: URL, in web: WKWebView, browser: Browser) -> Bool {
        guard action.targetFrame?.isMainFrame == true, refuses(url, in: web) else { return false }
        if let tab = browser.tabs.first(where: { $0.built === web }) {
            browser.replaceBlank(tab, with: url)
        } else {
            browser.open(url, foreground: true)
        }
        return true
    }

    /// The new-window hook (Browser.createWebViewWith): a window an
    /// extension's page opens at a web address can't be a view made from its
    /// configuration (WebKit hands that one over, and it is bound), so it is
    /// an ordinary tab. True when it was taken — the caller returns nil.
    static func popup(_ action: WKNavigationAction, from web: WKWebView, browser: Browser) -> Bool {
        guard let url = action.request.url, refuses(url, in: web) else { return false }
        // Behind, as Browser.createWebViewWith leaves a ⌘- or middle-clicked one.
        let flags = action.modifierFlags
        let behind = MouseButtons.isMiddle(action) || (flags.contains(.command) && !flags.contains(.shift))
        browser.open(url, foreground: !behind)
        return true
    }

    /// The popup's hook (ExtensionPopup's navigation delegate): a popup
    /// sending itself to a web address opens it in a tab, in front, and
    /// closes — the way a link with a target already did.
    static func leavePopup(_ action: WKNavigationAction, in web: WKWebView) -> Bool {
        guard #available(macOS 15.4, *), let url = action.request.url, action.targetFrame?.isMainFrame == true, refuses(url, in: web),
              let browser = Extensions.shared.browser else { return false }
        browser.open(url, foreground: true)
        ExtensionPopup.shared.close()
        return true
    }

    // MARK: - the tabs extensions see

    /// Every tab in every space, pins first, then each space's row in the
    /// order the spaces are in — not just the space on screen. A tab in
    /// another space is still open, its page still running its content
    /// scripts; told closed whenever its space was left, it was a tab WebKit
    /// no longer knew, and every message from those scripts failed with
    /// "Tab not found" (1Password's runtime.sendMessage and
    /// scripting.executeScript, listed among its errors). Arc shows an
    /// extension every space's tabs the same way. Private tabs stay out.
    static func every(in browser: Browser?) -> [Tab] {
        let spaces = Spaces.shared
        var seen = Set<Tab.ID>()
        var list: [Tab] = []
        for tab in spaces.pins + spaces.all.flatMap({ spaces.row($0.id) }) + (browser?.tabs ?? [])
        where !tab.shy && seen.insert(tab.id).inserted {
            list.append(tab)
        }
        return list
    }
}
