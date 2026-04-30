// Scarf landing page — minimal client behavior.
// No dependencies. Runs after defer-parse.

(function () {
  const root = document.documentElement;
  const STORAGE_KEY = 'scarf-theme';

  function applyTheme(theme) {
    if (theme === 'light' || theme === 'dark') {
      root.setAttribute('data-theme', theme);
    } else {
      root.removeAttribute('data-theme');
    }
  }

  // Hydrate stored preference (if any) — runs after DOMContentLoaded since the
  // <script> is deferred. There's a brief moment of media-query default before
  // hydrate; that's acceptable here (no FOUC because the media query already
  // gets the right colors).
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === 'light' || stored === 'dark') applyTheme(stored);
  } catch (_) { /* localStorage unavailable — fall back to media query */ }

  const toggle = document.querySelector('[data-theme-toggle]');
  if (toggle) {
    toggle.addEventListener('click', () => {
      const current = root.getAttribute('data-theme');
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      let next;
      if (current === 'light') next = 'dark';
      else if (current === 'dark') next = null;
      else next = prefersDark ? 'light' : 'dark';

      applyTheme(next);
      try {
        if (next) localStorage.setItem(STORAGE_KEY, next);
        else localStorage.removeItem(STORAGE_KEY);
      } catch (_) { /* ignore */ }
    });
  }

  // Auto-collapse sticky header on scroll-down, restore on scroll-up.
  // Pure progressive enhancement — no header in the DOM = nothing happens.
  const header = document.querySelector('.site-header');
  if (header) {
    let lastY = window.scrollY;
    let ticking = false;
    window.addEventListener('scroll', () => {
      if (ticking) return;
      window.requestAnimationFrame(() => {
        const y = window.scrollY;
        if (y > 80 && y > lastY) header.style.transform = 'translateY(-100%)';
        else header.style.transform = '';
        lastY = y;
        ticking = false;
      });
      ticking = true;
    }, { passive: true });
    header.style.transition = 'transform 0.25s ease';
  }
})();
