(function () {
  var d = document, root = d.documentElement;
  var $ = (s, c) => Array.from((c || d).querySelectorAll(s));
  var isDark = () => (root.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches && 'dark')) === 'dark';

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
        b.textContent = '\u2713 Copied'; b.classList.add('ok');
        setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('ok'); }, 1200);
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
    var all = $('.zoom'), seen = {}, cur = 0, last = null;
    var items = all.filter(function (b) { var k = b.getAttribute('data-full'); if (seen[k]) { return false; } seen[k] = true; return true; });
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
      last = b; var k = b.getAttribute('data-full');
      show(items.findIndex(function (x) { return x.getAttribute('data-full') === k; }));
      lb.showModal(); root.classList.add('lb-open');
    };
    all.forEach(function (b) { b.addEventListener('click', function () { open(b); }); });
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

  var links = $('nav a[href^="#"]');
  var secs = links.map(function (a) { return d.getElementById(a.getAttribute('href').slice(1)); });
  var onScroll = function () {
    var at = -1;
    secs.forEach(function (s, i) { if (s && s.getBoundingClientRect().top < window.innerHeight * 0.4) { at = i; } });
    links.forEach(function (a, i) { if (i === at) { a.setAttribute('aria-current', 'true'); } else { a.removeAttribute('aria-current'); } });
  };
  window.addEventListener('scroll', onScroll, { passive: true }); onScroll();
})();