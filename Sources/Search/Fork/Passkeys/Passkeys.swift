import AppKit
import CryptoKit
import Foundation
import WebKit

/// Copper's page-side WebAuthn authenticator.
///
/// WebKit cannot expose Apple's authenticator without an entitlement that a
/// third-party browser cannot obtain. The page sees the same WebAuthn shapes,
/// while the key and the user-verification prompt stay native.
@MainActor
enum Passkeys {
    static let name = "copperPasskeys"

    /// A test-only answer for the Touch ID sheet. It is never consulted in a
    /// normal run; bench sets it only in a SEARCH_PROBE world.
    static var autoProve: Bool?

    static var active: Bool {
        FormRelay.passkeysOffered && !Preferences.entitledToPasskeys
    }

    /// Prepended to every MAIN-world content script an extension ships (by
    /// `ExtensionShims.prepare`). WebKit injects extension content scripts
    /// before the tab's own user scripts, so a hook like 1Password's
    /// webauthn-listeners.js otherwise binds WebKit's unentitled
    /// `navigator.credentials` as its fallback and a declined request never
    /// reaches Copper. Riding inside the extension's own script is the only
    /// order WebKit guarantees. The tab registers the message handler only
    /// while Copper is the authenticator, so its absence keeps this inert.
    static let extensionFile = "search-passkeys.js"
    static var extensionPrelude: String {
        "/* Copper: WebAuthn authenticator before this extension's hooks (Fork/Passkeys/Passkeys.swift) */\n"
            + "if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(name)) {\n"
            + script + "\n}\n"
    }

    static let script = #"""
    (function () {
      if (window.__copperPasskeys) return;
      window.__copperPasskeys = true;

      // The fallback for non-WebAuthn requests is WebKit's own method when it
      // can be found: a hook that hands its slot over (below) and then calls
      // navigator.credentials.get itself must not loop back through Copper.
      var credentialsPrototype = navigator.credentials && Object.getPrototypeOf(navigator.credentials);
      var originalCreate = credentialsPrototype && native(credentialsPrototype.create)
        ? credentialsPrototype.create : navigator.credentials && navigator.credentials.create;
      var originalGet = credentialsPrototype && native(credentialsPrototype.get)
        ? credentialsPrototype.get : navigator.credentials && navigator.credentials.get;
      var te = new TextEncoder();
      var td = new TextDecoder();

      function b64(bytes) {
        var a = new Uint8Array(bytes), s = '';
        for (var i = 0; i < a.length; i += 0x8000) {
          s += String.fromCharCode.apply(null, a.subarray(i, Math.min(i + 0x8000, a.length)));
        }
        return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
      }
      function bytes(text) {
        var s = String(text || '').replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        var raw = atob(s), out = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
        return out.buffer;
      }
      function isBytes(value) {
        return value instanceof ArrayBuffer || (value && ArrayBuffer.isView(value));
      }
      function jsonValue(value) {
        if (isBytes(value)) return b64(value.buffer || value);
        if (Array.isArray(value)) return value.map(jsonValue);
        if (!value || typeof value !== 'object') return value;
        var out = {};
        Object.keys(value).forEach(function (key) { out[key] = jsonValue(value[key]); });
        return out;
      }
      function jsonOptions(options, kind) {
        var p = options && options.publicKey;
        if (!p) return null;
        var out = jsonValue(p);
        if (p.user) out.user = jsonValue(p.user);
        out.mediation = options.mediation || undefined;
        out.kind = kind;
        return out;
      }
      function domError(name, message) {
        try { return new DOMException(message || name, name); }
        catch (_) { var e = new Error(message || name); e.name = name; return e; }
      }
      // Only the error's name reaches the page, with the standard wording:
      // why Copper refused (which accounts exist, whether the vault is
      // locked, what bw said) would fingerprint the person's vault to any
      // site. The reason stays with Copper and the agent (Passkeys.note).
      var messages = {
        NotAllowedError: 'The operation either timed out or was not allowed. See: https://www.w3.org/TR/webauthn-2/#sctn-privacy-considerations-client.',
        InvalidStateError: 'The authenticator was previously registered.',
        NotSupportedError: 'The operation is not supported.',
        SecurityError: 'The operation is insecure.',
        UnknownError: 'The operation failed for an unknown transient reason.'
      };
      function fail(result) {
        var name = result && messages[result.error] ? result.error : 'NotAllowedError';
        throw domError(name, messages[name]);
      }
      // Credentials and responses inherit from the page's own WebAuthn
      // classes (WebKit's when it exposes them), so `instanceof
      // PublicKeyCredential` / `AuthenticatorAssertionResponse` checks pass
      // for Copper's answers and for an extension's alike. Values are own
      // properties: the native prototypes' getters only read WebKit's slots.
      function shaped(prototype, fields) {
        var item = Object.create(prototype), props = {};
        Object.keys(fields).forEach(function (key) {
          props[key] = { value: fields[key], enumerable: typeof fields[key] !== 'function', configurable: true, writable: true };
        });
        Object.defineProperties(item, props);
        return item;
      }
      function publicCredential(id, response, extensions) {
        var item = shaped(Classes.PublicKeyCredential.prototype, {
          id: id, rawId: bytes(id), type: 'public-key', response: response, authenticatorAttachment: 'platform',
          getClientExtensionResults: function () { return extensions || {}; },
          toJSON: function () {
            return { id: item.id, rawId: b64(item.rawId), type: item.type,
                     response: response && response.toJSON ? response.toJSON() : {},
                     authenticatorAttachment: item.authenticatorAttachment,
                     clientExtensionResults: extensions || {} };
          }
        });
        return item;
      }
      function attestation(result, requested) {
        var response = shaped(Classes.AuthenticatorAttestationResponse.prototype, {
          clientDataJSON: bytes(result.clientDataJSON),
          attestationObject: bytes(result.attestationObject),
          getTransports: function () { return ['internal']; },
          getAuthenticatorData: function () { return bytes(result.authenticatorData); },
          getPublicKey: function () { return result.publicKey ? bytes(result.publicKey) : null; },
          getPublicKeyAlgorithm: function () { return -7; },
          toJSON: function () {
            return { clientDataJSON: b64(this.clientDataJSON), attestationObject: b64(this.attestationObject),
                     transports: ['internal'], authenticatorData: result.authenticatorData,
                     publicKey: result.publicKey || null, publicKeyAlgorithm: -7 };
          }
        });
        var extensions = requested && requested.extensions && requested.extensions.credProps
          ? { credProps: { rk: true } } : {};
        return publicCredential(result.id, response, extensions);
      }
      function assertion(result) {
        var response = shaped(Classes.AuthenticatorAssertionResponse.prototype, {
          clientDataJSON: bytes(result.clientDataJSON),
          authenticatorData: bytes(result.authenticatorData),
          signature: bytes(result.signature),
          userHandle: result.userHandle ? bytes(result.userHandle) : null,
          toJSON: function () {
            return { clientDataJSON: b64(this.clientDataJSON), authenticatorData: b64(this.authenticatorData),
                     signature: b64(this.signature), userHandle: this.userHandle ? b64(this.userHandle) : null };
          }
        });
        return publicCredential(result.id, response, result.extensions || {});
      }
      function call(kind, options) {
        var p = options && options.publicKey;
        if (!p) return null;
        if (options.signal && options.signal.aborted) return Promise.reject(domError('AbortError', 'The operation was aborted'));
        if (options.mediation === 'conditional') return Promise.reject(domError('NotSupportedError', 'Conditional mediation is not available'));
        var payload = jsonOptions(options, kind);
        payload.origin = location.origin;
        try { payload.topOrigin = top.location.origin; } catch (_) { payload.topOrigin = location.origin; }
        payload.crossOrigin = window !== top;
        // Creation uses rp.id; assertion uses rpId. Falling back to the
        // sign-in host despite an explicit parent RP loses its credentials.
        payload.rpId = (kind === 'create' ? p.rp && p.rp.id : p.rpId) || location.hostname;
        payload.mediation = options.mediation || '';
        var message = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copperPasskeys;
        if (!message) return Promise.reject(domError('NotSupportedError', 'Copper passkeys are unavailable'));
        payload.requestId = Math.random().toString(36).slice(2);
        var reply = Promise.resolve(message.postMessage(payload)).then(function (result) {
          if (!result || result.error) return fail(result);
          return kind === 'create' ? attestation(result, p) : assertion(result);
        });
        if (options.signal) {
          reply = Promise.race([reply, new Promise(function (_, reject) {
            options.signal.addEventListener('abort', function () {
              reject(domError('AbortError', 'The operation was aborted'));
            }, { once: true });
          })]);
        }
        return reply;
      }

      // WebKit's classes stay in place when it has them: replacing
      // window.PublicKeyCredential would drop any hook an extension already
      // put on it. Only a page without WebAuthn classes gets stand-ins.
      var Classes = (function () {
        function stand(name, parent) {
          var make = function () { throw new TypeError('Illegal constructor'); };
          make.prototype = Object.create(parent ? parent.prototype : Object.prototype);
          Object.defineProperty(make.prototype, 'constructor', { value: make, configurable: true, writable: true });
          Object.defineProperty(make.prototype, Symbol.toStringTag, { value: name, configurable: true });
          Object.defineProperty(make, 'name', { value: name });
          return make;
        }
        function have(name, parent) {
          var existing = window[name];
          if (typeof existing === 'function' && existing.prototype) return existing;
          var made = stand(name, parent);
          try { Object.defineProperty(window, name, { value: made, configurable: true, writable: true }); } catch (_) {}
          return made;
        }
        var Credential = have('Credential');
        var Response = have('AuthenticatorResponse');
        return {
          PublicKeyCredential: have('PublicKeyCredential', Credential),
          AuthenticatorAttestationResponse: have('AuthenticatorAttestationResponse', Response),
          AuthenticatorAssertionResponse: have('AuthenticatorAssertionResponse', Response)
        };
      })();
      var statics = {
        isUserVerifyingPlatformAuthenticatorAvailable: function () { return Promise.resolve(true); },
        isConditionalMediationAvailable: function () { return Promise.resolve(false); },
        getClientCapabilities: function () { return Promise.resolve({
          userVerifyingPlatformAuthenticator: true, conditionalGet: false, hybridTransport: false,
          passkeyPlatformAuthenticator: true, relatedOrigins: false, signalAllAcceptedCredentials: false,
          userVerifyingPlatformAuthenticatorAvailable: true
        }); },
        parseCreationOptionsFromJSON: function (value) {
          var out = Object.assign({}, value || {});
          if (out.challenge) out.challenge = bytes(out.challenge);
          if (out.user) out.user = Object.assign({}, out.user, { id: bytes(out.user.id) });
          if (out.excludeCredentials) out.excludeCredentials = out.excludeCredentials.map(function (c) {
            return Object.assign({}, c, { id: bytes(c.id) });
          });
          return out;
        },
        parseRequestOptionsFromJSON: function (value) {
          var out = Object.assign({}, value || {});
          if (out.challenge) out.challenge = bytes(out.challenge);
          if (out.allowCredentials) out.allowCredentials = out.allowCredentials.map(function (c) {
            return Object.assign({}, c, { id: bytes(c.id) });
          });
          return out;
        }
      };

      // Copper sits underneath whatever wraps the API after it. A hook that
      // got here first (a script Copper could not precede) keeps precedence:
      // Copper takes a setter it offers, and otherwise leaves it alone —
      // replacing it would answer requests the hook meant to handle.
      function native(fn) {
        try { return typeof fn === 'function' && /\{\s*\[native code\]\s*\}\s*$/.test(Function.prototype.toString.call(fn)); }
        catch (_) { return false; }
      }
      // Native (or absent) → Copper's; an accessor with a setter → offered
      // through it, so the hook decides; anything else is a hook's and stays.
      function place(target, name, value, first, also) {
        var own = Object.getOwnPropertyDescriptor(target, name);
        if (own && own.get) {
          if (first && own.set) { try { target[name] = value; } catch (_) {} }
          return;
        }
        var current = target[name];
        if (current === value || (current !== undefined && !native(current))) return;
        [target, also].forEach(function (where) {
          if (!where) return;
          try { Object.defineProperty(where, name, { value: value, configurable: true, writable: true }); } catch (_) {}
        });
      }
      Object.keys(statics).forEach(function (key) { place(Classes.PublicKeyCredential, key, statics[key], true); });

      if (navigator.credentials) {
        var create = function (options) {
          var result = call('create', options);
          return result || originalCreate.call(navigator.credentials, options);
        };
        var get = function (options) {
          var result = call('get', options);
          return result || originalGet.call(navigator.credentials, options);
        };
        var installCredentials = function (first) {
          var credentials = navigator.credentials, prototype = Object.getPrototypeOf(credentials);
          place(credentials, 'create', create, first, prototype);
          place(credentials, 'get', get, first, prototype);
        };
        installCredentials(true);
        // Restore only a reverted native method; never a later wrapper.
        if (window.queueMicrotask) queueMicrotask(function () { installCredentials(false); });
        setTimeout(function () { installCredentials(false); }, 0);
      }
    })();
    """#

    private static let aaguid = Data([0x43, 0x6f, 0x70, 0x70, 0x65, 0x72, 0x20, 0x50,
                                      0x61, 0x73, 0x73, 0x6b, 0x65, 0x79, 0x73, 0x01])

    static func relay(_ body: [String: Any], tab: Tab?, reply: @escaping (Any?, String?) -> Void) {
        guard let op = body["kind"] as? String,
              let origin = body["origin"] as? String,
              let originURL = URL(string: origin),
              let host = originURL.host?.lowercased(), !host.isEmpty,
              allowedOrigin(originURL, host: host)
        else { reply(["error": "SecurityError"], nil); return }
        let rp = ((body["rpId"] as? String)?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? host
        guard allowedRP(rp, for: host) else { reply(["error": "SecurityError"], nil); return }
        if let pageHost = tab?.address?.host()?.lowercased(), !pageHost.isEmpty, !allowedRP(host, for: pageHost) {
            reply(["error": "SecurityError"], nil); return
        }
        switch op {
        case "create": create(body, origin: origin, rpId: rp, reply: reply)
        case "get": get(body, origin: origin, rpId: rp, tab: tab, reply: reply)
        default: reply(["error": "NotSupportedError"], nil)
        }
    }

    private static func allowedOrigin(_ url: URL, host: String) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && (host == "localhost" || host == "127.0.0.1" || host == "[::1]")
    }

    static func allowedRP(_ rp: String, for host: String) -> Bool {
        let rp = rp.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return rp == host || (host.hasSuffix("." + rp) && Vault.registrable(host) == Vault.registrable(rp))
    }

    private static func bytes(_ value: Any?) -> Data? {
        guard let text = value as? String else { return nil }
        return Data(base64URL: text)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        if Store.testing, let answer = autoProve { done(answer); return }
        Vault.prove(reason, done)
    }

    nonisolated private static func clientData(type: String, challenge: Data, origin: String, crossOrigin: Bool = false) -> Data {
        let value: [String: Any] = ["type": type, "challenge": challenge.base64URL, "origin": origin, "crossOrigin": crossOrigin]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    private static func create(_ body: [String: Any], origin: String, rpId: String, reply: @escaping (Any?, String?) -> Void) {
        guard let challenge = bytes(body["challenge"]), let user = body["user"] as? [String: Any],
              let userHandle = bytes(user["id"]), let userName = user["name"] as? String,
              let displayName = user["displayName"] as? String
        else { reply(["error": "InvalidStateError"], nil); return }
        let params = body["pubKeyCredParams"] as? [[String: Any]] ?? []
        guard params.contains(where: { integer($0["alg"]) == -7 }) else {
            reply(["error": "NotSupportedError"], nil); return
        }
        let excluded = (body["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { bytes($0["id"]) }
        // Compare exclude ids only within this relying party; an id from a
        // different site must not make registration fail.
        let existing = PasskeyStore.credentials(for: rpId).map(\.id) + BitwardenPasskeys.all()
            .filter { $0.passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame }.map(\.id)
        if excluded.contains(where: existing.contains) {
            reply(["error": "InvalidStateError"], nil); return
        }
        let name = userName.isEmpty ? displayName : userName
        prove("Create a passkey for \(rpId) as \(name)") { ok in
            guard ok else { reply(["error": "NotAllowedError"], nil); return }
            let credential = PasskeyStore.make(rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName)
            guard let key = credential.key else { reply(["error": "UnknownError"], nil); return }
            let rpName = (body["rp"] as? [String: Any])?["name"] as? String ?? ""
            store(credential, key: key, rpName: rpName) { saved in
                guard saved else { reply(["error": "UnknownError"], nil); return }
                attest(credential, key: key, body: body, challenge: challenge, origin: origin, rpId: rpId, reply: reply)
            }
        }
    }

    /// Where a new passkey is kept: Bitwarden when it is where new
    /// passwords go and it takes the item, otherwise the keychain.
    private static func store(_ credential: PasskeyStore.Credential, key: P256.Signing.PrivateKey, rpName: String,
                              _ done: @escaping (Bool) -> Void) {
        guard Credentials.saveTarget == .bitwarden else { done(PasskeyStore.save(credential)); return }
        Task { @MainActor in
            do {
                try await BitwardenPasskeys.save(credential, key: key, rpName: rpName)
                done(true)
            } catch {
                // The site is mid-registration: a passkey kept here beats
                // a failed one. Settings lists it under Copper.
                NSLog("Copper: Bitwarden did not take the new passkey (\(error.localizedDescription)); kept in the keychain")
                done(PasskeyStore.save(credential))
            }
        }
    }

    private static func attest(_ credential: PasskeyStore.Credential, key: P256.Signing.PrivateKey, body: [String: Any],
                               challenge: Data, origin: String, rpId: String, reply: @escaping (Any?, String?) -> Void) {
        let client = clientData(type: "webauthn.create", challenge: challenge, origin: origin, crossOrigin: body["crossOrigin"] as? Bool ?? false)
        let auth = authenticatorData(rpId: rpId, flags: 0x5D, counter: credential.counter, credential: credential, key: key)
        let attestation = CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(auth))]).encoded
        var result: [String: Any] = [
            "id": credential.id.base64URL,
            "clientDataJSON": client.base64URL,
            "authenticatorData": auth.base64URL,
            "attestationObject": attestation.base64URL,
            "publicKey": key.publicKey.derRepresentation.base64URL,
        ]
        if let requested = body["extensions"] as? [String: Any], requested["credProps"] != nil {
            result["extensions"] = ["credProps": ["rk": true]]
        }
        // userVerification=discouraged still proves once by design.
        reply(result, nil)
    }

    /// A passkey a sign-in may use: one of Copper's own (keychain) or one
    /// kept in Bitwarden. The picker lists both, Copper's first.
    enum Choice {
        case copper(PasskeyStore.Credential)
        case bitwarden(BitwardenPasskeys.Match)

        var label: String {
            switch self {
            case .copper(let credential): return credential.label
            case .bitwarden(let match): return match.label
            }
        }

        var source: String {
            switch self {
            case .copper(let credential): return credential.origin ?? "Copper"
            case .bitwarden: return "Bitwarden"
            }
        }
    }

    /// browser_sign_in what=passkey: the next sign-in request in this tab,
    /// within a minute, from the page that was showing when it was armed
    /// (its origin, in its own frame), may use these shared vault passkeys
    /// with no prompt.
    private struct Grant {
        let ids: Set<Data>
        let origin: String
        let until: Date
    }
    private static var grants: [Tab.ID: Grant] = [:]

    /// Arm one agent sign-in in `tab` (SignIn.swift) for the page at
    /// `origin`. Used once, by the next get() there; a later one is the
    /// person's again. A request from another origin or a frame leaves it.
    static func grant(_ matches: [BitwardenPasskeys.Match], tab: Tab.ID, origin: String, for seconds: TimeInterval = 60) {
        grants = grants.filter { $0.value.until > Date() }
        grants[tab] = Grant(ids: Set(matches.map(\.id)), origin: origin, until: Date().addingTimeInterval(seconds))
    }

    /// An address's origin the way PasskeyRelay spells a frame's:
    /// scheme://host, and the port only when it is not the scheme's own.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var text = "\(scheme)://\(host)"
        let standard = scheme == "https" ? 443 : scheme == "http" ? 80 : -1
        if let port = url.port, port != standard { text += ":\(port)" }
        return text
    }

    /// Why Copper last refused a sign-in in a tab. The page only ever sees
    /// a bare NotAllowedError; the reason goes to the log and, once, to the
    /// agent's next tool result on that tab (Tools.call).
    private struct Refusal {
        let detail: String
        let at: Date
    }
    private static var refusals: [Tab.ID: Refusal] = [:]

    private static func note(_ detail: String?, tab: Tab.ID?, origin: String) {
        guard let detail else { return }
        NSLog("%@", "Copper: passkey sign-in on \(origin) refused: \(detail)")
        if let tab { refusals[tab] = Refusal(detail: detail, at: Date()) }
    }

    /// The reason for the last passkey refusal in `tab`, within five
    /// minutes, handed out once.
    static func takeRefusal(_ tab: Tab.ID) -> String? {
        refusals = refusals.filter { $0.value.at > Date().addingTimeInterval(-300) }
        return refusals.removeValue(forKey: tab)?.detail
    }

    /// Test-only answer for the passkey chooser: an account name or a
    /// 1-based row. Read only in a test world, like `autoProve`.
    static var autoPick: String?
    /// The rows the chooser last offered ("label · source"), for the bench.
    private(set) static var lastOffered: [String] = []

    private static func get(_ body: [String: Any], origin: String, rpId: String, tab: Tab?, reply: @escaping (Any?, String?) -> Void) {
        guard let challenge = bytes(body["challenge"]) else { reply(["error": "InvalidStateError"], nil); return }
        let allow = (body["allowCredentials"] as? [[String: Any]] ?? []).compactMap { bytes($0["id"]) }
        let own = PasskeyStore.credentials(for: rpId).filter { allow.isEmpty || allow.contains($0.id) }
            .sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
        let vault = BitwardenPasskeys.matching(rpId: rpId, allow: allow)
        let request = Request(challenge: challenge, origin: origin, rpId: rpId,
                              crossOrigin: body["crossOrigin"] as? Bool ?? false, tab: tab?.id, reply: reply)
        grants = grants.filter { $0.value.until > Date() }

        // An agent signs in the way browser_sign_in fills a password: only
        // with a login the person shared with agents, no prompt, never in a
        // private tab, and the key never leaves this process. The sharing
        // switch is the consent. Nobody is there to verify, so the answer
        // claims user presence only (UP, not UV), and a site that requires
        // user verification is refused rather than told otherwise.
        //
        // Which requests are the agent's: one from the page of a tab the
        // agent armed with browser_sign_in what=passkey (once, within a
        // minute, same origin, its own frame), or one in a tab only the
        // agent can be driving — held backstage, on no screen — from that
        // tab's own page. A tab on screen that an agent merely touched
        // lately is still the person's: their click there gets their Touch
        // ID, not a free pass. A tab off screen never shows a prompt.
        if let tab {
            let backstage = Backstage.shared.holds(tab.id) && !AgentTabs.onScreen(tab)
            let ownFrame = !request.crossOrigin && Self.origin(of: tab.address) == origin
            var grant: Grant?
            if let armed = grants[tab.id], ownFrame, armed.origin == origin {
                grant = armed
                grants[tab.id] = nil
            }
            if grant != nil || backstage {
                let why: String
                var outright = backstage
                if !ownFrame {
                    why = "the request came from \(origin) in a frame, not the tab's own page; an agent's passkey sign-in is only for the page itself"
                } else if tab.shy {
                    why = "a private tab never uses a passkey for an agent"
                } else if (body["userVerification"] as? String)?.lowercased() == "required" {
                    why = "\(rpId) requires user verification, which only the person can give (Touch ID); an agent's sign-in proves presence only"
                } else {
                    let shared = vault.filter(BitwardenPasskeys.sharedWithAgents).filter { grant?.ids.contains($0.id) ?? true }
                    if shared.count == 1 { signVault(shared[0], request, agent: true); return }
                    if shared.count > 1 {
                        outright = true
                        why = "several shared Bitwarden passkeys for \(rpId) (\(shared.map(\.label).joined(separator: ", "))) \u{2014} name one with browser_sign_in what=passkey account=USER, then ask again"
                    } else if !vault.isEmpty {
                        why = "a Bitwarden passkey for \(rpId) exists but is not shared with agents \u{2014} Settings \u{203A} Passwords \u{203A} Agent access"
                    } else {
                        why = "no Bitwarden passkey for \(rpId) is shared with agents" + (own.isEmpty ? "" : "; Copper's own passkeys there need the person's Touch ID")
                    }
                }
                if outright { refuse(request, why); return }
                // On screen: the person at the Mac decides, as for any request.
                note(why + "; asked the person instead", tab: tab.id, origin: origin)
            }
        }

        let choices = own.map(Choice.copper) + vault.map(Choice.bitwarden)
        guard !choices.isEmpty else { refuse(request, nil); return }
        choose(choices, rpId: rpId, tab: tab) { choice in
            guard let choice else { refuse(request, nil); return }
            let kind = choice.source == "Bitwarden" ? "your Bitwarden passkey" : "your passkey"
            prove("Sign in to \(rpId) with \(kind) (\(choice.label))") { ok in
                guard ok else { request.reply(["error": "NotAllowedError"], nil); return }
                switch choice {
                case .copper(let credential): signCopper(credential, request)
                case .bitwarden(let match): signVault(match, request, agent: false)
                }
            }
        }
    }

    /// A bare NotAllowedError for the page, a moment later (the way an
    /// authenticator with nothing to offer answers); the reason, if any,
    /// for the log and the agent.
    private static func refuse(_ request: Request, _ detail: String?) {
        note(detail, tab: request.tab, origin: request.origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { request.reply(["error": "NotAllowedError"], nil) }
    }

    private struct Request {
        let challenge: Data
        let origin: String
        let rpId: String
        let crossOrigin: Bool
        let tab: Tab.ID?
        let reply: (Any?, String?) -> Void

        var client: Data { Passkeys.clientData(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: crossOrigin) }
    }

    private static func signCopper(_ credential: PasskeyStore.Credential, _ request: Request) {
        guard let key = credential.key else { request.reply(["error": "NotAllowedError"], nil); return }
        let client = request.client
        let auth = authenticatorData(rpId: request.rpId, flags: 0x1D, counter: credential.counter)
        let digestInput = auth + Data(SHA256.hash(data: client))
        guard let signature = try? key.signature(for: digestInput).derRepresentation else { request.reply(["error": "UnknownError"], nil); return }
        PasskeyStore.touch(credential)
        request.reply(["id": credential.id.base64URL, "clientDataJSON": client.base64URL, "authenticatorData": auth.base64URL,
                       "signature": signature.base64URL, "userHandle": credential.userHandle.base64URL], nil)
    }

    /// UP|UV|BE|BS after the person's Touch ID; UP|BE|BS (0x19) for an
    /// agent, which nobody verified.
    private static func signVault(_ match: BitwardenPasskeys.Match, _ request: Request, agent: Bool) {
        let client = request.client
        let rpId = request.rpId
        let flags: UInt8 = agent ? 0x19 : 0x1D
        Task { @MainActor in
            do {
                let assertion = try await BitwardenPasskeys.sign(match, clientDataHash: Data(SHA256.hash(data: client))) { counter in
                    authenticatorData(rpId: rpId, flags: flags, counter: counter)
                }
                request.reply(["id": match.id.base64URL, "clientDataJSON": client.base64URL,
                               "authenticatorData": assertion.authenticatorData.base64URL,
                               "signature": assertion.signature.base64URL, "userHandle": match.userHandle.base64URL], nil)
            } catch {
                refuse(request, "Bitwarden: \(error.localizedDescription)")
            }
        }
    }

    /// One passkey goes straight through; several ask which, the way a
    /// platform authenticator's account sheet does, as a sheet on the tab's
    /// own window. A page on no visible window gets no chooser at all.
    private static func choose(_ choices: [Choice], rpId: String, tab: Tab?, _ done: @escaping (Choice?) -> Void) {
        lastOffered = choices.map { "\($0.label) · \($0.source)" }
        guard choices.count > 1 else { done(choices.first); return }
        if Store.testing, let answer = autoPick {
            if let row = Int(answer), choices.indices.contains(row - 1) { done(choices[row - 1]); return }
            done(choices.first { $0.label.caseInsensitiveCompare(answer) == .orderedSame }); return
        }
        // A Mac nobody sits at has no one to ask.
        if Headless.on { done(choices.first); return }
        guard let window = tab?.built?.window, window.isVisible, !(window is Backstage.Window) else {
            NSLog("%@", "Copper: passkey chooser for \(rpId) not shown; the page is on no visible window")
            done(nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(rpId)"
        alert.informativeText = "Choose the passkey to use."
        // Menu items carry their row as a tag: NSPopUpButton's addItems(withTitles:)
        // folds equal titles into one, and the index would then point at
        // the wrong passkey.
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        menu.removeAllItems()
        for (row, title) in titles(choices).enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = row
            menu.menu?.addItem(item)
        }
        menu.select(menu.menu?.items.first)
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let row = menu.selectedItem?.tag ?? -1
            done(response == .alertFirstButtonReturn && choices.indices.contains(row) ? choices[row] : nil)
        }
    }

    /// The chooser's rows, each one different: equal "account · source"
    /// rows say which login (or site) they come from, then a number.
    private static func titles(_ choices: [Choice]) -> [String] {
        let plain = choices.map { "\($0.label) · \($0.source)" }
        var seen: [String: Int] = [:]
        return choices.enumerated().map { row, choice in
            var title = plain[row]
            if plain.filter({ $0 == title }).count > 1 {
                switch choice {
                case .bitwarden(let match): title += " (\(match.item.name.isEmpty ? match.passkey.rpName : match.item.name))"
                case .copper(let credential): title += " (\(credential.rpId))"
                }
            }
            seen[title, default: 0] += 1
            if seen[title]! > 1 { title += " #\(seen[title]!)" }
            return title
        }
    }

    private static func authenticatorData(rpId: String, flags: UInt8, counter: UInt32, credential: PasskeyStore.Credential? = nil, key: P256.Signing.PrivateKey? = nil) -> Data {
        var data = Data(SHA256.hash(data: Data(rpId.utf8)))
        data.append(flags)
        // Big-endian, each byte truncated: UInt8(counter) traps from 256 up.
        data.append(contentsOf: [UInt8(truncatingIfNeeded: counter >> 24), UInt8(truncatingIfNeeded: counter >> 16),
                                 UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)])
        guard let credential, let key else { return data }
        data.append(aaguid)
        data.append(UInt8(credential.id.count >> 8)); data.append(UInt8(credential.id.count & 0xff)); data.append(credential.id)
        data.append(CBOR.coseKey(key.publicKey.rawRepresentation).encoded)
        return data
    }

    private enum CBOR {
        case uint(UInt64), negative(Int64), bytes(Data), text(String), map([(CBOR, CBOR)]), array([CBOR])

        static func coseKey(_ raw: Data) -> CBOR {
            let bytes = Array(raw)
            guard bytes.count >= 64 else { return .map([]) }
            return .map([(.negative(-3), .bytes(Data(bytes[32..<64]))), (.negative(-2), .bytes(Data(bytes[0..<32]))),
                         (.negative(-1), .uint(1)), (.uint(1), .uint(2)), (.uint(3), .negative(-7))])
        }

        var encoded: Data {
            switch self {
            case .uint(let value): return head(0, value)
            case .negative(let value): return head(1, UInt64(-1 - value))
            case .bytes(let value): return head(2, UInt64(value.count)) + value
            case .text(let value): let data = Data(value.utf8); return head(3, UInt64(data.count)) + data
            case .array(let values): return head(4, UInt64(values.count)) + values.reduce(into: Data()) { $0.append($1.encoded) }
            case .map(let values):
                let ordered = values.sorted { $0.0.encoded.lexicographicallyPrecedes($1.0.encoded) }
                return head(5, UInt64(ordered.count)) + ordered.reduce(into: Data()) { $0.append($1.0.encoded); $0.append($1.1.encoded) }
            }
        }

        private func head(_ type: UInt8, _ value: UInt64) -> Data {
            if value < 24 { return Data([type << 5 | UInt8(truncatingIfNeeded: value)]) }
            if value <= 0xff { return Data([type << 5 | 24, UInt8(value)]) }
            if value <= 0xffff { return Data([type << 5 | 25, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
            if value <= 0xffffffff { return Data([type << 5 | 26, UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
            return Data([type << 5 | 27, UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48), UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32), UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
    }
}

/// The reply-capable WebKit bridge. One instance belongs to each tab's
/// configuration so a page cannot accidentally retain another tab's state.
@MainActor
final class PasskeyRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: Tab?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard var body = message.body as? [String: Any] else { replyHandler(["error": "InvalidStateError"], nil); return }
        // The origin is WebKit's word, never the page's: any script can post
        // to this handler directly and claim to be github.com. The frame's
        // security origin is what a real browser would sign into clientData.
        let frame = message.frameInfo.securityOrigin
        var origin = "\(frame.protocol)://\(frame.host)"
        let standard = frame.protocol == "https" ? 443 : frame.protocol == "http" ? 80 : -1
        if frame.port != 0, frame.port != standard { origin += ":\(frame.port)" }
        body["origin"] = origin
        body["crossOrigin"] = !message.frameInfo.isMainFrame
        Passkeys.relay(body, tab: tab, reply: replyHandler)
    }
}
