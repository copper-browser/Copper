import AppKit
import WebKit
import os

// Page voice: `window.copper.voice.listen()` for a web page in a tab.
//
// A page that already captures audio (a meeting recorder such as RGS) can
// have Copper's on-device Phonon-2 turn that same audio into words, with
// their times, while it goes on doing whatever it does with the audio. The
// page pushes its own 16 kHz mono PCM; Copper never opens the microphone
// for it, never keeps the audio and never sends anything anywhere. Words come
// back as events: `partial` (the phrase in flight, a guess that keeps
// changing), `final` (one finished phrase: text, start/end and per-word
// times, in seconds from the first sample the page pushed) and `end`.
//
// Who may ask: pages whose host matches `voice.pages.sites` in Copper's
// settings (default `*.apps.exowatt.com`, Exowatt's internal apps) — every
// other site never sees `window.copper`. Even an allowed site gets nothing
// until the person says yes once to "<site> wants to use your on-device
// speech to text", asked and remembered the way the microphone is
// (Browser.askPageVoice, `capture.<host>|voice`; Settings › Privacy forgets
// it with the camera and microphone choices). Voice must be on and its model
// ready (Settings › Intelligence › Voice); `voice.state()` says so first.
//
// It is the same live loop as Listen (LiveSession, `.listen`: a phrase ends
// at a 0.7 s pause or 15 s), fed by the page instead of the microphone. Each
// final is decoded once more for word timings (VoiceEngine.transcribe; tens
// of milliseconds for a phrase). docs/voice.md › On web pages.

/// The page's channel in. WebKit keeps every handler strongly, so it is one
/// object for every tab, holding nothing.
final class PageVoiceRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "copperPageVoice"
    static let shared = PageVoiceRelay()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated { PageVoice.shared.received(message, reply: replyHandler) }
    }
}

@MainActor
final class PageVoice {
    static let shared = PageVoice()
    static let log = Logger(subsystem: "com.collinrijock.copper", category: "pagevoice")

    /// Hosts that may ask, in `Store.settings`: exact hosts or `*.domain`.
    static let sitesKey = "voice.pages.sites"
    static let defaultSites = ["*.apps.exowatt.com"]
    /// The question, after "<host> wants to use your ".
    static let asks = "on-device speech to text"

    /// No audio for this long ends a session: its page went away.
    static let idleLimit: TimeInterval = 30
    /// Audio kept for the word-timing decode of a final (a final covers at most 16 s).
    static let keepSamples = 16_000 * 60
    /// At most this many at once (a new one from the same page replaces its old one).
    static let maxSessions = 3

    static var sites: [String] {
        let listed = (Store.settings.array(forKey: sitesKey) as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return listed ?? defaultSites
    }

    /// `host` matches one of `sites`: the host itself, or `*.domain` for
    /// the domain and every host under it.
    nonisolated static func allows(host: String, sites: [String]) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        for site in sites {
            if site.hasPrefix("*.") {
                let base = String(site.dropFirst(2))
                if !base.isEmpty, host == base || host.hasSuffix("." + base) { return true }
            } else if host == site {
                return true
            }
        }
        return false
    }

    /// Plain http only for this Mac itself (a page served locally); the rest https.
    nonisolated static func secure(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased()
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    /// The page's half, injected into every main frame at document start; it
    /// defines nothing unless the host is listed.
    static var script: String {
        let sites = (try? JSONSerialization.data(withJSONObject: sites)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return pageScript.replacingOccurrences(of: "__SITES__", with: sites)
    }

    // MARK: - sessions

    private final class Listening {
        let id: Int
        weak var web: WKWebView?
        let host: String
        let live: LiveSession
        /// Audio pushed so far, from sample `base` of the session on.
        var audio: [Swift.Float] = []
        var base = 0
        var fed = 0
        var lastFed = Date()
        /// Finals in order: each waits for the one before it.
        var tail: Task<Void, Never>?
        var finals = 0

        init(id: Int, web: WKWebView, host: String, live: LiveSession) {
            self.id = id
            self.web = web
            self.host = host
            self.live = live
        }

        func slice(_ t0ms: Int, _ t1ms: Int) -> [Swift.Float] {
            let from = max(t0ms * 16 - base, 0), to = min(t1ms * 16 - base, audio.count)
            return from < to ? Array(audio[from..<to]) : []
        }
    }

    private var sessions: [Int: Listening] = [:]
    private var nextID = 1
    private var sweeper: Timer?

    /// A page is listening: the model stays loaded.
    var listening: Bool { !sessions.isEmpty }

    // MARK: - messages

    func received(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        let host = origin.host.lowercased()
        guard message.frameInfo.isMainFrame, let web = message.webView,
              Self.secure(scheme: origin.protocol, host: host), Self.allows(host: host, sites: Self.sites) else {
            reply(Self.refusal("denied", "This site can't use Copper Voice."), nil)
            return
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            reply(Self.refusal("bad_request", "Not a page voice call."), nil)
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]
        let id = (params["id"] as? NSNumber)?.intValue ?? 0
        switch method {
        case "audio":
            feed(id, params["pcm"] as? String, from: web)
            reply(nil, nil)
        case "state":
            reply(state(host: host), nil)
        case "start":
            Task { reply(await self.start(web: web, host: host, params: params), nil) }
        case "stop":
            Task { reply(await self.stop(id, from: web), nil) }
        case "cancel":
            cancel(id, from: web, reason: "cancelled")
            reply(["ok": true], nil)
        default:
            reply(Self.refusal("bad_request", "No page voice method \"\(method)\"."), nil)
        }
    }

    private static func refusal(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "code": code, "message": message]
    }

    private func remembered(_ host: String) -> Bool? {
        Store.settings.object(forKey: "capture.\(host)|voice") as? Bool
    }

    func state(host: String) -> [String: Any] {
        let supported = VoicePrefs.supported
        let enabled = supported && VoicePrefs.shared.enabled
        let consent = remembered(host).map { $0 ? "granted" : "denied" } ?? "ask"
        return [
            "ok": true,
            "available": supported,
            "enabled": enabled,
            "model": ModelStore.shared.stateName,
            "ready": enabled && ModelStore.shared.state == .ready,
            "consent": consent,
            "engine": "phonon-2",
            "sampleRate": LiveSession.sampleRate,
        ]
    }

    private func start(web: WKWebView, host: String, params: [String: Any]) async -> [String: Any] {
        let rate = (params["sampleRate"] as? NSNumber)?.intValue ?? LiveSession.sampleRate
        guard rate == LiveSession.sampleRate else {
            return Self.refusal("bad_request", "Push 16 kHz mono audio (sampleRate 16000).")
        }
        guard VoicePrefs.supported else { return Self.refusal("disabled", AddonVoice.unsupported) }
        guard VoicePrefs.shared.enabled else { return Self.refusal("disabled", AddonVoice.off) }
        guard ModelStore.shared.state == .ready, ModelStore.shared.modelDir != nil else {
            return Self.refusal("not_ready", "Copper's speech model isn't ready (\(ModelStore.shared.stateName)).")
        }
        let granted: Bool
        if let known = remembered(host) {
            granted = known
        } else {
            let browser = Windows.all.first { $0.tab(for: web) != nil } ?? Windows.current
            granted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                browser.askPageVoice(host: host) { done.resume(returning: $0) }
            }
        }
        guard granted else { return Self.refusal("denied", "Not allowed for \(host) — Settings › Privacy forgets that choice.") }
        guard #available(macOS 15, *), let dir = ModelStore.shared.modelDir else {
            return Self.refusal("not_ready", "Copper's speech model isn't ready.")
        }
        // One per page: a page starting again (a reload, a second recording)
        // replaces what it had.
        for old in sessions.values where old.web === web { cancel(old.id, from: web, reason: "replaced") }
        while sessions.count >= Self.maxSessions, let oldest = sessions.keys.min() {
            cancel(oldest, from: nil, reason: "replaced")
        }
        Voice.shared.ensureWarm()
        let id = nextID
        nextID += 1
        let decode: @Sendable ([Swift.Float]) async throws -> String = { samples in
            await Voice.untilWarm()
            try await VoiceEngine.shared.prepare(modelDir: dir) { _ in }
            return try await VoiceEngine.shared.transcribe(samples).text
        }
        let live = LiveSession(mode: .listen, decode: decode) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { PageVoice.shared.heard(event, id: id) } }
        }
        sessions[id] = Listening(id: id, web: web, host: host, live: live)
        armSweeper()
        Self.log.info("page voice: session \(id, privacy: .public) for \(host, privacy: .public)")
        return ["ok": true, "id": id, "sampleRate": LiveSession.sampleRate, "engine": "phonon-2"]
    }

    private func feed(_ id: Int, _ pcm: String?, from web: WKWebView) {
        guard let s = sessions[id], s.web === web, let pcm, let data = Data(base64Encoded: pcm) else { return }
        let count = data.count / 2
        guard count > 0 else { return }
        var samples = [Swift.Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                samples[i] = Swift.Float(Int16(bitPattern: lo | hi << 8)) / 32_768
            }
        }
        s.audio.append(contentsOf: samples)
        if s.audio.count > Self.keepSamples + 16_000 * 10 {
            let drop = s.audio.count - Self.keepSamples
            s.audio.removeFirst(drop)
            s.base += drop
        }
        s.fed += count
        s.lastFed = Date()
        // LiveSession's gate is tuned on 50 ms blocks.
        var at = 0
        while at < count {
            let end = min(at + 800, count)
            s.live.feed(Array(samples[at..<end]))
            at = end
        }
    }

    private func heard(_ event: LiveEvent, id: Int) {
        guard let s = sessions[id] else { return }
        switch event {
        case .partial(let text):
            deliver(s, ["type": "partial", "text": text])
        case .final(let segment):
            let audio = s.slice(segment.t0ms, segment.t1ms)
            let before = s.tail
            s.finals += 1
            s.tail = Task { @MainActor in
                await before?.value
                let words = await Self.words(for: segment, audio: audio)
                self.deliver(s, [
                    "type": "final",
                    "seq": segment.seq,
                    "start": Double(segment.t0ms) / 1000,
                    "end": Double(segment.t1ms) / 1000,
                    "text": segment.text,
                    "words": words,
                ])
            }
        }
    }

    private func stop(_ id: Int, from web: WKWebView) async -> [String: Any] {
        guard let s = sessions[id], s.web === web else { return ["ok": true] }
        _ = await s.live.finish()
        // finish() returns once its events are out of LiveSession, and they
        // hop to the main actor ahead of this; the last final's words follow.
        while let tail = s.tail {
            await tail.value
            if s.tail == tail { break }
        }
        deliver(s, ["type": "end", "reason": "stopped"])
        sessions[id] = nil
        Self.log.info("page voice: session \(id, privacy: .public) stopped, \(s.finals, privacy: .public) finals")
        return ["ok": true, "finals": s.finals]
    }

    private func cancel(_ id: Int, from web: WKWebView?, reason: String) {
        guard let s = sessions[id], web == nil || s.web === web else { return }
        s.live.cancel()
        s.tail?.cancel()
        deliver(s, ["type": "end", "reason": reason])
        sessions[id] = nil
    }

    private func deliver(_ s: Listening, _ event: [String: Any]) {
        guard let web = s.web, let json = AddonSlotHost.json([s.id, event]) else { return }
        web.evaluateJavaScript("window.__copperPageVoice && window.__copperPageVoice.emit.apply(null, \(json))", completionHandler: nil)
    }

    /// Pages that went away (closed, reloaded, gone quiet) let go of theirs.
    private func armSweeper() {
        guard sweeper == nil else { return }
        sweeper = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { PageVoice.shared.sweep() }
        }
    }

    private func sweep() {
        let now = Date()
        for s in sessions.values where s.web == nil || now.timeIntervalSince(s.lastFed) > Self.idleLimit {
            cancel(s.id, from: nil, reason: s.web == nil ? "page closed" : "no audio")
        }
        if sessions.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
            Voice.shared.scheduleUnload()
        }
    }

    // MARK: - word timings

    /// The final's words with their times (seconds from the session's first
    /// sample). Its audio is decoded once more for timings; when that decode
    /// hears a different number of words than the final (the final was
    /// rescued in halves, say), the final's words are spread over its span
    /// instead and marked `approx`.
    static func words(for segment: VoiceSegment, audio: [Swift.Float]) async -> [[String: Any]] {
        let t0 = Double(segment.t0ms) / 1000, t1 = Double(segment.t1ms) / 1000
        if #available(macOS 15, *), !audio.isEmpty, let dir = ModelStore.shared.modelDir {
            do {
                try await VoiceEngine.shared.prepare(modelDir: dir) { _ in }
                let heard = try await VoiceEngine.shared.transcribe(audio)
                if agrees(heard.words.count, segment.text) {
                    return heard.words.map { ["text": $0.text, "start": round3(t0 + $0.start), "end": round3(t0 + $0.end)] }
                }
            } catch {
                log.error("page voice: word timings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return spread(segment.text, from: t0, to: t1)
    }

    nonisolated static func agrees(_ count: Int, _ text: String) -> Bool {
        let want = text.split(whereSeparator: \.isWhitespace).count
        return count > 0 && abs(count - want) <= max(1, want / 5)
    }

    /// Words laid evenly over a phrase, less the 0.7 s of quiet that closed it.
    nonisolated static func spread(_ text: String, from t0: Double, to t1: Double) -> [[String: Any]] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        let end = max(t0 + 0.1, t1 - 0.7)
        let step = (end - t0) / Double(parts.count)
        return parts.enumerated().map { i, word in
            ["text": word, "start": round3(t0 + Double(i) * step), "end": round3(t0 + Double(i + 1) * step), "approx": true]
        }
    }

    nonisolated static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    // MARK: - the page's half

    private static let pageScript = #"""
    (function () {
      "use strict";
      var SITES = __SITES__;
      var host = String(location.hostname || "").toLowerCase();
      var listed = false;
      for (var i = 0; i < SITES.length && !listed; i++) {
        var site = SITES[i];
        if (site.slice(0, 2) === "*.") {
          var base = site.slice(2);
          listed = host === base || host.slice(-(base.length + 1)) === "." + base;
        } else listed = host === site;
      }
      if (!listed || window.copper) return;
      var w = window.webkit, handler = w && w.messageHandlers && w.messageHandlers.copperPageVoice;
      if (!handler) return;
      var sessions = Object.create(null);
      function failure(code, message) {
        var e = new Error(message || code);
        e.name = "CopperError";
        e.code = code;
        return e;
      }
      function call(method, params) {
        return Promise.resolve(handler.postMessage({ method: method, params: params || {} })).then(function (r) {
          if (!r || r.ok === false) throw failure((r && r.code) || "internal", r && r.message);
          return r;
        });
      }
      function base64(pcm) {
        var bytes;
        if (pcm instanceof Float32Array) {
          var out = new Int16Array(pcm.length);
          for (var i = 0; i < pcm.length; i++) {
            var s = pcm[i] < -1 ? -1 : pcm[i] > 1 ? 1 : pcm[i];
            out[i] = s < 0 ? s * 32768 : s * 32767;
          }
          bytes = new Uint8Array(out.buffer);
        } else if (pcm instanceof ArrayBuffer) bytes = new Uint8Array(pcm);
        else if (ArrayBuffer.isView(pcm)) bytes = new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength);
        else throw new TypeError("push() takes 16 kHz mono PCM: an Int16Array, a Float32Array or an ArrayBuffer of pcm_s16le");
        var text = "";
        for (var j = 0; j < bytes.length; j += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(j, j + 0x8000));
        return btoa(text);
      }
      function hand(fn, value) {
        if (typeof fn !== "function") return;
        try { fn(value); } catch (err) { setTimeout(function () { throw err; }); }
      }
      Object.defineProperty(window, "__copperPageVoice", { value: {
        emit: function (id, event) {
          var s = sessions[id];
          if (!s || !event) return;
          if (event.type === "partial") hand(s.onPartial, event);
          else if (event.type === "final") hand(s.onFinal, event);
          else if (event.type === "error") hand(s.onError, event);
          else if (event.type === "end") { delete sessions[id]; hand(s.onEnd, event); }
        }
      } });
      var voice = {
        version: 1,
        engine: "phonon-2",
        sampleRate: 16000,
        state: function () { return call("state"); },
        listen: function (opts) {
          opts = opts || {};
          return call("start", { sampleRate: opts.sampleRate || 16000 }).then(function (r) {
            var id = r.id, open = true;
            sessions[id] = opts;
            return Object.freeze({
              id: id,
              push: function (pcm) {
                if (!open) return;
                Promise.resolve(handler.postMessage({ method: "audio", params: { id: id, pcm: base64(pcm) } })).then(null, function () {});
              },
              stop: function () {
                if (!open) return Promise.resolve();
                open = false;
                return call("stop", { id: id }).then(function () {});
              },
              cancel: function () {
                if (!open) return;
                open = false;
                call("cancel", { id: id }).then(null, function () {});
              }
            });
          });
        }
      };
      Object.defineProperty(window, "copper", { value: Object.freeze({ page: 1, voice: Object.freeze(voice) }) });
      try { window.dispatchEvent(new Event("copperready")); } catch (_) {}
    })();
    """#
}
