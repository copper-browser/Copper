import Foundation
import JavaScriptCore
import Testing
@testable import Search

// The page's half of sound Copper hands a page, run in JavaScriptCore
// against stand-ins for Web Audio: the PCM player's bounded scheduling
// (PCMPlayerScript), a shared tab's audio track (TabShareScript), and a page
// served Copper's microphone while another page captures (PageMicScript).

/// Web Audio, as far as the scripts use it: every buffer started is logged
/// with when and what.
private let webAudio = #"""
var window = this;
var log = [];
var scheduled = [], contexts = [];
function MediaStreamTrack() {}
MediaStreamTrack.prototype.readyState = 'live';
MediaStreamTrack.prototype.stop = function () { this.readyState = 'ended'; };
MediaStreamTrack.prototype.clone = function () { var copy = new MediaStreamTrack(); copy.kind = this.kind; return copy; };
MediaStreamTrack.prototype.getSettings = function () { return {}; };
MediaStreamTrack.prototype.dispatchEvent = function (event) { (this.heard = this.heard || []).push(event.type); };
function Event(type) { this.type = type; }
function DOMException(message, name) { this.message = message; this.name = name; }
function AudioContext(options) { this.state = 'running'; this.currentTime = 1; this.sampleRate = 48000; this.options = options; contexts.push(this); }
AudioContext.prototype.resume = function () { this.resumed = (this.resumed || 0) + 1; if (this.state !== 'closed') this.state = 'running'; return Promise.resolve(); };
AudioContext.prototype.suspend = function () { if (this.state !== 'closed') this.state = 'suspended'; return Promise.resolve(); };
AudioContext.prototype.close = function () { this.state = 'closed'; return Promise.resolve(); };
AudioContext.prototype.createMediaStreamDestination = function () {
  var track = new MediaStreamTrack();
  track.kind = 'audio';
  var tracks = [track];
  return { channelCount: 2, stream: { getAudioTracks: function () { return tracks.slice(); }, getTracks: function () { return tracks.slice(); } } };
};
AudioContext.prototype.createBuffer = function (channels, frames, rate) {
  var data = [];
  for (var c = 0; c < channels; c++) data.push(new Float32Array(frames));
  return { numberOfChannels: channels, length: frames, sampleRate: rate, duration: frames / rate, getChannelData: function (c) { return data[c]; } };
};
AudioContext.prototype.createBufferSource = function () {
  return { connect: function () {}, start: function (at) { scheduled.push({ at: at, buffer: this.buffer }); } };
};
var b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function atob(text) {
  var out = '', buffer = 0, bits = 0;
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i);
    if (c === '=') break;
    buffer = (buffer << 6) | b64.indexOf(c); bits += 6;
    if (bits >= 8) { bits -= 8; out += String.fromCharCode((buffer >> bits) & 255); }
  }
  return out;
}
var decode = function (text) { var raw = atob(text); var bytes = new Uint8Array(raw.length); for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i); return bytes; };
window.addEventListener = function (name, fn) { (window.listeners = window.listeners || []).push(name); (window.handlers = window.handlers || {})[name] = fn; };
window.removeEventListener = function (name) { if (window.handlers) delete window.handlers[name]; };
function setTimeout() {}
"""#

private func context(_ scripts: String...) -> JSContext {
    let js = JSContext()!
    js.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
    js.evaluateScript(webAudio)
    for script in scripts { js.evaluateScript(script) }
    return js
}

private func value(_ js: JSContext, _ script: String) -> String {
    js.evaluateScript(script)?.toString() ?? "undefined"
}

private func double(_ js: JSContext, _ script: String) -> Double {
    js.evaluateScript(script)?.toDouble() ?? .nan
}

/// One piece of `frames` frames of 16 kHz mono at `level`.
private func piece(_ seq: Int, frames: Int, level: Swift.Float = 0.5, rate: Int = 16_000) -> String {
    let data = PCM.int16([Swift.Float](repeating: level, count: frames)).base64EncodedString()
    return "{ seq: \(seq), frames: \(frames), rate: \(rate), channels: 1, data: '\(data)' }"
}

// MARK: - the player

private func player(pieces: [String]) -> JSContext {
    context("""
    var play = \(PCMPlayerScript.source);
    var context = new AudioContext(), destination = context.createMediaStreamDestination();
    var pieces = [\(pieces.joined(separator: ","))], at = 0, endedWith = null, asks = [];
    var pull = function (after) { asks.push(after); return at < pieces.length ? Promise.resolve(pieces[at++]) : new Promise(function () {}); };
    """)
}

@Test func piecesAreScheduledBackToBackALittleAheadOfTheClock() {
    let js = player(pieces: [piece(1, frames: 800), piece(2, frames: 800)])
    js.evaluateScript("var p = play(context, destination, pull, function (r) { endedWith = r; }, decode);")
    #expect(value(js, "scheduled.length") == "2")
    #expect(abs(double(js, "scheduled[0].at") - (1 + PCMPlayerScript.lead)) < 1e-9)
    #expect(abs(double(js, "scheduled[1].at") - (1 + PCMPlayerScript.lead + 0.05)) < 1e-9)
    // The samples, as they were: 0.5 in, 0.5 out.
    #expect(abs(double(js, "scheduled[0].buffer.getChannelData(0)[0]") - 0.5) < 0.001)
    #expect(value(js, "scheduled[0].buffer.sampleRate") == "16000")
    // Each ask says what the page has.
    #expect(value(js, "asks.join(',')") == "0,1,2")
}

@Test func soundTooFarAheadIsDroppedNeverQueued() {
    // Six pieces of 62.5 ms arriving at once, the clock standing still.
    let js = player(pieces: (1...6).map { piece($0, frames: 1_000) })
    js.evaluateScript("var p = play(context, destination, pull, function () {}, decode);")
    #expect(value(js, "scheduled.length") == "4")
    #expect(value(js, "p.state.dropped") == "2000")
    #expect(double(js, "scheduled[3].at") <= 1 + PCMPlayerScript.most)
}

@Test func aGapStartsTheLeadAgainAndASuspendedContextPlaysNothing() {
    // The clock runs on past what was scheduled before the next piece
    // comes: it starts a lead ahead of where the clock is now.
    let fresh = player(pieces: [piece(1, frames: 800), piece(2, frames: 800)])
    fresh.evaluateScript("""
    var p = play(context, destination, function (after) {
      if (after === 1) context.currentTime = 5;
      return pull(after);
    }, function () {}, decode);
    """)
    #expect(abs(double(fresh, "scheduled[1].at") - (5 + PCMPlayerScript.lead)) < 1e-9)
    // Suspended: nothing is scheduled, and nothing piles up for later.
    let asleep = player(pieces: [piece(1, frames: 800), piece(2, frames: 800)])
    asleep.evaluateScript("context.state = 'suspended'; var p = play(context, destination, pull, function () {}, decode);")
    #expect(value(asleep, "scheduled.length") == "0")
    #expect(value(asleep, "p.state.dropped") == "1600")
    #expect(value(asleep, "p.state.seq") == "2")
}

@Test func theSourceEndingIsSaidOnce() {
    let js = player(pieces: [piece(1, frames: 800), "{ ended: true, reason: 'the Mac went to sleep' }"])
    js.evaluateScript("var p = play(context, destination, pull, function (r) { endedWith = r; }, decode);")
    #expect(value(js, "endedWith") == "the Mac went to sleep")
    #expect(value(js, "p.state.live") == "false")
    #expect(value(js, "scheduled.length") == "1")
}

@Test func nonsensePiecesAreSkipped() {
    let js = player(pieces: [
        "{ seq: 1, frames: 10, rate: 16000, channels: 9, data: 'AAAA' }",
        "{ seq: 2, frames: 10, rate: 1, channels: 1, data: 'AAAA' }",
        "{ seq: 3, frames: 400, rate: 16000, channels: 1, data: 'AAAA' }", // shorter than it says
        "{ seq: 0 }",
        piece(4, frames: 800),
    ])
    js.evaluateScript("var p = play(context, destination, pull, function () {}, decode);")
    #expect(value(js, "scheduled.length") == "1")
    #expect(value(js, "p.state.seq") == "4")
}

// MARK: - a shared tab's sound

/// The page-side stand-ins TabShareScript needs on top of Web Audio.
private let sharePage = #"""
function MediaDevices() {}
MediaDevices.prototype.getDisplayMedia = function getDisplayMedia() { log.push('native'); return window.nativeAnswer(); };
var navigator = { mediaDevices: new MediaDevices() };
function Canvas() { this.width = 0; this.height = 0; }
Canvas.prototype.getContext = function () { return { fillRect: function () {}, drawImage: function () {} }; };
Canvas.prototype.captureStream = function () {
  var tracks = [new MediaStreamTrack()];
  return {
    getVideoTracks: function () { return tracks.filter(function (t) { return t.kind !== 'audio'; }); },
    getAudioTracks: function () { return tracks.filter(function (t) { return t.kind === 'audio'; }); },
    getTracks: function () { return tracks.slice(); }, addTrack: function (t) { tracks.push(t); },
  };
};
var document = { createElement: function () { return new Canvas(); } };
function Blob() {}
function createImageBitmap() { return Promise.resolve({ width: 1280, height: 720, close: function () {} }); }
var asked = [], sound = [], withSound = true, choice = 'tab';
window.nativeAnswer = function () { var e = new Error('denied'); e.name = 'NotAllowedError'; return Promise.reject(e); };
window.webkit = { messageHandlers: { copperShare: { postMessage: function (m) {
  asked.push(m);
  if (m.op === 'ask') {
    if (choice !== 'tab') return Promise.resolve({ choice: choice });
    return Promise.resolve({ choice: 'tab', share: 'S', width: 1280, height: 720, fps: 30, label: 'Weekly sync', audio: withSound });
  }
  if (m.op === 'frame') return m.after >= 1 ? new Promise(function () {}) : Promise.resolve({ seq: 1, data: 'AAAA', width: 1280, height: 720 });
  if (m.op === 'audio') return sound.length ? Promise.resolve(sound.shift()) : new Promise(function () {});
  return Promise.resolve(true);
} } } };
"""#

private func share(sound pieces: [String] = [], withSound: Bool = true, choice: String = "tab") -> JSContext {
    let js = context(sharePage, "sound = [\(pieces.joined(separator: ","))]; withSound = \(withSound); choice = '\(choice)';",
                     TabShareScript.source)
    js.evaluateScript("""
    var got = null, failed = null;
    navigator.mediaDevices.getDisplayMedia({ video: true, audio: { echoCancellation: false } })
      .then(function (s) { got = s; }, function (e) { failed = String(e && e.name); });
    """)
    return js
}

@Test func aTabSharedWithSoundCarriesAnAudioTrack() {
    let js = share(sound: [piece(1, frames: 800, rate: 48_000)])
    #expect(value(js, "failed") == "null")
    #expect(value(js, "got.getAudioTracks().length") == "1")
    #expect(value(js, "got.getVideoTracks().length") == "1")
    // Made inside the click, kept.
    #expect(value(js, "contexts.length") == "1")
    #expect(value(js, "contexts[0].state") == "running")
    let audio = "got.getAudioTracks()[0]"
    #expect(value(js, "\(audio).label") == "Weekly sync")
    #expect(value(js, "\(audio).getSettings().deviceId.indexOf('copper-tab:')") == "0")
    #expect(value(js, "\(audio).getSettings().channelCount") == "2")
    #expect(value(js, "\(audio).getSettings().echoCancellation") == "false")
    #expect(value(js, "JSON.stringify(\(audio).getSettings()).indexOf('\"S\"')") == "-1")
    // The sound is asked for, and played.
    #expect(value(js, "asked.filter(function (m) { return m.op === 'audio'; }).length >= 1") == "true")
    #expect(value(js, "scheduled.length") == "1")
}

@Test func keepingOnlyTheSoundStopsThePicturesNotTheShare() {
    let js = share()
    // What a transcriber does with a tab share: the pictures go at once.
    js.evaluateScript("got.getVideoTracks()[0].stop();")
    #expect(value(js, "asked.some(function (m) { return m.op === 'stop'; })") == "false")
    #expect(value(js, "contexts[0].state") == "running")
    // The sound's end is the share's.
    js.evaluateScript("got.getAudioTracks()[0].stop();")
    #expect(value(js, "asked[asked.length - 1].op") == "stop")
    #expect(value(js, "contexts[0].state") == "closed")
}

@Test func stoppingOnlyTheSoundTellsCopperAndKeepsThePictures() {
    let js = share()
    js.evaluateScript("got.getAudioTracks()[0].stop();")
    #expect(value(js, "asked[asked.length - 1].op") == "audio-stop")
    #expect(value(js, "contexts[0].state") == "closed")
    #expect(value(js, "got.getVideoTracks()[0].readyState") == "live")
}

@Test func coppersSoundEndingEndsTheAudioTrack() {
    let js = share(sound: ["{ ended: true, reason: 'no sound' }"])
    #expect(value(js, "got.getAudioTracks()[0].readyState") == "ended")
    #expect(value(js, "got.getAudioTracks()[0].heard.join(',')") == "ended")
    #expect(value(js, "got.getVideoTracks()[0].readyState") == "live")
}

@Test func aTabWithoutSoundOrAnotherAnswerClosesTheContext() {
    let quiet = share(withSound: false)
    #expect(value(quiet, "got.getAudioTracks().length") == "0")
    #expect(value(quiet, "contexts[0].state") == "closed")
    for answer in ["native", "cancel"] {
        let js = share(choice: answer)
        #expect(value(js, "contexts.length") == "1")
        #expect(value(js, "contexts[0].state") == "closed")
    }
}

@Test func aPageThatAsksNoSoundMakesNoContext() {
    let js = context(sharePage, TabShareScript.source)
    js.evaluateScript("navigator.mediaDevices.getDisplayMedia({ video: true });")
    #expect(value(js, "contexts.length") == "0")
}

// MARK: - a page served Copper's microphone

private let micPage = #"""
function MediaDevices() {}
MediaDevices.prototype.getUserMedia = function getUserMedia() { log.push('webkit'); return Promise.resolve('webkit-stream'); };
MediaDevices.prototype.enumerateDevices = function () {
  return Promise.resolve([{ kind: 'audioinput', deviceId: 'abc', label: 'AirPods Pro' }, { kind: 'videoinput', deviceId: 'cam', label: 'FaceTime' }]);
};
var navigator = { mediaDevices: new MediaDevices() };
var posted = [], busy = true, route = 'copper', sound = [];
window.webkit = { messageHandlers: { copperMic: { postMessage: function (m) {
  posted.push(m);
  if (m.op === 'watch') return m.busy === busy ? new Promise(function () {}) : Promise.resolve({ busy: busy });
  if (m.op === 'route') return Promise.resolve(route === 'copper' ? { route: 'copper', mic: 'M1', label: 'AirPods Pro', rate: 16000, channels: 1 } : { route: route });
  if (m.op === 'audio') return sound.length ? Promise.resolve(sound.shift()) : new Promise(function () {});
  return Promise.resolve(true);
} } } };
"""#

private func mic(busy: Bool = true, route: String = "copper", sound pieces: [String] = []) -> JSContext {
    context(micPage, "busy = \(busy); route = '\(route)'; sound = [\(pieces.joined(separator: ","))];", PageMicScript.source)
}

@Test func withNoOtherPageCapturingWebKitsCallIsMadeAtOnce() {
    let js = mic(busy: false)
    js.evaluateScript("var got = null; var answer = navigator.mediaDevices.getUserMedia({ audio: true }); log.push('returned');")
    // In the same turn as the page's call: its gesture, its rules.
    #expect(value(js, "log.join(',')") == "webkit,returned")
    #expect(value(js, "posted.filter(function (m) { return m.op === 'route'; }).length") == "0")
    #expect(value(js, "contexts.length") == "0")
}

@Test func whileAnotherPageCapturesTheMicrophoneIsCoppers() {
    let js = mic(sound: [piece(1, frames: 800)])
    js.evaluateScript("""
    var got = null, failed = null;
    navigator.mediaDevices.getUserMedia({ audio: { deviceId: { exact: 'abc' }, channelCount: 1, echoCancellation: true } })
      .then(function (s) { got = s; }, function (e) { failed = e.name; });
    """)
    #expect(value(js, "failed") == "null")
    #expect(value(js, "log.indexOf('webkit')") == "-1")
    // Copper is told the device by the name WebKit gave it.
    #expect(value(js, "posted.filter(function (m) { return m.op === 'route'; })[0].label") == "AirPods Pro")
    let track = "got.getAudioTracks()[0]"
    #expect(value(js, "\(track).label") == "AirPods Pro")
    #expect(value(js, "\(track).getSettings().deviceId") == "abc")
    #expect(value(js, "\(track).getSettings().channelCount") == "1")
    #expect(value(js, "\(track).getConstraints().echoCancellation") == "true")
    #expect(value(js, "scheduled.length") == "1")
    // Stopped by the page: Copper lets the microphone go.
    js.evaluateScript("\(track).stop();")
    #expect(value(js, "posted[posted.length - 1].op") == "stop")
    #expect(value(js, "posted[posted.length - 1].mic") == "M1")
    #expect(value(js, "contexts[0].state") == "closed")
}

@Test func copperCanSendThePageBackToWebKitOrSayNo() {
    let webkit = mic(route: "webkit")
    webkit.evaluateScript("var got = null; navigator.mediaDevices.getUserMedia({ audio: true }).then(function (s) { got = s; });")
    #expect(value(webkit, "got") == "webkit-stream")
    #expect(value(webkit, "contexts[0].state") == "closed")
    let denied = mic(route: "denied")
    denied.evaluateScript("var failed = null; navigator.mediaDevices.getUserMedia({ audio: true }).then(null, function (e) { failed = e.name; });")
    #expect(value(denied, "failed") == "NotAllowedError")
    #expect(value(denied, "log.length") == "0")
}

@Test func theCameraTooIsAlwaysWebKits() {
    let js = mic()
    js.evaluateScript("navigator.mediaDevices.getUserMedia({ audio: true, video: true });")
    #expect(value(js, "log.join(',')") == "webkit")
    #expect(value(js, "posted.filter(function (m) { return m.op === 'route'; }).length") == "0")
}

@Test func theMicrophoneGoingAwayEndsTheTrack() {
    let js = mic(sound: ["{ ended: true, reason: 'the microphone went away' }"])
    js.evaluateScript("var got = null; navigator.mediaDevices.getUserMedia({ audio: true }).then(function (s) { got = s; });")
    #expect(value(js, "got.getAudioTracks()[0].readyState") == "ended")
    #expect(value(js, "got.getAudioTracks()[0].heard.join(',')") == "ended")
    // Copper ended it: nothing to tell it back.
    #expect(value(js, "posted.filter(function (m) { return m.op === 'stop'; }).length") == "0")
}

@Test func aClickWhileAnotherPageCapturesReadiesTheContextForALaterRequest() {
    let js = mic(sound: [piece(1, frames: 800)])
    // Copper said another page captures: the page's clicks are listened for.
    #expect(value(js, "typeof window.handlers.pointerdown") == "function")
    // A click: a context started inside it, then quiet.
    js.evaluateScript("window.handlers.pointerdown();")
    #expect(value(js, "contexts.length") == "1")
    #expect(value(js, "contexts[0].state") == "suspended")
    // The request a few awaits later uses it, running again.
    js.evaluateScript("var got = null; navigator.mediaDevices.getUserMedia({ audio: true }).then(function (s) { got = s; });")
    #expect(value(js, "contexts.length") == "1")
    #expect(value(js, "contexts[0].state") == "running")
    #expect(value(js, "scheduled.length") == "1")
}

@Test func noOtherPageCapturingNoClickIsListenedFor() {
    let js = mic(busy: false)
    #expect(value(js, "window.handlers === undefined || window.handlers.pointerdown === undefined") == "true")
}

@Test func theMicWrapperLooksLikeTheOriginal() {
    let js = mic(busy: false)
    #expect(value(js, "navigator.mediaDevices.getUserMedia.name") == "getUserMedia")
    #expect(value(js, "Object.prototype.hasOwnProperty.call(navigator.mediaDevices, 'getUserMedia')") == "false")
}
