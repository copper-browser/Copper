// Execute the actual page-side Swift raw-string script, not a reimplementation.
// No browser profile, keychain, network, account or real credential is involved.
// node --test docs/fixtures/passkey-bridge-test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../Sources/Search/Fork/Passkeys/Passkeys.swift'), 'utf8');
const match = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/);
assert.ok(match, 'find the production WebAuthn bridge script');
const script = match[1];

// A bound function prints as `[native code]`, which is how Copper tells
// WebKit's own methods from an extension's or a page's wrapper.
const nativeLike = fn => fn.bind(undefined);

function page({reply, bridge = true, before = '', classes = false} = {}) {
  const messages = [];
  const fallbacks = [];
  const timers = [];
  class Credentials {}
  Credentials.prototype.create = nativeLike(options => { fallbacks.push(['create', options]); return Promise.resolve('original-create'); });
  Credentials.prototype.get = nativeLike(options => { fallbacks.push(['get', options]); return Promise.resolve('original-get'); });
  const context = vm.createContext({
    TextEncoder, TextDecoder, DOMException, AbortController, atob, btoa,
    navigator: {credentials: new Credentials()},
    location: {origin: 'https://accounts.example.test', hostname: 'accounts.example.test'},
    setTimeout: fn => { timers.push(fn); return timers.length; },
    queueMicrotask: fn => fn(),
    webkit: {messageHandlers: bridge ? {copperPasskeys: {postMessage(payload) {
      const copy = JSON.parse(JSON.stringify(payload));
      messages.push(copy);
      return reply ? reply(copy) : {
        id: 'AQID', clientDataJSON: 'AA', attestationObject: 'AA',
        authenticatorData: 'AA', publicKey: 'AA', signature: 'AA', userHandle: 'AQ'
      };
    }}} : {}}
  });
  vm.runInContext('window = globalThis; top = window;', context);
  // WebKit's own classes, as an unentitled build still exposes them.
  if (classes) vm.runInContext(`
    Credential = function Credential() {}; AuthenticatorResponse = function AuthenticatorResponse() {};
    PublicKeyCredential = function PublicKeyCredential() {};
    PublicKeyCredential.prototype = Object.create(Credential.prototype);
    PublicKeyCredential.isConditionalMediationAvailable = nativeStatic;
    AuthenticatorAssertionResponse = function AuthenticatorAssertionResponse() {};
    AuthenticatorAssertionResponse.prototype = Object.create(AuthenticatorResponse.prototype);
    AuthenticatorAttestationResponse = function AuthenticatorAttestationResponse() {};
    AuthenticatorAttestationResponse.prototype = Object.create(AuthenticatorResponse.prototype);
    nativePublicKeyCredential = PublicKeyCredential;`, Object.assign(context, {nativeStatic: nativeLike(() => Promise.resolve('native-static'))}));
  if (before) vm.runInContext(before, context);
  vm.runInContext(script, context);
  // `later()` runs what the script deferred with setTimeout (its reinstall).
  return {context, messages, fallbacks, later: () => timers.splice(0).forEach(fn => fn()),
          run: text => vm.runInContext(text, context)};
}

const createOptions = `({publicKey: {
  challenge: new Uint8Array([1, 2, 3]),
  rp: {id: 'example.test', name: 'Example'},
  user: {id: new Uint8Array([4]), name: 'synthetic-user', displayName: 'Synthetic'},
  pubKeyCredParams: [{type: 'public-key', alg: -7}]
}})`;

test('creation sends rp.id, not the RP object or the sign-in subdomain', async () => {
  const p = page();
  await p.run(`navigator.credentials.create(${createOptions})`);
  const body = p.messages[0];
  assert.equal(body.rpId, 'example.test');
  assert.equal(typeof body.rpId, 'string');
  assert.deepEqual(body.rp, {id: 'example.test', name: 'Example'});
  assert.equal(body.origin, 'https://accounts.example.test');
  assert.equal(body.challenge, 'AQID');
  assert.equal(body.user.id, 'BA');
});

test('assertion preserves publicKey.rpId for a parent-domain credential', async () => {
  const p = page();
  await p.run("navigator.credentials.get({publicKey: {rpId: 'example.test', challenge: new Uint8Array([1])}})");
  assert.equal(p.messages[0].rpId, 'example.test');
  assert.equal(p.messages[0].kind, 'get');
});

test('creation with no rp.id defaults to the document hostname', async () => {
  const p = page();
  await p.run("navigator.credentials.create({publicKey: {rp: {name: 'Example'}, challenge: new Uint8Array([1])}})");
  assert.equal(p.messages[0].rpId, 'accounts.example.test');
});

test('assertion with no rpId defaults to the document hostname', async () => {
  const p = page();
  await p.run("navigator.credentials.get({publicKey: {challenge: new Uint8Array([1])}})");
  assert.equal(p.messages[0].rpId, 'accounts.example.test');
});

test('create and get read only the RP field belonging to their operation', async () => {
  const p = page();
  await p.run("navigator.credentials.create({publicKey: {rp: {name: 'Example'}, rpId: 'ignored.test', challenge: new Uint8Array([1])}})");
  await p.run("navigator.credentials.get({publicKey: {rp: {id: 'ignored.test'}, challenge: new Uint8Array([1])}})");
  assert.deepEqual(p.messages.map(x => x.rpId), ['accounts.example.test', 'accounts.example.test']);
});

test('RP selection does not mutate the caller options', async () => {
  const p = page();
  await p.run(`options = ${createOptions}; before = JSON.stringify(options); navigator.credentials.create(options)`);
  assert.equal(p.run('JSON.stringify(options)'), p.run('before'));
});

test('attestation advertises internal transport only, not unsupported hybrid', async () => {
  const p = page();
  const result = await p.run(`navigator.credentials.create(${createOptions})`);
  assert.deepEqual(Array.from(result.response.getTransports()), ['internal']);
});

test('unrelated RP reaches native validation unchanged; native SecurityError propagates', async () => {
  const p = page({reply: body => body.rpId === 'unrelated.test' ? {error: 'SecurityError'} : {error: 'unexpected-default'}});
  await assert.rejects(p.run("navigator.credentials.get({publicKey: {rpId: 'unrelated.test', challenge: new Uint8Array([1])}})"), {name: 'SecurityError'});
  assert.equal(p.messages[0].rpId, 'unrelated.test');
});

test('requests without publicKey still use the original credential API', async () => {
  const p = page();
  assert.equal(await p.run("navigator.credentials.create({password: {id: 'synthetic'}})"), 'original-create');
  assert.equal(await p.run("navigator.credentials.get({password: true})"), 'original-get');
  assert.equal(p.messages.length, 0);
  assert.deepEqual(p.fallbacks.map(x => x[0]), ['create', 'get']);
});

test('aborted operation sends no native request', async () => {
  const p = page();
  p.run('controller = new AbortController(); controller.abort();');
  await assert.rejects(p.run("navigator.credentials.get({signal: controller.signal, publicKey: {rpId: 'example.test'}})"), {name: 'AbortError'});
  assert.equal(p.messages.length, 0);
});

test('conditional mediation remains unavailable without making a native request', async () => {
  const p = page();
  assert.equal(await p.run('PublicKeyCredential.isConditionalMediationAvailable()'), false);
  await assert.rejects(p.run("navigator.credentials.get({mediation: 'conditional', publicKey: {rpId: 'example.test'}})"), {name: 'NotSupportedError'});
  assert.equal(p.messages.length, 0);
});

test('missing native bridge fails cleanly', async () => {
  const p = page({bridge: false});
  await assert.rejects(p.run("navigator.credentials.get({publicKey: {rpId: 'example.test'}})"), {name: 'NotSupportedError'});
  assert.equal(p.messages.length, 0);
});

// Shaped like 1Password's inline/injected/webauthn-listeners.js: it binds
// navigator.credentials once at load as its fallback, then installs
// non-configurable accessors. `window.extensionAccepts` decides per call.
const extensionHook = `
  (function () {
    var c = navigator.credentials, fallbackGet = c.get.bind(c), fallbackCreate = c.create.bind(c);
    var conditional = PublicKeyCredential.isConditionalMediationAvailable;
    window.extensionCalls = 0;
    function mine(kind) {
      extensionCalls++;
      var response = Object.setPrototypeOf({clientDataJSON: new ArrayBuffer(1)},
        (kind === 'get' ? AuthenticatorAssertionResponse : AuthenticatorAttestationResponse).prototype);
      return Object.setPrototypeOf({id: 'from-extension', type: 'public-key', response: response,
        getClientExtensionResults: function () { return {}; }}, PublicKeyCredential.prototype);
    }
    var hooks = {
      get: async function (o) { return window.extensionAccepts ? mine('get') : fallbackGet(o); },
      create: async function (o) { return window.extensionAccepts ? mine('create') : fallbackCreate(o); }
    };
    var stored = {};
    ['get', 'create'].forEach(function (name) {
      Object.defineProperty(c, name, {configurable: false, enumerable: true,
        get: function () { return window.extensionProtects ? hooks[name] : (stored[name] || hooks[name]); },
        set: function (v) { stored[name] = v; }});
    });
    var available = async function () { return window.extensionAccepts ? true : conditional.call(PublicKeyCredential); };
    available.tag = 'extension';
    Object.defineProperty(PublicKeyCredential, 'isConditionalMediationAvailable', {configurable: false,
      get: function () { return available; }, set: function () {}});
  })();`;
const getOptions = "({publicKey: {rpId: 'example.test', challenge: new Uint8Array([1])}})";

test('an extension hooking after Copper falls through to Copper when it declines', async () => {
  const p = page({classes: true});
  p.run(extensionHook);
  p.run('extensionAccepts = false; extensionProtects = true;');
  const got = await p.run(`navigator.credentials.get(${getOptions})`);
  const made = await p.run(`navigator.credentials.create(${createOptions})`);
  assert.deepEqual(p.messages.map(m => m.kind), ['get', 'create']);
  assert.equal(p.fallbacks.length, 0, 'WebKit\'s unentitled implementation is never reached');
  assert.equal(p.run('extensionCalls'), 0);
  assert.ok(got instanceof p.context.PublicKeyCredential && got.response instanceof p.context.AuthenticatorAssertionResponse);
  assert.ok(made.response instanceof p.context.AuthenticatorAttestationResponse && made.response instanceof p.context.AuthenticatorResponse);
  assert.equal(await p.run('PublicKeyCredential.isConditionalMediationAvailable()'), false, 'Copper alone has no conditional UI');
});

test('an extension that handles the request wins and Copper is not asked', async () => {
  const p = page({classes: true});
  p.run(extensionHook);
  p.run('extensionAccepts = true; extensionProtects = true;');
  const got = await p.run(`navigator.credentials.get(${getOptions})`);
  const made = await p.run(`navigator.credentials.create(${createOptions})`);
  assert.equal(got.id, 'from-extension');
  assert.equal(made.id, 'from-extension');
  assert.equal(p.messages.length, 0);
  assert.ok(got instanceof p.context.PublicKeyCredential && got.response instanceof p.context.AuthenticatorAssertionResponse);
  assert.equal(await p.run('PublicKeyCredential.isConditionalMediationAvailable()'), true, 'the extension\'s conditional UI is reported');
});

test('Copper keeps WebKit\'s classes and its reinstall never undoes a later hook', async () => {
  const p = page({classes: true});
  assert.equal(p.run('PublicKeyCredential === nativePublicKeyCredential'), true);
  p.run(extensionHook);
  p.run('extensionAccepts = true; extensionProtects = false;');
  p.later();
  assert.equal(p.run('PublicKeyCredential.isConditionalMediationAvailable.tag'), 'extension');
  assert.equal((await p.run(`navigator.credentials.get(${getOptions})`)).id, 'from-extension');
  assert.equal(p.messages.length, 0);
});

test('a plain later wrapper keeps precedence over the deferred reinstall', async () => {
  const p = page({classes: true});
  p.run("navigator.credentials.get = function () { return Promise.resolve('page-wrapper'); };");
  p.later();
  assert.equal(await p.run(`navigator.credentials.get(${getOptions})`), 'page-wrapper');
  assert.equal(p.messages.length, 0);
});

test('the deferred reinstall restores Copper over a reverted native method', async () => {
  const p = page({classes: true});
  p.run('delete navigator.credentials.get; Object.getPrototypeOf(navigator.credentials).get = nativeStatic;');
  p.later();
  await p.run(`navigator.credentials.get(${getOptions})`);
  assert.deepEqual(p.messages.map(m => m.kind), ['get']);
});

test('an extension that hooked first keeps precedence; its setter is offered Copper', async () => {
  const p = page({classes: true, before: extensionHook});
  // Not protecting: the hook's getter returns what was stored through its
  // setter, which is Copper's authenticator.
  p.run('extensionAccepts = false; extensionProtects = false;');
  await p.run(`navigator.credentials.get(${getOptions})`);
  assert.deepEqual(p.messages.map(m => m.kind), ['get']);
  // Protecting and accepting: the extension answers, Copper is not asked.
  p.run('extensionAccepts = true; extensionProtects = true;');
  assert.equal((await p.run(`navigator.credentials.get(${getOptions})`)).id, 'from-extension');
  assert.equal(p.messages.length, 1);
  assert.equal(p.run('PublicKeyCredential.isConditionalMediationAvailable.tag'), 'extension');
});

test('non-WebAuthn requests reach WebKit, not a hook that handed Copper its slot', async () => {
  const p = page({classes: true, before: extensionHook});
  p.run('extensionAccepts = false; extensionProtects = false;');
  assert.equal(await p.run("navigator.credentials.get({password: true})"), 'original-get');
  assert.deepEqual(p.fallbacks.map(x => x[0]), ['get']);
});

test('the reply shapes serialise like WebKit credentials', async () => {
  const p = page({classes: true});
  const got = await p.run(`navigator.credentials.get(${getOptions})`);
  p.context.got = got;
  const json = JSON.parse(p.run('JSON.stringify(got)'));
  assert.equal(json.type, 'public-key');
  assert.equal(json.response.userHandle, 'AQ');
  assert.deepEqual(json.clientExtensionResults, {});
  assert.equal(Object.keys(got).includes('getClientExtensionResults'), false, 'methods are not enumerable fields');
});

test('a refusal reaches the page as its bare name with the standard wording, never Copper\'s reason', async () => {
  const p = page({reply: () => ({error: 'NotAllowedError', message: 'Several shared Bitwarden passkeys (alice, bob): Bitwarden is locked'})});
  await assert.rejects(p.run(`navigator.credentials.get(${getOptions})`), error => {
    assert.equal(error.name, 'NotAllowedError');
    assert.match(error.message, /^The operation either timed out or was not allowed/);
    assert.doesNotMatch(error.message, /alice|Bitwarden|locked/);
    return true;
  });
  // An error name Copper does not send is still only NotAllowedError.
  const q = page({reply: () => ({error: 'Not found.'})});
  await assert.rejects(q.run(`navigator.credentials.get(${getOptions})`), {name: 'NotAllowedError'});
});
