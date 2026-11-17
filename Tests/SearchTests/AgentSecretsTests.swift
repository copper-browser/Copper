import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

// Fork (secret-redact): conformance tests for "a secret Copper filled never
// reads back out to an agent". A sign-in page that copies the password
// everywhere it can — a visible div, the console, a global, the title, an
// address, JSON — is filled the way browser_sign_in fills it, then read the
// way every agent tool reads it; no answer may hold the secret in any
// encoding, and each must show the placeholder instead. The two layers are
// also proven apart: the page readers' structure rule without any remembered
// secret, and the scrubber on text no structure rule could see.

private typealias U = Tools.Ultrafast
private let P = AgentSecrets.placeholder

/// A secret no other test uses, with characters every encoding treats differently.
private func freshSecret() -> String { "Zq7/" + String(UUID().uuidString.prefix(8)) + " ä\"&<x>%+" }

/// Every way `secret` could be written in an answer: as Copper's scrubber
/// knows it, and as Foundation and the page would encode it themselves.
private func encodings(of secret: String) -> [String] {
    let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    let jsComponent = secret.addingPercentEncoding(withAllowedCharacters: ascii.union(CharacterSet(charactersIn: "-_.!~*'()")))!
    let json = String(data: try! JSONSerialization.data(withJSONObject: [secret], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst(2).dropLast(2)
    return AgentSecrets.variants(of: secret) + [jsComponent, String(json), secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!]
}

/// The encodings of `secret` found in `text` (empty: no leak).
private func leaks(_ text: String, _ secret: String) -> [String] { encodings(of: secret).filter { text.contains($0) } }

/// An answer as an agent gets it: through the one exit every tool's answer takes (Tools.call).
@MainActor private func delivered(_ text: String) -> String {
    AgentSecrets.outgoing([.text(text)]).compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
}

// MARK: - the scrubber

@Suite("AgentSecrets scrubber")
struct AgentSecretsScrubberTests {
    @Test("Raw, JSON, double-JSON, URL-encoded and HTML forms all become the placeholder")
    func everyEncoding() throws {
        let tab = UUID(), secret = freshSecret()
        AgentSecrets.remember(secret, tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        let jsonObject = String(data: try JSONSerialization.data(withJSONObject: ["password": secret]), encoding: .utf8)!
        let jsJSON = String(data: try JSONSerialization.data(withJSONObject: ["password": secret], options: [.withoutEscapingSlashes]), encoding: .utf8)!
        let doubled = String(data: try JSONSerialization.data(withJSONObject: [jsJSON], options: [.withoutEscapingSlashes]), encoding: .utf8)!
        var query = URLComponents(string: "https://x.test/collect")!
        query.queryItems = [URLQueryItem(name: "pw", value: secret)]
        let text = [secret, jsonObject, jsJSON, doubled, query.string!, encodings(of: secret).joined(separator: " | ")].joined(separator: "\n")
        #expect(!leaks(text, secret).isEmpty)
        let clean = AgentSecrets.scrub(text)
        #expect(leaks(clean, secret).isEmpty)
        #expect(clean.contains(P))
        #expect(AgentSecrets.count(tab: tab) == 1)
    }

    @Test("Digits-only secrets go only where they stand alone")
    func digits() {
        let tab = UUID()
        let otp = String(format: "%06d", Int.random(in: 100_000...999_999))
        let card = "4" + (0..<15).map { _ in String(Int.random(in: 0...9)) }.joined()
        AgentSecrets.remember(otp, tab: tab)
        AgentSecrets.remember(card, tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        #expect(AgentSecrets.scrub("code: \(otp).") == "code: \(P).")
        #expect(AgentSecrets.scrub("ref e\(otp) and 9\(otp)9") == "ref e\(otp) and 9\(otp)9")
        let grouped = stride(from: 0, to: 16, by: 4).map { i in String(Array(card)[i..<i + 4]) }
        let shown = AgentSecrets.scrub("[\(card)] \(grouped.joined(separator: " ")) \(grouped.joined(separator: "-"))")
        #expect(!shown.contains(card) && !shown.contains(grouped.joined(separator: " ")) && !shown.contains(grouped.joined(separator: "-")))
    }

    @Test("A three-character value is too short to hunt for in text")
    func tooShort() {
        let tab = UUID()
        AgentSecrets.remember("q7!", tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        #expect(AgentSecrets.scrub("q7! stays") == "q7! stays")
    }

    @Test("The secret set dies with the tab")
    func diesWithTab() {
        let tab = UUID(), secret = freshSecret()
        AgentSecrets.remember(secret, tab: tab)
        #expect(AgentSecrets.scrub(secret) == P)
        AgentSecrets.forget(tab: tab)
        #expect(AgentSecrets.count(tab: tab) == 0)
        #expect(AgentSecrets.scrub(secret) == secret)
    }

    @Test("A real tab's secrets go when it closes")
    @MainActor func realTabCloses() {
        _ = NSApplication.shared
        let tab = Tab(), secret = freshSecret()
        AgentSecrets.remember(secret, tab: tab.id)
        #expect(AgentSecrets.count(tab: tab.id) == 1)
        tab.close()
        #expect(AgentSecrets.count(tab: tab.id) == 0)
        #expect(AgentSecrets.scrub("x \(secret) y") == "x \(secret) y")
    }

    @Test("A model request stays valid JSON with the secret out of keys and values")
    func jsonBodies() throws {
        let tab = UUID(), secret = freshSecret()
        AgentSecrets.remember(secret, tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        let state: [String: Any] = ["page": ["text": "Checking \(secret)", "title": secret],
                                    "elements": [["label": "Password", "value": secret]], secret: [secret, 3, true]]
        let body = Jev.body(model: "jev-test", state: state, questions: ["operation": ["goal": "sign in as \(secret)"]])
        let data = try JSONSerialization.data(withJSONObject: body)
        let text = String(data: data, encoding: .utf8)!
        #expect(leaks(text, secret).isEmpty)
        #expect(text.contains(P))
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test("Errors, network listings and the driver timeline are scrubbed")
    @MainActor func errorsAndLogs() {
        let tab = UUID(), secret = freshSecret()
        AgentSecrets.remember(secret, tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        let error = AgentSecrets.scrub(error: Tools.Failure(text: "the page said: \(secret)"))
        let said = (error as? Tools.Failure)?.text ?? ""
        #expect(leaks(said, secret).isEmpty)
        let component = secret.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()"))!
        let entry = NetLog.Entry(id: 1, method: "POST", url: "https://login.test/collect?pw=\(component)", kind: "fetch", status: 200, error: nil)
        let listing = delivered(NetLog.lines([entry], includeStatic: true, limit: 10).joined(separator: "\n"))
        #expect(!listing.contains(component) && listing.contains(P))
        var outcome = Drive.Outcome(operation: "TYPE_TEXT", label: "Email \(secret)", text: secret)
        outcome.error = "failed: \(secret)"
        let shown = Drive.scrubbed(outcome)
        #expect(leaks([shown.label, shown.text ?? "", shown.error ?? ""].joined(separator: " "), secret).isEmpty)
        // The one-line summary a tool leaves for _meta.summary.
        let summary = Tools.SummaryBox()
        summary.line = "signed in · \(secret)"
        #expect(leaks(summary.line ?? "", secret).isEmpty)
    }

    @Test("Every sign-in refusal says what to do and never names the password")
    func refusals() {
        #expect(SignIn.refusal("ok", account: "ann@login.test") == nil)
        for word in ["not-password", "hidden-password", "other-account", "echoed", "no-fields", "anything"] {
            let said = SignIn.refusal(word, account: "ann@login.test")
            #expect(said != nil)
        }
    }
}

// MARK: - a real page

@MainActor private var kept: [AnyObject] = []

/// A tab with `html` loaded at https://login.test/, in a window so it lays
/// out, with Copper's forms script and the agent's helpers in.
@MainActor private func loginTab(_ html: String) async throws -> Tab {
    _ = NSApplication.shared
    let tab = Tab()
    let web = tab.web
    web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    kept.append(window)
    web.loadHTMLString(html, baseURL: URL(string: "https://login.test/"))
    for _ in 0..<300 {
        if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // A navigation arms the forms script (Tab.arm); a test's load may not
    // have, and the script is a no-op when it is already in.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        web.evaluateJavaScript(FormRelay.script + ";true", in: nil, in: .copper) { _ in done.resume() }
    }
    _ = try await Tools.Page.js(web, "true") // the agent's helper and the console recorder
    return tab
}

/// A page that copies the password everywhere it can the moment it lands.
private let leakyLogin = """
<!doctype html><html><head><title>Sign in</title></head><body>
<form id="login" action="/session" method="post">
  <label>Email <input id="email" type="email" name="email" autocomplete="username"></label>
  <label>Password <input id="pw" type="password" name="password" autocomplete="current-password"></label>
  <button type="submit">Sign in</button>
</form>
<div id="echo"></div>
<script>
  const pw = document.getElementById('pw');
  pw.addEventListener('input', () => {
    const v = pw.value;
    if (!v) return;
    document.getElementById('echo').textContent = 'Checking ' + v;
    console.log('typed password', v);
    console.log(JSON.stringify({password: v}));
    window.leak = {password: v, url: 'https://login.test/collect?pw=' + encodeURIComponent(v), nested: JSON.stringify(JSON.stringify(v))};
    document.title = 'Sign in ' + v;
  });
</script>
</body></html>
"""

@Suite("Agent reads never show a secret Copper filled", .serialized)
@MainActor
struct AgentSecretsPageTests {
    @Test("Every read tool's answer, and Jev's page, hold the placeholder and never the password")
    func everyReadPath() async throws {
        let tab = try await loginTab(leakyLogin)
        defer { tab.close() }
        let web = tab.web
        let secret = freshSecret()
        let word = await tab.signIn(user: "ann@login.test", password: secret)
        #expect(word == "ok")
        // The page did copy it (the scrubber has something to do).
        let copied = try await Tools.evaluate(web, function: "() => document.getElementById('echo').textContent", ref: "", frame: nil)
        #expect(copied.contains(secret))

        // Structure first, with no scrubbing: the password box reads as the placeholder.
        let rawSnapshot = try await Tools.Page.snapshot(web, selector: nil, interactive: false, limit: 600)
        let box = rawSnapshot.split(separator: "\n").first { $0.contains("textbox \"Password\"") }.map(String.init) ?? ""
        #expect(box.contains("[value=\"\(P)\"]"))
        #expect(!box.contains(secret))

        var answers: [String: String] = [:]
        answers["browser_snapshot"] = delivered(Tools.pageLine(tab) + "\n\n" + rawSnapshot)
        answers["browser_snapshot interactive"] = delivered(try await Tools.Page.snapshot(web, selector: nil, interactive: true, limit: 600))
        answers["browser_get_text (password box)"] = delivered(Tools.Page.render(try await Tools.Page.js(web, "window.__copper.text('css:#pw')")))
        answers["browser_get_text"] = delivered(Tools.Page.render(try await Tools.Page.js(web, "window.__copper.text('')")))
        answers["browser_find"] = delivered(Tools.Page.render(try await Tools.Page.js(web, "window.__copper.findText('Checking')")))
        answers["browser_evaluate (object)"] = delivered(try await Tools.evaluate(web, function: "() => window.leak", ref: "", frame: nil))
        answers["browser_evaluate (box value)"] = delivered(try await Tools.evaluate(web, function: "() => document.getElementById('pw').value", ref: "", frame: nil))
        answers["browser_evaluate (title)"] = delivered(try await Tools.evaluate(web, function: "document.title", ref: "", frame: nil))
        answers["browser_console_messages"] = delivered(try await Tools.Page.console(web))
        let observed = try #require(try await U.js(web, "window.__jevFast.observe(undefined, {deep: true})") as? [String: Any])
        let obs = U.Observation(raw: observed)
        answers["jev_observe table"] = delivered(U.table(obs))
        let state: [String: Any] = ["page": ["url": obs.url, "title": obs.title, "text": obs.text],
                                    "elements": U.actionSpace(obs.actions).elements, "recent_actions": []]
        answers["Jev model request"] = String(data: try JSONSerialization.data(withJSONObject: Jev.body(model: "jev-test", state: state, questions: [:])), encoding: .utf8)!
        answers["jev_extract input"] = AgentSecrets.scrub(Tools.Page.render(try await Tools.Page.js(web, "window.__copper.text('')")))

        for (name, text) in answers {
            #expect(leaks(text, secret).isEmpty, "\(name) leaked")
        }
        for name in ["browser_snapshot", "browser_get_text", "browser_get_text (password box)", "browser_find", "browser_evaluate (object)", "browser_evaluate (box value)",
                     "browser_console_messages", "Jev model request", "jev_extract input"] {
            #expect(answers[name]?.contains(P) == true, "\(name) has no placeholder")
        }
    }

    @Test("Before a picture, what shows a secret is masked, and put back after")
    func picturesMask() async throws {
        let tab = try await loginTab(leakyLogin.replacingOccurrences(of: "<div id=\"echo\"></div>", with: "<div id=\"echo\"></div><input id=\"mirror\" type=\"text\">")
            .replacingOccurrences(of: "console.log('typed password', v);", with: "console.log('typed password', v); document.getElementById('mirror').value = v;"))
        defer { tab.close() }
        let secret = freshSecret()
        _ = await tab.signIn(user: "ann@login.test", password: secret)
        // signIn emptied the mirror (an echo into a box); the page writes it again, as a page might later.
        _ = try await Tools.evaluate(tab.web, function: "() => { document.getElementById('mirror').value = 'x ' + window.leak.password; return true }", ref: "", frame: nil)
        let style = "() => [getComputedStyle(document.getElementById('echo')).color, getComputedStyle(document.getElementById('mirror')).webkitTextSecurity].join('|')"
        let before = try await Tools.evaluate(tab.web, function: style, ref: "", frame: nil)
        #expect(await AgentSecrets.masking(tab, on: true) >= 2)
        let during = try await Tools.evaluate(tab.web, function: style, ref: "", frame: nil)
        #expect(during.hasPrefix("rgba(0, 0, 0, 0)|disc"))
        await AgentSecrets.masking(tab, on: false)
        let after = try await Tools.evaluate(tab.web, function: style, ref: "", frame: nil)
        #expect(after == before)
    }

    @Test("Without any remembered secret, password, code and card boxes still read as the placeholder")
    func structureAlone() async throws {
        let typed = "typed-by-a-person-" + String(UUID().uuidString.prefix(6))
        let tab = try await loginTab("""
        <!doctype html><html><body>
        <label>Password <input id="pw" type="password"></label>
        <label>Code <input id="otp" autocomplete="one-time-code"></label>
        <label>Card number <input id="cc" autocomplete="cc-number"></label>
        <label>Security code <input id="csc" autocomplete="cc-csc"></label>
        <label>New password <input id="np" type="text" autocomplete="new-password"></label>
        <iframe srcdoc="<label>Frame password <input type=password value='\(typed)-frame'></label>"></iframe>
        <script>
          document.getElementById('pw').value = '\(typed)';
          document.getElementById('otp').value = '602214';
          document.getElementById('cc').value = '4000056655665556';
          document.getElementById('csc').value = '913';
          document.getElementById('np').value = '\(typed)-new';
        </script>
        </body></html>
        """)
        defer { tab.close() }
        #expect(AgentSecrets.count(tab: tab.id) == 0)
        let snapshot = try await Tools.Page.snapshot(tab.web, selector: nil, interactive: false, limit: 600)
        for value in [typed, "602214", "4000056655665556", "913", "\(typed)-new", "\(typed)-frame"] {
            #expect(!snapshot.contains(value), "snapshot shows a secret box's value")
        }
        #expect(snapshot.components(separatedBy: P).count - 1 >= 5)
        let observed = try #require(try await U.js(tab.web, "window.__jevFast.observe(undefined, {deep: true})") as? [String: Any])
        let obs = U.Observation(raw: observed)
        let table = U.table(obs)
        for value in [typed, "602214", "4000056655665556", "913", "\(typed)-new"] {
            #expect(!table.contains(value), "Jev's table shows a secret box's value")
            #expect(!obs.text.contains(value), "Jev's page text shows a secret box's value")
        }
        #expect(table.contains(P))
        for box in ["#pw", "#otp", "#cc", "#csc", "#np"] {
            let read = Tools.Page.render(try await Tools.Page.js(tab.web, "window.__copper.text('css:\(box)')"))
            #expect(read == P, "get_text on a secret box")
        }
    }

    @Test("Sign-in refuses a page with no real password box, and fills nothing")
    func refusesNonPasswordTarget() async throws {
        let tab = try await loginTab("""
        <!doctype html><html><body><form>
        <input id="email" type="email"><input id="pw" type="text" name="password" placeholder="Password">
        </form></body></html>
        """)
        defer { tab.close() }
        let secret = freshSecret()
        let word = await tab.signIn(user: "ann@login.test", password: secret)
        #expect(word != "ok")
        #expect(SignIn.refusal(word, account: "ann@login.test") != nil)
        let values = try await Tools.evaluate(tab.web, function: "() => [...document.querySelectorAll('input')].map(i => i.value).join('|')", ref: "", frame: nil)
        #expect(!values.contains(secret))
    }

    @Test("Sign-in refuses a password box that is not shown yet (account step first)")
    func refusesHiddenPasswordBox() async throws {
        let tab = try await loginTab("""
        <!doctype html><html><body><form>
        <input id="email" type="email"><input id="pw" type="password" style="opacity:0">
        </form></body></html>
        """)
        defer { tab.close() }
        let secret = freshSecret()
        #expect(await tab.signIn(user: "ann@login.test", password: secret) == "hidden-password")
        let values = try await Tools.evaluate(tab.web, function: "() => [...document.querySelectorAll('input')].map(i => i.value).join('|')", ref: "", frame: nil)
        #expect(!values.contains(secret))
    }

    @Test("Sign-in refuses when the account box holds someone else")
    func refusesOtherAccount() async throws {
        let tab = try await loginTab("""
        <!doctype html><html><body><form>
        <input id="email" type="email" value="someone.else@login.test"><input id="pw" type="password">
        </form></body></html>
        """)
        defer { tab.close() }
        let secret = freshSecret()
        #expect(await tab.signIn(user: "ann@login.test", password: secret) == "other-account")
        let values = try await Tools.evaluate(tab.web, function: "() => [...document.querySelectorAll('input')].map(i => i.value).join('|')", ref: "", frame: nil)
        #expect(!values.contains(secret))
        // The same account, written differently, is not someone else.
        #expect(await tab.signIn(user: "Someone.Else@login.test ", password: secret) == "ok")
    }

    @Test("A page that copies the password into another box gets every copy emptied")
    func emptiesEchoes() async throws {
        let tab = try await loginTab("""
        <!doctype html><html><body><form>
        <input id="email" type="email"><input id="pw" type="password">
        <input id="mirror" type="text">
        </form>
        <script>
          const pw = document.getElementById('pw');
          pw.addEventListener('input', () => { if (pw.value) document.getElementById('mirror').value = 'saw ' + pw.value; });
        </script>
        </body></html>
        """)
        defer { tab.close() }
        let secret = freshSecret()
        #expect(await tab.signIn(user: "ann@login.test", password: secret) == "echoed")
        let values = try await Tools.evaluate(tab.web, function: "() => [...document.querySelectorAll('input')].map(i => i.value).join('|')", ref: "", frame: nil)
        #expect(!values.contains(secret))
        // And had a copy survived, the answer still would not say it.
        #expect(leaks(delivered("saw \(secret)"), secret).isEmpty)
    }
}
