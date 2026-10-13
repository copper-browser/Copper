import AppKit
import WebKit

// Pointer lock: a page asking for the mouse — `element.requestPointerLock()`,
// which is how first-person 3D views, games and model viewers on the web turn
// the camera as the mouse moves (three.js `PointerLockControls` and the like).
//
// WebKit hands the request to the web view's UI delegate and, when the
// delegate has no answer for it, says no: the page gets `pointerlockerror`,
// the pointer stays free, and moving the mouse turns nothing. Copper had no
// answer, so mouse-look worked in Safari and Chrome and never here (#52). This
// is the answer, through the SPI Safari and WebKit's MiniBrowser use. The
// older `_webViewRequestPointerLock:` is the one *not* to implement: WebKit
// asks that one first when it is there, and then denies regardless.
//
// WebKit has already checked the page by the time it asks: the request came
// in a click or a key press, and the view is visible and first responder. It
// also lets go by itself — Escape, the window or the app losing focus, the
// page navigating or going away. What it does not know is whether a person is
// at that window, and a granted lock is not the page's alone: it hides the
// cursor and parts it from the mouse for the whole Mac (`CGDisplayHideCursor`,
// `CGAssociateMouseAndMouseCursorPosition`). So only a page in the real key
// window of the app in front gets one — never a tab an agent works in
// backstage (whose window says it is key without being it, Backstage.Window),
// and never a headless Copper.

extension Browser {
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func webView(_ webView: WKWebView, didRequestPointerLock decide: @escaping (Bool) -> Void) {
        let verdict = PointerLock.verdict(for: webView)
        Breadcrumbs.note("pointer-lock", [("result", verdict.rawValue)])
        PointerLock.last = verdict
        guard verdict == .granted else { return decide(false) }
        decide(true)
        PointerLock.hint(on: webView)
    }

    @objc(_webViewDidLosePointerLock:)
    func webViewDidLosePointerLock(_ webView: WKWebView) {
        PointerLock.unhint(webView)
    }
}

@MainActor
enum PointerLock {
    enum Verdict: String {
        case granted
        /// A headless Copper: nobody is at its windows.
        case headless
        /// The page's view is in no window.
        case windowless
        /// A tab an agent works in, hung off screen.
        case backstage
        /// Copper is not the app in front.
        case inactive
        /// Another window has the keyboard.
        case notKey = "not-key"
    }

    /// The last answer given, for the bench and a crash report's "before".
    static var last: Verdict?

    static func verdict(for webView: WKWebView) -> Verdict {
        let window = webView.window
        return verdict(
            headless: Headless.on,
            hasWindow: window != nil,
            backstage: window is Backstage.Window,
            appActive: NSApp.isActive,
            isKey: window != nil && NSApp.keyWindow === window
        )
    }

    /// The rule, apart from AppKit so it can be tested. `isKey` is AppKit's
    /// own key window, not the window's say-so: Backstage.Window answers
    /// `isKeyWindow` true without ever being key.
    nonisolated static func verdict(headless: Bool, hasWindow: Bool, backstage: Bool, appActive: Bool, isKey: Bool) -> Verdict {
        if headless { return .headless }
        guard hasWindow else { return .windowless }
        if backstage { return .backstage }
        guard appActive else { return .inactive }
        guard isKey else { return .notKey }
        return .granted
    }

    // MARK: - the hint

    static let message = "Press Esc to show your pointer"

    /// Said once over the page when the pointer goes, as Safari and Chrome
    /// do: a hidden pointer with no word about it reads as a dead mouse.
    static func hint(on webView: WKWebView) {
        unhint(webView)
        let hint = Hint(message)
        webView.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            hint.topAnchor.constraint(equalTo: webView.topAnchor, constant: 16),
        ])
        hint.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hint.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak hint] in hint?.dismiss() }
        NSAccessibility.post(
            element: webView,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// The lock is gone (Escape, a switch away): so is anything about it.
    static func unhint(_ webView: WKWebView) {
        for case let hint as Hint in webView.subviews { hint.dismiss() }
    }

    /// A small dark pill with one line on it. Never in the way of the page:
    /// it takes no clicks.
    final class Hint: NSView {
        private var leaving = false

        init(_ text: String) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
            layer?.cornerRadius = 8
            setAccessibilityElement(false)

            let label = NSTextField(labelWithString: text)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func dismiss() {
            guard !leaving else { return }
            leaving = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.removeFromSuperview()
            })
        }
    }
}
