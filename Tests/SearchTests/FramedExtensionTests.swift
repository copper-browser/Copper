import AppKit
import JavaScriptCore
import Testing
@testable import Search

// The sign-in page that kept refreshing. An extension's page inside a web
// page's frame (1Password's menu under a sign-in field, a shopping panel on a
// store) runs in that page's process; the shim asked WebKit for the current
// tab there, WebKit refuses tabs.getCurrent from any process it didn't make
// for the extension by ending it, and Copper loaded the page again — the
// trail showed `webcontent-gone host=accounts.google.com front=yes` a second
// apart, the system log `Received an invalid message
// WebExtensionContext_TabsGetCurrent`. ExtensionShims.script is run in
// JavaScriptCore against a stand-in for WebKit's extension APIs, framed and
// not; and a tab whose page keeps dying stops being loaded again.

private let page = #"""
var window = this;
var asked = [];
var document = {};
var navigator = { userAgent: "Mozilla/5.0 AppleWebKit/605.1.15 Chrome/140.0.0.0 Safari/537.36" };
var location = {
  protocol: "webkit-extension:", origin: "webkit-extension://abc", href: "webkit-extension://abc/menu.html",
  pathname: "/menu.html", ancestorOrigins: FRAMED ? ["https://accounts.google.com"] : []
};
window.top = FRAMED ? {} : window;
window.setTimeout = function (f) { f(); };
function event() { return { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } }; }
function answer(name, value) { return function () { asked.push(name); return Promise.resolve(value); }; }
window.chrome = {
  runtime: {
    id: "abc", onMessage: event(), onConnect: event(), onInstalled: event(), onStartup: event(),
    getManifest: function () { return { manifest_version: 3, permissions: [] }; },
    getURL: function (p) { return "webkit-extension://abc/" + p; },
    sendMessage: answer("runtime.sendMessage"), sendNativeMessage: answer("runtime.sendNativeMessage", {}),
    connect: function () { return { onMessage: event(), onDisconnect: event(), postMessage: function () {} }; }
  },
  tabs: {
    getCurrent: answer("tabs.getCurrent", { id: 7, index: 0, windowId: 1 }),
    query: answer("tabs.query", []), get: answer("tabs.get"),
    connect: function () { asked.push("tabs.connect"); return {}; },
    onUpdated: event(), onActivated: event(), onRemoved: event(), onCreated: event()
  },
  windows: { getCurrent: answer("windows.getCurrent", { id: 1 }), getAll: answer("windows.getAll", []), onFocusChanged: event() },
  cookies: { get: answer("cookies.get"), onChanged: event() },
  storage: { local: { get: answer("storage.local.get", {}) }, onChanged: event() },
  extension: { getViews: function () { return []; }, getBackgroundPage: function () { return null; } }
};
"""#

@available(macOS 15.4, *)
@MainActor private func extensionPage(framed: Bool) throws -> JSContext {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let js = try #require(JSContext())
    js.evaluateScript("var FRAMED = \(framed);" + page)
    // The shim reaches past what a stand-in has (the DOM, fetch); what is
    // checked here is all settled before any of that.
    js.evaluateScript(ExtensionShims.shim(for: folder))
    return js
}

private func value(_ js: JSContext, _ script: String) -> String {
    js.evaluateScript(script)?.toString() ?? "undefined"
}

@available(macOS 15.4, *)
@MainActor @Test func aFramedExtensionPageNeverAsksWebKitForItsTab() throws {
    let js = try extensionPage(framed: true)
    #expect(value(js, "window.__searchShim === true") == "true")
    #expect(value(js, "asked.includes('tabs.getCurrent')") == "false")

    js.evaluateScript("""
        var got = 'pending', rejected = 'pending', called = 'pending', error = '';
        chrome.tabs.getCurrent().then(function (t) { got = String(t); });
        chrome.tabs.query({}).then(function () { rejected = 'no'; }, function (e) { rejected = 'yes'; });
        chrome.tabs.getCurrent(function (t) { called = String(t); });
        chrome.cookies.get({}, function () { error = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none'; });
        try { chrome.tabs.connect(7); } catch (e) { var thrown = true; }
        """)
    // Promises settle on the next turn of JavaScriptCore's queue.
    js.evaluateScript("void 0")
    #expect(value(js, "got") == "undefined")
    #expect(value(js, "called") == "undefined")
    #expect(value(js, "rejected") == "yes")
    #expect(value(js, "error").contains("extension frame"))
    #expect(value(js, "thrown === true") == "true")
    // None of it reached WebKit, and what a frame may ask still does.
    #expect(value(js, "asked.filter(function (a) { return /^(tabs|windows|cookies)\\./.test(a); }).length") == "0")
    js.evaluateScript("chrome.storage.local.get('x')")
    #expect(value(js, "asked.includes('storage.local.get')") == "true")
}

@available(macOS 15.4, *)
@MainActor @Test func aTopLevelExtensionPageStillAsksForItsTab() throws {
    let js = try extensionPage(framed: false)
    #expect(value(js, "window.__searchShim === true") == "true")
    // The popup check, as before: WebKit is asked at once.
    #expect(value(js, "asked.includes('tabs.getCurrent')") == "true")
    js.evaluateScript("chrome.tabs.query({})")
    #expect(value(js, "asked.includes('tabs.query')") == "true")
}

@MainActor @Test func aPageThatKeepsCrashingStopsBeingReloaded() throws {
    // A tab asks the app's appearance for its icon; a test process has no app until asked.
    _ = NSApplication.shared
    let tab = Tab()
    tab.setAddressOptimistically(try #require(URL(string: "https://accounts.google.com/")))
    tab.recoverFromCrash()
    #expect(tab.failure == nil)
    tab.recoverFromCrash()
    #expect(tab.failure == nil)
    tab.recoverFromCrash()
    #expect(tab.failure != nil)
    // Try again starts it afresh.
    tab.reload()
    #expect(tab.failure == nil)
    tab.close()
}
