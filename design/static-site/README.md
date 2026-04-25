# Scarf Design System — static site

A self-contained, offline-friendly site that browses every artifact in the
Scarf design system. Open `index.html` directly in any browser — no server,
no build step.

## What's here

```
static-site/
├── index.html              ← landing page, links into everything
├── colors_and_type.css     ← shared design tokens (referenced everywhere)
│
├── ui-kit/                 ← interactive macOS UI kit
│   ├── index.html          ← click-thru of every screen in the app
│   └── *.jsx               ← React components (Sidebar, Chat, Dashboard…)
│
├── tokens/                 ← design-system cards
│   ├── _preview.css        ← shared card styling
│   ├── colors-*.html       ← brand / neutrals / semantic / tool-kinds
│   ├── type-*.html         ← display / body / mono
│   ├── spacing-*.html      ← scale / radii / shadows
│   ├── components-*.html   ← buttons / forms / sidebar / cards / chat / composer / tool-call
│   ├── iconography.html
│   └── brand-mark.html
│
└── assets/                 ← icons, brand artwork
```

## How to use it

- **Browse offline**: double-click `index.html`. Everything renders locally;
  the only network dependency is Google Fonts (Inter + JetBrains Mono).
- **Host as a site**: drop the whole folder onto any static host (Netlify,
  GitHub Pages, S3, your own nginx). Nothing needs building.
- **Embed in a doc**: link individual cards directly, e.g.
  `static-site/tokens/colors-brand.html`.
- **Show the macOS app**: `static-site/ui-kit/index.html` runs the full
  React-based interactive kit (single self-contained file — works from
  `file://`, no server needed). The traffic-light corner makes it look like
  the real app. Source components live alongside as `*.jsx` for editing —
  re-bundle into `index.html` when you change them.

## Notes

- The kit's `index.html` is a self-contained bundle — React, Babel, Lucide
  and every component are inlined, so it works from `file://` with no
  network. The original split-file source is preserved as
  `ui-kit/index.source.html` next to the `.jsx` files for editing.
- The font import in `colors_and_type.css` (`fonts.googleapis.com`) is the
  only other network call. Replace with locally-served WOFF2 if you need
  airgapped use.
