import Foundation
import JavaScriptCore
import Testing
@testable import Search

// The page's half of tab sharing (Fork/TabShare/TabShareScript.swift), run in
// JavaScriptCore against a stand-in for the page: navigator.mediaDevices whose
// getDisplayMedia is WebKit's, and a copperShare handler that answers the way
// Copper would. What it holds the wrapper to: invisible to feature detection
// until called; WebKit's own call made at once; a window or the screen, or a
// cancel, settled by WebKit's own answer.

private let page = #"""
var window = this;
var log = [];
function MediaDevices() {}
MediaDevices.prototype.getDisplayMedia = function getDisplayMedia() {
  log.push('native');
  return window.nativeAnswer();
};
MediaDevices.prototype.getUserMedia = function getUserMedia() { return Promise.resolve('camera'); };
function MediaStreamTrack() {}
MediaStreamTrack.prototype.stop = function () {};
MediaStreamTrack.prototype.clone = function () { return new MediaStreamTrack(); };
MediaStreamTrack.prototype.getSettings = function () { return {}; };
var navigator = { mediaDevices: new MediaDevices() };
window.addEventListener = function () {};
window.copperAnswer = function (message) { return Promise.resolve({ choice: 'native' }); };
window.nativeAnswer = function () { return Promise.resolve('native-stream'); };
window.webkit = { messageHandlers: { copperShare: { postMessage: function (message) {
  log.push(message.op);
  return window.copperAnswer(message);
} } } };
var originalGetDisplayMedia = MediaDevices.prototype.getDisplayMedia;
var originalDescriptor = Object.getOwnPropertyDescriptor(MediaDevices.prototype, 'getDisplayMedia');
"""#

private func context(bridge: Bool = true) -> JSContext {
    let js = JSContext()!
    js.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
    js.evaluateScript(page)
    if !bridge { js.evaluateScript("delete window.webkit;") }
    js.evaluateScript(TabShareScript.source)
    return js
}

private func value(_ js: JSContext, _ script: String) -> String {
    js.evaluateScript(script)?.toString() ?? "undefined"
}

@Test func theWrapperLooksLikeTheOriginalToFeatureDetection() {
    let js = context()
    #expect(value(js, "navigator.mediaDevices.getDisplayMedia !== originalGetDisplayMedia") == "true")
    #expect(value(js, "typeof navigator.mediaDevices.getDisplayMedia") == "function")
    #expect(value(js, "navigator.mediaDevices.getDisplayMedia.name") == "getDisplayMedia")
    #expect(value(js, "navigator.mediaDevices.getDisplayMedia.length") == "0")
    #expect(value(js, "'getDisplayMedia' in MediaDevices.prototype") == "true")
    #expect(value(js, "Object.prototype.hasOwnProperty.call(navigator.mediaDevices, 'getDisplayMedia')") == "false")
    #expect(value(js, "Function.prototype.toString.call(navigator.mediaDevices.getDisplayMedia)").contains("[native code]"))
    // Nothing was asked of Copper, and nothing else was touched.
    #expect(value(js, "log.length") == "0")
    // The same kind of property it was: enumerable, writable, configurable alike.
    #expect(value(js, """
    (function () { var now = Object.getOwnPropertyDescriptor(MediaDevices.prototype, 'getDisplayMedia');
      return now.enumerable === originalDescriptor.enumerable && now.writable === originalDescriptor.writable
        && now.configurable === originalDescriptor.configurable; })()
    """) == "true")
}

@Test func withoutCoppersHandlerThePageKeepsWebKitsOwn() {
    let js = context(bridge: false)
    #expect(value(js, "navigator.mediaDevices.getDisplayMedia === originalGetDisplayMedia") == "true")
}

@Test func aWindowOrTheScreenIsWebKitsStreamAndCopperIsToldItIsSettled() {
    let js = context()
    js.evaluateScript("var got = null; navigator.mediaDevices.getDisplayMedia({ video: { width: { max: 1280 } }, audio: true }).then(function (s) { got = s; });")
    #expect(value(js, "got") == "native-stream")
    // Copper hears of the ask first, then WebKit's own request goes out, in the same turn.
    #expect(value(js, "log.join(',')") == "ask,native,drop")
}

@Test func theAskCarriesWhatThePageAskedFor() {
    let js = context()
    js.evaluateScript("""
    var asked = null;
    window.copperAnswer = function (m) { if (m.op === 'ask') asked = m; return Promise.resolve({ choice: 'native' }); };
    navigator.mediaDevices.getDisplayMedia({ video: { width: { max: 1280 }, frameRate: 15, junk: { a: 1 } }, audio: true,
                                             selfBrowserSurface: 'include', preferCurrentTab: true });
    """)
    #expect(value(js, "asked.audio") == "true")
    #expect(value(js, "asked.video.width.max") == "1280")
    #expect(value(js, "asked.video.frameRate") == "15")
    #expect(value(js, "'junk' in asked.video") == "false")
    #expect(value(js, "asked.selfBrowserSurface") == "include")
    #expect(value(js, "asked.preferCurrentTab") == "true")
    #expect(value(js, "typeof asked.id === 'string' && asked.id.length > 8") == "true")
}

@Test func cancellingIsWebKitsNotAllowedError() {
    let js = context()
    js.evaluateScript("""
    var failed = null;
    window.copperAnswer = function (m) { return Promise.resolve(m.op === 'ask' ? { choice: 'cancel' } : true); };
    window.nativeAnswer = function () { var e = new Error('denied'); e.name = 'NotAllowedError'; return Promise.reject(e); };
    navigator.mediaDevices.getDisplayMedia({ video: true }).then(null, function (e) { failed = e.name; });
    """)
    #expect(value(js, "failed") == "NotAllowedError")
    #expect(value(js, "log.join(',')") == "ask,native,settled")
}

@Test func aSynchronousRefusalStillThrowsAndCopperForgetsTheAsk() {
    let js = context()
    js.evaluateScript("""
    var thrown = null;
    window.nativeAnswer = function () { throw new TypeError('bad constraints'); };
    try { navigator.mediaDevices.getDisplayMedia({ video: { width: { min: 99999 } } }); } catch (e) { thrown = e.name; }
    """)
    #expect(value(js, "thrown") == "TypeError")
    #expect(value(js, "log.join(',')") == "ask,native,drop")
}

/// Every frame of every page runs the script: it must not make the frame's
/// MediaDevices object, nor leave a listener behind, for a page that never
/// shares anything.
@Test func aPageThatNeverSharesIsLeftAsItWas() {
    let js = JSContext()!
    js.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
    js.evaluateScript(page)
    js.evaluateScript("""
    var touched = 0, listeners = [];
    var devices = navigator.mediaDevices;
    navigator = { get mediaDevices() { touched++; return devices; } };
    window.addEventListener = function (name) { listeners.push(name); };
    """)
    js.evaluateScript(TabShareScript.source)
    #expect(value(js, "touched") == "0")
    #expect(value(js, "listeners.length") == "0")
    #expect(value(js, "MediaDevices.prototype.getDisplayMedia !== originalGetDisplayMedia") == "true")
}

/// Just enough of a page for the tab path: a canvas whose capture track is a
/// MediaStreamTrack, an image decoder, timers that never fire.
private let tabPage = #"""
var listeners = [];
window.addEventListener = function (name) { listeners.push(name); };
function Canvas() { this.width = 0; this.height = 0; }
Canvas.prototype.getContext = function () { return { fillRect: function () {}, drawImage: function () {} }; };
Canvas.prototype.captureStream = function () {
  var track = new MediaStreamTrack();
  return { getVideoTracks: function () { return [track]; }, getTracks: function () { return [track]; } };
};
var document = { createElement: function () { return new Canvas(); } };
function Blob() {}
function createImageBitmap() { return Promise.resolve({ width: 1280, height: 720, close: function () {} }); }
function setTimeout() {}
function atob() { return '\0\0\0'; }
function DOMException(message, name) { this.message = message; this.name = name; }
function Event(type) { this.type = type; }
MediaStreamTrack.prototype.readyState = 'live';
MediaStreamTrack.prototype.dispatchEvent = function () {};
var asked = [];
window.copperAnswer = function (m) {
  asked.push(m);
  if (m.op === 'ask') return Promise.resolve({ choice: 'tab', share: 'SECRET-SHARE-ID', width: 1280, height: 720, fps: 30,
                                               label: 'Slides', maxWidth: 1920, maxHeight: 1200 });
  if (m.op === 'frame') {
    if (m.after >= 3) return new Promise(function () {});
    return Promise.resolve({ seq: m.after + 1, data: 'AAAA', label: 'Bank statement \u2014 private', width: 1280, height: 720 });
  }
  return Promise.resolve(true);
};
window.nativeAnswer = function () { var e = new Error('denied'); e.name = 'NotAllowedError'; return Promise.reject(e); };
"""#

@Test func aSharedTabKeepsItsLabelAndItsShareIdStaysBetweenTheScriptAndCopper() {
    let js = JSContext()!
    js.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
    js.evaluateScript(page)
    js.evaluateScript(tabPage)
    js.evaluateScript(TabShareScript.source)
    #expect(value(js, "listeners.length") == "0")
    js.evaluateScript("var got = null, failed = null; navigator.mediaDevices.getDisplayMedia({ video: true }).then(function (s) { got = s; }, function (e) { failed = String(e && e.name); });")
    #expect(value(js, "failed") == "null")
    #expect(value(js, "got !== null") == "true")
    // Three pictures came, each naming another title: the label is the
    // tab's as it was chosen, as a track's label never changes.
    #expect(value(js, "asked.filter(function (m) { return m.op === 'frame'; }).length") == "4")
    #expect(value(js, "got.getVideoTracks()[0].label") == "Slides")
    #expect(value(js, "got.getVideoTracks()[0].getSettings().displaySurface") == "browser")
    // The share id is Copper's capability for the pictures: never in what
    // the page can read off the track.
    #expect(value(js, "JSON.stringify(got.getVideoTracks()[0].getSettings()).indexOf('SECRET-SHARE-ID')") == "-1")
    #expect(value(js, "JSON.stringify(got.getVideoTracks()[0].getCapabilities()).indexOf('SECRET-SHARE-ID')") == "-1")
    // Leaving the page is listened for now that something is shared.
    #expect(value(js, "listeners.indexOf('pagehide') >= 0") == "true")
    // The page's own stop tells Copper.
    js.evaluateScript("got.getVideoTracks()[0].readyState = 'ended'; got.getVideoTracks()[0].stop();")
    #expect(value(js, "asked[asked.length - 1].op") == "stop")
    #expect(value(js, "asked[asked.length - 1].share") == "SECRET-SHARE-ID")
}

@Test func otherMediaCallsAreLeftAlone() {
    let js = context()
    js.evaluateScript("var cam = null; navigator.mediaDevices.getUserMedia({ video: true }).then(function (s) { cam = s; });")
    #expect(value(js, "cam") == "camera")
    #expect(value(js, "log.length") == "0")
}
