---
id: t-fe0a1bdc
title: Design system: white on dark-mode accent fails contrast
status: done
added: 2026-10-05
---

## Description

--on-accent is #FFFFFF in both modes. In dark mode, white on BrandRust #E89360 is 2.39:1 (hover 1.98:1), so it fails WCAG AA even for large text. This affects the landing .btn-primary ("Download for Mac") and anything else using on-accent in dark mode. Light mode: white on #C25A2A is 4.38:1, just under AA for normal text, and accent link text on #FAF7F2 is 4.10:1. Fix belongs in the design system (ScarfBrand.xcassets OnAccent + colors_and_type.css), e.g. a dark on-accent colour for dark mode. Then mirror it to site/landing/styles.css.

## Plan



## Artifacts



