import AppKit
import WebKit

// Live web frames: a link on the board with `live: true` shows its site in an
// <iframe> (canvas-app src/canvas/frames.ts, components/WebFrame.tsx). The page
// draws the frame and syncs where it is; Copper does the parts a page can't:
//
// - Embedding. The board is a file:// page, so every site in a frame is
//   cross-site, and the ones that send X-Frame-Options or a frame-ancestors
//   policy (GitHub, Google, most sign-in pages) are refused outright. The
//   board's own view — and only it — sets WebKit's private feature
//   `IgnoreIframeEmbeddingProtectionsEnabled`, which lets them load. It is a
//   WKPreferences of the board's configuration alone; no tab has it, and a
//   popup from a frame never gets the board's configuration (`popup`).
// - Cookies. The board uses the store of the space it was built in
//   (Store.websites, which knows the space's profile), so a frame carries the
//   same session as a tab in that space — what WebKit lets a cross-site frame
//   carry, which is SameSite=None and unset cookies; Lax and Strict never go
//   to a frame under a file:// page, and the knob that would change that is
//   store-wide (docs/canvas.md, "Live web frames").
// - Reports. A frame is another site's document; the board can't read where
//   it went. A user script in every subframe — in a content world of its own,
//   out of the site's reach — says where the frame is, its title and icon,
//   Escape pressed and not used, and a page that hid itself, to its own
//   handler (`copperFrame`); the host hands each to the page with
//   `copperCanvas.frameEvent`, named by the iframe's `window.name`.
// - Popups. "Sign in with…" windows and target=_blank links from a frame
//   open as ordinary tabs (`popup`, and CanvasHost.decide for links).

extension CanvasHost {
    static let frameHandler = "copperFrame"
    static let frameWorld = WKContentWorld.world(name: "CopperCanvasFrames")

    /// The board's view only: sites that refuse to be framed load anyway.
    /// Private API, so asked for only when this WebKit has it; without it a
    /// refusing site shows the page's "doesn't allow embedding" card.
    static func allowEmbedding(_ preferences: WKPreferences) {
        let list = NSSelectorFromString("_features")
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: list), preferences.responds(to: set),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: { ($0.value(forKey: "key") as? String) == "IgnoreIframeEmbeddingProtectionsEnabled" })
        else {
            log.notice("frames: no IgnoreIframeEmbeddingProtectionsEnabled in this WebKit; sites that refuse embedding stay refused")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, true, feature)
    }

    /// Whether this view's preferences let refusing sites be framed (the bench asks).
    static func embeddingAllowed(_ web: WKWebView) -> Bool? {
        let list = NSSelectorFromString("_features")
        let get = NSSelectorFromString("_isEnabledForFeature:")
        let preferences = web.configuration.preferences
        guard (WKPreferences.self as AnyObject).responds(to: list), preferences.responds(to: get),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: { ($0.value(forKey: "key") as? String) == "IgnoreIframeEmbeddingProtectionsEnabled" })
        else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(preferences.method(for: get), to: Getter.self)(preferences, get, feature)
    }

    /// The frame handler on a board's controller (configuration, attach).
    static func addFrameHandler(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: frameHandler, contentWorld: frameWorld)
        controller.add(CanvasFrameRelay.shared, contentWorld: frameWorld, name: frameHandler)
    }

    static func removeFrameHandler(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: frameHandler, contentWorld: frameWorld)
    }

    /// The reporter, for CanvasHost.arm: every subframe, its own world.
    static var frameScript: WKUserScript {
        WKUserScript(source: frameReporter, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: frameWorld)
    }

    /// A window a frame on the board asked for (window.open, a form with a
    /// target): an ordinary tab, never a view built from the board's
    /// configuration — that would be a board without a canvas, with the
    /// board's preferences and handlers. True: handled, make no view. The
    /// opener link is lost; a sign-in finished in the tab is picked up when
    /// the frame reloads (the page reloads one whose Sign in was pressed).
    static func popup(_ action: WKNavigationAction, from web: WKWebView, browser: Browser) -> Bool {
        guard isBoard(web) else { return false }
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            browser.open(url, foreground: true)
        }
        return true
    }

    /// A frame's report, checked by the relay: on to the page.
    func frameEvent(_ event: [String: Any]) {
        frameEvents.append(event)
        if frameEvents.count > 40 { frameEvents.removeFirst(frameEvents.count - 40) }
        guard isReady, let web = tab?.built else { return }
        web.callAsyncJavaScript("const c = window.copperCanvas; return !!(c && typeof c.frameEvent === 'function' && c.frameEvent(e));",
                                arguments: ["e": event], in: nil, in: .page, completionHandler: nil)
    }

    /// After init: the page knows silence from a frame means it didn't load.
    func tellFrameHost() {
        guard let web = tab?.built else { return }
        let reports = web.board
        web.callAsyncJavaScript("const c = window.copperCanvas; if (c && typeof c.frameHost === 'function') c.frameHost(f);",
                                arguments: ["f": ["reports": reports]], in: nil, in: .page, completionHandler: nil)
    }

    /// Says where it is, what it is called, and when Escape went unused —
    /// from a frame directly on the board only (not the site's own frames),
    /// and only one whose name the board gave it. Runs before the site's own
    /// scripts, so the name it reads is the board's, not one the site set.
    static let frameReporter = """
    (function () {
      if (window === window.top) return;
      var direct = false;
      try { direct = window.parent === window.top; } catch (_) {}
      if (!direct) return;
      var name = String(window.name || '');
      if (name.indexOf('copper-frame:') !== 0 || name.length > 200) return;
      if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(frameHandler);
      if (!handler) return;
      function post(message) {
        message.name = name;
        try { handler.postMessage(message); } catch (_) {}
      }
      function icon() {
        var links = document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel~="apple-touch-icon"]');
        var touch = '';
        for (var i = 0; i < links.length; i++) {
          var href = links[i].href || '';
          if (!/^https:/i.test(href) || href.length > 2048) continue;
          if (/apple-touch-icon/i.test(links[i].rel)) { touch = touch || href; continue; }
          return href;
        }
        if (touch) return touch;
        return location.protocol === 'https:' ? location.origin + '/favicon.ico' : '';
      }
      var last = '';
      function report() {
        var url = location.href;
        var title = String(document.title || '').slice(0, 500);
        var ic = document.head ? icon() : '';
        var key = url + '\\n' + title + '\\n' + ic;
        if (key === last) return;
        last = key;
        post({ kind: 'nav', url: url, title: title, icon: ic });
      }
      document.addEventListener('DOMContentLoaded', report);
      window.addEventListener('load', report);
      window.addEventListener('popstate', report);
      window.addEventListener('hashchange', report);
      if (window.navigation && typeof window.navigation.addEventListener === 'function') {
        window.navigation.addEventListener('navigatesuccess', function () { setTimeout(report, 0); });
      }
      // An app that changes its address or title without either event.
      setInterval(function () { if (document.visibilityState === 'visible') report(); }, 1000);
      window.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape' || e.isComposing) return;
        var full = !!(document.fullscreenElement || document.webkitFullscreenElement);
        setTimeout(function () { if (!e.defaultPrevented && !full) post({ kind: 'escape' }); }, 0);
      });
      // A page that hides itself when it finds it is framed.
      function hidden(el) {
        if (!el) return false;
        var s = getComputedStyle(el);
        return s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0;
      }
      window.addEventListener('load', function () {
        setTimeout(function () {
          if (!(hidden(document.documentElement) || hidden(document.body))) return;
          setTimeout(function () {
            if (hidden(document.documentElement) || hidden(document.body)) post({ kind: 'blank', url: location.href });
          }, 1500);
        }, 3000);
      });
    })();
    """
}

/// The `copperFrame` handler every board shares, in the frames' own content
/// world (a site's scripts can't reach it). It answers only subframes of a
/// board's own page, and passes on only what the page's parser takes.
final class CanvasFrameRelay: NSObject, WKScriptMessageHandler {
    static let shared = CanvasFrameRelay()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard !message.frameInfo.isMainFrame, let web = message.webView,
                  CanvasHost.isBoard(web), CanvasPage.isPage(web.url),
                  let host = CanvasHost.host(showing: web),
                  let event = Self.event(message.body, origin: message.frameInfo.securityOrigin)
            else { return }
            host.frameEvent(event)
        }
    }

    /// The report, checked: a board-given name, a known kind, and an address
    /// on the origin WebKit says the frame is on.
    static func event(_ raw: Any, origin: WKSecurityOrigin) -> [String: Any]? {
        guard let body = raw as? [String: Any],
              let name = body["name"] as? String, name.hasPrefix("copper-frame:"), name.count <= 200,
              let kind = body["kind"] as? String
        else { return nil }
        if kind == "escape" { return ["name": name, "kind": kind] }
        guard kind == "nav" || kind == "blank",
              let text = body["url"] as? String, text.count <= 4096, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              scheme == origin.protocol.lowercased(), url.host?.lowercased() == origin.host.lowercased()
        else { return nil }
        var event: [String: Any] = ["name": name, "kind": kind, "url": text]
        if kind == "nav" {
            event["title"] = String((body["title"] as? String ?? "").prefix(500))
            if let icon = body["icon"] as? String, icon.count <= 2048, icon.lowercased().hasPrefix("https://") { event["icon"] = icon }
        }
        return event
    }
}
