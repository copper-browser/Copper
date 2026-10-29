import Foundation
import Testing
@testable import Search

// Settings › Intelligence and Agents: the rules behind the rows, apart
// from any window or network — what Check says for each way a question can
// fail, when its verdict stops counting,
// which tabs a cancelled Claude sign-in closes, and that Copy and Open stay
// in a test world only when one is running.

@MainActor
@Suite("Check's words")
struct CheckWords {
    @Test func networkFailuresNameTheNextStep() {
        let offline = IntelligenceCheck.network(URLError(.notConnectedToInternet), "Jev", waited: 4)
        #expect(offline == "This Mac is offline — Jev wasn't asked. Try again once you're connected.")
        let slow = IntelligenceCheck.network(URLError(.timedOut), "The gateway", waited: 15)
        #expect(slow == "The gateway didn't answer in 15 seconds. Try again; if it keeps happening, check the address.")
        let lost = IntelligenceCheck.network(URLError(.cannotFindHost), "The gateway", waited: 15)
        #expect(lost == "The gateway couldn't be found at that address — check it, or your network.")
        let refused = IntelligenceCheck.network(URLError(.cannotConnectToHost), "The gateway", waited: 15)
        #expect(refused == "Nothing answered at the gateway's address — check it.")
        let tls = IntelligenceCheck.network(URLError(.serverCertificateUntrusted), "Jev", waited: 4)
        #expect(tls == "Jev's address has a certificate this Mac doesn't trust.")
        #expect(IntelligenceCheck.network(Router.Failure(detail: "x"), "Jev", waited: 4) == nil)
    }

    /// "…start with https://." read as a typo; the address ends the sentence.
    @Test func noStrayPeriodAfterTheScheme() throws {
        let words = try #require(IntelligenceCheck.network(URLError(.unsupportedURL), "The gateway", waited: 15))
        #expect(words.hasSuffix("https://"))
        #expect(!words.contains("https://."))
    }

    @Test func jevFailures() {
        let refused = IntelligenceCheck.jevFailure(Jev.Failure(kind: "http_401", detail: "{\"error\":\"bad key\"}"))
        #expect(refused.refused && !refused.ok)
        #expect(refused.text == "Jev turned the key away — paste a new one below.")
        #expect(IntelligenceCheck.jevFailure(Jev.Failure(kind: "http_402", detail: "")).refused)
        let busy = IntelligenceCheck.jevFailure(Jev.Failure(kind: "http_429", detail: ""))
        #expect(!busy.refused && busy.text.contains("try again in a minute"))
        #expect(IntelligenceCheck.jevFailure(Jev.Failure(kind: "http_503", detail: "")).text == "Jev is having trouble on its side (503). Try again later.")
        #expect(IntelligenceCheck.jevFailure(Jev.Failure(kind: "bad_endpoint", detail: "")).text == "Jev's address isn't a web address.")
        // Never the raw body.
        #expect(!refused.text.contains("{"))
    }

    @Test func gatewayFailures() {
        let refused = IntelligenceCheck.gatewayFailure(Router.Failure(detail: "router 401: {\"error\":…}", status: 401), model: "opus")
        #expect(refused.refused && refused.lane == "router")
        #expect(refused.text == "The gateway turned the key away — paste a new one above.")
        // An unknown model is named, whether the gateway says 400 or 404.
        for status in [400, 404] {
            let unknown = IntelligenceCheck.gatewayFailure(Router.Failure(detail: "Invalid model name passed", status: status), model: "no-such-model")
            #expect(unknown.text == "The gateway has no model called “no-such-model” — check Model names.")
            #expect(!unknown.refused)
        }
        let missing = IntelligenceCheck.gatewayFailure(Router.Failure(detail: "not found", status: 404), model: "opus")
        #expect(missing.text == "Nothing at that address answers like a gateway — check the address.")
        let other = IntelligenceCheck.gatewayFailure(Router.Failure(detail: "bad request", status: 400), model: "opus")
        #expect(other.text == "The gateway answered with an error (400).")
        #expect(IntelligenceCheck.gatewayFailure(Router.Failure(detail: "", status: 502), model: "opus").text.contains("(502)"))
        #expect(IntelligenceCheck.gatewayFailure(Router.Failure(detail: "garbled"), model: "opus").text == "The gateway's answer didn't make sense — is that the right address?")
    }

    @Test func claudeFailures() {
        let out = IntelligenceCheck.claudeFailure(Claude.Failure(status: 401, text: "unauthorized"))
        #expect(out.refused && out.text == "Claude signed this Mac out — sign in again above.")
        #expect(IntelligenceCheck.claudeFailure(Claude.Failure(status: 429, text: "")).text == "Your Claude plan's limit is reached for now — try again later.")
        #expect(IntelligenceCheck.claudeFailure(ClaudeAccount.Failure(text: "Not signed in to Claude — Settings › Intelligence › Model access")).text == "Not signed in to Claude — Sign in above.")
    }

    @Test func durations() {
        #expect(IntelligenceCheck.duration(361.4) == "361 ms")
        #expect(IntelligenceCheck.duration(1830) == "1.8 s")
    }

    @Test func webAddresses() {
        #expect(IntelligencePage.isWebAddress("https://gateway.example"))
        #expect(IntelligencePage.isWebAddress(" http://127.0.0.1:4000 "))
        #expect(!IntelligencePage.isWebAddress("gateway.example"))
        #expect(!IntelligencePage.isWebAddress("ftp://gateway.example"))
        #expect(!IntelligencePage.isWebAddress(""))
    }
}

@MainActor
@Suite("When a verdict still holds")
struct CheckFreshness {
    private func setup() -> IntelligenceCheck.Setup {
        var keys = Intelligence.Keys()
        keys.jevKey = "ts-one"
        keys.routerKey = "sk-one"
        keys.routerURL = "https://gateway.example"
        keys.lane = .key
        return IntelligenceCheck.Setup(keys: keys, model: "sonnet", account: "")
    }

    @Test func holdsForTheSameSetupOnly() {
        let asked = setup()
        #expect(IntelligenceCheck.holds(asked.whole, now: asked))
        #expect(!IntelligenceCheck.holds(nil, now: asked))
    }

    @Test func changingTheLaneTheModelOrAKeyEndsIt() {
        let asked = setup()
        var lane = asked
        lane.keys.lane = .claude
        #expect(!IntelligenceCheck.holds(asked.whole, now: lane))
        var model = asked
        model.model = "opus"
        #expect(!IntelligenceCheck.holds(asked.whole, now: model))
        var jev = asked
        jev.keys.jevKey = "ts-two"
        #expect(!IntelligenceCheck.holds(asked.whole, now: jev))
        var router = asked
        router.keys.routerKey = "sk-two"
        #expect(!IntelligenceCheck.holds(asked.whole, now: router))
        var address = asked
        address.keys.routerURL = "https://other.example"
        #expect(!IntelligenceCheck.holds(asked.whole, now: address))
        // Signing in to another account matters only on the account lane.
        var account = asked
        account.account = "someone@example.com#2"
        #expect(IntelligenceCheck.holds(asked.whole, now: account))
        var claude = asked
        claude.keys.lane = .claude
        var claudeAgain = claude
        claudeAgain.account = "someone@example.com#2"
        #expect(!IntelligenceCheck.holds(claude.whole, now: claudeAgain))
    }

    @Test func somethingElseLeavesItStanding() {
        let asked = setup()
        var other = asked
        other.keys.textModel = "haiku"
        #expect(IntelligenceCheck.holds(asked.whole, now: other))
    }

    /// A refusal is about one lane's key: a new gateway key doesn't
    /// un-refuse Jev's, and the model asked for doesn't matter.
    @Test func aRefusalFollowsItsOwnKey() {
        let asked = setup()
        var router = asked
        router.keys.routerKey = "sk-two"
        #expect(router.key("jev") == asked.key("jev"))
        #expect(router.key("router") != asked.key("router"))
        var model = asked
        model.model = "opus"
        #expect(model.key("router") == asked.key("router"))
    }
}

@Suite("Claude sign-in tab")
struct SignInTab {
    @Test func closesOnlyTabsStillSigningIn() {
        #expect(ClaudeAccount.isSignInHost("claude.ai"))
        #expect(ClaudeAccount.isSignInHost("CLAUDE.AI"))
        #expect(ClaudeAccount.isSignInHost("platform.claude.com"))
        #expect(ClaudeAccount.isSignInHost("console.anthropic.com"))
        #expect(ClaudeAccount.isSignInHost("localhost"))
        #expect(ClaudeAccount.isSignInHost(nil))
        #expect(!ClaudeAccount.isSignInHost("example.com"))
        #expect(!ClaudeAccount.isSignInHost("notclaude.ai"))
    }
}

@Suite("Copy and Open in test worlds")
struct ProbeSeams {
    /// Only a named test world with the bench on keeps them to itself; the
    /// browser somebody is using (no world) always uses the real ones.
    @Test func offOutsideAProbe() {
        #expect(!SettingsActions.seams(world: nil, bench: true))
        #expect(!SettingsActions.seams(world: nil, bench: false))
        #expect(!SettingsActions.seams(world: "", bench: true))
        #expect(!SettingsActions.seams(world: "cux-ai", bench: false))
        #expect(SettingsActions.seams(world: "cux-ai", bench: true))
    }
}
