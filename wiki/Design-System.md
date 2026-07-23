---
title: Design-System
type: note
permalink: scarf-wiki/design-system
created: 2026-05-29
updated: 2026-05-29
---

# Design System (ScarfDesign)

Scarf and ScarfGo share a single typed design-token bundle: the **ScarfDesign** Swift Package at [`scarf/Packages/ScarfDesign/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfDesign). Both targets `import ScarfDesign` and consume the same `ScarfColor` / `ScarfFont` / `ScarfSpace` / `ScarfRadius` / `ScarfShadow` tokens plus a small set of reusable SwiftUI components.

If you're building a new view or polishing an existing one, reach for these tokens first. Hardcoded colors, fonts, paddings, and corner radii are a code smell — convert them.

## Where the tokens live

```
scarf/Packages/ScarfDesign/
  Sources/ScarfDesign/
    ScarfBrand.xcassets/        # color set: brand rust, grayscale, semantic, tool kinds
    ScarfTheme.swift            # ScarfColor accessors + environment keys
    ScarfTypography.swift       # ScarfFont scale + .scarfStyle modifier
    ScarfComponents.swift       # PageHeader, Card, Badge, TextField, button styles
    ScarfChatView.swift         # 3-pane chat reference (Mac)
    ScarfPreview.swift          # preview canvas helpers
```

The `ScarfBrand.xcassets` color set ships in the package; both targets resolve `Color("AccentColor", bundle: .module)` to the rust accent automatically. No per-target asset duplication.

## Color tokens

| Token | Use |
|---|---|
| `ScarfColor.accent` | Primary brand rust. Buttons, focused states, chat user-bubble fill. |
| `ScarfColor.accentTint` | Translucent accent for chip backgrounds + selection rows. |
| `ScarfColor.onAccent` | Foreground on rust fills (high-contrast). |
| `ScarfColor.foregroundPrimary` | Default body text. |
| `ScarfColor.foregroundMuted` | Secondary text — captions, list-row subtitles. |
| `ScarfColor.foregroundFaint` | Tertiary text — metadata, "12 / 100 chars" hints. |
| `ScarfColor.backgroundPrimary` | Window/page background. |
| `ScarfColor.backgroundSecondary` | Card / list-row background. Elevated one step. |
| `ScarfColor.backgroundTertiary` | Sub-elevation for inset / inner panels. |
| `ScarfColor.border` | Default 1px stroke for cards + inputs. |
| `ScarfColor.borderStrong` | Pronounced stroke for divider rules between sections. |
| `ScarfColor.success` | Green — success badges, "Saved" pill. |
| `ScarfColor.danger` | Red — destructive button accent, error banners. |
| `ScarfColor.warning` | Amber — non-fatal banner, "missing dependency" hint. |
| `ScarfColor.info` | Cool blue — informational chips. |
| `ScarfColor.Tool.bash` | Tool-call card kind tints — `bash`. |
| `ScarfColor.Tool.edit` | `edit` (file changes). |
| `ScarfColor.Tool.search` | `search` / `grep`. |
| `ScarfColor.Tool.web` | `fetch` / browser. |
| `ScarfColor.Tool.think` | reasoning / thinking. |

All colors resolve from `ScarfBrand.xcassets`, so they adapt light/dark automatically. Don't ship terminal or syntax-highlight palettes through ScarfColor — those are content semantics, keep them inline.

## Typography (ScarfFont)

Eleven preset styles, all fixed-size on Mac:

```swift
.scarfStyle(.title1)            // 32pt semibold
.scarfStyle(.title2)            // 24pt semibold
.scarfStyle(.title3)            // 20pt semibold
.scarfStyle(.headline)          // 17pt semibold
.scarfStyle(.body)              // 15pt regular
.scarfStyle(.callout)           // 14pt regular
.scarfStyle(.footnote)          // 13pt regular
.scarfStyle(.caption)           // 12pt regular
.scarfStyle(.captionUppercase)  // 11pt semibold tracked, uppercase
.scarfStyle(.codeInline)        // 13pt monospaced
.scarfStyle(.codeBlock)         // 13pt monospaced, room for tabs
```

**Mac:** adopt `ScarfFont` everywhere. The Mac doesn't have system-wide text scaling, so fixed sizes are correct.

### iOS Dynamic Type policy

iOS users can scale text via Settings → Accessibility → Display & Text Size. ScarfFont uses fixed point sizes; adopting it blanket on iOS would regress accessibility on `.accessibility2` (much larger) or `.xSmall` (smaller) users.

iOS-specific rule:

- **Use `ScarfFont` only for**: status badges, chip labels, intentional-display elements (e.g. onboarding step titles, header chrome that's meant to be a fixed visual size).
- **Keep `.font(.headline)` / `.body` / `.caption` semantic tokens for**: list-row primary + secondary text, body copy, error messages, chat content — anything the user reads.

Decision tree per text element: *"is this read for content?"* → semantic token. *"Is this chrome / a label / a badge?"* → ScarfFont.

The iOS app already clamps Dynamic Type at the scene root (`ScarfIOSApp.swift`: `.dynamicTypeSize(.xSmall ... .accessibility2)`) so the maximum scale factor stays sane — keep that in place.

### iOS page chrome

Don't retrofit `ScarfPageHeader` over iOS tab roots. iOS uses `.navigationTitle(...)` + `.navigationBarTitleDisplayMode(.large)` as its native page-header pattern; stacking ScarfPageHeader on top creates double titles. Use ScarfPageHeader only on iOS sub-views without a native large-title bar (rare).

iOS button styling: only swap `.borderedProminent` → `ScarfPrimaryButton`. **Leave `.bordered` native** — it's the iOS convention and inherits rust through `AccentColor.colorset` automatically. Same for `.plain` (used as compact tap targets in lists).

## Spacing, radius, shadow

```swift
ScarfSpace.s1 = 4    // tight (chip padding)
ScarfSpace.s2 = 8    // small (intra-row gap)
ScarfSpace.s3 = 12   // medium (form fields)
ScarfSpace.s4 = 16   // page padding
ScarfSpace.s5 = 20
ScarfSpace.s6 = 24   // section break
ScarfSpace.s7 = 32
ScarfSpace.s8 = 40
ScarfSpace.s9 = 56
ScarfSpace.s10 = 80

ScarfRadius.sm  = 4
ScarfRadius.md  = 6
ScarfRadius.lg  = 8        // default for cards, inputs
ScarfRadius.xl  = 12
ScarfRadius.xxl = 14
ScarfRadius.pill = 999
```

Hardcoded `.padding(12)` or `cornerRadius: 8` is a code smell — convert. Same for `.scarfShadow(.sm/.md/.lg/.xl)` instead of bespoke `Shadow(...)`.

## Components

Apply with `.buttonStyle(...)` for buttons; the rest are SwiftUI views you compose directly.

| Component | Purpose |
|---|---|
| `ScarfPageHeader("Title", subtitle: "...") { trailing }` | Mac-style page header with title + subtitle + trailing-edge actions slot. |
| `ScarfCard { ... }` | Bordered, elevated container with `backgroundSecondary` fill + border + radius + shadow baked in. |
| `ScarfBadge("text", kind: .success)` | Pill chip with semantic kind (`.success/.danger/.warning/.info/.neutral`). |
| `ScarfTextField` | Themed text field — bordered, rounded, accent on focus. |
| `ScarfSectionHeader("Section")` | Uppercase tracked label used inside cards / lists. |
| `ScarfDivider` | 1px border-colored hairline. |
| `.buttonStyle(ScarfPrimaryButton())` | Rust filled button. |
| `.buttonStyle(ScarfSecondaryButton())` | Bordered button — neutral surface. |
| `.buttonStyle(ScarfGhostButton())` | Text-only button, no chrome. Use for Cancel / dismiss. |
| `.buttonStyle(ScarfDestructiveButton())` | Red filled button. Confirmation actions only. |

## Reference: design folder

Full screen mockups live at [`design/static-site/ui-kit/*.jsx`](https://github.com/awizemann/scarf/tree/main/design/static-site/ui-kit). Open `design/static-site/index.html` in a browser to walk through every screen at fidelity.

The `ScarfChatView.ChatRootView` reference component in the package is a 3-pane chat redesign target — usable for previews but not yet swapped into the live chat (the existing `RichChatView` machinery still owns the real ACP pipeline).

## Common mistakes to avoid

- **Don't introduce purple/violet tones.** v2.5 shifted away; rust is the brand color now.
- **Don't use yellow for success.** `#F0AD4E` is `.warning`. `.success` is green.
- **Don't bypass the type scale** with `.font(.system(size: 13.5))`. Pick the closest preset.
- **Don't ship terminal / syntax-highlight palettes through ScarfColor.** Content semantics — keep them inline in the renderer.
- **Don't double-up page headers on iOS** (large nav title + ScarfPageHeader → looks broken).

## Adding a new component

If you're tempted to add a ninth button style or a new section-header variant: see if an existing component plus a token modifier covers it. New components belong in `ScarfComponents.swift`, must accept `ScarfColor` / `ScarfSpace` / `ScarfRadius` parameters (no hardcoded values), and need a corresponding entry in this page.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (initial publication)_