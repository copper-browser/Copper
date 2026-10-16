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

function page({reply, bridge = true} = {}) {
  const messages = [];
  const fallbacks = [];
  class Credentials {
    create(options) { fallbacks.push(['create', options]); return Promise.resolve('original-create'); }
    get(options) { fallbacks.push(['get', options]); return Promise.resolve('original-get'); }
  }
  const context = vm.createContext({
    TextEncoder, TextDecoder, DOMException, AbortController, atob, btoa,
    navigator: {credentials: new Credentials()},
    location: {origin: 'https://accounts.example.test', hostname: 'accounts.example.test'},
    setTimeout: () => 0,
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
  vm.runInContext(script, context);
  return {context, messages, fallbacks, run: text => vm.runInContext(text, context)};
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

test('conditional get is offered and waits on the native list', async () => {
  const p = page();
  assert.equal(await p.run('PublicKeyCredential.isConditionalMediationAvailable()'), true);
  assert.equal((await p.run('PublicKeyCredential.getClientCapabilities()')).conditionalGet, true);
  const result = await p.run("navigator.credentials.get({mediation: 'conditional', publicKey: {challenge: new Uint8Array([9])}})");
  assert.equal(p.messages.length, 1);
  assert.equal(p.messages[0].mediation, 'conditional');
  assert.equal(p.messages[0].kind, 'get');
  assert.equal(p.messages[0].rpId, 'accounts.example.test');
  assert.equal(p.messages[0].challenge, 'CQ');
  assert.equal(result.id, 'AQID');
  assert.equal(result.type, 'public-key');
});

test('aborting a waiting conditional get tells Copper to let it go', async () => {
  const pending = [];
  const p = page({reply: body => body.kind === 'cancel' ? {ok: true} : new Promise(resolve => pending.push(resolve))});
  p.run('controller = new AbortController();');
  const waiting = p.run("navigator.credentials.get({mediation: 'conditional', signal: controller.signal, publicKey: {challenge: new Uint8Array([1])}})");
  p.run('controller.abort();');
  await assert.rejects(waiting, {name: 'AbortError'});
  assert.equal(p.messages.length, 2);
  assert.equal(p.messages[1].kind, 'cancel');
  assert.equal(p.messages[1].requestId, p.messages[0].requestId);
});

test('a native refusal of a conditional get rejects it', async () => {
  const p = page({reply: () => ({error: 'AbortError'})});
  await assert.rejects(p.run("navigator.credentials.get({mediation: 'conditional', publicKey: {challenge: new Uint8Array([1])}})"), {name: 'AbortError'});
});

test('conditional creation is still refused without a native request', async () => {
  const p = page();
  await assert.rejects(p.run(`navigator.credentials.create(Object.assign(${createOptions}, {mediation: 'conditional'}))`), {name: 'NotSupportedError'});
  assert.equal(p.messages.length, 0);
});

test('missing native bridge fails cleanly', async () => {
  const p = page({bridge: false});
  await assert.rejects(p.run("navigator.credentials.get({publicKey: {rpId: 'example.test'}})"), {name: 'NotSupportedError'});
  assert.equal(p.messages.length, 0);
});
