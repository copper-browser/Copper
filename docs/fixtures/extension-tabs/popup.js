// The two ways 1Password's Sign in opens start.1password.com: a new tab,
// or sending the extension's own page there (window.location.href).
const target = () => new URLSearchParams(location.search).get("to") || "https://example.com/?from=fixture";
document.getElementById("create").addEventListener("click", () => chrome.tabs.create({ url: target() }));
document.getElementById("navigate").addEventListener("click", () => { window.location.href = target(); });
