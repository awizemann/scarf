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
    applyImageTheme();
  }

  // Resolve the *effective* theme — explicit data-theme wins, otherwise
  // fall back to the OS preference.
  function resolveTheme() {
    const explicit = root.getAttribute('data-theme');
    if (explicit === 'light' || explicit === 'dark') return explicit;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  // Swap every <img data-dark-src="..."> between its light and dark variants.
  // Also rewrites the parent <picture>'s <source srcset> so the picture
  // algorithm doesn't override us on resize/layout passes.
  function applyImageTheme() {
    const theme = resolveTheme();
    document.querySelectorAll('img[data-dark-src]').forEach((img) => {
      if (!img.dataset.lightSrc) {
        img.dataset.lightSrc = img.getAttribute('src');
      }
      const target = theme === 'dark' ? img.dataset.darkSrc : img.dataset.lightSrc;
      if (img.getAttribute('src') !== target) img.setAttribute('src', target);
      const picture = img.parentElement;
      if (picture && picture.tagName === 'PICTURE') {
        picture.querySelectorAll('source').forEach((s) => {
          if (s.getAttribute('srcset') !== target) s.setAttribute('srcset', target);
        });
      }
    });
  }

  // Hydrate stored preference (if any) — runs after DOMContentLoaded since
  // the <script> is deferred. There's a brief moment of media-query default
  // before hydrate; that's acceptable here (no FOUC because the media query
  // already gets the right colors and the first images render at light by
  // default — JS swaps within a frame on dark-mode systems).
  let stored = null;
  try {
    stored = localStorage.getItem(STORAGE_KEY);
    if (stored === 'light' || stored === 'dark') applyTheme(stored);
    else applyImageTheme(); // initial pass even if no stored preference
  } catch (_) {
    applyImageTheme();
  }

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

  // Re-apply on system preference change so users who haven't set an
  // explicit override still get matching screenshots.
  if (window.matchMedia) {
    const mql = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => {
      if (!root.hasAttribute('data-theme')) applyImageTheme();
    };
    if (mql.addEventListener) mql.addEventListener('change', onChange);
    else if (mql.addListener) mql.addListener(onChange);
  }

  // Auto-collapse sticky header on scroll-down, restore on scroll-up.
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
