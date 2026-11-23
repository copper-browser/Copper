import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

// Approve cards (Fork/MCP/Approve.swift): which agent inputs pay, send,
// delete or book, when Copper asks, and what the page shows the card.

private func kind(_ label: String, alt: String = "", link: Bool = false, card: Bool = false, message: Bool = false, key: Bool = false) -> Approve.Kind? {
    Approve.kind(label: label, alt: alt, link: link, card: card, message: message, key: key)
}

// The page the look reads in the last test.

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@MainActor private var kept: [AnyObject] = []

@MainActor
private func page(_ html: String) async -> WKWebView {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    let loaded = Loaded()
    web.navigationDelegate = loaded
    await withCheckedContinuation { c in loaded.done = c; web.loadHTMLString(html, baseURL: URL(string: "https://shop.test/")) }
    kept += [window, loaded]
    return web
}

private let checkout = """
<html><body style="margin:0;font:14px system-ui">
<form id="pay" style="position:absolute;left:20px;top:20px;width:300px">
  <div>Subtotal $38.00</div><div>Shipping $4.00</div><div><b>Total $42.00</b></div>
  <input autocomplete="cc-number" value="4242 4242 4242 4242">
  <button id="go" style="position:absolute;left:0;top:120px;width:200px;height:40px">Pay now</button>
</form>
<div id="chat" style="position:absolute;left:400px;top:20px;width:300px">
  <input aria-label="To recipients" value="ana@example.com">
  <textarea id="msg">See you at 7</textarea>
  <button id="send" style="position:absolute;left:0;top:120px;width:100px;height:30px">Send</button>
</div>
<button id="del" style="position:absolute;left:20px;top:300px;width:200px;height:30px">Delete 3 items</button>
</body></html>
"""

@Suite struct ApproveTests {
    @Test func paymentsAreThePayBuyOrderAndCheckoutButtons() {
        for label in ["Pay $42.00", "Buy now", "Place order", "Place your order", "Complete purchase", "Confirm and pay",
                      "Checkout", "Check out", "Donate", "Buy with Apple Pay", "Submit order", "Transfer $500"] {
            #expect(kind(label) == .pay, "\(label)")
        }
    }

    @Test func goingToCheckoutOrChoosingAPaymentMethodIsNotPaying() {
        for label in ["Proceed to checkout", "Continue to payment", "Payment method", "PayPal account settings", "Add to cart", "Transfer files"] {
            #expect(kind(label) == nil, "\(label)")
        }
    }

    @Test func sendingIsSendPostReplyButNotAOneTimeCode() {
        for label in ["Send", "Post", "Reply all", "Publish", "Tweet", "Comment"] { #expect(kind(label) == .send, "\(label)") }
        for label in ["Send code", "Resend verification link", "Send me a text", "Postcode lookup"] { #expect(kind(label) == nil, "\(label)") }
    }

    @Test func deletingAndBooking() {
        for label in ["Delete", "Delete 3 items", "Move to trash", "Erase all content", "Delete this repository", "Remove account"] {
            #expect(kind(label) == .delete, "\(label)")
        }
        #expect(kind("Undelete") == nil)
        #expect(kind("Remove item") == nil)
        for label in ["Book now", "Reserve a table", "Confirm booking", "Complete your reservation"] { #expect(kind(label) == .book, "\(label)") }
        #expect(kind("Bookmarks") == nil)
        #expect(kind("Log in with Facebook") == nil)
    }

    @Test func aLinkOnlyGoesSomewhereUnlessItDeletes() {
        #expect(kind("Buy now", link: true) == nil)
        #expect(kind("Book a demo", link: true) == nil)
        #expect(kind("Delete", link: true) == .delete)
    }

    @Test func aWordThatSaysNothingTakesItsKindFromTheForm() {
        #expect(kind("Submit", card: true) == .pay)
        #expect(kind("Continue", card: true) == .pay)
        #expect(kind("Submit", message: true) == .send)
        #expect(kind("Submit") == nil)
        #expect(kind("Search", card: true) == nil)
        // Return in a field: the form decides.
        #expect(kind("", card: true, key: true) == .pay)
        #expect(kind("", message: true, key: true) == .send)
        #expect(kind("", key: true) == nil)
        // A click with no words (into a card's own frame) asks nothing.
        #expect(kind("", card: true) == nil)
        // The aria-label counts too.
        #expect(kind("→", alt: "Send message") == .send)
    }

    @Test func asksOnlyForAKindTheUserWantsAndOnlyWhenSomeoneCanAnswer() {
        let all = Set(Approve.Kind.allCases)
        #expect(Approve.decide(nil, asks: all, canAsk: true) == .go)
        #expect(Approve.decide(.pay, asks: all, canAsk: true) == .ask(.pay))
        #expect(Approve.decide(.pay, asks: [.send], canAsk: true) == .go)
        #expect(Approve.decide(.delete, asks: [], canAsk: true) == .go)
        // Headless: never a card nobody can answer.
        #expect(Approve.decide(.pay, asks: all, canAsk: false) == .skip(.pay, "headless"))
        #expect(Approve.decide(.send, asks: [.pay], canAsk: false) == .go)
    }

    @Test func theSwitchesAreOnForPeopleAndOffInTestWorlds() {
        #expect(Approve.defaultOn(testing: false))
        #expect(!Approve.defaultOn(testing: true))
    }

    @MainActor @Test func theLookReadsTheButtonTheAmountTheCardAndTheMessage() async throws {
        let web = await page(checkout)
        let pay = try await Tools.Page.raw(web, Approve.look(CGPoint(x: 100, y: 160), full: true)) as? [String: Any]
        #expect(pay?["label"] as? String == "Pay now")
        #expect(pay?["card"] as? Bool == true)
        #expect(pay?["amount"] as? String == "$42.00")
        #expect(pay?["last4"] as? String == "4242")
        #expect(Approve.kind(label: pay?["label"] as? String ?? "", card: true) == .pay)

        let send = try await Tools.Page.raw(web, Approve.look(CGPoint(x: 450, y: 155), full: true)) as? [String: Any]
        #expect(send?["label"] as? String == "Send")
        #expect(send?["message"] as? Bool == true)
        #expect(send?["to"] as? String == "ana@example.com")
        #expect(send?["text"] as? String == "See you at 7")

        let del = try await Tools.Page.raw(web, Approve.look(CGPoint(x: 100, y: 315), full: true)) as? [String: Any]
        #expect(del?["count"] as? String == "3")

        // Return in the message box: the Send button beside it is what it sends.
        _ = try await Tools.Page.raw(web, "document.getElementById('msg').focus(); true")
        let key = try await Tools.Page.raw(web, Approve.look(nil)) as? [String: Any]
        #expect(key?["label"] as? String == "Send")
        #expect(key?["message"] as? Bool == true)
    }
}
