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

    static let script = #"""
    (function () {
      if (window.__copperPasskeys) return;
      window.__copperPasskeys = true;

      var originalCreate = navigator.credentials && navigator.credentials.create;
      var originalGet = navigator.credentials && navigator.credentials.get;
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
      function fail(result) {
        var name = result && result.error ? result.error : 'NotAllowedError';
        throw domError(name, result && result.message);
      }
      function publicCredential(id, response, extensions) {
        var item = Object.create(PublicKeyCredential.prototype);
        Object.defineProperties(item, {
          id: { value: id, enumerable: true },
          rawId: { value: bytes(id), enumerable: true },
          type: { value: 'public-key', enumerable: true },
          response: { value: response, enumerable: true },
          authenticatorAttachment: { value: 'platform', enumerable: true }
        });
        item.getClientExtensionResults = function () { return extensions || {}; };
        item.toJSON = function () {
          return { id: item.id, rawId: b64(item.rawId), type: item.type,
                   response: response && response.toJSON ? response.toJSON() : {},
                   authenticatorAttachment: item.authenticatorAttachment };
        };
        return item;
      }
      function attestation(result, requested) {
        var response = {
          clientDataJSON: bytes(result.clientDataJSON),
          attestationObject: bytes(result.attestationObject),
          getTransports: function () { return ['internal']; },
          getAuthenticatorData: function () { return bytes(result.authenticatorData); },
          getPublicKey: function () { return result.publicKey ? bytes(result.publicKey) : null; },
          getPublicKeyAlgorithm: function () { return -7; },
          toJSON: function () {
            return { clientDataJSON: b64(this.clientDataJSON), attestationObject: b64(this.attestationObject) };
          }
        };
        var extensions = requested && requested.extensions && requested.extensions.credProps
          ? { credProps: { rk: true } } : {};
        return publicCredential(result.id, response, extensions);
      }
      function assertion(result) {
        var response = {
          clientDataJSON: bytes(result.clientDataJSON),
          authenticatorData: bytes(result.authenticatorData),
          signature: bytes(result.signature),
          userHandle: result.userHandle ? bytes(result.userHandle) : null,
          toJSON: function () {
            return { clientDataJSON: b64(this.clientDataJSON), authenticatorData: b64(this.authenticatorData),
                     signature: b64(this.signature), userHandle: this.userHandle ? b64(this.userHandle) : null };
          }
        };
        return publicCredential(result.id, response, result.extensions || {});
      }
      // Conditional requests still waiting in Copper, by request id. A site
      // aborts one before starting the next; leaving the page drops them all.
      var waiting = {};
      function cancel(requestId) {
        if (!waiting[requestId]) return;
        delete waiting[requestId];
        var message = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copperPasskeys;
        if (!message) return;
        try {
          Promise.resolve(message.postMessage({ kind: 'cancel', requestId: requestId })).catch(function () {});
        } catch (_) {}
      }
      if (window.addEventListener) window.addEventListener('pagehide', function () {
        Object.keys(waiting).forEach(cancel);
      });
      function call(kind, options) {
        var p = options && options.publicKey;
        if (!p) return null;
        if (options.signal && options.signal.aborted) return Promise.reject(domError('AbortError', 'The operation was aborted'));
        // A conditional get waits in Copper until its passkey is picked from
        // the list under the sign-in box; creation has no conditional form here.
        if (options.mediation === 'conditional' && kind !== 'get') return Promise.reject(domError('NotSupportedError', 'Conditional creation is not available'));
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
        var requestId = payload.requestId = Math.random().toString(36).slice(2);
        var conditional = payload.mediation === 'conditional';
        if (conditional) waiting[requestId] = true;
        var reply = Promise.resolve(message.postMessage(payload)).then(function (result) {
          delete waiting[requestId];
          if (!result || result.error) return fail(result);
          return kind === 'create' ? attestation(result, p) : assertion(result);
        }, function (error) { delete waiting[requestId]; throw error; });
        if (options.signal) {
          reply = Promise.race([reply, new Promise(function (_, reject) {
            options.signal.addEventListener('abort', function () {
              if (conditional) cancel(requestId);
              reject(domError('AbortError', 'The operation was aborted'));
            }, { once: true });
          })]);
        }
        return reply;
      }

      function PublicKeyCredential() {}
      PublicKeyCredential.prototype = {};
      Object.defineProperty(PublicKeyCredential.prototype, 'constructor', { value: PublicKeyCredential });
      PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
      PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(true); };
      PublicKeyCredential.getClientCapabilities = function () { return Promise.resolve({
        userVerifyingPlatformAuthenticator: true, conditionalGet: true, hybridTransport: false,
        passkeyPlatformAuthenticator: true, relatedOrigins: false, signalAllAcceptedCredentials: false,
        userVerifyingPlatformAuthenticatorAvailable: true
      }); };
      PublicKeyCredential.parseCreationOptionsFromJSON = function (value) {
        var out = Object.assign({}, value || {});
        if (out.challenge) out.challenge = bytes(out.challenge);
        if (out.user) out.user = Object.assign({}, out.user, { id: bytes(out.user.id) });
        if (out.excludeCredentials) out.excludeCredentials = out.excludeCredentials.map(function (c) {
          return Object.assign({}, c, { id: bytes(c.id) });
        });
        return out;
      };
      PublicKeyCredential.parseRequestOptionsFromJSON = function (value) {
        var out = Object.assign({}, value || {});
        if (out.challenge) out.challenge = bytes(out.challenge);
        if (out.allowCredentials) out.allowCredentials = out.allowCredentials.map(function (c) {
          return Object.assign({}, c, { id: bytes(c.id) });
        });
        return out;
      };
      window.PublicKeyCredential = PublicKeyCredential;

      if (navigator.credentials) {
        var create = function (options) {
          var result = call('create', options);
          return result || originalCreate.call(navigator.credentials, options);
        };
        var get = function (options) {
          var result = call('get', options);
          return result || originalGet.call(navigator.credentials, options);
        };
        function installCredentials() {
          var credentials = navigator.credentials;
          var prototype = Object.getPrototypeOf(credentials);
          try {
            Object.defineProperty(credentials, 'create', { value: create, configurable: true, writable: true });
            Object.defineProperty(credentials, 'get', { value: get, configurable: true, writable: true });
          } catch (_) {}
          try {
            Object.defineProperty(prototype, 'create', { value: create, configurable: true, writable: true });
            Object.defineProperty(prototype, 'get', { value: get, configurable: true, writable: true });
          } catch (_) {}
        }
        installCredentials();
        if (window.queueMicrotask) queueMicrotask(installCredentials);
        setTimeout(installCredentials, 0);
      }
    })();
    """#

    private static let aaguid = Data([0x43, 0x6f, 0x70, 0x70, 0x65, 0x72, 0x20, 0x50,
                                      0x61, 0x73, 0x73, 0x6b, 0x65, 0x79, 0x73, 0x01])

    /// A conditional sign-in a page has asked for and is waiting on: its
    /// passkeys hang in the account list under the sign-in box, and the one
    /// picked there answers it. One per tab, the newest.
    struct Waiting {
        let requestId: String
        let body: [String: Any]
        let origin: String
        let rpId: String
        let reply: (Any?, String?) -> Void
    }

    private static var waiting: [UUID: Waiting] = [:]

    /// Told when a tab starts or stops waiting, so a list already up can
    /// show its passkeys or let them go.
    static var onChange: ((Tab) -> Void)?

    /// The passkeys the tab's waiting request may use, most recently used
    /// first. Empty when nothing waits or the page has moved to another host.
    static func waitingCredentials(for tab: Tab) -> [PasskeyStore.Credential] {
        guard let request = waiting[tab.id],
              let origin = URL(string: request.origin)?.host?.lowercased(),
              tab.address?.host()?.lowercased() == origin
        else { return [] }
        let allow = (request.body["allowCredentials"] as? [[String: Any]] ?? []).compactMap { bytes($0["id"]) }
        return PasskeyStore.credentials(for: request.rpId)
            .filter { allow.isEmpty || allow.contains($0.id) }
            .sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
    }

    /// The passkey picked from the list: Touch ID, then the waiting request
    /// is answered with its signature. `done` hears whether it was.
    /// A Touch ID cancelled leaves the request waiting, as the site expects:
    /// its list is still there to pick from.
    static func answer(tab: Tab, with credential: PasskeyStore.Credential, done: @escaping (Bool) -> Void) {
        guard let request = waiting[tab.id] else { done(false); return }
        sign(credential, body: request.body, origin: request.origin, rpId: request.rpId) { result, error in
            // Signed, but only for the request still waiting — not one
            // aborted or replaced while Touch ID was up.
            guard (result as? [String: Any])?["error"] == nil,
                  waiting[tab.id]?.requestId == request.requestId
            else { done(false); return }
            waiting.removeValue(forKey: tab.id)
            request.reply(result, error)
            done(true)
        }
    }

    /// The tab is going away: whatever it waited on is let go.
    static func drop(_ tab: Tab) {
        waiting.removeValue(forKey: tab.id)?.reply(["error": "AbortError"], nil)
    }

    /// Let go of the tab's request because the page asked to, and redraw.
    private static func cancel(_ tab: Tab) {
        guard let request = waiting.removeValue(forKey: tab.id) else { return }
        request.reply(["error": "AbortError"], nil)
        onChange?(tab)
    }

    static func relay(_ body: [String: Any], tab: Tab?, reply: @escaping (Any?, String?) -> Void) {
        if body["kind"] as? String == "cancel" {
            if let tab, let id = body["requestId"] as? String, waiting[tab.id]?.requestId == id { cancel(tab) }
            reply(["ok": true], nil)
            return
        }
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
        case "get" where body["mediation"] as? String == "conditional":
            guard let tab else { reply(["error": "NotSupportedError"], nil); return }
            // A newer conditional request replaces the older one, as a
            // browser's single autofill slot does.
            waiting.removeValue(forKey: tab.id)?.reply(["error": "AbortError"], nil)
            guard bytes(body["challenge"]) != nil else { reply(["error": "InvalidStateError"], nil); return }
            waiting[tab.id] = Waiting(requestId: body["requestId"] as? String ?? "", body: body,
                                      origin: origin, rpId: rp, reply: reply)
            onChange?(tab)
        case "get": get(body, origin: origin, rpId: rp, reply: reply)
        default: reply(["error": "NotSupportedError"], nil)
        }
    }

    private static func allowedOrigin(_ url: URL, host: String) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && (host == "localhost" || host == "127.0.0.1" || host == "[::1]")
    }

    private static func allowedRP(_ rp: String, for host: String) -> Bool {
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

    private static func clientData(type: String, challenge: Data, origin: String, crossOrigin: Bool = false) -> Data {
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
        let existing = PasskeyStore.credentials(for: rpId)
        if excluded.contains(where: { id in existing.contains { $0.id == id } }) {
            reply(["error": "InvalidStateError"], nil); return
        }
        let name = userName.isEmpty ? displayName : userName
        prove("Create a passkey for \(rpId) as \(name)") { ok in
            guard ok else { reply(["error": "NotAllowedError"], nil); return }
            let credential = PasskeyStore.make(rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName)
            guard PasskeyStore.save(credential), let key = credential.key else { reply(["error": "UnknownError"], nil); return }
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
    }

    private static func get(_ body: [String: Any], origin: String, rpId: String, reply: @escaping (Any?, String?) -> Void) {
        guard bytes(body["challenge"]) != nil else { reply(["error": "InvalidStateError"], nil); return }
        let all = PasskeyStore.credentials(for: rpId)
        let allow = (body["allowCredentials"] as? [[String: Any]] ?? []).compactMap { bytes($0["id"]) }
        let candidates = allow.isEmpty ? all : all.filter { allow.contains($0.id) }
        guard let credential = candidates.sorted(by: { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }).first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reply(["error": "NotAllowedError"], nil) }
            return
        }
        sign(credential, body: body, origin: origin, rpId: rpId, reply: reply)
    }

    /// Touch ID, then the assertion: the same for a passkey the site asked
    /// for outright and one picked from the list under the sign-in box.
    private static func sign(_ credential: PasskeyStore.Credential, body: [String: Any], origin: String, rpId: String,
                             reply: @escaping (Any?, String?) -> Void) {
        guard let challenge = bytes(body["challenge"]) else { reply(["error": "InvalidStateError"], nil); return }
        prove("Sign in to \(rpId) with your passkey (\(credential.label))") { ok in
            guard ok, let key = credential.key else { reply(["error": "NotAllowedError"], nil); return }
            let client = clientData(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: body["crossOrigin"] as? Bool ?? false)
            let auth = authenticatorData(rpId: rpId, flags: 0x1D, counter: credential.counter)
            let digestInput = auth + Data(SHA256.hash(data: client))
            guard let signature = try? key.signature(for: digestInput).derRepresentation else { reply(["error": "UnknownError"], nil); return }
            PasskeyStore.touch(credential)
            reply(["id": credential.id.base64URL, "clientDataJSON": client.base64URL, "authenticatorData": auth.base64URL,
                   "signature": signature.base64URL, "userHandle": credential.userHandle.base64URL], nil)
        }
    }

    private static func authenticatorData(rpId: String, flags: UInt8, counter: UInt32, credential: PasskeyStore.Credential? = nil, key: P256.Signing.PrivateKey? = nil) -> Data {
        var data = Data(SHA256.hash(data: Data(rpId.utf8)))
        data.append(flags)
        data.append(contentsOf: [UInt8(counter >> 24), UInt8(counter >> 16), UInt8(counter >> 8), UInt8(counter)])
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
            if value < 24 { return Data([type << 5 | UInt8(value)]) }
            if value <= 0xff { return Data([type << 5 | 24, UInt8(value)]) }
            if value <= 0xffff { return Data([type << 5 | 25, UInt8(value >> 8), UInt8(value)]) }
            if value <= 0xffffffff { return Data([type << 5 | 26, UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)]) }
            return Data([type << 5 | 27, UInt8(value >> 56), UInt8(value >> 48), UInt8(value >> 40), UInt8(value >> 32), UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)])
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
