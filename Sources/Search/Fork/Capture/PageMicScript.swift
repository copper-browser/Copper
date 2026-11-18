import Foundation

// The page's half of PageMic (PageMic.swift): getUserMedia wrapped in the
// main frame, so an audio-only request can be served Copper's microphone
// while another page is capturing.
//
// Nothing changes while no other page captures: the wrapper calls WebKit's
// own getUserMedia at once, in the same turn — its user-gesture rules, its
// remembered refusals, its focus rules stay its own. Copper says when that
// changes (`watch`, a long poll answered only when it does), and only then
// is an audio-only request put to Copper first (`route`): Copper answers
// "webkit" (WebKit's call is made then), "denied" (NotAllowedError, as
// WebKit's), or a microphone of its own, whose sound plays into a Web Audio
// graph whose MediaStreamAudioDestinationNode is the page's track
// (PCMPlayerScript). WebKit lets a context start only inside a click, and a
// page usually asks for the microphone a few awaits after one (a transcriber
// loads its worklet first). So while another page is capturing, a click or
// key in the page readies a context — started inside it, then suspended at
// once, so it renders nothing — for a request in the next half minute;
// started that way it may run again later without a click. Failing that, one
// is made inside the call (in case that is a click), and failing that it
// starts on the page's next click. No gesture is ever given to the page.
//
// The device the page asked for is named to Copper by the label WebKit gave
// it (its ids are WebKit's, salted per site), read from enumerateDevices.
enum PageMicScript {
    static let source = #"""
(() => {
  'use strict';
  if (typeof MediaDevices === 'undefined' || typeof MediaStreamTrack === 'undefined') return;
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copperMic;
  if (!bridge) return;
  const AudioCtx = typeof window.AudioContext === 'function' ? window.AudioContext : null;
  if (!AudioCtx) return;
  const proto = MediaDevices.prototype;
  const described = Object.getOwnPropertyDescriptor(proto, 'getUserMedia');
  if (!described || typeof described.value !== 'function') return;
  const original = described.value;
  const enumerate = proto.enumerateDevices;
  const post = bridge.postMessage.bind(bridge);
  const send = (message) => { try { Promise.resolve(post(message)).catch(() => {}); } catch (e) {} };
  const trackProto = MediaStreamTrack.prototype;
  const realStop = trackProto.stop, realClone = trackProto.clone, realSettings = trackProto.getSettings;
  const define = (target, name, value) => Object.defineProperty(target, name, { value, configurable: true, writable: true });
  const fromBase64 = typeof Uint8Array.fromBase64 === 'function'
    ? (text) => Uint8Array.fromBase64(text)
    : (text) => { const raw = atob(text); const bytes = new Uint8Array(raw.length); for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i); return bytes; };
  const player = \#(PCMPlayerScript.source);

  const openSound = () => {
    try {
      const context = new AudioCtx({ latencyHint: 'interactive' });
      try { Promise.resolve(context.resume()).catch(() => {}); } catch (e) {}
      return context;
    } catch (e) { return null; }
  };
  const closeSound = (context) => {
    if (!context) return;
    try { Promise.resolve(context.close()).catch(() => {}); } catch (e) {}
  };

  // A context readied by the page's last click, while another page captures.
  let ready = null, readyTimer = 0;
  const forget = () => { if (readyTimer) { try { clearTimeout(readyTimer); } catch (e) {} readyTimer = 0; } };
  const readyUp = () => {
    forget();
    if (!ready || ready.state === 'closed') {
      const context = openSound();
      if (!context) return;
      ready = context;
      // Started inside the click, then quiet until it is wanted.
      Promise.resolve(context.resume()).then(() => {
        if (ready === context) { try { Promise.resolve(context.suspend()).catch(() => {}); } catch (e) {} }
      }, () => {});
    }
    const mine = ready;
    readyTimer = setTimeout(() => { if (ready === mine) { closeSound(mine); ready = null; } readyTimer = 0; }, 30000);
  };
  const takeReady = () => {
    const context = ready;
    ready = null;
    forget();
    if (!context || context.state === 'closed') return null;
    try { Promise.resolve(context.resume()).catch(() => {}); } catch (e) {}
    return context;
  };
  const gestures = ['pointerdown', 'mousedown', 'keydown', 'touchend', 'click'];
  let readying = false;
  const readyOnClicks = (on) => {
    if (on === readying) return;
    readying = on;
    for (const kind of gestures) (on ? window.addEventListener : window.removeEventListener).call(window, kind, readyUp, true);
    if (!on && ready) { closeSound(ready); ready = null; forget(); }
  };

  // Whether another page is capturing, as Copper last said.
  let busy = false;
  const watch = () => {
    let asked;
    try { asked = Promise.resolve(post({ op: 'watch', busy })); } catch (e) { return; }
    asked.then((answer) => {
      if (!answer || typeof answer.busy !== 'boolean') return;
      busy = answer.busy;
      readyOnClicks(busy);
      watch();
    }, () => {});
  };
  watch();

  const live = new Set();
  let listening = false;
  const listen = () => {
    if (listening) return;
    listening = true;
    window.addEventListener('pagehide', () => { for (const state of [...live]) end(state, false); });
  };

  const wake = (context) => {
    if (!context || context.state === 'running') return;
    const kinds = ['pointerdown', 'keydown', 'click'];
    const off = () => { for (const kind of kinds) window.removeEventListener(kind, kick, true); };
    function kick() {
      if (context.state === 'running' || context.state === 'closed') return off();
      try { Promise.resolve(context.resume()).then(off, () => {}); } catch (e) {}
    }
    for (const kind of kinds) window.addEventListener(kind, kick, true);
  };

  function end(state, fromCopper) {
    if (!state.live) return;
    state.live = false;
    live.delete(state);
    if (state.player) state.player.stop();
    closeSound(state.context);
    for (const track of state.tracks) {
      if (track.readyState === 'ended') continue;
      realStop.call(track);
      if (fromCopper) { try { track.dispatchEvent(new Event('ended')); } catch (e) {} }
    }
    if (!fromCopper) send({ op: 'stop', mic: state.mic });
  }

  function dress(track, state) {
    state.tracks.add(track);
    Object.defineProperty(track, 'label', { get: () => state.label, configurable: true });
    define(track, 'getSettings', function getSettings() {
      const settings = realSettings.call(this) || {};
      return Object.assign(settings, {
        deviceId: state.device, groupId: '', sampleRate: state.rate, channelCount: 1, sampleSize: 16,
        echoCancellation: false, autoGainControl: false, noiseSuppression: false,
      });
    });
    define(track, 'getCapabilities', function getCapabilities() {
      return {
        deviceId: state.device, groupId: '', sampleRate: { min: state.rate, max: state.rate }, channelCount: { min: 1, max: 1 },
        sampleSize: { min: 16, max: 16 }, echoCancellation: [false], autoGainControl: [false], noiseSuppression: [false],
      };
    });
    define(track, 'getConstraints', function getConstraints() { return Object.assign({}, state.constraints); });
    define(track, 'applyConstraints', function applyConstraints(constraints) {
      state.constraints = (constraints && typeof constraints === 'object') ? constraints : {};
      return Promise.resolve();
    });
    define(track, 'stop', function stop() {
      realStop.call(this);
      if (state.live && [...state.tracks].every((each) => each.readyState === 'ended')) end(state, false);
    });
    define(track, 'clone', function clone() {
      const copy = realClone.call(this);
      if (copy) dress(copy, state);
      return copy;
    });
  }

  function build(answer, context, device, asked) {
    const destination = context.createMediaStreamDestination();
    try { destination.channelCount = 1; } catch (e) {}
    const stream = destination.stream;
    const track = stream.getAudioTracks()[0];
    const state = {
      mic: answer.mic, live: true, tracks: new Set(), context, player: null, label: answer.label || 'Microphone',
      device: device || 'default', rate: context.sampleRate,
      constraints: asked && typeof asked === 'object' ? Object.assign({}, asked) : {},
    };
    live.add(state);
    listen();
    dress(track, state);
    state.player = player(context, destination, (after) => post({ op: 'audio', mic: state.mic, after }),
                          () => end(state, true), fromBase64);
    wake(context);
    return stream;
  }

  // What the page asked for, read the way getUserMedia reads it.
  const audioOnly = (constraints) => !!(constraints && typeof constraints === 'object' && constraints.audio && !constraints.video);
  const deviceOf = (audio) => {
    if (!audio || typeof audio !== 'object') return null;
    let id = audio.deviceId;
    if (id && typeof id === 'object' && !Array.isArray(id)) id = id.exact !== undefined ? id.exact : id.ideal;
    if (Array.isArray(id)) id = id[0];
    return typeof id === 'string' && id && id !== 'default' ? id : null;
  };
  const labelOf = async (devices, id) => {
    if (!id || typeof enumerate !== 'function') return null;
    try {
      const list = await Reflect.apply(enumerate, devices, []);
      for (const device of list) if (device.kind === 'audioinput' && device.deviceId === id) return device.label || null;
    } catch (e) {}
    return null;
  };

  // A Proxy of what is there now (CaptureHook's wrapper of WebKit's): to
  // feature detection the same function.
  const wrapper = new Proxy(original, {
    apply(target, self, args) {
      const constraints = args[0];
      if (!busy || !audioOnly(constraints)) return Reflect.apply(target, self, args);
      // Readied by a click, or made now in case this is one.
      const sound = takeReady() || openSound();
      return (async () => {
        const device = deviceOf(constraints.audio);
        const label = await labelOf(self, device);
        let answer = null;
        try { answer = await post({ op: 'route', audio: true, video: false, label }); } catch (e) {}
        if (!answer || answer.route === 'webkit' || (answer.route === 'copper' && typeof answer.mic !== 'string')) {
          closeSound(sound);
          return Reflect.apply(target, self, args);
        }
        if (answer.route !== 'copper') {
          closeSound(sound);
          throw new DOMException('The request is not allowed by the user agent or the platform in the current context.', 'NotAllowedError');
        }
        const context = sound || openSound();
        if (!context) { send({ op: 'stop', mic: answer.mic }); return Reflect.apply(target, self, args); }
        return build(answer, context, device, constraints.audio);
      })();
    },
  });
  Object.defineProperty(proto, 'getUserMedia', Object.assign({}, described, { value: wrapper }));
})();
"""#
}
