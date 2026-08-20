---
title: Privacy policy page on gh-pages is hand-generated
type: note
permalink: scarf/operations/privacy-policy-page-on-gh-pages-is-hand-generated
source_paths: [scarf/docs/PRIVACY_POLICY.md, wiki/Privacy-Policy.md]
source_paths_inferred: false
source_sha: 5e9a1798e99e68774ab81f48bac62dd2368a9448
created: 2026-08-20
updated: 2026-08-20
---

The public privacy page https://awizemann.github.io/scarf/privacy/ (linked from iOS Info.plist, App Store Connect, README, and the policy docs themselves) is a static page at gh-pages `privacy/index.html`, first published 2026-08-20 (gh-pages 525392e) — before that the "canonical" URL had 404'd since April 2026.

## Observations
- [fact] The page is a one-off HTML render of `scarf/docs/PRIVACY_POLICY.md` (the source of truth) with inline light/dark CSS matching the landing theme (#C2563D / #1A1818). No build step regenerates it — `release.sh` and `site/` templates don't touch it. #site
- [constraint] Whenever `scarf/docs/PRIVACY_POLICY.md` changes materially, the gh-pages `privacy/index.html` must be re-rendered and pushed by hand (and `sitemap.xml` lastmod bumped), or the App-Store-linked page silently drifts from the canonical text. #maintenance
- [gotcha] The wiki `Privacy-Policy.md` is a third copy (mirror). Update order: canonical repo file → wiki mirror (Memophant tier) → gh-pages render. #copies

## Relations
- relates_to [[Release Distribution and Updates]]
