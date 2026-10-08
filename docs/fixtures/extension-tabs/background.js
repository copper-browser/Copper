// Every frame the content script ran in reports here: where, and whether
// its dynamic import() of a web-accessible module worked.
const seen = [];
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message && message.kind === "injected") {
    seen.push({ url: message.url, ok: message.ok, error: message.error || "", tab: sender.tab ? sender.tab.id : null });
    reply({ ok: true });
  } else if (message && message.kind === "seen") {
    reply(seen.slice());
  }
  return false;
});
