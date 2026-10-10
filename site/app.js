const root = document.documentElement;
root.classList.add('js');
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const finePointer = matchMedia('(hover: hover) and (pointer: fine)');

// Theme: follow the system unless the reader picked one.
const darkPreference = matchMedia('(prefers-color-scheme: dark)');
let manualTheme = null;
try { manualTheme = localStorage.getItem('windowshade-theme'); } catch {}
if (manualTheme === 'light' || manualTheme === 'dark') root.dataset.theme = manualTheme;
function syncTheme() {
  const dark = root.dataset.theme ? root.dataset.theme === 'dark' : darkPreference.matches;
  document.querySelector('.theme')?.setAttribute('aria-pressed', String(dark));
}
syncTheme();
darkPreference.addEventListener('change', syncTheme);
document.querySelector('.theme')?.addEventListener('click', () => {
  const dark = root.dataset.theme ? root.dataset.theme === 'dark' : darkPreference.matches;
  root.dataset.theme = dark ? 'light' : 'dark';
  try { localStorage.setItem('windowshade-theme', root.dataset.theme); } catch {}
  syncTheme();
});

// The header hairline appears only once content scrolls under it.
const syncScrolled = () => root.toggleAttribute('data-scrolled', scrollY > 4);
syncScrolled();
addEventListener('scroll', syncScrolled, { passive: true });

// Below-the-fold blocks settle in once. Anything already on screen is shown as-is.
if ('IntersectionObserver' in window && document.body.classList.contains('home')) {
  const targets = document.querySelectorAll('.section-head, .way-list, .story-head, .story-book, .today, .feature-copy, .feature-demo, .shortcut-list, .trust-copy, .questions, .closing');
  const reveal = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('is-in'); reveal.unobserve(entry.target); }
  }, { rootMargin: '0px 0px -8% 0px' });
  for (const el of targets) {
    if (el.getBoundingClientRect().top < innerHeight) continue;
    el.dataset.reveal = '';
    reveal.observe(el);
  }
}

// Scroll-linked animation, the way Apple's product pages do it: a demo's progress follows
// where it sits on screen, so a reader scrolling on a phone drives it with their own finger
// and can never miss it. Each scrubber maps its element's centre from `from` to `to`
// (fractions of the viewport height) onto 0 → 1. With Reduce Motion, progress snaps to
// 0 or 1 and the CSS turns the change into a short fade instead of travel.
const scrubbers = [];
let scrubFrame = 0;
function runScrubbers() {
  scrubFrame = 0;
  const vh = innerHeight;
  for (const sc of scrubbers) {
    if (sc.off?.()) continue;
    const r = sc.el.getBoundingClientRect();
    const c = (r.top + r.height / 2) / vh;
    const from = typeof sc.from === 'function' ? sc.from() : sc.from, to = from - sc.span;
    let p = Math.min(1, Math.max(0, (from - c) / (from - to)));
    if (reduceMotion.matches) p = p >= .5 ? 1 : 0;
    sc.apply(p);
  }
}
const scheduleScrub = () => { if (!scrubFrame) scrubFrame = requestAnimationFrame(runScrubbers); };
addEventListener('scroll', scheduleScrub, { passive: true });
addEventListener('resize', scheduleScrub);

// Hero: roll the reference window up into its bar, and drag the bar anywhere on the desk.
const desk = document.querySelector('#desk');
const reference = document.querySelector('#reference');
const fold = document.querySelector('#fold');
const bar = document.querySelector('#reference-bar');
const body = document.querySelector('#reference-body');
const status = document.querySelector('#demo-status');
if (desk && reference && fold && bar && body && status) {
  let folded = false;
  let touched = false;
  let rollNow = 0;
  let stopRoll = () => {};
  new ResizeObserver(() => desk.style.setProperty('--body-h', `${body.offsetHeight}px`)).observe(body);
  // When the screen changes size (a window resized, a foldable opened or closed), a dragged
  // position measured in pixels no longer means the same place: settle the window back home.
  let deskWidth = 0;
  new ResizeObserver(([entry]) => {
    const w = Math.round(entry.contentRect.width);
    if (deskWidth && w !== deskWidth && (offset.x || offset.y)) { offset.x = offset.y = 0; reference.style.transition = 'none'; place(0, 0); }
    deskWidth = w;
  }).observe(desk);

  function setRoll(p) {
    rollNow = p;
    desk.style.setProperty('--roll', p.toFixed(4));
    desk.style.setProperty('--roller', p > .01 && p < .99 ? '1' : '0');
    desk.classList.toggle('is-folded', p >= .99);
  }
  function animateRoll(to) {
    stopRoll();
    const from = rollNow;
    desk.classList.add('is-rolling');
    if (reduceMotion.matches || !window.WSMotion) { setRoll(to); desk.classList.remove('is-rolling'); return; }
    // 没有动量的收起 / 展开：calm。滚动条直接改 --roll，不走这段。
    stopRoll = WSMotion.play('calm', p => setRoll(from + (to - from) * p), () => desk.classList.remove('is-rolling'));
  }
  function setFolded(next, announce = true) {
    folded = next;
    animateRoll(folded ? 1 : 0);
    fold.textContent = folded ? fold.dataset.unfold : fold.dataset.fold;
    fold.setAttribute('aria-expanded', String(!folded));
    bar.setAttribute('aria-expanded', String(!folded));
    bar.setAttribute('aria-label', `${bar.textContent.trim()}: ${folded ? fold.dataset.unfold : fold.dataset.fold}`);
    body.setAttribute('aria-hidden', String(folded));
    if (announce) status.textContent = folded ? status.dataset.folded : status.dataset.expanded;
  }
  const toggle = () => { touched = true; setFolded(!folded); };
  fold.addEventListener('click', toggle);
  // Mouse mirrors the app's double-click; keyboard gets a single activation.
  bar.addEventListener('click', e => { if (e.detail === 0) toggle(); });

  // Drag: track 1:1 from where the bar was grabbed, soften past the desk's edges,
  // and settle back inside on release. A tiny threshold keeps double-clicks clean.
  const offset = { x: 0, y: 0 };
  let drag = null;
  let lastDragEnd = 0;
  const rubber = (over, size) => (over * size * .55) / (size + .55 * Math.abs(over));
  function bounds() {
    const d = desk.getBoundingClientRect(), w = reference.getBoundingClientRect();
    const baseX = w.left - d.left - offset.x, baseY = w.top - d.top - offset.y;
    const top = d.width * .044;
    return { minX: -baseX - w.width * .55, maxX: d.width - baseX - w.width * .45, minY: top - baseY, maxY: d.height - baseY - bar.offsetHeight, w: d.width, h: d.height };
  }
  const soft = (v, lo, hi, size) => v < lo ? lo + rubber(v - lo, size) : v > hi ? hi + rubber(v - hi, size) : v;
  function place(x, y) { reference.style.translate = `${x}px ${y}px`; }
  bar.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    touched = true;
    // Capture on press so a quick flick off the bar still reports its release here.
    try { bar.setPointerCapture(e.pointerId); } catch {}
    drag = { id: e.pointerId, sx: e.clientX, sy: e.clientY, ox: offset.x, oy: offset.y, moving: false, b: bounds() };
  });
  bar.addEventListener('pointermove', e => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.sx, dy = e.clientY - drag.sy;
    if (!drag.moving) {
      if (Math.hypot(dx, dy) < 4) return;
      drag.moving = true;
      reference.classList.add('is-dragging');
      reference.style.transition = 'none';
    }
    const { minX, maxX, minY, maxY, w, h } = drag.b;
    offset.x = soft(drag.ox + dx, minX, maxX, w);
    offset.y = soft(drag.oy + dy, minY, maxY, h);
    place(offset.x, offset.y);
  });
  function endDrag(e) {
    if (!drag || e.pointerId !== drag.id) return;
    if (drag.moving) {
      const { minX, maxX, minY, maxY } = drag.b;
      const toX = Math.min(maxX, Math.max(minX, offset.x));
      const toY = Math.min(maxY, Math.max(minY, offset.y));
      const fromX = offset.x, fromY = offset.y;
      reference.style.transition = 'none';
      reference.classList.remove('is-dragging');
      // 松手回到桌面里：calm，不套 0.38 秒的贝塞尔。
      if (window.WSMotion && !reduceMotion.matches) {
        WSMotion.play('calm', p => {
          offset.x = fromX + (toX - fromX) * p;
          offset.y = fromY + (toY - fromY) * p;
          place(offset.x, offset.y);
        });
      } else { offset.x = toX; offset.y = toY; place(toX, toY); }
      lastDragEnd = performance.now();
    }
    drag = null;
  }
  bar.addEventListener('pointerup', endDrag);
  bar.addEventListener('pointercancel', endDrag);
  bar.addEventListener('lostpointercapture', endDrag);
  bar.addEventListener('dblclick', e => { if (lastTap.touch) return; if (performance.now() - lastDragEnd > 250) toggle(); });
  // Touch browsers do not reliably send dblclick (iOS Safari least of all), so count taps here.
  const lastTap = { t: 0, x: 0, y: 0, touch: false };
  bar.addEventListener('pointerup', e => {
    lastTap.touch = e.pointerType !== 'mouse';
    if (!lastTap.touch || performance.now() - lastDragEnd < 250) return;
    const now = performance.now();
    if (now - lastTap.t < 350 && Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 24) { lastTap.t = 0; toggle(); return; }
    Object.assign(lastTap, { t: now, x: e.clientX, y: e.clientY });
  });

  // Scrolling rolls the window up; scrolling back unrolls it. It starts from wherever the desk
  // sits when the page opens, so nothing is rolled before the reader moves. Once they double-click,
  // drag or press the button, the window is theirs and scrolling leaves it alone.
  const home = (desk.getBoundingClientRect().top + scrollY + desk.offsetHeight / 2) / innerHeight;
  scrubbers.push({ el: desk, from: () => Math.min(.62, home) - .02, span: .3, off: () => touched, apply: p => {
    stopRoll();
    if (!!folded !== p >= .5) { folded = p >= .5; fold.textContent = folded ? fold.dataset.unfold : fold.dataset.fold; bar.setAttribute('aria-expanded', String(!folded)); fold.setAttribute('aria-expanded', String(!folded)); }
    setRoll(p);
  } });
}

// Three ways to move a window aside: each tile follows its own position on screen.
for (const way of document.querySelectorAll('.way')) {
  scrubbers.push({ el: way, from: .85, span: .4, apply: p => {
    way.style.setProperty('--p', p.toFixed(4));
    way.style.setProperty('--pr', p > .02 && p < .98 ? '1' : '0');
    way.classList.toggle('done', p >= .98);
    way.classList.toggle('play', p >= .5);
  } });
}

// Glance: preserve the crossing between the bar and card; touch and keyboard toggle it.
const glanceDesk = document.querySelector('.stage-glance');
const glanceStrip = document.querySelector('.glance-strip');
const glanceCard = document.querySelector('#glance-card');
if (glanceDesk && glanceStrip && glanceCard) {
  let closeTimer = 0;
  const setGlance = open => {
    clearTimeout(closeTimer);
    glanceDesk.classList.toggle('is-open', open);
    glanceStrip.setAttribute('aria-expanded', String(open));
    glanceCard.setAttribute('aria-hidden', String(!open));
  };
  for (const surface of [glanceStrip, glanceCard]) {
    surface.addEventListener('pointerenter', event => {
      if (event.pointerType !== 'touch') setGlance(true);
    });
    surface.addEventListener('pointerleave', event => {
      if (event.pointerType !== 'touch') closeTimer = setTimeout(() => setGlance(false), 160);
    });
  }
  glanceStrip.addEventListener('click', event => {
    // Mouse hover already opened the card. Touch and keyboard get an explicit toggle.
    if (event.detail === 0 || event.pointerType === 'touch' || !finePointer.matches) {
      setGlance(!glanceDesk.classList.contains('is-open'));
    }
  });
  glanceStrip.addEventListener('blur', () => setGlance(false));
  // Shown once when it first comes into view: the card drops down, stays a moment, rolls back.
  if ('IntersectionObserver' in window && !reduceMotion.matches) {
    const seen = new IntersectionObserver(entries => {
      if (!entries.some(entry => entry.isIntersecting)) return;
      seen.disconnect();
      setTimeout(() => {
        if (glanceDesk.classList.contains('is-open')) return;
        setGlance(true);
        closeTimer = setTimeout(() => { if (!glanceDesk.matches(':hover')) setGlance(false); }, 1800);
      }, 600);
    }, { threshold: .6 });
    seen.observe(glanceDesk);
  }
  glanceStrip.addEventListener('keydown', event => {
    if (event.key === 'Escape') setGlance(false);
  });
}

// Draw every scroll-linked demo once, so a page opened mid-way starts in the right state.
runScrubbers();
