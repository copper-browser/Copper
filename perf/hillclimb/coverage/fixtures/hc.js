// Shared by every fixture: rec(key, value) keeps what happened, for the check.
window.__r = window.__r || {};
function rec(k, v) { window.__r[k] = v; document.documentElement.setAttribute('data-hc-' + k, typeof v === 'string' ? v : JSON.stringify(v)); }
