import Foundation
import WebKit

// An extension's background, from the bench: what its worker sees.
//
// The worker is the one part of an extension nobody can look at — no tab,
// no popup — and its content security policy forbids `eval`, so an
// extension page can't ask it to run anything either. WebKit keeps it in a
// web view of its own (`_backgroundWebView`, the SPI Safari's Web Inspector
// uses to reach it); JavaScript evaluated there by the app runs in the
// worker's global scope, past the policy, as Web Inspector's console does.
// Kept to the bench of a test world, and to one defensive lookup, so a
// WebKit without the SPI just answers that it can't.

@available(macOS 15.4, *)
@MainActor
enum ExtensionWorker {
    static func view(of context: WKWebExtensionContext) -> WKWebView? {
        let key = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: key) else { return nil }
        return context.value(forKey: "_backgroundWebView") as? WKWebView
    }

    /// `bench ext-worker ID JS` — `JS` is an async function body: `return`
    /// what to hear back (JSON-able), `await` freely. Starts the background
    /// first when WebKit has let it go.
    static func bench(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "only in a test world"]); return }
        guard let id = request["id"] as? String, let context = Extensions.shared.context(id) else {
            answer(["error": "no such extension loaded"])
            return
        }
        let js = request["js"] as? String ?? "return typeof self"
        let run = {
            guard let web = view(of: context) else { answer(["error": "this WebKit doesn't show the background"]); return }
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): answer(["value": Bench.plain(value), "url": web.url?.absoluteString ?? ""])
                case .failure(let error): answer(["error": (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription])
                }
            }
        }
        if view(of: context) != nil { run(); return }
        context.loadBackgroundContent { error in
            MainActor.assumeIsolated {
                if let error { answer(["error": "background didn't load: \(error.localizedDescription)"]); return }
                run()
            }
        }
    }
}
