import AppKit
import WebKit

// Fork (sites): what a page reads as its window — `window.outerWidth`,
// `outerHeight`, `screenX`, `screenY`.
//
// WebKit asks the web view's UI delegate for that frame (WKUIDelegatePrivate)
// and, with no answer, tells the page 0×0 at 0,0. In Safari it is the window
// the page is in. Bot checks read "0×0 and focused" as a headless browser —
// FingerprintJS BotD's windowSize rule, which PyPI's Fastly Client Challenge
// runs before it decides whether to show a CAPTCHA. So every focused Copper
// tab, and every tab an agent works in (Backstage says it is key), looked like
// a headless Chrome there and nowhere in Safari. The answer is the window a
// person sees the tab in: its own, or for a tab off stage (in the background,
// or hung backstage for an agent) its browser's — as a background tab in
// Safari reports the window it belongs to.

extension Browser {
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrame reply: @escaping (CGRect) -> Void) {
        let page = webView.window
        reply(WindowFrame.frame(page: page.flatMap { $0 is Backstage.Window ? nil : $0.frame },
                                browser: Windows.window(of: self)?.frame,
                                screen: NSScreen.main?.visibleFrame))
    }
}

enum WindowFrame {
    /// The page's own window if it is on a stage, else its browser's, else
    /// the screen's usable part: never the empty frame WebKit would say.
    static func frame(page: CGRect?, browser: CGRect?, screen: CGRect?) -> CGRect {
        for frame in [page, browser, screen] {
            if let frame, frame.width > 0, frame.height > 0 { return frame }
        }
        return CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
