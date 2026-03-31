# 05 -- Design System

Centralized visual and interaction standard for all macOS apps in this suite.

Each project keeps its own concrete theme file (e.g., `ShabuBoxTheme.swift`,
`DSTokens.swift`). This document defines the structure and rules those themes
must follow.

**Aesthetic target:** Things-like + Liquid Glass. Content is stable and legible;
glass is chrome and framing only.

---

## 1. Core Principles

1. **Content-first.** Glass is reserved for chrome and floating UI. Primary reading and editing surfaces remain stable and high-contrast.
2. **Calm density.** Use whitespace and grouping; avoid excessive dividers and "always visible" buttons.
3. **Keyboard-first.** Every primary action must be accessible via keyboard and reflected in menus with shortcuts.
4. **One coherent material model.** Use a small set of material tiers (see Section 3), consistently applied.
5. **Accessibility always.** The UI must remain usable with Reduce Transparency, Increase Contrast, Reduce Motion, and Large Dynamic Type.
6. **Native components by default.** Use system controls (Buttons, Lists, Toolbars, Forms) unless a custom control is materially better.

---

## 2. Aesthetic

The visual language blends the calm, content-first productivity feel of
**Things** (Cultured Code) with the modern navigation chrome and depth of
Apple's **Liquid Glass**.

**North star:** content is stable and legible; glass is used as chrome and
framing, never as the primary reading surface.

- Prefer quiet backgrounds and generous whitespace over ornament.
- Depth comes from the material tiers below, not from decorative gradients.
- Accent color is used sparingly to convey meaning, not for decoration.

---

## 3. Material Tiers

Use only these three tiers across the app.

### Tier A -- Chrome Glass (default)

| Where | Sidebar background, toolbar background, tab bars, navigation chrome |
|-------|---------------------------------------------------------------------|
| Character | Subtle translucency, subtle border stroke, minimal shadow |

### Tier B -- Floating Glass

| Where | Popovers, menus, pickers, floating inspector panels, tooltips |
|-------|---------------------------------------------------------------|
| Character | Stronger separation than Tier A (stroke + shadow). Content remains legible over any wallpaper. |

### Tier C -- Content Plate (stabilizer)

| Where | Text fields, long lists, forms, editors, notes |
|-------|------------------------------------------------|
| Character | More opaque background, clear edge separation. Keeps text crisp. |

Used *inside* glass containers whenever content is multi-line, form inputs, or
long lists.

### Hard Constraints

- **Never place long-form reading surfaces directly on Tier A or Tier B glass.**
- Always wrap dense text fields and lists in a Tier C plate.
- Respect Reduce Transparency: when enabled, glass becomes opaque with standard
  system background colors. Do not fight the system.

---

## 4. Typography

Use Apple semantic text styles instead of hard-coded sizes.

### Semantic Styles

| Style | Typical Size / Weight | Usage |
|-------|----------------------|-------|
| `.largeTitle` | 28pt Bold | Screen titles (rare) |
| `.title` | 22pt Semibold | Section headers |
| `.title2` | 20pt Semibold | Sub-section headers |
| `.title3` | 18pt Semibold | Card titles |
| `.headline` | 17pt Semibold | Emphasized body |
| `.body` | 15pt Regular | Primary content |
| `.callout` | 14pt Regular | Supporting text |
| `.subheadline` | 13pt Regular | Secondary labels |
| `.footnote` | 12pt Regular | Metadata |
| `.caption` | 11pt Regular | Timestamps, hints |
| `.caption` (bold) | 11pt Semibold | Badge text |

### Rules

- Max **one** primary headline per view.
- Secondary text uses `.foregroundStyle(.secondary)`.
- Max **3 text styles** per view unless it is a dense inspector.
- If a design requires a size not in the table, add a named token to the
  project theme file first. Never use `.font(.system(size: N))` with an
  unlisted size.

### Token Example (project theme file)

```swift
enum Typography {
    static let largeTitle = Font.system(.largeTitle, weight: .bold)
    static let title      = Font.system(.title, weight: .semibold)
    static let headline   = Font.system(.headline, weight: .semibold)
    static let body       = Font.system(.body)
    static let subheadline = Font.system(.subheadline)
    static let footnote   = Font.system(.footnote)
    static let caption    = Font.system(.caption)
    static let captionBold = Font.system(.caption, weight: .semibold)
    static let badge      = Font.system(size: 10, weight: .bold)
    static let sectionHeader = Font.system(.caption, weight: .semibold)
                               .smallCaps()
}
```

---

## 5. Iconography

- Use **SF Symbols exclusively**.
- Consistent symbol per meaning -- do not rotate icons for novelty.
- Use **filled** variants for selected states; regular (outline) for default.
- Icon-only buttons **must** have a tooltip and an accessibility label.

---

## 6. Spacing

All spacing is on a **4pt grid**. This is more flexible than a strict 8pt grid
while still maintaining alignment.

### Token Table

| Token | Value |
|-------|-------|
| `xxs` | 4 pt |
| `xs` | 8 pt |
| `sm` | 12 pt |
| `md` | 16 pt |
| `lg` | 20 pt |
| `xl` | 24 pt |
| `xxl` | 32 pt |
| `xxxl` | 40 pt |
| `xxxxl` | 48 pt |

### Token Example

```swift
enum Spacing {
    static let xxs: CGFloat   = 4
    static let xs: CGFloat    = 8
    static let sm: CGFloat    = 12
    static let md: CGFloat    = 16
    static let lg: CGFloat    = 20
    static let xl: CGFloat    = 24
    static let xxl: CGFloat   = 32
    static let xxxl: CGFloat  = 40
    static let xxxxl: CGFloat = 48
}
```

---

## 7. Corner Radii

### Token Table

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4 pt | Small badges, pills |
| `sm` | 8 pt | Controls, buttons |
| `md` | 12 pt | Cards, input fields |
| `lg` | 16 pt | Panels, sheets |
| `xl` | 20 pt | Large floating panels |
| `full` | 999 pt | Circular / capsule |

### Guideline

- **Controls:** 8--12 pt (`sm` to `md`).
- **Panels / cards:** 12--16 pt (`md` to `lg`).
- If a design requires a radius not in the table, add the token to the project
  theme first. Do not use inline `.clipShape(RoundedRectangle(cornerRadius: N))`
  with non-token values.

---

## 8. Color

### Approach

- Prefer **system semantic colors** (`primary`, `secondary`, `tertiary`,
  `separator`, `windowBackground`, `textBackground`, etc.) for automatic
  light/dark and accessibility support.
- The accent tint conveys meaning; avoid decorative tint floods.
- Avoid large tinted glass areas behind dense text.

### Semantic Color Categories

Each project theme should define tokens in these categories:

| Category | Example Tokens |
|----------|---------------|
| Background | `primaryBackground`, `secondaryBackground`, `tertiaryBackground`, `sidebarBackground` |
| Text | `textPrimary`, `textSecondary`, `textTertiary` |
| Accent | `accent`, project-specific accent variants |
| Status | `success`, `warning`, `error`, `info` |
| File-type (if applicable) | `fileDocument`, `fileImage`, `fileVideo`, `fileAudio`, `fileArchive`, `fileOther` |

### Rules

- No custom colors unless branding requires it. Keep branding to `tint` and
  small accents.
- All custom colors must have both light and dark variants defined in an asset
  catalog or via `Color(light:dark:)`.

---

## 9. Shadows

### Token Table

| Token | Radius | Opacity | Usage |
|-------|--------|---------|-------|
| `subtle` | 4 pt | 0.04 | Default card resting state |
| `medium` | 8 pt | 0.08 | Elevated elements |
| `elevated` | 16 pt | 0.12 | Floating panels |
| `hover` | 12 pt | 0.15 | Hover state lift |

### Token Example

```swift
enum Shadows {
    static let subtle   = (radius: CGFloat(4),  opacity: 0.04)
    static let medium   = (radius: CGFloat(8),  opacity: 0.08)
    static let elevated = (radius: CGFloat(16), opacity: 0.12)
    static let hover    = (radius: CGFloat(12), opacity: 0.15)
}
```

---

## 10. Animations & Transitions

### Animation Tokens

| Token | Definition | Usage |
|-------|-----------|-------|
| `quick` | `easeOut(duration: 0.15)` | Hover, focus, toggle |
| `standard` | `spring(response: 0.3, dampingFraction: 0.8)` | Selection, card interaction |
| `smooth` | `spring(response: 0.4, dampingFraction: 0.85)` | Panel resize, expand/collapse |
| `slow` | `spring(response: 0.5, dampingFraction: 0.9)` | View switches, overlays |
| `interactive` | `spring(response: 0.3, dampingFraction: 0.7)` | User-driven toggle/tap |
| `appear` | `easeOut(duration: 0.2)` | Content fade-in |

### Replacement Mapping

When reviewing existing code, replace ad-hoc values:

| Ad-hoc Value | Replace With |
|---|---|
| `.easeInOut(duration: 0.15)` | `Animation.quick` |
| `.easeOut(duration: 0.2)` | `Animation.appear` |
| `.spring(response: 0.3)` | `Animation.standard` |
| `.spring(response: 0.3, dampingFraction: 0.7)` | `Animation.interactive` |
| `.spring(response: 0.4, dampingFraction: 0.85)` | `Animation.smooth` |
| Long-running repeating anims (2s+) | Keep inline |

### Transition Tokens

| Token | Effect | Usage |
|-------|--------|-------|
| `slideTrailing` | Move from trailing edge | Right panels, slide-in detail |
| `slideLeading` | Move from leading edge | Left panels |
| `slideBottom` | Move from bottom | Toasts, bottom sheets |
| `scaleUp` | Scale up + fade | Modals |
| `scaleSmall` | Small scale pulse | Loading indicators |
| `fade` | Opacity crossfade | Section switching |

---

## 11. View Modifiers

Each project theme should provide these standard view modifiers (names may vary
by project):

| Modifier | Purpose |
|----------|---------|
| `.glassCard(radius:shadow:)` | Frosted glass container with `.ultraThinMaterial` |
| `.solidCard(radius:shadow:backgroundColor:)` | Opaque card with secondary background |
| `.hoverScale(scale:hoverShadow:restShadow:)` | Scale ~1.03 + shadow lift on hover |
| `.themeBadge(color:style:)` | Capsule badge (`.filled` or `.tinted`) |
| `.sidebarItem(isSelected:accentColor:)` | Left accent bar + selection background |
| `.shimmer()` | Loading skeleton animation |
| `.themeShadow(_:)` | Apply a shadow token |
| `.cardPress(scale:)` | Press-down micro-interaction |
| `.sectionTransition(id:)` | Fade on content ID change |

---

## 12. Layout System

### Primary Window Template (3-column)

Use `NavigationSplitView` for the primary structure:

```
+----------+---------------------+-----------+
| Sidebar  |   Content List      | Inspector |
| (nav)    |   (work items)      | (detail)  |
+----------+---------------------+-----------+
```

1. **Sidebar:** Perspectives and containers (areas / projects / sections).
2. **Content list:** Items within the current scope.
3. **Inspector / detail:** Editable properties, notes, metadata.

### Sidebar Structure

- Short labels (1--2 words).
- Optional count badges.
- Clear selection highlight and hierarchy indentation.
- Settings is **not** a sidebar item -- access via `Cmd+,` (native Settings scene).

### Slide-In Detail Pattern

For module views, use a single-pane layout where the detail view animates in
from the trailing edge:

```
+----------+----------------------------+
| Sidebar  | Module Content             |
|          | +------------------------+ |
|          | | Detail (slides in)     | |
|          | +------------------------+ |
+----------+----------------------------+
```

- Width: 400--500 pt (configurable).
- Background: Tier B (Floating Glass) material.
- Dismiss via close button or clicking outside.
- Animation: `spring(response: 0.3, dampingFraction: 0.8)` with
  `move(edge: .trailing)` + opacity.

### Layout Constants

| Constant | Value |
|----------|-------|
| Sidebar expanded | ~200 pt |
| Sidebar collapsed | ~56 pt |
| Sidebar item height | 36 pt |
| Right info panel | 280 pt (240 pt min) |
| Grid cells | 160--200 pt, aspect ratio ~1.29 |
| Grid spacing | 16 pt |
| List row height | 52 pt |
| List row icon size | 32 pt |
| Toolbar height | 36 pt |

---

## 13. Components

### Buttons

Prefer system button styles:

| Style | Usage |
|-------|-------|
| `.borderedProminent` | Primary action (0--1 per view) |
| `.bordered` | Secondary actions |
| `.plain` | Tertiary / inline |
| Toolbar icon buttons | Icon-only with tooltip + accessibility label |

**Rules:**
- One primary action per view.
- Do not place prominent buttons on glass without a Tier C plate behind them.

### Tab Bar

- Use for view-mode switching (e.g., Board / List), not for status filters.
- Icon + text for each tab.
- Selected state: accent color with ~15% opacity background.
- Unselected state: `.secondary` foreground.
- Tab enums should conform to a `TabItem`-style protocol (label + icon).

### Text Fields & Editors

- Search is global and always reachable (toolbar / search field).
- Inline title editing: commit on Return, cancel on Escape.
- Notes editor lives on a Tier C plate even if surrounding UI is glass.

### Lists

**Row anatomy:**
- Leading: status control (checkbox / icon).
- Center: title (`.body`), optional secondary line (`.secondary`).
- Trailing: metadata (date / badges), de-emphasized.

**Interactions:**
- Hover reveals secondary actions (overflow menu, quick actions) -- primary
  info never jumps.
- Drag-and-drop reorder where applicable.
- Selection state must be obvious under Increase Contrast.

### Inspector

A calm, form-like panel. Recommended sections:
- Title + status
- Schedule / dates
- Tags / people
- Notes
- Attachments / links

Use popovers for quick pickers, sheets for multi-step edits.

### Modals

| Type | Usage |
|------|-------|
| Popover | Quick pickers / actions |
| Sheet | Multi-field create / edit flows |
| Alert | Destructive / irreversible confirmation only |

**Sheet rules:**
- Clear title.
- Cancel on the leading side, primary action on the trailing side.
- Minimal fields per step (avoid mega-sheets).

### Context Menus

- Provide context menus for all list rows.
- Menu items mirror keyboard shortcuts.

---

## 14. Rules for New Views

Before shipping any new view, verify all of the following:

1. [ ] Import project theme tokens -- never hardcode colors, spacing, fonts, or animation values.
2. [ ] Use `.glassCard()` or `.solidCard()` (or project equivalent) for containers.
3. [ ] Use theme animation tokens for all animations.
4. [ ] Use theme spacing tokens for all padding and gaps.
5. [ ] Use theme typography tokens for all font specs.
6. [ ] Add `.hoverScale()` or equivalent for interactive cards / elements.
7. [ ] Support light and dark mode through semantic colors.
8. [ ] One clear primary action (or none) per view.
9. [ ] Visual hierarchy scannable in under 1 second.
10. [ ] No dense content placed directly on glass -- use Tier C plate.
11. [ ] Secondary actions hidden until hover or context menu.
12. [ ] Keyboard shortcuts for primary actions, discoverable via menu / tooltips.
13. [ ] Works with Reduce Transparency enabled.
14. [ ] When SwiftUI type-checker times out, extract sub-views into `@ViewBuilder` computed properties.

---

## 15. macOS Platform Standards

All apps in this suite must follow these macOS conventions:

- **`NavigationSplitView`** for multi-column layouts.
- **SF Symbols** exclusively for icons.
- **Dark Mode** support -- all custom colors must work in both appearances.
- **Dynamic Type** support -- use semantic text styles, never fixed pixel sizes
  as the sole font definition.
- **Keyboard navigation** -- shortcuts for all primary actions. Benchmark
  depth: Things-level (Go-To shortcuts, search / command palette, context-
  sensitive "New item", inspector toggle).
- **`.searchable`** modifier for search integration.
- **`.inspector`** modifier for inspector panels where appropriate.
- **`.confirmationDialog`** for destructive action confirmation.
- **Settings** via SwiftUI `Settings` scene, accessed by `Cmd+,`. Settings is
  never a sidebar item.
- Follow Apple HIG for toolbar placement and controls.

---

## 16. Accessibility Requirements

The UI must work correctly with all of the following enabled:

| Setting | Requirement |
|---------|-------------|
| **Reduce Transparency** | Glass becomes opaque with system background colors. Do not fight the system. |
| **Increase Contrast** | Selection states, focus rings, and borders must remain clearly visible. |
| **Large Dynamic Type** | Layouts must reflow; no truncation of primary content. |
| **Reduce Motion** | Replace spring animations with simple crossfades or instant transitions. |

### Additional Requirements

- **VoiceOver labels** on all interactive elements.
- All visual states (default, hover, pressed, disabled, selected, focus ring)
  must be defined for every interactive component.
- All glass surfaces must be tested on busy wallpapers to guarantee legibility.
- When Reduce Transparency is enabled, do not attempt to restore translucency.

---

## References

- [Apple Liquid Glass Overview](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SF Symbols](https://developer.apple.com/sf-symbols/)
- [Things by Cultured Code](https://culturedcode.com/things/features/)
