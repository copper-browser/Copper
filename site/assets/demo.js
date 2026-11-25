/* The working copy of Copper's window (site/try/). The sites in it are made up; the window, its keys and
   what they do are Copper's (README "Keys"). In ?embed (the homepage's iframe) the first click or key
   posts {type:'copper-demo-click'} to the parent page, once. */
(function () {
  'use strict';
  var cw = document.getElementById('cw');
  if (!cw) return;
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var embed = document.documentElement.classList.contains('embed');
  var isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
  if (!isMac) $$('kbd[data-k]').forEach(function (k) { k.textContent = k.dataset.k.replace('⇧', 'Shift+').replace('⌘', 'Ctrl+').replace('⌃', 'Ctrl+'); });
  var live = $('#cw-live');
  function say(msg) { live.textContent = ''; setTimeout(function () { live.textContent = msg; }, 30); }

  /* ---------- the made-up sites ---------- */
  function site(name, right) { return '<div class="site"><span>' + name + '</span><span>' + right + '</span></div>'; }
  function wrap(html, extra) { return '<div class="cw-scroll" tabindex="-1"><div class="pg">' + html + '</div></div>' + (extra || ''); }
  function pinned(name, host) {
    return function () { return wrap(site(name, host) + '<h3>' + name + '</h3><p>A pinned tab. Pins sit at the top of the column as tiles and are the same in every space, like Arc’s Favorites.</p>'); };
  }
  var PAGES = {
    ledger: function () {
      return wrap(site('Morning Ledger', 'Tuesday') +
        '<h3>The harbour clock has been four minutes fast for sixty years</h3>' +
        '<p>Nobody on the quay remembers who set it. The ferries leave by it anyway, and so, it turns out, does most of the town.</p>' +
        '<aside class="promo" data-hide="promo" data-label="newsletter box"><span>Get the Ledger in your inbox, every morning.</span><span class="fakebtn">Subscribe</span></aside>' +
        '<p>The last keeper retired in 1998 and left a note in the case: <em>do not correct</em>. The council has voted twice to fix it, and twice to leave it as it is.</p>' +
        '<p>“If it were right,” says the harbourmaster, “we would all be late.”</p>',
        '<div class="cookie" data-hide="cookie" data-label="cookie banner"><p>We use cookies to make this site work and to understand how it is used.</p><div class="acts"><span class="fakebtn ghost">Manage</span><span class="fakebtn">Accept all</span></div></div>');
    },
    readme: function () {
      return wrap(site('copper-browser / Copper', 'README') +
        '<h3>Copper</h3><p>An open source Mac browser on WebKit, made by Collin and Felipe.</p>' +
        '<p>Tabs go down the left or across the top. An MCP server is built in, so the agent you already pay for can drive it.</p>' +
        '<ul class="rows"><li><span>Language</span><span>Swift</span></li><li><span>Engine</span><span>WebKit</span></li><li><span>License</span><span>MIT</span></li></ul>');
    },
    bread: function () {
      return wrap(site('Recipes', 'Bread') +
        '<h3>Sunday bread</h3><p>Ten minutes of work, then it rests overnight.</p>' +
        '<ul><li>500 g bread flour</li><li>360 g water</li><li>10 g salt</li><li>2 g dried yeast</li></ul>' +
        '<aside class="promo" data-hide="related" data-label="related recipes"><span>You might also like: 14 breads for a lazy weekend</span><span class="fakebtn ghost">See all</span></aside>' +
        '<p>Mix, cover, and leave it on the counter until morning. Shape it, give it an hour, and bake in a hot pot with the lid on.</p>');
    },
    weather: function () {
      return wrap(site('Weather', 'Lisbon') +
        '<div class="big">21°</div><p>Clear, with a light wind from the north-west.</p>' +
        '<ul class="rows"><li><span>Wednesday</span><span>22° · 15°</span></li><li><span>Thursday</span><span>20° · 14°</span></li><li><span>Friday</span><span>19° · 14°</span></li></ul>');
    },
    kiln: function () {
      return wrap(site('Studio Kiln', 'Firing schedule') +
        '<h3>Glaze firing, Saturday</h3><p>Load by Friday at six. Shelves fill in the order pots arrive.</p>' +
        '<aside class="promo" data-hide="banner" data-label="membership banner"><span>Members fire at half price. Join the studio.</span><span class="fakebtn">Join</span></aside>' +
        '<ul class="rows"><li><span>Bisque</span><span>Thu · 1000 °C</span></li><li><span>Glaze</span><span>Sat · 1240 °C</span></li><li><span>Unload</span><span>Mon · 9:00</span></li></ul>');
    },
    inbox: function () {
      return wrap(site('Mail', 'Inbox') +
        '<h3>Inbox</h3><ul class="rows"><li><span>Studio: the new type specimens</span><span>9:41</span></li><li><span>Invoice for September</span><span>Mon</span></li><li><span>Lunch on Thursday?</span><span>Sun</span></li></ul>');
    },
    plan: function () {
      return wrap(site('Docs', 'Edited 2 hours ago') +
        '<h3>Plan for the quarter</h3><p>Three projects this quarter. Each one gets a week of work before review.</p>' +
        '<ul><li>Ship the archive</li><li>Rewrite the onboarding</li><li>Close the old tracker</li></ul>');
    },
    notes: function () {
      return wrap(site('Notes', 'Design review') +
        '<h3>Design review</h3><p>The current tab is paper on the column, with a heavier title. The others stay plain.</p><p>Put two tabs side by side with ⇧⌘D.</p>');
    }
  };
  function tab(id, letter, color, title, host, page) { return { id: id, letter: letter, color: color, title: title, host: host, page: page }; }
  function fresh() {
    return {
      pins: [
        tab('cal', 'C', '#D2553F', 'Calendar', 'calendar.example.com', pinned('Calendar', 'calendar.example.com')),
        tab('mail', 'M', '#3A78C9', 'Mail', 'mail.example.com', pinned('Mail', 'mail.example.com')),
        tab('mus', '♪', '#C43F7A', 'Music', 'music.example.com', pinned('Music', 'music.example.com'))
      ],
      order: ['copper', 'patina', 'ember'],
      spaces: {
        copper: { name: 'Copper', icon: '', tabs: [
          tab('ledger', 'L', '#8A5A2B', 'The harbour clock is four minutes fast', 'morningledger.example', PAGES.ledger),
          tab('readme', 'G', '#24292F', 'copper-browser/Copper', 'github.com', PAGES.readme),
          tab('bread', 'R', '#C9822B', 'Sunday bread', 'recipes.example.com', PAGES.bread)
        ], active: 'ledger', split: null },
        patina: { name: 'Patina', icon: '🌊', tabs: [
          tab('inbox', 'I', '#2F6FB5', 'Inbox (3)', 'mail.example.com', PAGES.inbox),
          tab('plan', 'D', '#2E8B57', 'Plan for the quarter', 'docs.example.com', PAGES.plan),
          tab('notes', 'N', '#B8902B', 'Design review notes', 'notes.example.com', PAGES.notes)
        ], active: 'inbox', split: null },
        ember: { name: 'Ember', icon: '🔥', tabs: [
          tab('kiln', 'K', '#B5452F', 'Glaze firing, Saturday', 'kiln.example.com', PAGES.kiln),
          tab('weather', 'W', '#2D8BC9', 'Lisbon Weather', 'weather.example.com', PAGES.weather)
        ], active: 'kiln', split: null }
      }
    };
  }

  /* ---------- state ---------- */
  var S, space, hidden, hiding, userLayout = null, seq = 0;
  var pinsEl = $('#cw-pins'), tabsEl = $('#cw-tabs'), rowsEl = $('#cw-rows'), labelEl = $('#cw-label'), markEl = $('#cw-mark');
  var main = $('#cw-main'), addr = $('#cw-addr'), strip = $('#cw-strip');
  var bar = $('#cw-bar'), toast = $('#cw-toast'), scrim = $('#cw-scrim'), q = $('#cw-q'), list = $('#cw-list');
  var narrow = window.matchMedia('(max-width: 640px)');

  function sp() { return S.spaces[space]; }
  function find(id) {
    var p = S.pins.filter(function (x) { return x.id === id; })[0];
    if (p) return { tab: p, space: space, pin: true };
    for (var k in S.spaces) { var t = S.spaces[k].tabs.filter(function (x) { return x.id === id; })[0]; if (t) return { tab: t, space: k }; }
    return null;
  }
  function current() { return find(sp().active).tab; }
  function fav(t) {
    var f = document.createElement('span'); f.className = 'cw-fav'; f.setAttribute('aria-hidden', 'true');
    f.style.background = t.color; f.textContent = t.letter; return f;
  }
  function tabButton(t, isPin) {
    var b = document.createElement('button');
    b.type = 'button'; b.className = isPin ? 'cw-pin' : 'cw-tab';
    b.id = 'cwt-' + t.id; b.dataset.id = t.id;
    b.setAttribute('role', 'tab'); b.setAttribute('aria-controls', 'cw-main');
    b.appendChild(fav(t));
    if (isPin) { b.setAttribute('aria-label', t.title + ' (pinned)'); b.title = t.title; }
    else { var n = document.createElement('span'); n.className = 'cw-title'; n.textContent = t.title; b.appendChild(n); }
    return b;
  }
  function chipContent(k) {
    var s = S.spaces[k];
    if (s.icon) return s.icon;
    return '<span class="orb"></span>';
  }
  function renderStrip() {
    strip.replaceChildren();
    S.order.forEach(function (k, i) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'cw-chip'; b.dataset.space = k;
      b.title = S.spaces[k].name + ' · ⌃' + (i + 1);
      b.setAttribute('aria-label', S.spaces[k].name + ' space');
      b.setAttribute('aria-pressed', String(k === space));
      b.innerHTML = '<span aria-hidden="true">' + chipContent(k) + '</span>';
      strip.appendChild(b);
    });
    var n = document.createElement('span'); n.className = 'cw-sp-name'; n.setAttribute('aria-hidden', 'true'); n.textContent = '⌃1–3';
    strip.appendChild(n);
  }
  function renderSide() {
    cw.dataset.space = space;
    labelEl.textContent = sp().name;
    markEl.innerHTML = chipContent(space);
    pinsEl.replaceChildren.apply(pinsEl, S.pins.map(function (t) { return tabButton(t, true); }));
    tabsEl.replaceChildren.apply(tabsEl, sp().tabs.map(function (t) { return tabButton(t, false); }));
    $$('.cw-chip', strip).forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.space === space)); });
    markSelected();
  }
  function splitOn() {
    var s = sp().split;
    return s && s.indexOf(sp().active) >= 0 ? s : null;
  }
  function markSelected() {
    var a = sp().active, s = splitOn(), all = sp().split || [];
    $$('[role="tab"]', cw).forEach(function (b) {
      var on = b.dataset.id === a;
      b.setAttribute('aria-selected', String(on)); b.tabIndex = on ? 0 : -1;
      b.classList.toggle('paired', !!s && !on && s.indexOf(b.dataset.id) >= 0);
      b.classList.toggle('in-split', all.indexOf(b.dataset.id) >= 0);
    });
    if (!$('[aria-selected="true"]', pinsEl) && pinsEl.firstChild) pinsEl.firstChild.tabIndex = 0;
    var t = current();
    addr.querySelector('span').textContent = t.host;
    main.setAttribute('aria-labelledby', 'cwt-' + a);
  }
  function paneFor(t) {
    var pane = document.createElement('div');
    pane.className = 'cw-pane'; pane.dataset.id = t.id;
    if (t.query != null) pane.appendChild(newTabPage(t)); else pane.innerHTML = t.page();
    var set = hidden[t.host] || {};
    $$('[data-hide]', pane).forEach(function (el) { if (set[el.dataset.hide]) el.classList.add('gone'); });
    return pane;
  }
  function renderPage() {
    var s = splitOn(), a = sp().active;
    var order = sp().tabs.map(function (t) { return t.id; });
    var ids = s ? s.slice().sort(function (x, y) { return order.indexOf(x) - order.indexOf(y); }) : [a];
    var panes = ids.map(function (id) { var p = paneFor(find(id).tab); p.classList.toggle('focus', id === a); return p; });
    main.replaceChildren.apply(main, panes);
    if (s) main.dataset.split = ''; else delete main.dataset.split;
    armHideables();
  }
  function newTabPage(t) {
    var sc = document.createElement('div'); sc.className = 'cw-scroll'; sc.tabIndex = -1;
    var pg = document.createElement('div'); pg.className = 'pg';
    var s = document.createElement('div'); s.className = 'site';
    var a = document.createElement('span'); a.textContent = t.host; var b = document.createElement('span'); b.textContent = t.search ? 'Search' : 'New tab';
    s.appendChild(a); s.appendChild(b);
    var h = document.createElement('h3'); h.textContent = t.search ? 'Results for “' + t.query + '”' : t.query;
    var p = document.createElement('p');
    p.textContent = t.search
      ? 'In Copper this is your search engine’s page. Your words go to it when you press Return, not before.'
      : 'In Copper this is the page itself. The field finishes addresses from your own history and sends nothing until you press Return.';
    pg.appendChild(s); pg.appendChild(h); pg.appendChild(p); sc.appendChild(pg);
    return sc;
  }
  function select(id, focus) {
    var hit = find(id); if (!hit) return;
    var changed = hit.space !== space;
    space = hit.space; sp().active = id;
    if (changed) renderSide(); else markSelected();
    renderPage();
    if (focus) { var b = document.getElementById('cwt-' + id); if (b) b.focus(); }
  }
  function switchSpace(k, focus) {
    if (k === space || !S.spaces[k]) return;
    var from = S.order.indexOf(space), to = S.order.indexOf(k);
    space = k; renderSide(); renderPage();
    rowsEl.classList.remove('from-right', 'from-left'); void rowsEl.offsetWidth;
    rowsEl.classList.add(to > from ? 'from-right' : 'from-left');
    say(sp().name + ' space');
    if (focus) { var b = $('.cw-chip[data-space="' + k + '"]', strip); if (b) b.focus(); }
  }

  cw.querySelector('.cw-side').addEventListener('click', function (e) {
    var b = e.target.closest('[role="tab"]'); if (b) { select(b.dataset.id); return; }
    var c = e.target.closest('.cw-chip'); if (c) switchSpace(c.dataset.space);
  });
  cw.querySelector('.cw-side').addEventListener('keydown', function (e) {
    var b = e.target.closest('[role="tab"]'); if (!b) return;
    var group = $$('[role="tab"]', b.parentNode), i = group.indexOf(b), n = group.length, j = null;
    var vertical = cw.dataset.layout === 'side' && b.parentNode === tabsEl;
    var next = vertical ? 'ArrowDown' : 'ArrowRight', prev = vertical ? 'ArrowUp' : 'ArrowLeft';
    if (e.key === next) j = (i + 1) % n; else if (e.key === prev) j = (i - 1 + n) % n;
    else if (e.key === 'Home') j = 0; else if (e.key === 'End') j = n - 1;
    if (j === null) return;
    e.preventDefault(); select(group[j].dataset.id, true);
  });
  // a click in a split's other pane makes it the current tab
  main.addEventListener('mousedown', function (e) {
    if (hiding || main.dataset.split == null) return;
    var p = e.target.closest('.cw-pane');
    if (p && p.dataset.id !== sp().active) { sp().active = p.dataset.id; markSelected(); $$('.cw-pane', main).forEach(function (x) { x.classList.toggle('focus', x === p); }); }
  });

  /* ---------- split view (⇧⌘D) ---------- */
  function toggleSplit() {
    var s = sp();
    if (splitOn()) { s.split = null; renderSide(); renderPage(); say('Split closed'); return; }
    if (find(s.active).pin) { say('Split view takes two tabs from the space'); return; }
    var i = s.tabs.map(function (t) { return t.id; }).indexOf(s.active);
    if (s.tabs.length < 2) { say('Open another tab to split with'); return; }
    var other = s.tabs[i + 1] || s.tabs[i - 1];
    s.split = [s.active, other.id];
    renderSide(); renderPage();
    say(current().title + ' and ' + other.title + ' side by side');
  }

  /* ---------- ⌘K / ⌘L / ⌘T ---------- */
  var results = [], cursor = 0, lastFocus = null;
  function score(query, text) {
    var t = text.toLowerCase(), qq = query.toLowerCase();
    var at = t.indexOf(qq);
    if (at >= 0) { var idx = []; for (var i = 0; i < qq.length; i++) idx.push(at + i); return { s: 100 - at + (at === 0 || /\W/.test(t[at - 1]) ? 20 : 0), idx: idx }; }
    var ix = [], from = 0, s = 0;
    for (var c = 0; c < qq.length; c++) {
      if (qq[c] === ' ') continue;
      var k = t.indexOf(qq[c], from); if (k < 0) return null;
      if (ix.length && k === ix[ix.length - 1] + 1) s += 3;
      if (k === 0 || /\W/.test(t[k - 1])) s += 4;
      ix.push(k); from = k + 1;
    }
    return ix.length ? { s: s - (ix[ix.length - 1] - ix[0]) * .1, idx: ix } : null;
  }
  function looksLikeAddress(v) { return /^(https?:\/\/)?[\w-]+(\.[\w-]+)+(\/\S*)?$/i.test(v); }
  function candidates() {
    var out = S.pins.map(function (t) { return { tab: t, space: null }; });
    [space].concat(S.order.filter(function (k) { return k !== space; })).forEach(function (k) {
      S.spaces[k].tabs.forEach(function (t) { out.push({ tab: t, space: k }); });
    });
    return out;
  }
  function renderList() {
    var v = q.value.trim();
    results = [];
    candidates().forEach(function (c) {
      if (!v) { results.push({ tab: c.tab, space: c.space, idx: [], s: 0 }); return; }
      var m = score(v, c.tab.title), h = score(v, c.tab.host);
      var best = m && (!h || m.s >= h.s - 5) ? m : null;
      if (best) results.push({ tab: c.tab, space: c.space, idx: best.idx, s: best.s });
      else if (h) results.push({ tab: c.tab, space: c.space, idx: [], s: h.s - 10 });
    });
    if (v) results.sort(function (a, b) { return b.s - a.s; });
    results = results.slice(0, 7);
    if (v) results.push({ go: v, address: looksLikeAddress(v) });
    cursor = Math.max(0, Math.min(cursor, results.length - 1));
    list.replaceChildren();
    results.forEach(function (r, i) {
      var li = document.createElement('li');
      li.id = 'cwr-' + i; li.setAttribute('role', 'option'); li.setAttribute('aria-selected', String(i === cursor));
      var t = document.createElement('span'); t.className = 't';
      var s = document.createElement('span'); s.className = 's';
      if (r.go) {
        t.textContent = r.address ? 'Go to ' + r.go : 'Search for “' + r.go + '”';
        s.textContent = 'Return';
      } else {
        li.appendChild(fav(r.tab));
        var title = r.tab.title, set = {}; r.idx.forEach(function (k) { set[k] = 1; });
        var run = '', inMark = false;
        var flush = function () { if (!run) return; if (inMark) { var m = document.createElement('mark'); m.textContent = run; t.appendChild(m); } else t.appendChild(document.createTextNode(run)); run = ''; };
        for (var c = 0; c < title.length; c++) { var on = !!set[c]; if (on !== inMark) { flush(); inMark = on; } run += title[c]; }
        flush();
        s.textContent = r.space === null ? 'Pinned' : (r.tab.id === sp().active && r.space === space ? 'Current tab' : S.spaces[r.space].name);
      }
      li.appendChild(t); li.appendChild(s);
      li.addEventListener('mousedown', function (e) { e.preventDefault(); });
      li.addEventListener('click', function () { cursor = i; choose(); });
      list.appendChild(li);
    });
    if (!results.length) { var e = document.createElement('li'); e.className = 'empty'; e.textContent = 'Type to find a tab'; list.appendChild(e); }
    q.setAttribute('aria-activedescendant', results.length ? 'cwr-' + cursor : '');
    var sel = $('#cwr-' + cursor); if (sel && sel.scrollIntoView) sel.scrollIntoView({ block: 'nearest' });
  }
  function openPalette(seed, selectAll) {
    if (hiding) stopHide();
    if (!scrim.hidden) { q.select(); return; }
    lastFocus = document.activeElement;
    scrim.hidden = false; q.value = seed || ''; cursor = 0; renderList(); q.focus();
    if (selectAll) q.select();
    $$('[data-act="find"]').forEach(function (h) { h.setAttribute('aria-expanded', 'true'); });
  }
  function closePalette(restore) {
    if (scrim.hidden) return;
    scrim.hidden = true;
    $$('[data-act="find"]').forEach(function (h) { h.setAttribute('aria-expanded', 'false'); });
    if (restore !== false && lastFocus && document.contains(lastFocus)) lastFocus.focus();
  }
  function choose() {
    var r = results[cursor]; if (!r) return;
    closePalette(false);
    if (r.go) {
      var v = r.go, id = 'new' + (++seq);
      var host = r.address ? v.replace(/^https?:\/\//, '').split('/')[0] : 'search';
      var t = { id: id, letter: (r.address ? host : v).charAt(0).toUpperCase(), color: '#7A7068', title: r.address ? host : v, host: host, query: v, search: !r.address };
      var row = sp().tabs; row.push(t);
      if (row.length > 7) { var gone = row.splice(0, 1)[0]; if (sp().split && sp().split.indexOf(gone.id) >= 0) sp().split = null; }
      sp().active = id; renderSide(); renderPage();
      say('Opened ' + t.title + ' in a new tab');
    } else {
      select(r.tab.id);
      say('Switched to ' + r.tab.title);
    }
    var b = document.getElementById('cwt-' + sp().active); if (b) b.focus();
  }
  q.addEventListener('input', function () { cursor = 0; renderList(); });
  q.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); cursor = (cursor + 1) % results.length; renderList(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); cursor = (cursor - 1 + results.length) % results.length; renderList(); }
    else if (e.key === 'Enter') { e.preventDefault(); choose(); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePalette(); }
    else if (e.key === 'Tab') { e.preventDefault(); }
  });
  scrim.addEventListener('mousedown', function (e) { if (e.target === scrim) { e.preventDefault(); closePalette(); } });
  $('#cw-new').addEventListener('click', function () { openPalette(''); });
  addr.addEventListener('click', function () { var t = current(); openPalette(t.query || t.host, true); });

  /* ---------- hide anything (⇧⌘H) ---------- */
  var toastTimer, lastHidden = null;
  function armHideables() {
    $$('[data-hide]', main).forEach(function (el) {
      if (hiding) { el.tabIndex = 0; el.setAttribute('role', 'button'); el.setAttribute('aria-label', 'Hide the ' + el.dataset.label); }
      else { el.removeAttribute('tabindex'); el.removeAttribute('role'); el.removeAttribute('aria-label'); }
    });
  }
  function startHide() {
    closePalette(false);
    if (!$('[data-hide]:not(.gone)', main)) {
      var lh = hidden['morningledger.example'] || {};
      if (!(lh.cookie && lh.promo)) select('ledger');
    }
    hiding = true; cw.classList.add('hiding'); bar.hidden = false; toast.hidden = true;
    $$('[data-act="hide"]').forEach(function (h) { h.setAttribute('aria-pressed', 'true'); });
    armHideables();
    var first = $('[data-hide]:not(.gone)', main);
    say(first ? 'Hide mode. Choose something on the page to hide, or press Escape.' : 'Hide mode. Nothing left to hide on this page. Press Escape.');
    if (first && cw.contains(document.activeElement)) first.focus();
  }
  function stopHide() {
    hiding = false; cw.classList.remove('hiding'); bar.hidden = true;
    $$('[data-act="hide"]').forEach(function (h) { h.setAttribute('aria-pressed', 'false'); });
    armHideables();
  }
  function hideEl(el) {
    var t = find(el.closest('.cw-pane').dataset.id).tab, key = el.dataset.hide;
    (hidden[t.host] = hidden[t.host] || {})[key] = true;
    el.classList.add('gone'); stopHide();
    lastHidden = { host: t.host, key: key };
    $('span', toast).textContent = 'Hidden on ' + t.host + '. Still gone next time.';
    toast.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(function () { toast.hidden = true; }, 6000);
    say('Hid the ' + el.dataset.label + ' on ' + t.host + '. It stays hidden next time.');
    var sc = $('.cw-scroll', el.closest('.cw-pane')); if (sc) sc.focus();
  }
  main.addEventListener('click', function (e) {
    if (!hiding) return;
    var el = e.target.closest('[data-hide]'); e.preventDefault();
    if (el) hideEl(el);
  });
  main.addEventListener('keydown', function (e) {
    if (!hiding) return;
    var el = e.target.closest('[data-hide]');
    if (el && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); hideEl(el); }
  });
  $('button', toast).addEventListener('click', function () {
    if (!lastHidden) return;
    delete (hidden[lastHidden.host] || {})[lastHidden.key];
    toast.hidden = true; renderPage(); say('Shown again');
  });

  /* ---------- layout (⇧⌘S) and folding the column (⌘S) ---------- */
  function setLayout(l) {
    cw.dataset.layout = l;
    tabsEl.setAttribute('aria-orientation', l === 'side' ? 'vertical' : 'horizontal');
    $$('[data-act="layout"] .lbl').forEach(function (s) { s.textContent = l === 'side' ? 'Tabs on top' : 'Tabs on the left'; });
  }
  function toggleLayout() {
    userLayout = cw.dataset.layout === 'side' ? 'top' : 'side';
    if (userLayout === 'top') delete cw.dataset.folded;
    setLayout(userLayout); say(userLayout === 'top' ? 'Tabs across the top' : 'Tabs down the left');
  }
  function toggleFold() {
    if (cw.dataset.layout === 'top') return;
    if (cw.dataset.folded != null) { delete cw.dataset.folded; say('Sidebar shown'); var f = $('[data-act="fold"]', cw); if (f) f.focus(); }
    else { cw.dataset.folded = ''; say('Sidebar hidden. Press ⌘S or the sidebar button to bring it back.'); $('#cw-unfold button').focus(); }
  }
  if (narrow.addEventListener) narrow.addEventListener('change', function () { if (!userLayout) setLayout(narrow.matches ? 'top' : 'side'); });

  /* ---------- buttons ---------- */
  function act(a) {
    if (a === 'find') openPalette('');
    else if (a === 'hide') { hiding ? stopHide() : startHide(); }
    else if (a === 'layout') toggleLayout();
    else if (a === 'split') toggleSplit();
    else if (a === 'fold') toggleFold();
    else if (a === 'reset') { reset(); say('Demo reset'); }
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-act]'); if (b) act(b.dataset.act);
  });
  $$('[data-act="find"]').forEach(function (h) { h.setAttribute('aria-haspopup', 'dialog'); h.setAttribute('aria-expanded', 'false'); });

  /* ---------- keys ---------- */
  var over = false;
  cw.addEventListener('pointerenter', function () { over = true; });
  cw.addEventListener('pointerleave', function () { over = false; });
  document.addEventListener('keydown', function (e) {
    var mod = isMac ? e.metaKey : e.ctrlKey;
    var key = (e.key || '').toLowerCase();
    var inDemo = embed || over || cw.contains(document.activeElement) || !!(document.activeElement && document.activeElement.closest && document.activeElement.closest('.demo'));
    if (mod && !e.shiftKey && !e.altKey && key === 'k') {
      e.preventDefault();
      var r = cw.getBoundingClientRect();
      if (r.bottom < 0 || r.top > window.innerHeight) cw.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
      openPalette('');
      return;
    }
    if (!inDemo) return;
    var code = e.code || '';
    if (mod && !e.shiftKey && key === 'l') { e.preventDefault(); var t = current(); openPalette(t.query || t.host, true); }
    else if (mod && !e.shiftKey && key === 't') { e.preventDefault(); openPalette(''); }
    else if (mod && e.shiftKey && key === 'h') { e.preventDefault(); hiding ? stopHide() : startHide(); }
    else if (mod && e.shiftKey && key === 's') { e.preventDefault(); toggleLayout(); }
    else if (mod && !e.shiftKey && key === 's') { e.preventDefault(); toggleFold(); }
    else if (mod && e.shiftKey && key === 'd') { e.preventDefault(); toggleSplit(); }
    else if (e.ctrlKey && !e.metaKey && /^Digit[1-3]$/.test(code)) { e.preventDefault(); switchSpace(S.order[+code.slice(5) - 1], cw.contains(document.activeElement)); }
    else if (e.key === 'Escape' && hiding) { e.preventDefault(); stopHide(); say('Stopped hiding'); }
  });

  /* ---------- the homepage's cue: tell the parent once ---------- */
  if (embed && window.parent !== window) {
    var told = false;
    var tell = function () {
      if (told) return; told = true;
      try { window.parent.postMessage({ type: 'copper-demo-click' }, '*'); } catch (e) {}
      document.removeEventListener('pointerdown', tell, true); document.removeEventListener('keydown', tell, true);
    };
    document.addEventListener('pointerdown', tell, true);
    document.addEventListener('keydown', tell, true);
  }

  function reset() {
    S = fresh(); space = 'copper'; hidden = {}; userLayout = null;
    if (hiding) stopHide(); hiding = false; toast.hidden = true; closePalette(false);
    delete cw.dataset.folded;
    setLayout(narrow.matches ? 'top' : 'side');
    renderStrip(); renderSide(); renderPage();
  }
  reset();
})();
