import Foundation
import Security
import WebKit

// The 1Password browser extension's two ways in, made reachable in Copper.
//
// 1. Signing the extension in by itself (email, Secret Key, password). Its
//    own Start setup → Sign in opens https://my.1password.com/signin?auth-only=1;
//    the web app there hands the account to the extension's content script
//    (a `B5SignInSucceeded` DOM event → runtime.sendMessage
//    "sign-in-succeeded"), and the extension's worker signs in with it and
//    unlocks itself from then on with the account password. That works in
//    Copper (docs/fixtures/onepassword-e2e.sh drives it as far as 1Password's
//    servers without an account); this file only gives it a button.
//
// 2. The desktop app (Touch ID). 1Password's BrowserSupport host checks the
//    browser that started it: one it knows by signature connects at once;
//    any other signed app in /Applications is held while it waits for a
//    "partner browser authorization" from the extension (BrowserSupport's
//    log: "waiting for potential partner browser authorization from B5X").
//    The extension asks for that only from its welcome page, and only for
//    the browsers in its own list — Copper isn't one, so it never asked and
//    the extension never connected. Its own message for it is
//    "authorize-browser"; sent from one of the extension's pages, BrowserSupport
//    asks the 1Password app, which shows its own Allow prompt and remembers
//    the answer (1Password › Settings › Browser). An ad-hoc-signed build
//    (./build.sh without a certificate) is refused before that: "parent
//    browser was not valid".

@available(macOS 15.4, *)
@MainActor
final class OnePasswordExtension: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = OnePasswordExtension()

    /// 1Password's Chromium extensions — the ids its native host lists.
    static let ids: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // stable
        "khgocmkkpikpnmmkgmdnfckapcdkgfaf", // beta
        "gejiddohjgogedgjnonbofjigllpkmbf", // nightly
        "hjlinigoblmkhjejkmbegnoaljkphmgo",
        "bkpbhnjcbehoklfkljkkbbmipaphipgl",
        "dppgmdbiimibapkepcbdbmkaabgiofem", // Edge
    ]

    /// The extension's own sign-in page, the one its Start setup opens.
    static let signInPage = URL(string: "https://my.1password.com/signin?auth-only=1")!

    enum Asking: Equatable {
        case idle
        case asking
        case allowed
        case refused(String)
    }
    @Published private(set) var asking: Asking = .idle

    /// The page the question is asked from, while it is asked.
    private var page: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?

    /// Opens the page that signs the extension in.
    func signIn(in browser: Browser) {
        browser.open(Self.signInPage, foreground: true)
    }

    /// Asks the 1Password app to let Copper connect, through the extension.
    func connect(_ id: String) {
        guard asking != .asking else { return }
        guard let context = Extensions.shared.context(id), // Fork (ardia profiles): the profile in front's
              let url = URL(string: "credits.html", relativeTo: context.baseURL) else {
            asking = .refused("The 1Password extension isn't on")
            return
        }
        asking = .asking
        Task { asking = await ask(from: url, configuration: context.webViewConfiguration) }
    }

    private func ask(from url: URL, configuration: WKWebViewConfiguration?) async -> Asking {
        guard let configuration else { return .refused("The 1Password extension isn't on") }
        // One of the extension's own pages, never shown: its runtime is the
        // extension's, so the worker takes the message as its own page's.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        web.navigationDelegate = self
        page = web
        defer { page = nil }
        let ready = await withCheckedContinuation { done in
            loaded = done
            web.load(URLRequest(url: url))
        }
        guard ready else { return .refused("The extension's page didn't open") }
        // 1Password waits for the person at the Mac to answer its prompt.
        let script = """
            const answer = await Promise.race([
              chrome.runtime.sendMessage({ name: "authorize-browser", data: null }),
              new Promise((done) => setTimeout(() => done({ type: "Timeout" }), 180000)),
            ]);
            return JSON.stringify(answer ?? null);
            """
        do {
            let raw = try await web.callAsyncJavaScript(script, contentWorld: .page) as? String ?? "null"
            let answer = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            if answer?["type"] as? String == "Timeout" { return .refused("1Password didn't answer in three minutes") }
            let data = answer?["data"] as? [String: Any]
            if data?["authorized"] as? Bool == true { return .allowed }
            return .refused(Self.whyNot ?? Self.refusal)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// What 1Password's helper turns away before it asks anyone: a browser
    /// outside /Applications, or one signed ad hoc (a local ./build.sh).
    static var whyNot: String? {
        let bundle = Bundle.main.bundleURL
        if !bundle.path.hasPrefix("/Applications/") {
            return "1Password only lets a browser in /Applications connect — this \(Fork.name) runs from \(bundle.deletingLastPathComponent().path)"
        }
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let facts = info as? [String: Any] else { return nil }
        let flags = (facts[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || facts[kSecCodeInfoCertificates as String] == nil {
            return "This \(Fork.name) build isn't signed with a certificate, and 1Password won't consider it — use a release build, or sign the extension in by itself"
        }
        return nil
    }

    /// What a "no" usually means; 1Password doesn't say which it was.
    static let refusal = "1Password didn't allow Copper. Check that Copper is in Applications, 1Password is unlocked with Touch ID (Settings › Security), and Settings › Browser › Connect with 1Password in the browser is on — then try again, or sign the extension in by itself"

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(false) }
    }

    private func finishLoad(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    /// `bench ext-manager onepassword [connect ID|signin]`.
    func bench(_ words: [String], in browser: Browser) -> [String: Any] {
        switch words.first ?? "status" {
        case "connect":
            connect(words.count > 1 ? words[1] : "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        case "signin":
            signIn(in: browser)
        case "status":
            break
        default:
            return ["error": "ext-manager onepassword [connect ID|signin|status]"]
        }
        let state: String
        var detail = ""
        switch asking {
        case .idle: state = "idle"
        case .asking: state = "asking"
        case .allowed: state = "allowed"
        case .refused(let why): state = "refused"; detail = why
        }
        return ["onepassword": state, "detail": detail]
    }
}
