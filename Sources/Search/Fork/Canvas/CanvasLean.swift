import AppKit
import WebKit

// What a canvas tab is spared.
//
// Every tab is built for the open web: a reporter for the scroll position, the
// hide-something picker, a sign-in watcher with a MutationObserver over the
// whole document, a scroll and click listener in the capture phase, the image
// menu, the Chrome Web Store mender, the passkey shim, the ad blocker's rule
// list, and — on every trackpad event — the back/forward swipe: the disc, a
// sideways tracker, and a script in every frame that walks up from the
// pointer through getComputedStyle on each sideways wheel event to say
// whether something under it scrolls. A canvas is Copper's own page. It has
// no sign-in, no ads, no store, and its two-finger pan is the board's, never
// Back. So a canvas tab gets none of that:
//
// - `dress` (Tab.build, once the handlers are on): no pinch magnification
//   (the board zooms itself, on gesture events and ⌘/ctrl-wheel), the
//   scroll/veil/image/store/passkey handlers off, no content rule list, and
//   the view marked as a board.
// - `arm` (Tab.arm(hiding:), every time a tab is re-armed): every user script
//   off, and one small one in their place that says whether the caret is in
//   something that takes typing — the one thing the sign-in watcher told
//   Copper that a board needs, since Tab belongs to Copper unless it is —
//   and the live web frames' reporter (CanvasFrames), in subframes only.
// - `PageView.boardScroll` (PageView.scrollWheel): the event to WebKit and
//   nothing else — no swipe tracking, no ask, no disc. Only the first event
//   of a gesture counts as touching the page.
//
// What stays: the `canvas` message handler (CanvasRelay, on the
// configuration since before the view existed — it is a handler, not a user
// script, so `arm` never touches it) and everything CanvasHost says to the
// page (callAsyncJavaScript), the title/address/progress observers, sleep
// after half an hour and the picture it wakes behind, the first-frame fade,
// the audio watch. Only the defaults key `canvas.lean` (NO) turns this off,
// for the bench's before-and-after.

extension CanvasHost {
    /// Read once, at launch. `defaults write <domain> canvas.lean -bool NO`
    /// builds canvas tabs the way every other tab is built, for comparison.
    static let lean: Bool = Store.settings.object(forKey: "canvas.lean") as? Bool ?? true

    /// Tab.build(), after its handlers are added: a canvas's view keeps only
    /// what a board uses. Any other view is left alone.
    static func dress(_ web: PageView) {
        guard isBoard(web) else { return }
        // The board zooms itself; WebKit's pinch would magnify the toolbar with it.
        web.allowsMagnification = false
        guard lean else { return }
        web.board = true
        let controller = web.configuration.userContentController
        for name in [ScrollRelay.name, VeilRelay.name, ImageRelay.name, StoreRelay.name] {
            controller.removeScriptMessageHandler(forName: name)
        }
        controller.removeScriptMessageHandler(forName: Passkeys.name, contentWorld: .page)
        // Nothing third-party loads on the board itself, and the blocker's
        // cosmetic rules are a stylesheet matched on every style pass. (A
        // live web frame is a site's own page, shown unblocked: CanvasFrames.)
        controller.removeAllContentRuleLists()
        Shield.shared.forget(controller) // Fork (navperf)
    }

    /// Tab.arm(hiding:): true when this is a board, armed here instead.
    static func arm(_ web: PageView) -> Bool {
        guard web.board else { return false }
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        Shield.shared.forget(controller) // Fork (navperf): its next tune puts the list back as before
        // In Copper's own world: the forms handler it tells is heard from there only (Fork/MCP/Frames.swift).
        controller.addUserScript(WKUserScript(source: typing, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .copper))
        // Live web frames say where they are (CanvasFrames), from their own world.
        controller.addUserScript(frameScript)
        return true
    }

    /// Whether the caret is in something that takes typing — a sticky's
    /// editor, a frame's title, the search field — said on focus changes
    /// only, to the same handler (FormRelay's `focus`) every page's sign-in
    /// watcher uses.
    static let typing = """
    (function () {
      if (window.__copperBoardKeys) return;
      window.__copperBoardKeys = true;
      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toLowerCase();
        if (tag === 'textarea' || el.isContentEditable === true) return true;
        if (tag !== 'input') return false;
        var kind = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number'].indexOf(kind) >= 0;
      }
      var was = null;
      function tell() {
        var now = editable(document.activeElement);
        if (now === was) return;
        was = now;
        window.webkit.messageHandlers.\(FormRelay.name).postMessage({ kind: 'focus', typing: now, rect: null, field: null, hint: '' });
      }
      document.addEventListener('focusin', tell, true);
      document.addEventListener('focusout', function () { setTimeout(tell, 0); }, true);
    })();
    """
}

extension PageView {
    /// PageView.scrollWheel for a board: WebKit gets the event, and that is
    /// all. A canvas tab's back list is the board alone, so there is never a
    /// swipe to read; the two-finger pan, the ⌘-wheel zoom and the pinch are
    /// the board's.
    func boardScroll(_ event: NSEvent) {
        if event.momentumPhase == [], event.phase == .began || event.phase == .mayBegin { onTouch?() }
        super.scrollWheel(with: event)
    }
}
