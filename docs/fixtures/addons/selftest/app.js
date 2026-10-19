// The bridge self-test addon: calls every window.copper method, marks each
// against what Copper should answer, and logs every event. Copper's bench
// (`./bench agent addons selftest`) calls the bridge on its own; this page is
// for looking at, and for a person checking a build by hand.
//
// Calls that would act on the person's things are made the way that is
// refused (a javascript: URL, an unknown model, a host outside the manifest),
// which still goes the whole way to Copper and back. The buttons at the end
// make the real ones.
(function () {
  "use strict";

  var $ = function (id) { return document.getElementById(id); };
  var results = [];

  function show(value) {
    if (value === undefined) return "undefined";
    try { return JSON.stringify(value, null, 1); } catch (_) { return String(value); }
  }

  function row(list, name, mark, good, value) {
    var li = document.createElement("li");
    var n = document.createElement("span");
    n.className = "name";
    n.textContent = name;
    var m = document.createElement("span");
    m.className = "mark " + (good ? "ok" : "bad");
    m.textContent = mark;
    li.appendChild(n);
    li.appendChild(m);
    if (value !== undefined) {
      var v = document.createElement("span");
      v.className = "value";
      v.textContent = value;
      li.appendChild(v);
    }
    list.appendChild(li);
  }

  // `expect` is "ok", an error code, or a list of acceptable outcomes.
  async function check(name, expect, call) {
    var outcome, value;
    try {
      value = await call();
      outcome = "ok";
    } catch (e) {
      outcome = (e && e.code) || "threw";
      value = { code: e && e.code, message: e && e.message };
    }
    var wanted = Array.isArray(expect) ? expect : [expect];
    var good = wanted.indexOf(outcome) >= 0;
    results.push({ name: name, outcome: outcome, expected: wanted, good: good, value: value });
    row($("calls"), name, good ? "✓ " + outcome : "✗ " + outcome + " (wanted " + wanted.join("|") + ")", good, show(value));
    return value;
  }

  async function run() {
    var c = window.copper;
    $("calls").textContent = "";
    results = [];
    if (!c) {
      row($("calls"), "window.copper", "✗ missing", false);
      return results;
    }
    var info = await check("info()", "ok", function () { return c.info(); });
    if (info) {
      document.documentElement.classList.toggle("dark", !!(info.theme && info.theme.dark));
      $("who").textContent = info.addon.id + " " + info.addon.version + " · bridge " + info.bridge + " · " + info.platform + " " + info.appVersion + " · " + info.slot;
    }
    await check("identity()", "ok", function () { return c.identity(); });
    var settings = await check("settings()", "ok", function () { return c.settings(); });
    if (settings && settings.greeting) $("greeting").textContent = settings.greeting;
    var stamp = { at: Date.now() };
    await check("storage.set()", "ok", function () { return c.storage.set("selftest", stamp); });
    await check("storage.get() returns what was set", "ok", function () {
      return c.storage.get("selftest").then(function (v) {
        if (!v || v.at !== stamp.at) throw Object.assign(new Error("got " + show(v)), { code: "mismatch" });
        return v;
      });
    });
    await check("storage.keys()", "ok", function () { return c.storage.keys(); });
    await check("storage.remove()", "ok", function () { return c.storage.remove("selftest"); });
    await check("storage.get() after remove is null", "ok", function () {
      return c.storage.get("selftest").then(function (v) {
        if (v !== null) throw Object.assign(new Error("got " + show(v)), { code: "mismatch" });
        return v;
      });
    });
    await check("fetch(https://example.com/)", ["ok", "network", "timeout"], function () {
      return c.fetch("https://example.com/", { timeoutMs: 15000 }).then(function (r) {
        return { status: r.status, type: r.headers["content-type"], bytes: r.body.length };
      });
    });
    await check("fetch() to a host not in the manifest", "denied", function () { return c.fetch("https://denied.invalid/"); });
    await check("fetch() over plain http", "denied", function () { return c.fetch("http://example.com/"); });
    await check("oauth.authorize() to a host not in the manifest", "denied", function () {
      return c.oauth.authorize({ url: "https://denied.invalid/authorize", redirectPrefix: "http://127.0.0.1:53682/callback" });
    });
    await check("oauth.authorize() with a bad redirectPrefix", "bad_request", function () {
      return c.oauth.authorize({ url: "https://example.com/authorize", redirectPrefix: "http://example.net/callback" });
    });
    await check("openUrl(javascript:)", "bad_request", function () { return c.openUrl("javascript:void(0)"); });
    await check("page.current()", "ok", function () { return c.page.current(); });
    await check("agent.state()", "ok", function () {
      return c.agent.state().then(function (s) {
        return { available: s.available, busy: s.busy, model: s.model, models: s.models.map(function (m) { return m.id; }), items: s.items.length };
      });
    });
    await check("agent.setModel(unknown)", "bad_request", function () { return c.agent.setModel("no-such-model"); });
    await check("agent.send('')", "bad_request", function () { return c.agent.send(""); });
    await check("agent.stop()", "ok", function () { return c.agent.stop(); });
    await check("window.open() is refused", "ok", function () {
      var w = window.open("https://example.com/");
      if (w !== null) throw Object.assign(new Error("a window opened"), { code: "opened" });
      return null;
    });
    await check("the page's own fetch() is blocked by CSP", "ok", function () {
      return fetch("https://example.com/").then(
        function () { throw Object.assign(new Error("it went out"), { code: "not_blocked" }); },
        function () { return "blocked"; });
    });
    await check("isSecureContext", "ok", function () { return Promise.resolve(window.isSecureContext); });
    var good = results.filter(function (r) { return r.good; }).length;
    $("tally").textContent = good + " of " + results.length + " as expected";
    document.body.dataset.done = "1";
    return results;
  }

  function log(name, payload) {
    var list = $("events");
    if (list.firstElementChild && list.firstElementChild.classList.contains("muted")) list.textContent = "";
    var li = document.createElement("li");
    var n = document.createElement("span");
    n.className = "name";
    n.textContent = new Date().toLocaleTimeString() + " " + name;
    var v = document.createElement("span");
    v.className = "value";
    v.textContent = show(payload);
    li.appendChild(n);
    li.appendChild(v);
    list.insertBefore(li, list.firstChild);
    while (list.children.length > 20) list.removeChild(list.lastChild);
  }

  function listen() {
    var c = window.copper;
    if (!c) return;
    ["visibility", "theme", "settings", "agent", "page"].forEach(function (name) {
      c.on(name, function (payload) {
        log(name, name === "agent" ? { busy: payload.busy, model: payload.model, items: payload.items.length } : payload);
        if (name === "theme") document.documentElement.classList.toggle("dark", !!payload.dark);
        if (name === "settings" && payload && payload.greeting) $("greeting").textContent = payload.greeting;
      });
    });
  }

  function buttons() {
    var footer = document.querySelector("footer");
    [["Open example.com", function () { return window.copper.openUrl("https://example.com/"); }],
     ["Clear the agent", function () { return window.copper.agent.clear(); }],
     ["Close the sidebar", function () { return window.copper.ui.close(); }]].forEach(function (pair) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = pair[0];
      b.style.marginRight = "6px";
      b.addEventListener("click", function () {
        pair[1]().then(function (v) { log(pair[0], v); }, function (e) { log(pair[0] + " failed", { code: e.code, message: e.message }); });
      });
      footer.parentNode.insertBefore(b, footer);
    });
  }

  window.selftest = { run: run, results: function () { return results; } };
  $("run").addEventListener("click", run);
  listen();
  buttons();
  run();
})();
