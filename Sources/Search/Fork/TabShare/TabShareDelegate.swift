import WebKit

// WebKit's private question for a page that wants a window or the screen
// (WKUIDelegatePrivate.h):
//
//   - (void)_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:
//            withSystemAudio:decisionHandler:(void (^)(WKDisplayCapturePermissionDecision))
//
//   WKDisplayCapturePermissionDecisionDeny = 0          → the page gets NotAllowedError
//   WKDisplayCapturePermissionDecisionScreenPrompt = 1  → the system picker, for a screen
//   WKDisplayCapturePermissionDecisionWindowPrompt = 2  → the system picker, for a window
//
// UIDelegate.mm asks `respondsToSelector:` for exactly this selector before a
// display request; with no answer it shows the system picker on its own (and
// before WebKit's fix for bug 274896, May 2024, it sent screen sharing down
// the camera path: "wants to use your camera"). Answering it is what puts
// Copper's own picker — tabs first — in front of the page. Browser is the WKUIDelegate of
// every tab and an NSObject, so an @objc method in an extension is enough;
// the public camera and microphone method in Browser.swift is not involved.
extension Browser {
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func tabShareRequest(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                         decisionHandler: @escaping (Int) -> Void) {
        TabShare.shared.request(from: webView, origin: origin, frame: frame, systemAudio: systemAudio,
                                in: self, decide: decisionHandler)
    }
}
