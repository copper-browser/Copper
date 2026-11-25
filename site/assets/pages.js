/* Subpages: the theme switch (same storage key as index.html) and copy buttons. */
(function () {
  'use strict';
  var root = document.documentElement;
  var btn = document.getElementById('theme');
  var darkMQ = window.matchMedia('(prefers-color-scheme: dark)');
  function effective() { return root.dataset.theme || (darkMQ.matches ? 'dark' : 'light'); }
  function sync() {
    var t = effective();
    if (btn) btn.setAttribute('aria-label', t === 'dark' ? 'Switch to light appearance' : 'Switch to dark appearance');
    if (root.dataset.theme) Array.prototype.forEach.call(document.querySelectorAll('meta[name="theme-color"]'), function (m) { m.content = t === 'dark' ? '#0C0A09' : '#F8F2EA'; });
  }
  if (btn) btn.addEventListener('click', function () {
    var next = effective() === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('copper-theme', next); } catch (e) {}
    sync();
  });
  if (darkMQ.addEventListener) darkMQ.addEventListener('change', sync);
  sync();

  Array.prototype.forEach.call(document.querySelectorAll('[data-copy]'), function (b) {
    b.addEventListener('click', function () {
      var label = b.querySelector('span') || b, was = label.textContent;
      var done = function () { label.textContent = 'Copied'; setTimeout(function () { label.textContent = was; }, 1800); };
      if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(b.dataset.copy).then(done, function () { label.textContent = 'Press ⌘C'; });
      else label.textContent = 'Press ⌘C';
    });
  });
})();
