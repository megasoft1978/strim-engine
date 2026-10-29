import Foundation

/// site/assets/site.js: copy buttons, theme toggle, screenshot lightbox, reveal-on-scroll with count-up, active nav section, scroll progress, window tilt.
/// Everything is progressive enhancement: with JS off the page shows its final state. Written to stay under 6 KB.
let SITE_JS = #"""
(function () {
  var d = document, root = d.documentElement;
  var $ = (s, c) => Array.from((c || d).querySelectorAll(s));
  var rm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var isDark = () => (root.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches && 'dark')) === 'dark';
  root.classList.add('js');

  function copyText(t, done) {
    function fb() {
      try {
        var a = d.createElement('textarea');
        a.value = t; a.style.cssText = 'position:fixed;opacity:0';
        d.body.appendChild(a); a.select();
        var ok = d.execCommand('copy');
        a.remove();
        if (ok) done();
      } catch {}
    }
    if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(t).then(done, fb); } else { fb(); }
  }
  $('[data-copy]').forEach(function (b) {
    b.hidden = false;
    b.addEventListener('click', function () {
      copyText(b.getAttribute('data-copy'), function () {
        b.textContent = 'Copied'; b.classList.add('ok');
        setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('ok'); }, 1600);
      });
    });
  });
  var tb = d.getElementById('theme');
  if (tb) {
    tb.hidden = false;
    tb.addEventListener('click', function () {
      var n = isDark() ? 'light' : 'dark';
      root.setAttribute('data-theme', n);
      try { localStorage.setItem('strim-theme', n); } catch (e) {}
    });
  }

  var lb = d.getElementById('lb');
  if (lb && lb.showModal) {
    var items = $('.zoom'), cur = 0, last = null;
    var img = d.getElementById('lbi'), cap = d.getElementById('lbcap'), cnt = d.getElementById('lbc');
    var show = function (n) {
      cur = (n + items.length) % items.length;
      var b = items[cur];
      img.src = (!isDark() && b.getAttribute('data-full-light')) || b.getAttribute('data-full');
      img.alt = b.getAttribute('data-alt') || '';
      cap.textContent = b.getAttribute('data-cap') || '';
      cnt.textContent = (cur + 1) + ' / ' + items.length;
      lb.classList.remove('z');
    };
    var open = function (b) {
      last = b; show(items.indexOf(b));
      lb.showModal(); root.classList.add('lb-open');
    };
    items.forEach(function (b) { b.addEventListener('click', function () { open(b); }); });
    lb.addEventListener('close', function () { root.classList.remove('lb-open'); if (last) { last.focus(); } });
    lb.addEventListener('click', function (e) { if (e.target === lb || e.target.className === 'lbstage') { lb.close(); } });
    d.getElementById('lbx').addEventListener('click', function () { lb.close(); });
    d.getElementById('lbp').addEventListener('click', function () { show(cur - 1); });
    d.getElementById('lbn').addEventListener('click', function () { show(cur + 1); });
    lb.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft') { show(cur - 1); e.preventDefault(); }
      else if (e.key === 'ArrowRight') { show(cur + 1); e.preventDefault(); }
    });
    img.addEventListener('dblclick', function () { lb.classList.toggle('z'); });
    var x0 = null;
    lb.addEventListener('touchstart', function (e) { x0 = e.touches.length === 1 ? e.touches[0].clientX : null; }, { passive: true });
    lb.addEventListener('touchend', function (e) {
      if (x0 === null || lb.classList.contains('z')) { return; }
      var dx = e.changedTouches[0].clientX - x0; x0 = null;
      if (dx > 50) { show(cur - 1); } else if (-dx > 50) { show(cur + 1); }
    });
    var q = /lightbox=(\d)/.exec(location.search);
    if (q && items.length) { open(items[Math.min(+q[1] - 1, items.length - 1)]); }
  }

  function count(el) {
    var to = parseFloat(el.getAttribute('data-count')), dp = (el.getAttribute('data-count').split('.')[1] || '').length, suf = el.getAttribute('data-suffix') || '';
    if (rm || isNaN(to)) { return; }
    var t0 = null;
    (function tick(t) {
      if (t0 === null) { t0 = t; }
      var p = Math.min(1, (t - t0) / 1100), e = 1 - Math.pow(1 - p, 3);
      el.textContent = (to * e).toFixed(dp) + suf;
      if (p !== 1) { requestAnimationFrame(tick); } else { el.textContent = to.toFixed(dp) + suf; }
    })(performance.now());
  }
  var rv = $('.rev');
  var enter = function (el) { el.classList.add('in'); $('[data-count]', el).forEach(count); };
  var showAll = () => rv.forEach(el => el.classList.add('in'));
  if ('IntersectionObserver' in window && !rm) {
    try {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { enter(e.target); io.unobserve(e.target); } });
      }, { threshold: 0.25 });
      rv.forEach(function (el) { io.observe(el); });
      setTimeout(showAll, 1200);
    } catch (e) { showAll(); }
  } else { showAll(); }

  var links = $('nav a[href^="#"]');
  var secs = links.map(function (a) { return d.getElementById(a.getAttribute('href').slice(1)); });
  var bar = d.getElementById('prog');
  var onScroll = function () {
    var y = window.scrollY, h = root.scrollHeight - window.innerHeight;
    if (bar && h > 0) { bar.style.transform = 'scaleX(' + Math.min(1, y / h) + ')'; }
    var at = -1;
    secs.forEach(function (s, i) { if (s && s.getBoundingClientRect().top < window.innerHeight * 0.4) { at = i; } });
    links.forEach(function (a, i) { if (i === at) { a.setAttribute('aria-current', 'true'); } else { a.removeAttribute('aria-current'); } });
  };
  window.addEventListener('scroll', onScroll, { passive: true }); onScroll();

  var w = d.querySelector('.macwin');
  if (w && !rm && window.matchMedia('(pointer: fine)').matches) {
    w.addEventListener('pointermove', function (e) {
      var r = w.getBoundingClientRect(), x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      w.style.transform = 'perspective(1400px) rotateY(' + (x * 3).toFixed(2) + 'deg) rotateX(' + (-y * 2.4).toFixed(2) + 'deg)';
    });
    w.addEventListener('pointerleave', function () { w.style.transform = ''; });
  }
})();
"""#
