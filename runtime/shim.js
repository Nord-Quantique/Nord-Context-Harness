/* Text-only inline edit mode + zoom for the Nord HTML bundle.
   Injected at serve time by _edit/server.py — never written into the pages themselves.
   Edits text in place; cannot alter structure, classes or CSS. */
(function () {
  'use strict';
  if (window.__nqEdit) return;

  var INLINE = { B:1, I:1, EM:1, STRONG:1, BR:1, CODE:1, SUP:1, SUB:1, SPAN:1, U:1, SMALL:1 };
  var SKIP   = { SCRIPT:1, STYLE:1, TITLE:1 };
  var STEPS  = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];

  var targets = [], original = new Map(), on = false;
  var CV = document.querySelector('.canvas, #cv');   // fixed-canvas pages only
  var zoom = 'fit';                                   // 'fit' | number

  /* ---------------- zoom ---------------- */
  function baseSize() {
    return { w: (CV && CV.offsetWidth)  || 1660, h: (CV && CV.offsetHeight) || 950 };
  }
  function fitScale() {
    var b = baseSize();
    return Math.min((window.innerWidth - 40) / b.w, (window.innerHeight - 56) / b.h, 1);
  }
  function zoomValue() { return zoom === 'fit' ? fitScale() : zoom; }
  function applyZoom() {
    if (!CV) { zlab.textContent = 'n/a'; return; }
    var b = baseSize(), z = zoomValue();
    document.documentElement.style.setProperty('--nqz', z);
    document.body.style.setProperty('min-width',  Math.ceil(b.w * z + 24) + 'px', 'important');
    document.body.style.setProperty('min-height', Math.ceil(b.h * z + 24) + 'px', 'important');
    zlab.textContent = (zoom === 'fit' ? 'Fit · ' : '') + Math.round(z * 100) + '%';
  }
  function stepZoom(dir) {
    if (!CV) return;
    var cur = zoomValue(), i;
    if (dir > 0) { for (i = 0; i < STEPS.length; i++) if (STEPS[i] > cur + 0.001) break; }
    else         { for (i = STEPS.length - 1; i >= 0; i--) if (STEPS[i] < cur - 0.001) break; }
    zoom = STEPS[Math.max(0, Math.min(STEPS.length - 1, i))];
    applyZoom();
  }
  function zoomToFit() { zoom = 'fit'; applyZoom(); }

  /* keep the focused block on screen when zoomed in */
  function keepVisible(el) {
    var r = el.getBoundingClientRect();
    if (r.top < 60 || r.bottom > window.innerHeight - 70 ||
        r.left < 0 || r.right > window.innerWidth) {
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
    }
  }

  /* ---------------- find text-bearing leaves ---------------- */
  function isTextLeaf(el) {
    if (SKIP[el.tagName]) return false;
    if (el.closest('[data-nq-ui]')) return false;
    if (el.closest('svg')) return false;
    var hasText = false;
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3) { if (n.textContent.trim()) hasText = true; }
      else if (n.nodeType === 1) { if (!INLINE[n.tagName]) return false; }
    }
    return hasText;
  }
  function collect() {
    targets = []; original = new Map();
    var all = document.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (isTextLeaf(all[i])) { targets.push(all[i]); original.set(all[i], all[i].innerHTML); }
    }
  }

  /* ---------------- sanitise ---------------- */
  function clean(html) {
    var box = document.createElement('div');
    box.innerHTML = html;
    (function walk(node) {
      var kids = Array.prototype.slice.call(node.childNodes);
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i];
        if (c.nodeType === 8) { c.remove(); continue; }
        if (c.nodeType !== 1) continue;
        walk(c);
        var keepTag  = INLINE[c.tagName] && c.tagName !== 'SPAN';
        var keepSpan = c.tagName === 'SPAN' && c.getAttribute('class');
        if (keepTag || keepSpan) {
          var cls = c.getAttribute('class');
          while (c.attributes.length) c.removeAttribute(c.attributes[0].name);
          if (keepSpan && cls) c.setAttribute('class', cls);
        } else {
          while (c.firstChild) node.insertBefore(c.firstChild, c);
          c.remove();
        }
      }
    })(box);
    return box.innerHTML.replace(/&nbsp;|\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  }

  /* ---------------- edit mode ---------------- */
  function setMode(v) {
    on = v;
    if (v && typeof cmt !== 'undefined' && cmt) setCmt(false);
    for (var i = 0; i < targets.length; i++) {
      var el = targets[i];
      if (v) { el.setAttribute('contenteditable', 'true'); el.setAttribute('spellcheck', 'false'); }
      else   { el.removeAttribute('contenteditable'); el.removeAttribute('spellcheck'); }
    }
    document.documentElement.classList.toggle('__nqed_on', v);
    btn.textContent = v ? 'Editing' : 'Edit off';
    btn.className = v ? 'act' : '';
    say(v ? '⌘S save · ⇧Enter line break · ⌥+ / ⌥− zoom' : 'Edit mode off', '');
  }

  /* ---------------- save ---------------- */
  function save() {
    var changes = [], seen = {}, wiped = 0;
    for (var i = 0; i < targets.length; i++) {
      var el = targets[i], was = original.get(el);
      var occ = seen[was] === undefined ? 0 : seen[was];
      seen[was] = occ + 1;
      var now = clean(el.innerHTML);
      var wasFlat = was.replace(/\s+/g, ' ').trim();
      if (now === wasFlat) continue;
      var empty = !now.replace(/<br\s*\/?>/gi, '').replace(/&nbsp;|\u00a0/g, '').trim();
      if (empty && wasFlat) { wiped++; continue; }          // refuse to blank existing content
      changes.push({ old: was, now: now, occurrence: occ, el: i });
    }
    if (wiped) say(wiped + ' emptied block' + (wiped > 1 ? 's' : '') + ' skipped — reload to restore', 'warn');
    if (!changes.length) { if (!wiped) say('Nothing changed', 'warn'); return; }
    say('Saving ' + changes.length + '…', '');
    fetch('/_save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        file: location.pathname.replace(/^\//, ''),
        changes: changes.map(function (c) { return { old: c.old, now: c.now, occurrence: c.occurrence }; })
      })
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (!res.ok) { say('FAILED — ' + res.error, 'bad'); return; }
      for (var i = 0; i < changes.length; i++) {
        if (res.applied.indexOf(i) >= 0) original.set(targets[changes[i].el], changes[i].now);
      }
      fetch('/_mtime?file=' + encodeURIComponent(here), { cache: 'no-store' })
        .then(function (r) { return r.json(); }).then(function (m) { stamp = m.html; }).catch(function () {});
      var msg = 'Saved ' + res.applied.length + '/' + changes.length;
      if (res.failed.length) msg += ' · ' + res.failed.length + ' unmatched';
      if (res.png) msg += ' · PNG rebuilt';
      say(msg, res.failed.length ? 'warn' : 'good');
    }).catch(function (e) { say('FAILED — ' + e.message, 'bad'); });
  }


  /* ================= comments ================= */
  var cmt = false, notes = [], composer = null, panel = null;
  var layer = document.createElement('div');
  layer.id = '__nqcm'; layer.setAttribute('data-nq-ui', '1');
  layer.style.cssText = 'position:fixed;inset:0;z-index:2147483640;pointer-events:none';

  function pathOf(el) {
    var p = [];
    while (el && el.nodeType === 1 && el !== document.body) {
      var i = 1, s = el;
      while (s.previousElementSibling) { s = s.previousElementSibling; i++; }
      var cls = (typeof el.className === 'string' && el.className.trim())
        ? '.' + el.className.trim().split(/\s+/).join('.') : '';
      p.unshift(el.tagName.toLowerCase() + cls + ':nth-child(' + i + ')');
      el = el.parentElement;
    }
    return p.join(' > ');
  }
  function resolve(n) {
    try { var e = document.body.querySelector(n.target.path); if (e) return e; } catch (x) {}
    var all = document.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].textContent.trim() === (n.text || '').trim() && isTextLeaf(all[i])) return all[i];
    }
    return null;
  }
  function nearestLeaf(el) {
    while (el && el !== document.body && !isTextLeaf(el)) el = el.parentElement;
    return (el && el !== document.body) ? el : null;
  }

  function drawPins() {
    layer.querySelectorAll('.pin').forEach(function (p) { p.remove(); });
    notes.forEach(function (n, i) {
      var el = resolve(n); if (!el) return;
      var r = el.getBoundingClientRect();
      if (r.bottom < 0 || r.top > window.innerHeight) return;
      var pin = document.createElement('button');
      pin.className = 'pin' + (n.status !== 'open' ? ' done' : '');
      pin.textContent = i + 1;
      pin.style.left = Math.max(2, r.left - 9) + 'px';
      pin.style.top  = Math.max(2, r.top - 9) + 'px';
      pin.title = n.comment;
      pin.onclick = function (e) { e.stopPropagation(); openNote(n, el); };
      layer.appendChild(pin);
    });
    cbtn.textContent = 'Comment' + (notes.length ? ' (' + notes.length + ')' : '');
  }

  function post(body) {
    body.page = location.pathname.replace(/^\//, '');
    return fetch('/_comments', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body) }).then(function (r) { return r.json(); })
      .then(function (res) {
        if (!res.ok) { say('Comment failed — ' + res.error, 'bad'); return res; }
        notes = res.comments || []; drawPins(); return res;
      });
  }
  function loadNotes() {
    return fetch('/_comments.json').then(function (r) { return r.json(); }).then(function (all) {
      var here = location.pathname.replace(/^\//, '');
      notes = all.filter(function (c) { return c.page === here; });
      drawPins();
    }).catch(function () {});
  }

  function closeUI() {
    if (composer) { composer.remove(); composer = null; }
    if (panel) { panel.remove(); panel = null; }
  }

  function box(cls) {
    var d = document.createElement('div');
    d.className = cls; d.setAttribute('data-nq-ui', '1');
    d.style.pointerEvents = 'auto';
    d.onclick = function (e) { e.stopPropagation(); };
    return d;
  }
  function place(d, r) {
    var W = 300, top = r.bottom + 8, left = Math.min(r.left, window.innerWidth - W - 14);
    if (top + 150 > window.innerHeight) top = Math.max(8, r.top - 158);
    d.style.left = Math.max(8, left) + 'px'; d.style.top = top + 'px';
  }

  function openComposer(el, selText) {
    closeUI();
    var r = el.getBoundingClientRect();
    composer = box('cbox');
    var quote = (selText || el.textContent.trim()).slice(0, 140);
    composer.innerHTML = '<div class="cq"></div><textarea rows="3" placeholder="What should change?"></textarea>' +
      '<div class="cr"><span class="hint">⏎ save · esc cancel</span><button class="x">Cancel</button><button class="ok">Comment</button></div>';
    composer.querySelector('.cq').textContent = '“' + quote + (quote.length >= 140 ? '…' : '') + '”';
    place(composer, r);
    layer.appendChild(composer);
    var ta = composer.querySelector('textarea'); ta.focus();
    el.classList.add('__nqcm_hl');
    function done() { el.classList.remove('__nqcm_hl'); closeUI(); }
    composer.querySelector('.x').onclick = done;
    composer.querySelector('.ok').onclick = function () {
      var v = ta.value.trim(); if (!v) { ta.focus(); return; }
      post({ action: 'add', comment: v, text: el.textContent.trim(),
             selection: selText || null,
             target: { path: pathOf(el), tag: el.tagName, classes: (el.className || '') + '' } })
        .then(function () { say('Comment saved', 'good'); done(); });
    };
    ta.onkeydown = function (e) {
      // stop it here, or the document handler below sees a closed composer
      // and leaves comment mode on the same keypress
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(); }
      else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); composer.querySelector('.ok').click(); }
    };
  }

  function openNote(n, el) {
    closeUI();
    var r = el.getBoundingClientRect();
    panel = box('cbox');
    panel.innerHTML = '<div class="cq"></div><textarea rows="3"></textarea>' +
      '<div class="cr"><button class="del">Delete</button><button class="res"></button><button class="ok">Update</button></div>' +
      '<div class="cm2"></div>';
    panel.querySelector('.cq').textContent = '“' + (n.selection || n.text || '').slice(0, 140) + '”';
    panel.querySelector('textarea').value = n.comment;
    panel.querySelector('.res').textContent = n.status === 'open' ? 'Mark done' : 'Reopen';
    panel.querySelector('.cm2').textContent = n.created + ' · ' + n.status;
    place(panel, r);
    layer.appendChild(panel);
    panel.querySelector('.ok').onclick = function () {
      post({ action: 'edit', id: n.id, comment: panel.querySelector('textarea').value.trim() })
        .then(function () { say('Comment updated', 'good'); closeUI(); });
    };
    panel.querySelector('.del').onclick = function () {
      post({ action: 'delete', id: n.id }).then(function () { say('Comment deleted', 'good'); closeUI(); });
    };
    panel.querySelector('.res').onclick = function () {
      post({ action: 'status', id: n.id, status: n.status === 'open' ? 'done' : 'open' })
        .then(function () { closeUI(); });
    };
  }

  function setCmt(v) {
    cmt = v;
    if (v && on) setMode(false);
    document.documentElement.classList.toggle('__nqcm_on', v);
    cbtn.className = v ? 'act' : '';
    closeUI();
    say(v ? 'Select text or click a block to comment' : 'Comment mode off', '');
  }

  document.addEventListener('mousedown', function (e) {
    if (!cmt || e.target.closest('[data-nq-ui]')) return;
    e.preventDefault();
  }, true);
  document.addEventListener('click', function (e) {
    if (!cmt || e.target.closest('[data-nq-ui]')) return;
    e.preventDefault(); e.stopPropagation();
    var sel = window.getSelection();
    var selText = (sel && !sel.isCollapsed) ? sel.toString().trim() : '';
    var el = nearestLeaf(e.target) || e.target;
    openComposer(el, selText);
  }, true);

  addEventListener('scroll', drawPins, true);
  addEventListener('resize', drawPins);


  /* ================= live reload + render ================= */
  var stamp = null, dirtyWarned = false;
  var here = location.pathname.replace(/^\//, '');

  function unsaved() {
    for (var i = 0; i < targets.length; i++) {
      var was = (original.get(targets[i]) || '').replace(/\s+/g, ' ').trim();
      if (clean(targets[i].innerHTML) !== was) return true;
    }
    return false;
  }

  function poll() {
    fetch('/_mtime?file=' + encodeURIComponent(here), { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (m) {
        if (!m.html) return;
        if (stamp === null) { stamp = m.html; return; }
        if (m.html === stamp) return;
        // Half-written feedback is worth more than a prompt refresh. stamp is not
        // advanced here, so the next poll reloads as soon as the comment is closed.
        if (document.querySelector('.cbox')) return;
        if (unsaved()) {
          if (!dirtyWarned) {
            dirtyWarned = true;
            rbtn.textContent = 'Reload ⟳';
            rbtn.className = 'act';
            say('File changed on disk — you have unsaved edits. Reload discards them.', 'warn');
          }
          return;
        }
        say('Updated on disk — reloading…', 'good');
        setTimeout(function () { location.reload(); }, 250);
      }).catch(function () {});
  }
  setInterval(poll, 1200);

  function rerender() {
    say('Rendering PNG…', '');
    fetch('/_render', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: here }) })
      .then(function (r) { return r.json(); })
      .then(function (res) { say(res.ok ? 'PNG re-rendered' : 'Render failed — ' + res.error,
                                 res.ok ? 'good' : 'bad'); })
      .catch(function (e) { say('Render failed — ' + e.message, 'bad'); });
  }

  /* ---------------- ui ---------------- */
  var css = document.createElement('style');
  css.textContent =
    /* zoom takes the page's own fit() scale over — stylesheet !important beats its inline style */
    'html.__nqed_z .canvas,html.__nqed_z #cv{transform:scale(var(--nqz,1))!important;' +
      'transform-origin:top left!important}' +
    'html.__nqed_z body{display:block!important;height:auto!important;padding:12px!important;' +
      'justify-content:flex-start!important;align-items:flex-start!important}' +
    '#__nqtop{display:inline-flex;flex-wrap:wrap;align-items:center;gap:6px;margin-left:14px;padding-left:14px;border-left:1px solid rgba(128,128,128,.22);font:inherit}' +
    '#__nqtop b{font-size:9.5px;font-weight:800;letter-spacing:.09em;text-transform:uppercase;opacity:.42;margin-right:3px}' +
    /* namespaced: the bar is injected into pages that style .grp/.chip/.tg for
       their own content, and a page rule was shifting the audience group. */
    '#__nqtop .nqg,#__nqtop .nqt{display:inline-flex;align-items:center;gap:4px;margin:0}' +
    '#__nqtop .nqt{margin-left:8px}' +
    /* a native select sizes and vertically centres its own text, which left the
       selects 1.2px taller than the chips beside them. Both pills share one box
       below and the caret is drawn here, since appearance:none drops it.
       16px is the back-link's own line box, so the row adds no height to the bar. */
    '#__nqtop select,#__nqtop .nqc{font-size:11px;font-weight:600;height:16px;padding:0 7px;margin:0;' +
      'border:1px solid rgba(128,128,128,.28);border-radius:12px}' +
    '#__nqtop select{font-family:inherit;color:inherit;opacity:.75;cursor:pointer;max-width:150px;' +
      'appearance:none;-webkit-appearance:none;padding-right:16px;background:transparent no-repeat;' +
      'background-image:linear-gradient(45deg,transparent 50%,currentColor 50%),' +
                       'linear-gradient(135deg,currentColor 50%,transparent 50%);' +
      'background-size:4px 4px,4px 4px;' +
      'background-position:right 8px center,right 5px center}' +
    '#__nqtop select:hover{opacity:1;border-color:#2a78d6}' +
    '#__nqtop select.pub{color:#0ca30c;border-color:rgba(12,163,12,.4);opacity:1}' +
    '#__nqtop select.norepo{color:#c07d16;border-color:rgba(192,125,22,.45);opacity:1}' +
    '#__nqtop select.nqadd{border-style:dashed;width:32px;padding:0;background-image:none;' +
      'text-align:center;text-align-last:center}' +
    '#__nqtop .nqc{display:inline-flex;align-items:center;gap:3px;opacity:.7}' +
    '#__nqtop .nqc i{font-style:normal;opacity:.5;cursor:pointer}' +
    '#__nqtop .nqc i:hover{opacity:1;color:#c94b4b}' +
    '.nqback.__nqfallback{position:sticky;top:0;z-index:60}' +
    'html.render #__nqtop{display:none}' +
    '#__nqed .nqmode{font-size:9.5px;font-weight:800;letter-spacing:.09em;padding:3px 7px;border-radius:5px;flex:none}' +
      '#__nqed .nqmode{background:rgba(120,170,255,.18);color:#9ec8ff}' +
      'html.__nqadmin #__nqed .nqmode{background:rgba(192,125,22,.22);color:#f0b756}' +
      '#__nqed{position:fixed;left:12px;bottom:12px;z-index:2147483647;display:flex;align-items:center;gap:7px;' +
      'font:600 12.5px/1.2 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;' +
      'background:rgba(16,26,40,.94);color:#fff;padding:7px 9px;border-radius:9px;' +
      'box-shadow:0 4px 18px rgba(0,0,0,.3);backdrop-filter:blur(6px)}' +
    '#__nqed button{font:inherit;color:#fff;background:#2c3d55;border:1px solid #46586f;' +
      'border-radius:6px;padding:4px 9px;cursor:pointer}' +
    '#__nqed button:hover{background:#3a4d67}' +
    '#__nqed button.act{background:#b8791a;border-color:#d8952f}' +
    '#__nqed .z{display:flex;align-items:center;gap:4px;padding-left:6px;margin-left:1px;' +
      'border-left:1px solid #3d4f66}' +
    '#__nqed .z button{padding:4px 8px;min-width:26px}' +
    '#__nqed .zl{opacity:.85;font-variant-numeric:tabular-nums;min-width:62px;text-align:center;font-weight:500}' +
    '#__nqed .st{opacity:.82;font-weight:500;max-width:400px;padding-left:6px;border-left:1px solid #3d4f66}' +
    '#__nqed .st.good{color:#6ee7b7;opacity:1}#__nqed .st.warn{color:#fcd34d;opacity:1}' +
    '#__nqed .st.bad{color:#fca5a5;opacity:1}' +
    '#__nqcm .pin{position:fixed;pointer-events:auto;width:19px;height:19px;border-radius:50%;' +
      'background:#c07d16;color:#fff;border:2px solid #fff;font:700 10.5px/1 system-ui;cursor:pointer;' +
      'box-shadow:0 1px 5px rgba(0,0,0,.3);display:flex;align-items:center;justify-content:center;padding:0}' +
    '#__nqcm .pin.done{background:#5a9e5a}' +
    '#__nqcm .cbox{position:fixed;width:300px;background:#fff;border:1px solid #c8d3e0;border-radius:10px;' +
      'box-shadow:0 8px 30px rgba(16,26,40,.22);padding:11px 12px;' +
      'font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;color:#16283d}' +
    '#__nqcm .cq{font-size:11.7px;font-style:italic;color:#6b7d8f;border-left:2px solid #dfe5ec;' +
      'padding-left:8px;margin-bottom:8px;max-height:52px;overflow:hidden}' +
    '#__nqcm textarea{width:100%;box-sizing:border-box;font:inherit;padding:7px 8px;resize:vertical;' +
      'border:1px solid #cfd8e3;border-radius:6px;outline:none}' +
    '#__nqcm textarea:focus{border-color:#c07d16;box-shadow:0 0 0 2px rgba(192,125,22,.15)}' +
    '#__nqcm .cr{display:flex;align-items:center;gap:6px;margin-top:8px}' +
    '#__nqcm .cr .hint{flex:1;font-size:10.8px;color:#93a1b0}' +
    '#__nqcm .cr button{font:600 12px system-ui;padding:5px 10px;border-radius:6px;cursor:pointer;' +
      'border:1px solid #cfd8e3;background:#f4f6f9;color:#3c4b5c}' +
    '#__nqcm .cr .ok{background:#c07d16;border-color:#a86d12;color:#fff}' +
    '#__nqcm .cr .del{margin-right:auto;color:#a33;border-color:#e3c4c4;background:#fdf6f6}' +
    '#__nqcm .cm2{font-size:10.8px;color:#93a1b0;margin-top:7px}' +
    'html.__nqcm_on *{cursor:crosshair!important}' +
    'html.__nqcm_on [data-nq-ui] *{cursor:auto!important}' +
    '.__nqcm_hl{outline:2px solid #c07d16!important;outline-offset:2px;background:rgba(192,125,22,.1)!important}' +
    'html.__nqed_on [contenteditable]{outline:1px dashed rgba(192,125,22,.5);outline-offset:2px;border-radius:3px}' +
    'html.__nqed_on [contenteditable]:hover{outline-style:solid;background:rgba(192,125,22,.07)}' +
    'html.__nqed_on [contenteditable]:focus{outline:2px solid #c07d16;background:rgba(192,125,22,.11)}';
  document.head.appendChild(css);

  var MODE = window.__NQ_MODE || {};
  var READER = !!window.__NQ_READER || MODE.mode === 'reader';
  var bar = document.createElement('div'); bar.id = '__nqed'; bar.setAttribute('data-nq-ui','1');
  var btn = document.createElement('button');
  var sv  = document.createElement('button'); sv.textContent = 'Save ⌘S';
  var cbtn= document.createElement('button'); cbtn.textContent = 'Comment'; cbtn.title = 'Comment mode (⌘K)';
  var clist=document.createElement('button'); clist.textContent = '☰'; clist.title = 'All comments';
  var rbtn = document.createElement('button'); rbtn.textContent = 'Render'; rbtn.title = 'Rebuild the PNG from this page';
  var zw  = document.createElement('div');    zw.className = 'z';
  var zo  = document.createElement('button'); zo.textContent = '−'; zo.title = 'Zoom out (⌥−)';
  var zlab= document.createElement('div');    zlab.className = 'zl';
  var zi  = document.createElement('button'); zi.textContent = '+'; zi.title = 'Zoom in (⌥+)';
  var zf  = document.createElement('button'); zf.textContent = 'Fit'; zf.title = 'Fit to window (⌥0)';
  var st  = document.createElement('div');    st.className = 'st';
  // which server am I looking at. The two used to share a port and nothing
  // on screen distinguished them.
  var badge = document.createElement('div'); badge.className = 'nqmode';
  badge.textContent = READER ? 'READER' : 'ADMIN';
  badge.title = (MODE.store ? MODE.store + '  ' : '')
              + (MODE.port ? 'port ' + MODE.port : '')
              + (READER ? '  — a published store, read-only'
                        : '  — the working bundle, editable');
  zw.append(zo, zlab, zi, zf);
  // Reader mode is what ships to whoever loads the app: leaving a comment and
  // zooming are the whole surface. Edit, save, the comment list and the PNG
  // re-render are never appended, so there is no hidden control to reveal.
  if (READER) bar.append(badge, cbtn, zw, st);
  else        bar.append(badge, btn, sv, cbtn, clist, rbtn, zw, st);
  function say(t, k) { st.textContent = t; st.className = 'st ' + (k || ''); }

  btn.onclick = function () { setMode(!on); };
  sv.onclick  = save;
  cbtn.onclick = function () { setCmt(!cmt); };
  clist.onclick = function () { window.open('/_comments.html', '_blank'); };
  rbtn.onclick = function () { if (dirtyWarned) location.reload(); else rerender(); };
  zi.onclick  = function () { stepZoom(1); };
  zo.onclick  = function () { stepZoom(-1); };
  zf.onclick  = zoomToFit;

  document.addEventListener('keydown', function (e) {
    var meta = e.metaKey || e.ctrlKey;
    if (meta && e.key === 's' && !READER) { e.preventDefault(); on ? save() : say('Turn edit mode on first', 'warn'); }
    else if (meta && e.key === 'e' && !READER) { e.preventDefault(); setMode(!on); }
    else if (meta && e.key === 'k') { e.preventDefault(); setCmt(!cmt); }
    else if (e.key === 'Escape' && cmt) {
      // first Escape leaves the comment you are on, the second leaves the mode
      if (composer || panel) closeUI();
      else setCmt(false);
    }
    else if (e.altKey && (e.key === '=' || e.key === '+' || e.code === 'Equal')) { e.preventDefault(); stepZoom(1); }
    else if (e.altKey && (e.key === '-' || e.key === '_' || e.code === 'Minus')) { e.preventDefault(); stepZoom(-1); }
    else if (e.altKey && (e.key === '0' || e.code === 'Digit0')) { e.preventDefault(); zoomToFit(); }
    else if (e.key === 'Enter' && on && e.target.isContentEditable) {
      e.preventDefault();
      if (e.shiftKey) document.execCommand('insertHTML', false, '<br>');
    }
  });
  document.addEventListener('beforeinput', function (e) {
    if (!on) return;
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
    var r = sel.getRangeAt(0);
    var a = r.startContainer, b = r.endContainer;
    a = (a.nodeType === 1 ? a : a.parentElement).closest('[contenteditable]');
    b = (b.nodeType === 1 ? b : b.parentElement).closest('[contenteditable]');
    if (a && b && a !== b) {
      e.preventDefault();
      sel.removeAllRanges();
      say('Blocked — that selection spanned several blocks. Edit one at a time.', 'warn');
    }
  }, true);

  document.addEventListener('paste', function (e) {
    if (!on || !e.target.isContentEditable) return;
    e.preventDefault();
    document.execCommand('insertText', false, (e.clipboardData || window.clipboardData).getData('text/plain'));
  });
  document.addEventListener('focusin', function (e) {
    if (on && e.target.isContentEditable && zoom !== 'fit') keepVisible(e.target);
  });
  addEventListener('resize', function () { if (zoom === 'fit') applyZoom(); });


  /* ---- who this page is for, and how it is tagged -------------------------
     Both belong to the page, so they are reachable while reading it. They ride
     inside nav.js's own bar rather than in a pill of their own, so they read as
     part of the navigation instead of a second widget. The index is skipped: it
     already has a filter bar, and its audience belongs there with the other
     filters. Lives in the shim, which is injected at serve time and never
     published, so these controls cannot reach a shared copy. */
  var TOP = null, tState = {groups: {}, group: 'private', labels: {}, tags: []};

  function tpost(url, body) {
    return fetch(url, {method: 'POST', headers: {'Content-Type': 'application/json'},
                       body: JSON.stringify(body)}).then(function (r) { return r.json(); });
  }

  function drawTop() {
    if (!TOP) return;
    var page = location.pathname.replace(/^\//, '') || 'index.html';
    TOP.innerHTML = '';

    var g = document.createElement('span');
    g.className = 'nqg';
    g.innerHTML = '<b>for</b>';
    var sel = document.createElement('select');
    // A group with no repository has nowhere to publish to, so assigning a page to
    // it would record an intention that cannot be carried out. Offer private, which
    // means "stays here", plus the groups that have a destination.
    Object.keys(tState.groups).filter(function (slug) {
      return slug === 'private' || (tState.groups[slug] || {}).repo;
    }).forEach(function (slug) {
      var o = document.createElement('option');
      o.value = slug;
      o.textContent = tState.groups[slug].label || slug;
      if (slug === tState.group) o.selected = true;
      sel.appendChild(o);
    });
    function paint() {
      var info = tState.groups[sel.value] || {};
      sel.className = sel.value === 'private' ? '' : (info.repo ? 'pub' : 'norepo');
      sel.title = sel.value === 'private' ? 'Stays on this machine'
                : (info.repo ? 'Publishes to ' + info.repo : 'This group has no repository yet');
    }
    paint();
    sel.onchange = function () {
      var want = sel.value;
      tpost('/_audience', {action: 'set', page: page, group: want}).then(function (r) {
        if (!r.ok) { alert(r.error || 'could not set the audience'); sel.value = tState.group; return; }
        tState.group = want; paint();
        say('audience: ' + (tState.groups[want].label || want), 'ok');
      });
    };
    g.appendChild(sel);
    TOP.appendChild(g);

    var t = document.createElement('span');
    t.className = 'nqt';
    t.innerHTML = '<b>tags</b>';
    tState.tags.forEach(function (slug) {
      var chip = document.createElement('span');
      chip.className = 'nqc';
      chip.textContent = tState.labels[slug] || slug;
      var x = document.createElement('i');
      x.textContent = '×';
      x.title = 'remove this tag';
      x.onclick = function () {
        tpost('/_tags', {action: 'rm', page: page, tag: slug}).then(function (r) {
          if (r.ok) { tState.tags = r.tags || []; drawTop(); say('tag removed', 'ok'); }
        });
      };
      chip.appendChild(x);
      t.appendChild(chip);
    });
    var add = document.createElement('select');
    add.className = 'nqadd';
    var ph = document.createElement('option');
    ph.textContent = '+'; ph.value = '';
    add.appendChild(ph);
    Object.keys(tState.labels).forEach(function (slug) {
      if (tState.tags.indexOf(slug) > -1) return;
      var o = document.createElement('option');
      o.value = slug; o.textContent = tState.labels[slug];
      add.appendChild(o);
    });
    add.onchange = function () {
      if (!add.value) return;
      tpost('/_tags', {action: 'add', page: page, tag: add.value}).then(function (r) {
        if (r.ok) { tState.tags = r.tags || []; drawTop(); say('tag added', 'ok'); }
      });
    };
    t.appendChild(add);
    TOP.appendChild(t);
  }

  /* nav.js builds its bar on the same tick, so give it a few frames to appear
     before falling back to a standalone strip. */
  function mountTop(tries) {
    if (READER) return;                                // authoring control, not shipped
    var here = location.pathname.replace(/^\//, '') || 'index.html';
    if (here === 'index.html') return;                 // the index filters instead
    var host = document.querySelector('.nqback');
    if (!host) {
      if ((tries || 0) < 20) return setTimeout(function () { mountTop((tries || 0) + 1); }, 60);
      host = document.createElement('div');
      host.className = 'nqback __nqfallback';
      document.body.insertBefore(host, document.body.firstChild);
    }
    TOP = document.createElement('span');
    TOP.id = '__nqtop';
    var pg = host.querySelector('.pg');
    if (pg) host.insertBefore(TOP, pg); else host.appendChild(TOP);
    loadTop();
  }

  function loadTop() {
    var page = location.pathname.replace(/^\//, '') || 'index.html';
    fetch('/_meta?page=' + encodeURIComponent(page)).then(function (r) { return r.json(); })
      .then(function (d) {
        tState = {groups: d.groups || {}, group: d.group || 'private',
                  labels: d.labels || {}, tags: d.tags || []};
        drawTop();
      }).catch(function () { if (TOP) TOP.remove(); });
  }


  function boot() {
    if (!READER) document.documentElement.classList.add('__nqadmin');
    mountTop();
    document.body.appendChild(bar);
    document.body.appendChild(layer);
    collect();
    setMode(false);
    if (CV) { document.documentElement.classList.add('__nqed_z'); applyZoom(); }
    else    { zlab.textContent = '⌘+'; zo.disabled = zi.disabled = zf.disabled = true; }
    loadNotes();
    say(targets.length + ' text blocks · ' +
        (READER ? '⌘K comment' : '⌘E edit · ⌘K comment'), '');
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  window.__nqEdit = { save: save, mode: setMode, comment: setCmt, render: rerender, notes: function () { return notes; }, zoom: function (z) { zoom = z; applyZoom(); } };
})();
