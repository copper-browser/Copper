import WebKit

// Fork (page-capture): what every tab's WebKit configuration and page carry
// for the camera and the microphone, and Copper's answer to the Permissions
// API. Three one-line hooks in Tab.swift call in here (PATCHES.md, page-capture).

/// Fork (page-capture): what every tab's WebKit configuration carries for
/// the camera and the microphone. Called from Web.configuration, which is
/// not tied to the main actor, so it is not part of CaptureHook, which is.
enum CapturePreferences {
    /// Every page: a hidden page keeps its microphone and camera — WebKit's
    /// default on a Mac, said out loud so a different default can't quietly
    /// cut a call in a background tab. A test world with `capture.mock` gets
    /// WebKit's stand-in camera and microphone (a test pattern and a beeping
    /// tone): no hardware is opened and macOS never asks — never anywhere else
    /// (CaptureSystem.mock reads the same switch). Private preferences, set
    /// only where this WebKit has them: an unknown KVC key throws at launch.
    static func configure(_ config: WKWebViewConfiguration) {
        let preferences = config.preferences
        set(preferences, "interruptAudioOnPageVisibilityChangeEnabled", false)
        guard Store.testing, Store.settings.bool(forKey: "capture.mock") else { return }
        set(preferences, "mockCaptureDevicesEnabled", true)
        // The stand-ins still go through Copper's question, as real devices do.
        set(preferences, "mockCaptureDevicesPromptEnabled", true)
    }

    private static func set(_ preferences: WKPreferences, _ key: String, _ value: Bool) {
        let setter = NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
        guard preferences.responds(to: setter) else { return }
        preferences.setValue(value, forKey: key)
    }
}

@MainActor
enum CaptureHook {
    // MARK: - the page (Tab.build, Tab.arm)

    static let name = "copperCapture"

    /// Registered once per page (a tab opened by a link shares its opener's
    /// controller, and registering a name twice is a crash, not an error).
    static func listen(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: name)
        controller.add(relay, name: name)
    }

    static func arm(_ controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private static let relay = Relay()

    /// The page says when it asks for the camera or the microphone, and when
    /// it hears back. WebKit passes a page's requests to Copper one at a time,
    /// holding the rest back until the first is answered — so a call page
    /// asking for the microphone and the camera together would be asked about
    /// twice. Knowing what is still in flight, the bar asks once, about both
    /// (CaptureWants). And a page told no says so: usually that was you, but
    /// when macOS refuses Copper the device, WebKit refuses the page before
    /// Copper is ever asked, and this is the only word of it; the bar then
    /// says so, with the way to System Settings. The page's call itself is not
    /// changed in any way: same arguments, same promise, same answer.
    static let script = """
    (function () {
      var proto = window.MediaDevices && window.MediaDevices.prototype;
      var original = proto && proto.getUserMedia;
      var handlers = window.webkit && window.webkit.messageHandlers;
      var relay = handlers && handlers.\(name);
      if (!relay) return;
      function tell(message) { try { relay.postMessage(message); } catch (e) {} }
      // A new page: whatever the last one had in flight went with it.
      if (window === window.top) tell({ op: 'page' });
      // A page that mutes itself through the Media Session API is left
      // muted: Copper only ever resumes what WebKit paused (CaptureCalls).
      // Only the mute is told; an unmute shows in the capture itself.
      var session = window.MediaSession && window.MediaSession.prototype;
      [['setMicrophoneActive', 'audio'], ['setCameraActive', 'video']].forEach(function (pair) {
        var own = session && session[pair[0]];
        if (!own || own.__copperCapture) return;
        var mine = function (active) {
          if (!active) {
            var message = { op: 'session', active: false };
            message[pair[1]] = true;
            tell(message);
          }
          return own.apply(this, arguments);
        };
        Object.defineProperty(mine, '__copperCapture', { value: true });
        Object.defineProperty(session, pair[0], { value: mine, writable: true, enumerable: true, configurable: true });
      });
      if (!original || original.__copperCapture) return;
      // No named parameter: the original's length is 0, and pages read it.
      var wrapped = {
        getUserMedia: function () {
          var wanted = arguments[0] || {};
          var asked = { audio: !!wanted.audio, video: !!wanted.video };
          tell({ op: 'ask', audio: asked.audio, video: asked.video });
          var answer;
          try {
            answer = original.apply(this, arguments);
          } catch (error) {
            tell({ op: 'done', audio: asked.audio, video: asked.video });
            throw error;
          }
          if (answer && typeof answer.then === 'function') {
            answer.then(function () {
              tell({ op: 'done', audio: asked.audio, video: asked.video });
            }, function (error) {
              tell({ op: 'done', audio: asked.audio, video: asked.video, refused: !!error && error.name === 'NotAllowedError' });
            });
          } else {
            tell({ op: 'done', audio: asked.audio, video: asked.video });
          }
          return answer;
        }
      }.getUserMedia;
      Object.defineProperty(wrapped, '__copperCapture', { value: true });
      Object.defineProperty(proto, 'getUserMedia', { value: wrapped, writable: true, enumerable: true, configurable: true });
    })();
    """

    private final class Relay: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let op = body["op"] as? String,
                  let web = message.webView else { return }
            var devices: CaptureDevices = []
            if body["audio"] as? Bool == true { devices.insert(.microphone) }
            if body["video"] as? Bool == true { devices.insert(.camera) }
            // Any frame can post here, and say anything. A new page is only
            // the main frame's to announce (it drops the view's requests and
            // refusals); a mute only ever makes Copper hold back more.
            let main = message.frameInfo.isMainFrame
            MainActor.assumeIsolated {
                switch op {
                case "page" where main: CaptureDesk.reset(web)
                case "session" where !devices.isEmpty && body["active"] as? Bool == false:
                    CaptureCalls.shared.page(web, muted: devices)
                case "ask" where !devices.isEmpty: CaptureDesk.began(devices, in: web)
                case "done" where !devices.isEmpty:
                    CaptureDesk.ended(devices, in: web)
                    guard body["refused"] as? Bool == true,
                          case let .blocked(blocked, restricted) = CaptureSystem.state(devices),
                          let tab = CaptureDesk.tab(for: web) else { return }
                    AgentTabs.owner(of: tab).capture.showSystem(blocked, restricted: restricted, tab: tab.id)
                default: break
                }
            }
        }
    }

    // MARK: - the Permissions API (Browser's _webView:queryPermission:…)

    /// What `navigator.permissions.query({name: "microphone"})` answers, and
    /// what WebKit itself reads before enumerateDevices() and every
    /// getUserMedia(): a site allowed a device is "granted" — so a call page
    /// goes straight to its microphone instead of its own "allow your
    /// microphone" step, and its device list carries names (AirPods, MacBook
    /// Pro Microphone) before it has opened one. Anything else is "prompt",
    /// WebKit's own answer when nobody is asked. A site allowed a device macOS
    /// refuses Copper is told "denied", and the bar says why, once a session.
    static func permission(_ name: String, origin: WKSecurityOrigin, page web: WKWebView, in browser: Browser) -> WKPermissionDecision {
        let device: CaptureDevices
        switch name {
        case "microphone": device = .microphone
        case "camera": device = .camera
        default: return .prompt
        }
        guard !origin.host.isEmpty else { return .prompt }
        let site = CaptureChoices.site(host: origin.host, port: origin.port)
        guard CaptureBook.choices.covers(site, device) else { return .prompt }
        if case let .blocked(blocked, restricted) = CaptureSystem.state(device) {
            if told.insert("\(site)|\(device.rawValue)").inserted {
                let tab = CaptureDesk.tab(for: web)
                (tab.map { AgentTabs.owner(of: $0) } ?? browser).capture.showSystem(blocked, restricted: restricted, tab: tab?.id)
            }
            return .deny
        }
        return .grant
    }

    /// Sites already told this session that macOS refuses a device.
    private static var told = Set<String>()
}

extension Browser {
    /// Fork (page-capture): the Permissions API's camera and microphone
    /// answers (WKUIDelegatePrivate; CaptureHook.permission). Any other
    /// permission gets "prompt", WebKit's answer when nobody is asked.
    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    func _webView(_ webView: WKWebView, queryPermission name: String, forOrigin origin: WKSecurityOrigin,
                  completionHandler: @escaping (WKPermissionDecision) -> Void) {
        completionHandler(CaptureHook.permission(name, origin: origin, page: webView, in: self))
    }
}
