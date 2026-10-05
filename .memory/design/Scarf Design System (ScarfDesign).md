---
title: Scarf Design System (ScarfDesign)
type: note
permalink: scarf/design/scarf-design-system-scarf-design
tags: [design, ui]
created: 2026-05-29
updated: 2026-10-05
---

## Observations
- [package] All app UI uses the typed token bundle at scarf/Packages/ScarfDesign/. Both `scarf` and `scarf mobile` targets `import ScarfDesign` #package
- [colors] Tokens: ScarfColor.accent, .foregroundPrimary/Muted/Faint, .backgroundPrimary/Secondary/Tertiary, .border/.borderStrong, .success/.danger/.warning/.info, .Tool.{bash,edit,search,web,think}. Resolve from ScarfBrand.xcassets; auto light/dark #color
- [typography] Use .scarfStyle(.title2/.body/.captionUppercase/…) — eleven preset styles. Never .font(.system(size: 13.5)) #typography
- [spacing] ScarfSpace.s1…s10 (4/8/12/16/20/24/32/40), ScarfRadius.sm/md/lg/xl/xxl/pill, .scarfShadow(.sm/.md/.lg/.xl). Hardcoded .padding(12) or cornerRadius:8 is a code smell #spacing
- [components] ScarfPageHeader, ScarfCard, ScarfBadge, ScarfTextField, ScarfSectionHeader, ScarfDivider, ScarfPrimary/Secondary/Ghost/DestructiveButton (apply with .buttonStyle(...)) #components
- [branding] Rust accent palette. AccentColor.colorset resolves Color.accentColor to rust so unmigrated SwiftUI controls still tint correctly. Don't introduce purple/violet (legacy) #branding
- [anti-pattern] Don't use yellow #F0AD4E for success — that's .warning; .success is green. Don't ship terminal/syntax-highlight palettes through ScarfColor — keep content semantics inline #pitfalls
- [reference] Full screen mockups live at design/static-site/ui-kit/*.jsx (open design/static-site/index.html). ScarfChatView.ChatRootView is a 3-pane chat redesign target — preview only, not yet swapped into live chat (RichChatView owns the real ACP pipeline) #reference

## Relations
- applies_to [[Scarf Architecture Rules]]
- extended_by [[iOS Platform Rules]]


## Brand vs UI accent (decided by Alan 2026-10-05, commit 27b8e405)
- [decision] BrandRust (#C25A2A light / #E89360 dark) is the BRAND color: logo, brand mark, gradients. The semantic UI accent (ScarfColor.accent*, CSS --accent*) lives in ScarfBrand.xcassets/Accent/. Light: #A6481E / hover #7A2E14 / active #5C220F (brand 600-800). Dark: #E89360 / #F0A879 / #D87844. Why: white on #C25A2A was 4.38:1 and white on dark #E89360 was 2.39:1, both below WCAG AA.
- [invariant] Text on an accent fill always uses ScarfColor.onAccent / var(--on-accent): white in light, #3B1608 (brand-900) in dark. Never .white or #fff. Tints are 0.10/0.18 (light) and 0.10/0.24 (dark).
- [invariant] Never use .buttonStyle(.borderedProminent): the system draws a white label on the accent, which fails AA in dark mode. Use ScarfPrimaryButton (task t-a9944075).
- [convention] tools/check-design-tokens.py is the gate. site.sh and catalog.sh run it. It fails on CSS/xcassets/AccentColor drift, on a token declared outside a recognised theme block, on text over an accent fill that isn't on-accent, on any pair below AA, and on a stale ui-kit bundle (fix with tools/refresh-ui-kit-bundle.py). Change tokens in xcassets first, then mirror them; the guard tells you where.

- [decision] App AccentColor (system tint, both apps) is NOT Accent/Accent in dark mode: it is #D87844. No colour passes both "white on it" and "it as text on the dark bg" at 4.5:1. #D87844 clears 3:1 for system-drawn checkmarks and knobs and 4.5:1+ as text. Light stays #A6481E. (commit 6a704429)
- [invariant] Danger: ScarfColor.danger is text/icons only (light #B83C38, dark #E36864). Fills use dangerFill (#B83C38 both modes) with onDanger (white). Default-action buttons always carry a Scarf button style. Swipe-action tints come from an allowlist in the guard (brandRustDeep, dangerFill). ScarfPrimaryButton/ScarfDestructiveButton honour isEnabled and controlSize, scale with Dynamic Type, and keep a 44pt hit target on iOS.

- [invariant] Status colours (2026-10-05, commit after 24f81cea): ScarfColor.success/warning/info/danger are TEXT-SAFE (≥4.5 as text, ≥3 as icon/dot on every surface, ≥4.5 on their own tint). Washes use ScarfColor.<kind>Tint (or ScarfBadgeKind/ScarfToolTone .tinted(alpha) for other densities). Borders, halos and chart marks use ScarfColor.<kind>Hue (the original lighter hue), never as text. Neutral chips use neutralTint. Never write ScarfColor.<status>.opacity(a) as a wash; the guard fails it.
