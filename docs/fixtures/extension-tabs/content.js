// What 1Password's inline/inject-content-scripts.js does: import a module
// from the extension into every frame it is injected into. The outcome is
// kept in storage too, which needs no tab — a frame WebKit can't place in
// one still says how its import went.
(async () => {
  let ok = false, error = "";
  try {
    await import(chrome.runtime.getURL("/injected.js"));
    ok = true;
  } catch (e) {
    error = String(e && e.message || e);
    console.error("[FixtureInject]", error);
  }
  const report = { kind: "injected", url: location.href, ok, error };
  try { await chrome.storage.local.set({ ["frame:" + Date.now() + ":" + Math.random().toString(36).slice(2)]: report }); } catch (e) {}
  try { await chrome.runtime.sendMessage(report); } catch (e) {}
})();
