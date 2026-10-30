import Foundation

// The page's half of tab sharing (docs/screen-sharing.md).
//
// WebKit's getDisplayMedia only knows windows and screens. This wraps it so a
// page can be handed one Copper tab instead, without changing anything for a
// page that never asks: the wrapper only exists on the prototype, and does
// nothing at all until getDisplayMedia is called.
//
// When it is called, the original runs at once, inside the same click, so
// WebKit's own rules — a user gesture, one request at a time, a visible
// document, the display-capture permissions policy — are WebKit's, untouched.
// Alongside it the page tells Copper an ask is coming ("ask"), and WebKit's
// request reaches Copper's private UI delegate (TabShareDelegate.swift), which
// puts up Copper's picker. A window or the screen goes on to WebKit's own
// system picker and the original's stream is the answer. A tab: Copper
// refuses WebKit's request and answers the ask with a share, and the wrapper
// builds the stream itself — a canvas that is never in the document, fed with
// pictures of the tab (TabShareCapture.swift), captured as a video track.
// Cancel: WebKit's refusal is the answer, NotAllowedError, as in Chrome.
//
// The canvas stays out of the document on purpose: a canvas WebKit does not
// draw on screen hands each new picture to its capture track at once, so the
// track keeps its pace while the calling page is a background tab.
enum TabShareScript {
    /// The script message handler's name (`window.webkit.messageHandlers.copperShare`).
    static let handler = "copperShare"

    static let source = #"""
(() => {
  'use strict';
  // The interfaces, not navigator.mediaDevices: reading that makes the
  // frame's MediaDevices object, in every frame of every page, for nothing.
  // (Neither interface exists outside a secure context.)
  if (typeof MediaDevices === 'undefined' || typeof MediaStreamTrack === 'undefined') return;
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copperShare;
  if (!bridge) return;
  const proto = MediaDevices.prototype;
  const described = Object.getOwnPropertyDescriptor(proto, 'getDisplayMedia');
  if (!described || typeof described.value !== 'function') return;
  const original = described.value;
  const post = bridge.postMessage.bind(bridge);
  // Fire and forget: a message whose answer nobody needs must never become an
  // unhandled rejection in the page's console.
  const send = (message) => { try { Promise.resolve(post(message)).catch(() => {}); } catch (e) {} };
  const trackProto = MediaStreamTrack.prototype;
  const realStop = trackProto.stop, realClone = trackProto.clone, realSettings = trackProto.getSettings;
  const define = (target, name, value) => Object.defineProperty(target, name, { value, configurable: true, writable: true });
  const fromBase64 = typeof Uint8Array.fromBase64 === 'function'
    ? (text) => Uint8Array.fromBase64(text)
    : (text) => { const raw = atob(text); const bytes = new Uint8Array(raw.length); for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i); return bytes; };
  const live = new Set();
  let counter = 0;
  // Leaving the page ends what it was sharing; nothing outlives its
  // document. Listened for from the first share on, not on every page.
  // (Copper also ends it itself the moment another document commits.)
  let listening = false;
  const listen = () => {
    if (listening) return;
    listening = true;
    window.addEventListener('pagehide', () => { for (const state of [...live]) end(state, false); });
  };

  // What the page asked for, as plain data: numbers and words only.
  const plain = (value) => {
    if (value === undefined || value === null) return null;
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') return value;
    if (typeof value !== 'object') return null;
    const out = {};
    for (const key of ['width', 'height', 'frameRate', 'aspectRatio', 'displaySurface', 'cursor', 'logicalSurface']) {
      const part = value[key];
      if (part === undefined) continue;
      if (typeof part === 'object' && part !== null) {
        const range = {};
        for (const edge of ['min', 'max', 'ideal', 'exact']) if (typeof part[edge] === 'number' || typeof part[edge] === 'string') range[edge] = part[edge];
        out[key] = range;
      } else if (typeof part === 'number' || typeof part === 'string' || typeof part === 'boolean') out[key] = part;
    }
    return out;
  };

  function end(state, fromCopper) {
    if (!state.live) return;
    state.live = false;
    live.delete(state);
    for (const track of state.tracks) {
      if (track.readyState === 'ended') continue;
      realStop.call(track);
      // The source went away (Copper's Stop, the tab closed): the page hears
      // it as it would for any capture — `ended` on every track. A page that
      // stops its own track hears nothing, as the spec has it.
      if (fromCopper) { try { track.dispatchEvent(new Event('ended')); } catch (e) {} }
    }
    if (!fromCopper) send({ op: 'stop', share: state.share });
    if (state.firstDone) { state.firstDone(); state.firstDone = null; }
  }

  function dress(track, state) {
    state.tracks.add(track);
    try { track.contentHint = 'detail'; } catch (e) {}
    Object.defineProperty(track, 'label', { get: () => state.label, configurable: true });
    define(track, 'getSettings', function getSettings() {
      const settings = realSettings.call(this) || {};
      const width = state.canvas.width, height = state.canvas.height;
      return Object.assign(settings, {
        width, height, aspectRatio: height ? width / height : undefined, frameRate: state.fps,
        displaySurface: 'browser', logicalSurface: true, cursor: 'never', resizeMode: 'crop-and-scale',
        deviceId: state.device,
      });
    });
    define(track, 'getCapabilities', function getCapabilities() {
      return {
        width: { min: 1, max: state.maxWidth }, height: { min: 1, max: state.maxHeight },
        aspectRatio: { min: 1 / state.maxHeight, max: state.maxWidth }, frameRate: { min: 0, max: 30 },
        displaySurface: 'browser', logicalSurface: true, cursor: ['never'], resizeMode: ['none', 'crop-and-scale'],
        deviceId: state.device,
      };
    });
    define(track, 'getConstraints', function getConstraints() { return Object.assign({}, state.constraints); });
    define(track, 'applyConstraints', function applyConstraints(constraints) {
      state.constraints = (constraints && typeof constraints === 'object') ? constraints : {};
      if (!state.live) return Promise.resolve();
      return Promise.resolve(post({ op: 'tune', share: state.share, want: plain(state.constraints) }))
        .then((tuned) => { if (tuned && tuned.fps) state.fps = tuned.fps; }, () => {});
    });
    define(track, 'stop', function stop() {
      realStop.call(this);
      // The share ends with the last of its tracks, clones included.
      if (state.live && [...state.tracks].every((each) => each.readyState === 'ended')) end(state, false);
    });
    define(track, 'clone', function clone() {
      const copy = realClone.call(this);
      if (copy) dress(copy, state);
      return copy;
    });
  }

  async function pump(state) {
    let seq = 0;
    while (state.live) {
      let frame;
      try { frame = await post({ op: 'frame', share: state.share, after: seq }); } catch (e) { end(state, true); return; }
      if (!state.live) return;
      if (!frame || frame.ended) { end(state, true); return; }
      if (typeof frame.seq !== 'number' || frame.seq <= seq) continue;
      seq = frame.seq;
      try {
        const picture = await createImageBitmap(new Blob([fromBase64(frame.data)], { type: 'image/jpeg' }));
        if (!state.live) { picture.close(); return; }
        const canvas = state.canvas;
        if (canvas.width !== picture.width || canvas.height !== picture.height) {
          canvas.width = picture.width; canvas.height = picture.height;
        }
        state.context.drawImage(picture, 0, 0);
        picture.close();
        if (state.firstDone) { state.firstDone(); state.firstDone = null; }
      } catch (e) { /* one bad picture: wait for the next */ }
    }
  }

  async function build(answer, options, id) {
    const canvas = document.createElement('canvas');
    canvas.width = answer.width || 1280;
    canvas.height = answer.height || 720;
    const context = canvas.getContext('2d', { alpha: false });
    context.fillStyle = '#000';
    context.fillRect(0, 0, canvas.width, canvas.height);
    const stream = canvas.captureStream();
    const track = stream.getVideoTracks()[0];
    const video = options && typeof options.video === 'object' ? options.video : {};
    const state = {
      // The device's name is the page's own ask id, never the share's: that
      // stays between this script and Copper.
      share: answer.share, device: 'copper-tab:' + id, live: true, tracks: new Set(), canvas, context, fps: answer.fps || 30,
      label: answer.label || 'Tab', constraints: Object.assign({}, video),
      maxWidth: answer.maxWidth || canvas.width, maxHeight: answer.maxHeight || canvas.height, firstDone: null,
    };
    live.add(state);
    listen();
    dress(track, state);
    const first = new Promise((done) => { state.firstDone = done; });
    pump(state);
    // The first picture before the page sees the stream, so a call never
    // starts on a black frame; a slow tab gets two seconds.
    await Promise.race([first, new Promise((done) => setTimeout(done, 2000))]);
    if (!state.live) throw new DOMException('The shared tab went away.', 'AbortError');
    return stream;
  }

  // A Proxy of the original, not a new function: to feature detection it is
  // the same function — its name, its length, `[native code]` from
  // Function.prototype.toString — until it is called.
  const wrapper = new Proxy(original, {
    apply(target, self, args) {
      const options = args[0];
      const id = Date.now().toString(36) + '.' + (++counter) + '.' + Math.random().toString(36).slice(2);
      let ask;
      try {
        ask = Promise.resolve(post({
          op: 'ask', id,
          audio: !!(options && options.audio),
          video: options && options.video !== undefined ? plain(options.video) : true,
          selfBrowserSurface: options && typeof options.selfBrowserSurface === 'string' ? options.selfBrowserSurface : null,
          preferCurrentTab: !!(options && options.preferCurrentTab),
        })).catch(() => null);
      } catch (e) { ask = Promise.resolve(null); }
      // WebKit's own request, now, inside the same click: its checks — the
      // gesture, the visible document, the permissions policy — stay its own.
      let native;
      try { native = Reflect.apply(target, self, args); } catch (e) { send({ op: 'drop', id }); throw e; }
      return new Promise((resolve, reject) => {
        let settled = false;
        const finish = (how, value) => { if (!settled) { settled = true; how(value); } };
        ask.then((answer) => {
          if (!answer || answer.choice !== 'tab') return;
          // WebKit's own request was refused on purpose; its rejection is not news.
          Promise.resolve(native).catch(() => {});
          build(answer, options, id).then((stream) => finish(resolve, stream), (error) => finish(reject, error));
        });
        Promise.resolve(native).then(
          (stream) => { send({ op: 'drop', id }); finish(resolve, stream); },
          (error) => {
            send({ op: 'settled', id });
            ask.then((answer) => { if (!answer || answer.choice !== 'tab') finish(reject, error); });
          });
      });
    },
  });
  Object.defineProperty(proto, 'getDisplayMedia', Object.assign({}, described, { value: wrapper }));
})();
"""#
}
