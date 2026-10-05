#!/usr/bin/env python3
"""Guard the Scarf accent and status tokens against drift and contrast regressions.

The asset catalog is the source of truth:

    scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfBrand.xcassets
        Accent/Accent, Accent/AccentHover, Accent/AccentActive,
        Accent/AccentTint, Accent/AccentTintStrong   -> --accent, --accent-hover,
                                                        --accent-active, --accent-tint,
                                                        --accent-tint-strong
        Foreground/OnAccent                          -> --on-accent
        Surface/BackgroundPrimary                    -> --bg
        Surface/BackgroundSecondary                  -> --bg-card
        Semantic/Semantic{Success,Warning,Info,Danger} -> --success, --warning, --info,
                                                        --danger (text / icons / dots)
        Danger/DangerFill, Danger/OnDanger           -> --danger-fill, --on-danger
        Status/{Success,Warning,Info,Danger}Tint     -> --success-tint, ... --danger-tint
        Tool/ToolWeb, Tool/ToolSearch (+ *Tint)       -> --tool-web(-tint), --tool-search(-tint)

The guard FAILS CLOSED: anything it can't place or parse is an error, not a pass.

Checks, for light and dark:

  1. Every CSS mirror (design/static-site/colors_and_type.css, site/landing/styles.css,
     site/styles.css) defines the same values in each theme block it has. Recognized
     theme contexts, and nothing else:
         light  top-level `:root` / `html`; `[data-theme="light"]` (optionally
                prefixed with `:root` or `html`)
         dark   `[data-theme="dark"]` (same prefixes); `:root`, `:root:not([data-theme])`
                or `:root:not([data-theme="light"])` directly inside exactly
                `@media (prefers-color-scheme: dark)`
     Quote style and whitespace are normalized ([data-theme=dark] is fine). A guarded
     token (--accent*, --on-accent, --bg, --bg-card, --bg-tertiary, or any custom
     property whose value resolves to an accent-family color) declared in any other
     context — another selector, @layer, @supports, a non-dark or nested @media — is an
     error. A dark block inherits what it leaves out from :root, as the cascade does,
     so a dark block that forgets --on-accent is caught too. `!important` is ignored.
  2. The two app AccentColor colorsets (macOS + iOS) are the SYSTEM tint: checkboxes,
     switches, default buttons and links that AppKit/UIKit draw, often with a WHITE glyph
     or label on the tint. Light must equal Accent/Accent light (#A6481E: white on it is
     5.89:1). Dark deliberately differs from Accent/Accent: no single color can carry
     white at 4.5:1 (needs luminance <= 0.183) AND read as 4.5:1 text on the dark page
     (needs >= 0.205 on --bg, >= 0.228 on --bg-card). So the dark tint must give white
     >= 3.0:1 (the non-text bar for a checkmark / switch knob) and be >= 4.5:1 as text on
     the dark bg, card and tertiary surfaces; it is #D87844 (accentActive dark): white
     3.14:1, text 5.91 / 5.41. Text on an accent FILL in our own views uses
     ScarfPrimaryButton / onAccent, never the system tint. ScarfTheme.swift (comments
     stripped) still binds ScarfColor.accent* / onAccent / danger* / success / warning /
     info / <kind>Tint / Tool.web / search / webTint / searchTint to their assets;
     ScarfComponents.swift's ScarfBadgeKind `text` / `fill` return ScarfColor.<kind> /
     ScarfColor.<kind>Tint for success, warning, info, danger, and ScarfToolTone
     `color` / `wash` return the verified pairs (read/edit/execute -> the status pairs,
     fetch/browser -> Tool.web(Tint) / Tool.search(Tint), other -> foregroundMuted on
     backgroundTertiary).
  3. WCAG 2.x contrast: on-accent on accent / hover / active >= 4.5; accent, hover and
     active as text on the page and card backgrounds >= 4.5; accent and active text on
     --accent-tint and hover text on --accent-tint-strong (composited over both) >= 4.5;
     accent as a focus ring / border vs both >= 3.0. Where a stylesheet defines
     --bg-tertiary (composited over --bg if translucent): accent and hover text on it
     >= 4.5, hover text on either tint over it >= 4.5 (tinted accent text on a tertiary
     surface uses the hover step), focus ring >= 3.0. Danger, where defined (always in
     the xcassets; the danger tokens are optional per stylesheet but must match when
     present): --danger text on --bg, --bg-card and --bg-tertiary >= 4.5, --on-danger on
     --danger-fill >= 4.5. The xcassets run includes Surface/BackgroundTertiary.
     Status and tool colors (success, warning, info, danger, tool-web, tool-search),
     where defined (always in the xcassets; optional per stylesheet, but a --X-tint
     needs its --X, and both must match): --X is opaque and >= 4.5 as text and >= 3.0
     as a dot / icon on --bg, --bg-card and --bg-tertiary; --X-tint is translucent and
     --X is >= 4.5 on it composited over each surface. The tint keeps the LIGHTER hue
     (green/orange/blue-500, red-600, purple-tool / indigo-500); a lighter wash of it
     only raises contrast. --on-accent is >= 4.5 on each solid --X (the verified
     on-color for a solid status / tool fill). xcassets only: ForegroundMuted on
     Status/NeutralTint over each surface >= 4.5 (neutral badge, "other" tool chip), and
     ScarfBadgeKind.fillAlpha / ScarfToolTone.washAlpha equal their tint colorsets' alpha.
     Accent text on --accent-tint-strong: only --accent-hover is checked (and allowed,
     check 4); dark --accent-active on it is 3.28-3.81:1, --accent 3.65-4.19.
  4. Fill lint, in the CSS mirrors, the <style> blocks and style="" attributes of
     design/static-site/**/*.html, and the ui-kit .jsx style objects: a rule (or style
     object) whose background / background-color / background-image is an accent fill
     must not set a text color other than var(--on-accent). An accent fill is
     var(--accent|--accent-hover|--accent-active) (any spacing, with or without a
     fallback), anything that resolves to an accent-family color (brand-300..900 from
     colors_and_type.css plus the xcassets accent states), including gradients. The
     brand-50..200 pastels are not accent fills: they take dark text, not --on-accent.
     In .jsx only white text ('#fff' / '#FFF' / '#ffffff' / 'white') is flagged.
     Danger fills get the same treatment: a rule or style object whose fill is red-500 /
     red-600, var(--danger*) or a danger colorset value, and that sets a text color, must
     fill with var(--danger-fill) and color the text var(--on-danger) (white on the
     dark-mode --danger is 3.27:1). The red-100 pastel isn't a danger fill.
     Status washes too: a rule or style object whose fill is a status / tool tint
     (var(--<kind>-tint), var(--tool-web|search-tint), a green/red/orange/blue-100
     pastel, or a translucent tint-hue color such as rgba(217, 83, 79, 0.12)) must not
     color its text with a tint hue (green/red-500/600, orange/blue-500, purple-tool /
     indigo-500, a *Tint colorset RGB, a var resolving to one, or one named
     --green/red/orange/blue(-500|600), --purple-tool-500, --indigo-500 even where
     it's undefined): use var(--<kind>). A ternary color is flagged if any branch is.
     And a rule / style object filled with var(--accent-tint-strong) must color its
     text var(--accent-hover) (a missing color counts: it would inherit). A rule / style
     object with a SOLID status / tool fill (var(--success|warning|info|tool-web|
     tool-search|green|orange|blue), a green/orange/blue-500..700, --purple-tool-500,
     --indigo-500) that sets a text color must use var(--on-accent).

  5. (Run last, and collected rather than raised, so it never hides the other results.)
     The ui-kit bundle (design/static-site/ui-kit/index.html) is fresh: its embedded
     colors_and_type.css (ignoring the inlined @font-face swap for the Google Fonts
     @import) and each embedded .jsx equal the sources in design/static-site. Decoding
     is shared with tools/refresh-ui-kit-bundle.py, which fixes a stale bundle.

  6. Swift lint (comments and string-literal contents stripped, identifier backticks
     dropped, #if/#else/#endif lines blanked) over every .swift file under scarf/scarf,
     "scarf/Scarf iOS" and scarf/Packages/*/Sources (build output such as .build/ is
     skipped):
       - no `.borderedProminent` / `BorderedProminentButtonStyle`, `.glassProminent` /
         `GlassProminentButtonStyle`, or `.controlProminence(.increased)`. The system
         prominent styles fill with the app AccentColor and draw a WHITE label. Use
         `.buttonStyle(ScarfPrimaryButton())`, which draws ScarfColor.onAccent.
       - a Button with `.keyboardShortcut(.defaultAction)` (or `.return` with no
         modifiers) must carry a Scarf style (`ScarfPrimaryButton()` /
         `ScarfDestructiveButton()`, or Secondary / Ghost for an "Enter cancels" sheet)
         in the SAME modifier chain: otherwise macOS draws its default-button look, a
         white label on the system tint. The chain is found by bracket matching: back
         over `.member`, call parens, trailing and `label:` closures to the root, forward
         over following `.modifier(...)` links; only `.buttonStyle` at depth 0 of the
         chain counts (not one inside the label closure).
       - inside a `.swipeActions { ... }` closure, every `.tint(...)` must be in
         SWIPE_TINT_ALLOWED (brandRustDeep, dangerFill: white clears AA on both in both
         appearances), and every swipe Button must carry one: untinted, the system uses
         its red (3.55 / 3.41:1) or the app tint (3.14:1 dark) under a white label.
       - no `.fill(ScarfColor.danger)` / `.background(ScarfColor.danger, ...)` without an
         opacity: a solid danger surface is ScarfColor.dangerFill (+ onDanger).
       - text on a wash of its own color. For every `.background(...)` / `.background {
         }` whose argument (outside `.stroke` / `.strokeBorder` calls) holds
         `X.opacity(...)`, where X is ScarfColor.success / warning / info / danger /
         accent, a system color (`.orange`, `Color.red`, ...), a bare local (`tint`,
         `color`: it may hold one), a call (`statusColor(...)`, matched as text) or a
         parenthesized ternary of those: no `.foregroundStyle` / `.foregroundColor`
         anywhere in that modifier chain (the root's content closures included; same
         bracket matching as above) may name X. The status colors are the darker text
         hue, so a wash of themselves is mud and misses AA (light warning on its own
         0.18 wash is 4.12:1 on tertiary): wash with ScarfColor.<kind>Tint
         (`.opacity(f)` for a lighter banner), ScarfBadgeKind `.fill` or ScarfToolTone
         `.wash`, which check 3 verifies.
       - text on a SOLID status / tool fill in one chain (`.background(X)`,
         `Capsule|Circle|Rectangle|RoundedRectangle().fill(X)`, X a bare ScarfColor.
         success / warning / info / danger / Tool.web / Tool.search or a system color, or
         X.opacity(a) with a >= 0.5) must be ScarfColor.onAccent (verified in check 3);
         on a system color nothing is verified. White on system orange is about 2:1.
       - no `ScarfColor.<token>.opacity(f)` with a literal f > 1 (it can't add density;
         a stronger border uses the *Hue token).
     A missing source root, no .swift files found, or unbalanced brackets / an
     unterminated literal is a setup error (fail closed).

Known limitation: the fill lint only pairs declarations within one rule / style object.
A fill set on `.btn:hover` with the text color on `.btn` (or a JSX conditional that
splits them across objects) isn't paired. The ui-kit/index.html bundle is not scanned
(its sources are).
The Swift lint can't see: a button style applied to a CONTAINER (`HStack {...}
.buttonStyle(...)`) or to a stored view (`let b = Button(...)`; `b.buttonStyle(...)`),
which the default-action rule reports as missing (a false positive, never a pass); a
default button created by AppKit/UIKit itself (alerts, confirmation dialogs, NSAlert),
which takes the system tint, hence check 2's dark AccentColor; a `.tint` applied outside
the `.swipeActions` closure; and a danger fill reached through a variable or a custom
ShapeStyle. Checkboxes / switches draw on the system tint, covered by check 2.
The text-on-tint lint compares expressions, not values: it can't see a wash and a text
color that hold the same color under DIFFERENT names (`toneBackground` /
`toneForeground` computed properties, a `.fill(kind.fill)` with `.foregroundStyle(kind.fg)`
on another type), siblings layered in a ZStack (a tinted Circle under an Image), a wash
in `.overlay` / `.listRowBackground`, a `.foregroundStyle(.tint)` over `.tint(X)`, or a
member path other than the listed semantic / system colors (`tone.color`, `x.fill`)
— those wash colors are ignored, not failed (the tone APIs are pinned by check 2
instead). Raw semantic text on a plain surface needs no lint: check 3 holds every
status color at 4.5:1 on all three surfaces. In CSS / JSX, a wash and its text color
must sit in one rule / style object; a `t.fg` / `t.bg` lookup isn't resolved.
Also not seen, by design (documented, not chased): a solid fill or wash reached through a
local or a computed property (`Circle().fill(tint)` with an icon on it, as in the voice
orb); `.tinted(f)` above a kind's tint alpha (it clamps, so it can't over-saturate); an
opacity given as an expression rather than a literal; a JSX tone object with `bg` / `fg`
keys rather than `background` / `color`; chart and sparkline marks (non-text, judged by
the 3.0 dot / icon check on the tokens, not per rule); and the Hue tokens as text (they
have no contrast floor: they are for borders, halos and chart marks only).

Stdlib only. Exit 0 when clean, 1 on any failure (each one printed), 2 on a setup
error (missing file, unparseable colorset).

Usage: tools/check-design-tokens.py [--repo PATH] [-v]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

XCASSETS = "scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfBrand.xcassets"
APP_ACCENT_COLORSETS = (
    "scarf/scarf/Assets.xcassets/AccentColor.colorset",
    "scarf/Scarf iOS/Assets.xcassets/AccentColor.colorset",
)
THEME_SWIFT = "scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfTheme.swift"
COMPONENTS_SWIFT = "scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfComponents.swift"
BRAND_SCALE_CSS = "design/static-site/colors_and_type.css"
CSS_MIRRORS = (
    "design/static-site/colors_and_type.css",
    "site/landing/styles.css",
    "site/styles.css",
)
DESIGN_HTML_ROOT = "design/static-site"
DESIGN_HTML_SKIP = {"design/static-site/ui-kit/index.html"}  # generated bundle
JSX_GLOB = "design/static-site/ui-kit/*.jsx"
SWIFT_ROOTS = ("scarf/scarf", "scarf/Scarf iOS")
SWIFT_PACKAGES_GLOB = "scarf/Packages/*/Sources"
SWIFT_SKIP_DIRS = {".build", ".dd", "build", "DerivedData", ".swiftpm"}

# CSS token -> colorset (relative to XCASSETS).
TOKENS = {
    "accent": "Accent/Accent",
    "accent-hover": "Accent/AccentHover",
    "accent-active": "Accent/AccentActive",
    "accent-tint": "Accent/AccentTint",
    "accent-tint-strong": "Accent/AccentTintStrong",
    "on-accent": "Foreground/OnAccent",
    "bg": "Surface/BackgroundPrimary",
    "bg-card": "Surface/BackgroundSecondary",
    "danger": "Semantic/SemanticDanger",
    "danger-fill": "Danger/DangerFill",
    "on-danger": "Danger/OnDanger",
    # Status colors (text, icons, dots; text-safe on every surface) and the tint they
    # sit on in badges, pills, status strips / tiles. Optional per stylesheet; a
    # --<kind>-tint needs its --<kind>, and both must match.
    "success": "Semantic/SemanticSuccess",
    "warning": "Semantic/SemanticWarning",
    "info": "Semantic/SemanticInfo",
    "success-tint": "Status/SuccessTint",
    "warning-tint": "Status/WarningTint",
    "info-tint": "Status/InfoTint",
    "danger-tint": "Status/DangerTint",
    # Tool-kind chip colors without a status equivalent (web fetch, browser).
    "tool-web": "Tool/ToolWeb",
    "tool-web-tint": "Tool/ToolWebTint",
    "tool-search": "Tool/ToolSearch",
    "tool-search-tint": "Tool/ToolSearchTint",
}
STATUS_KINDS = ("success", "warning", "info", "danger")
# (text token, its tint) pairs verified like the status kinds.
TEXT_ON_TINT = tuple((k, f"{k}-tint") for k in STATUS_KINDS) + \
    (("tool-web", "tool-web-tint"), ("tool-search", "tool-search-tint"))
# Every theme block must resolve these (the tints are optional per file).
REQUIRED = ("accent", "accent-hover", "accent-active", "on-accent", "bg", "bg-card")
# Contrast-checked but not mirrored from the xcassets.
EXTRA_GUARDED = ("bg-tertiary",)

# ScarfColor property -> asset name it must load.
SWIFT_BINDINGS = {
    "accent": "Accent/Accent",
    "accentHover": "Accent/AccentHover",
    "accentActive": "Accent/AccentActive",
    "accentTint": "Accent/AccentTint",
    "accentTintStrong": "Accent/AccentTintStrong",
    "onAccent": "Foreground/OnAccent",
    "danger": "Semantic/SemanticDanger",
    "dangerFill": "Danger/DangerFill",
    "onDanger": "Danger/OnDanger",
    "success": "Semantic/SemanticSuccess",
    "warning": "Semantic/SemanticWarning",
    "info": "Semantic/SemanticInfo",
    **{f"{k}Tint": f"Status/{k.capitalize()}Tint" for k in STATUS_KINDS},
    "web": "Tool/ToolWeb",
    "search": "Tool/ToolSearch",
    "webTint": "Tool/ToolWebTint",
    "searchTint": "Tool/ToolSearchTint",
    "neutralTint": "Status/NeutralTint",
    **{f"{k}Hue": f"Status/{k.capitalize()}Hue" for k in STATUS_KINDS},
}

TEXT_AA = 4.5
NON_TEXT = 3.0
ALPHA_TOLERANCE = 0.006  # colorsets store alpha to 3 decimals


class SetupError(Exception):
    pass


# ---------------------------------------------------------------- colors

RGBA = tuple  # (r, g, b, a) with r/g/b in 0..255 ints, a in 0..1


def hexstr(c: RGBA) -> str:
    s = "#%02X%02X%02X" % c[:3]
    if c[3] < 1:
        s += " @ %.2f" % c[3]
    return s


def _channel(raw: str) -> int:
    """Xcode's rules: "0x.." is hex 0-255, a value with a '.' is a 0-1 float, and a
    bare integer is 0-255 (so "1" is 1/255, not full intensity)."""
    raw = str(raw).strip()
    if raw.lower().startswith("0x"):
        return int(raw, 16)
    if "." in raw:
        return round(float(raw) * 255)
    return int(raw)


def _alpha(raw: str) -> float:
    raw = str(raw).strip()
    if raw.lower().startswith("0x"):
        return int(raw, 16) / 255
    return float(raw)  # alpha is always 0-1 in Xcode's output


def read_colorset(path: Path) -> dict[str, RGBA]:
    """Return {"light": rgba, "dark": rgba} for a .colorset directory."""
    f = path / "Contents.json"
    if not f.is_file():
        raise SetupError(f"missing colorset: {f}")
    data = json.loads(f.read_text())
    out: dict[str, RGBA] = {}
    for entry in data.get("colors", []):
        appearance = "light"
        for a in entry.get("appearances", []):
            if a.get("appearance") == "luminosity":
                appearance = {"dark": "dark", "light": "light"}.get(a.get("value"), "skip")
            else:
                appearance = "skip"  # high-contrast and other variants aren't mirrored
        if appearance == "skip" or appearance in out:
            continue
        comps = entry["color"]["components"]
        space = entry["color"].get("color-space", "srgb")
        if space not in ("srgb", "extended-srgb"):
            raise SetupError(f"{f}: unsupported color-space {space!r}")
        rgb = tuple(_channel(comps[k]) for k in ("red", "green", "blue"))
        if not all(0 <= v <= 255 for v in rgb):
            raise SetupError(f"{f}: component out of range {rgb}")
        out[appearance] = rgb + (round(_alpha(comps.get("alpha", "1.0")), 3),)
    if "light" not in out:
        raise SetupError(f"{f}: no universal (light) color")
    out.setdefault("dark", out["light"])
    return out


_HEX = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
_RGB = re.compile(r"^rgba?\(\s*([^)]*)\)$")
_NAMED = {"white": (255, 255, 255, 1.0), "black": (0, 0, 0, 1.0)}
_IMPORTANT = re.compile(r"\s*!\s*important\s*$", re.I)


def clean_value(v: str) -> str:
    return _IMPORTANT.sub("", " ".join(v.split()))


def parse_css_color(value: str) -> RGBA | None:
    v = clean_value(value)
    if v.lower() in _NAMED:
        return _NAMED[v.lower()]
    m = _HEX.match(v)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), round(a, 3))
    m = _RGB.match(v)
    if m:
        parts = [p for p in re.split(r"[\s,/]+", m.group(1).strip()) if p]
        if len(parts) not in (3, 4):
            return None
        try:
            rgb = [int(round(float(p.rstrip("%")) * (2.55 if p.endswith("%") else 1))) for p in parts[:3]]
            a = 1.0
            if len(parts) == 4:
                a = float(parts[3].rstrip("%")) / (100 if parts[3].endswith("%") else 1)
        except ValueError:
            return None
        return (rgb[0], rgb[1], rgb[2], round(a, 3))
    return None


def colors_in(text: str) -> list[RGBA]:
    """Every literal color (hex / rgb() / rgba()) appearing anywhere in a value."""
    out = []
    for m in re.finditer(r"#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)", text):
        c = parse_css_color(m.group(0))
        if c:
            out.append(c)
    return out


def same(a: RGBA, b: RGBA) -> bool:
    return a[:3] == b[:3] and abs(a[3] - b[3]) <= ALPHA_TOLERANCE


def over(fg: RGBA, bg: RGBA) -> RGBA:
    """Composite a translucent color over an opaque one."""
    a = fg[3]
    return tuple(round(fg[i] * a + bg[i] * (1 - a)) for i in range(3)) + (1.0,)


def luminance(c: RGBA) -> float:
    def ch(v: int) -> float:
        s = v / 255
        return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: RGBA, b: RGBA) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------- CSS

def strip_comments(css: str) -> str:
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def parse_rules(css: str, where: str, context: tuple = ()) -> list[tuple[tuple, str, str]]:
    """Flatten a stylesheet into (at-rule context, selector, body) triples. Recurses
    into every block at-rule (@media, @supports, @layer, ...); the context records the
    full chain. Unbalanced braces are a setup error (fail closed)."""
    if css.count("{") != css.count("}"):
        raise SetupError(f"{where}: unbalanced braces")
    rules = []
    i, n = 0, len(css)
    while i < n:
        j = css.find("{", i)
        if j < 0:
            break
        prelude = css[i:j].strip()
        # Drop statement at-rules (@import ...; @layer a, b;) sitting before this block.
        if ";" in prelude:
            prelude = prelude[prelude.rfind(";") + 1:].strip()
        depth, k = 1, j + 1
        while k < n and depth:
            if css[k] == "{":
                depth += 1
            elif css[k] == "}":
                depth -= 1
            k += 1
        body = css[j + 1:k - 1]
        prelude = " ".join(prelude.split())
        if prelude.startswith("@") and not prelude.startswith(("@font-face", "@page", "@property")) \
                and "{" in body:
            rules.extend(parse_rules(body, where, context + (prelude,)))
        else:
            rules.append((context, prelude, body))
        i = k
    return rules


def declarations(body: str) -> list[tuple[str, str]]:
    out = []
    for decl in body.split(";"):
        if ":" not in decl:
            continue
        prop, _, val = decl.partition(":")
        out.append((prop.strip(), clean_value(val)))
    return out


def _norm_sel(sel: str) -> str:
    s = re.sub(r"\s+", "", sel).replace("'", '"')
    # [data-theme=dark] -> [data-theme="dark"]
    s = re.sub(r'\[data-theme=([A-Za-z-]+)\]', r'[data-theme="\1"]', s)
    # optional html / :root prefix
    if s.startswith("html"):
        s = ":root" + s[4:]
    if s.startswith("[data-theme"):
        s = ":root" + s
    return s


LIGHT_SELECTORS = {':root[data-theme="light"]'}
DARK_SELECTORS = {':root[data-theme="dark"]'}
DARK_MEDIA_ROOT = {":root", ':root:not([data-theme="light"])', ":root:not([data-theme])"}
DARK_MEDIA = "@media (prefers-color-scheme: dark)"


def classify(context: tuple, selector: str) -> tuple[str, str] | None:
    """Return (theme, label) for a recognized theme-root rule, else None."""
    sels = {_norm_sel(s) for s in selector.split(",")}
    if not context:
        if sels == {":root"}:
            return ("light", ":root")
        if sels <= LIGHT_SELECTORS:
            return ("light", selector)
        if sels <= DARK_SELECTORS:
            return ("dark", selector)
        return None
    if len(context) == 1 and re.sub(r"\s+", "", context[0]) == re.sub(r"\s+", "", DARK_MEDIA) \
            and sels <= DARK_MEDIA_ROOT:
        return ("dark", f"{DARK_MEDIA} {selector}")
    return None


_VAR = re.compile(r"var\(\s*--([\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\)[^()]*)*))?\)")


def resolve(value: str, scope: dict[str, str], depth: int = 0) -> str:
    if depth > 10:
        return value
    def sub(mt: re.Match) -> str:
        name, fallback = mt.group(1), mt.group(2)
        if name in scope:
            return resolve(scope[name], scope, depth + 1)
        return resolve(fallback.strip(), scope, depth + 1) if fallback else mt.group(0)
    return _VAR.sub(sub, value)


def read_brand_family(repo: Path, truth: dict) -> list[RGBA]:
    """Accent-family colors: brand-300..900 plus every xcassets accent state."""
    css = strip_comments((repo / BRAND_SCALE_CSS).read_text())
    fam = []
    for step, hx in re.findall(r"--brand-(\d+)\s*:\s*(#[0-9A-Fa-f]{6})", css):
        if int(step) >= 300:
            fam.append(parse_css_color(hx))
    if len(fam) < 7:
        raise SetupError(f"{BRAND_SCALE_CSS}: couldn't read the brand-300..900 scale")
    for t in ("accent", "accent-hover", "accent-active"):
        fam += [truth[t]["light"], truth[t]["dark"]]
    return fam


def is_accent_color(c: RGBA, family: list[RGBA]) -> bool:
    return c[3] >= 0.9 and any(c[:3] == f[:3] for f in family)


ACCENT_VAR = re.compile(r"var\(\s*--accent(?:-hover|-active)?\s*[,)]")
FILL_PROPS = ("background", "background-color", "background-image")


def is_accent_fill(value: str, scope: dict[str, str], family: list[RGBA]) -> bool:
    if ACCENT_VAR.search(value):
        return True
    return any(is_accent_color(c, family) for c in colors_in(resolve(value, scope)))


DANGER_VAR = re.compile(r"var\(\s*--(?:danger|danger-fill|red-500|red-600)\s*[,)]")
DANGER_FILL_VAR = re.compile(r"^var\(\s*--danger-fill\s*(?:,[^)]*)?\)$")
DANGER_FAMILY: list[RGBA] = []  # filled by run(): red-500/600 + danger colorset values


def read_danger_family(repo: Path, truth: dict) -> list[RGBA]:
    css = strip_comments((repo / BRAND_SCALE_CSS).read_text())
    fam = [parse_css_color(hx) for step, hx in
           re.findall(r"--red-(\d+)\s*:\s*(#[0-9A-Fa-f]{6})", css) if int(step) >= 500]
    if len(fam) < 2:
        raise SetupError(f"{BRAND_SCALE_CSS}: couldn't read the red-500/600 scale")
    for t in ("danger", "danger-fill"):
        fam += [truth[t]["light"], truth[t]["dark"]]
    return fam


def is_danger_fill(value: str, scope: dict[str, str]) -> bool:
    if DANGER_VAR.search(value):
        return True
    return any(is_accent_color(c, DANGER_FAMILY) for c in colors_in(resolve(value, scope)))


def danger_fill_error(fill: str, color: str) -> str | None:
    """A danger fill that carries text must be var(--danger-fill) + var(--on-danger)."""
    f, c = re.sub(r"\s+", "", fill).strip("'\""), re.sub(r"\s+", "", color).strip("'\"")
    if c != "var(--on-danger)" or not DANGER_FILL_VAR.match(f):
        return (f"text color `{color.strip()}` on a danger fill (`{fill.strip()}`); fill with "
                f"var(--danger-fill) and color the text var(--on-danger)")
    return None


STATUS_FAMILY: list[RGBA] = []  # filled by run(): the lighter tint hues (not text-safe)
STATUS_TINT_VAR = re.compile(r"var\(\s*--(?:(?:success|warning|info|danger|tool-web|tool-search)-tint"
                             r"|(?:green|red|orange|blue)-100)\s*[,)]")


# Raw status colors by name, caught even where the stylesheet doesn't define them.
RAW_STATUS_VAR = re.compile(r"var\(\s*--(?:(?:green|red|orange|blue)-[56]00|green|red|orange|blue"
                            r"|purple-tool-500|indigo-500)\s*[,)]")


def read_status_family(repo: Path) -> list[RGBA]:
    """The LIGHTER, tint hues that aren't text-safe on a tint: green/red-500/600,
    orange/blue-500, purple-tool-500 / indigo-500 from colors_and_type.css plus the
    RGB of every Status/*Tint and Tool/*Tint colorset. The text-safe status colors
    (Semantic/*, --success.., the 700 steps) aren't in it."""
    css = strip_comments((repo / BRAND_SCALE_CSS).read_text())
    fam = [parse_css_color(hx) for name, step, hx in
           re.findall(r"--(green|red|orange|blue)-(\d+)\s*:\s*(#[0-9A-Fa-f]{6})", css)
           if 500 <= int(step) <= 600]
    fam += [parse_css_color(hx) for hx in
            re.findall(r"--(?:purple-tool|indigo)-500\s*:\s*(#[0-9A-Fa-f]{6})", css)]
    if len(fam) < 8:
        raise SetupError(f"{BRAND_SCALE_CSS}: couldn't read the green/red/orange/blue/tool 500-600 scale")
    for asset in [f"Status/{k.capitalize()}Tint" for k in STATUS_KINDS] + \
            ["Tool/ToolWebTint", "Tool/ToolSearchTint"]:
        cs = read_colorset(repo / XCASSETS / f"{asset}.colorset")
        fam += [cs["light"][:3] + (1.0,), cs["dark"][:3] + (1.0,)]
    return fam


def _raw_status(c: RGBA) -> bool:
    return any(c[:3] == f[:3] for f in STATUS_FAMILY)


def is_status_wash(value: str, scope: dict[str, str]) -> bool:
    """A status tint behind text: var(--<kind>-tint), a -100 pastel, or a translucent
    raw status color (rgba(217, 83, 79, 0.12))."""
    if STATUS_TINT_VAR.search(value):
        return True
    return any(c[3] < 1 and _raw_status(c) for c in colors_in(resolve(value, scope)))


def status_text_error(fill: str, color: str, scope: dict[str, str]) -> str | None:
    """Tint-hue text (a 500/600 or a *Tint RGB) on a status wash misses AA: light
    orange-500 is 1.6:1 on its tint. Use var(--<kind>) (text-safe)."""
    cols = colors_in(resolve(color, scope))
    if RAW_STATUS_VAR.search(color) or any(c[3] >= 0.9 and _raw_status(c) for c in cols):
        return (f"tint-hue text `{color.strip()}` on a status tint (`{fill.strip()}`); "
                f"use var(--<kind>) on var(--<kind>-tint)")
    return None


# A SOLID status / tool fill: only --on-accent is verified on it (check 3). Danger has
# its own rule (--danger-fill + --on-danger).
SOLID_STATUS_VAR = re.compile(r"^var\(\s*--(?:success|warning|info|tool-web|tool-search|green|orange|blue"
                              r"|(?:green|orange|blue)-[5-7]00|purple-tool-500|indigo-500)\s*(?:,[^)]*)?\)$")


def solid_status_error(fill: str, color: str) -> str | None:
    f = re.sub(r"\s+", "", fill).strip("'\"")
    if SOLID_STATUS_VAR.match(f) and re.sub(r"\s+", "", color).strip("'\"") != "var(--on-accent)":
        return (f"text `{color.strip()}` on a solid status fill (`{fill.strip()}`); only "
                f"var(--on-accent) is verified on it (or use a --<kind>-tint pill)")
    return None


TINT_STRONG_VAR = re.compile(r"var\(\s*--accent-tint-strong\s*[,)]")


def tint_strong_error(fill: str, color: str) -> str | None:
    """--accent-tint-strong carries only --accent-hover text: dark --accent-active on it
    is 3.28-3.81:1, --accent 3.65-4.19."""
    if TINT_STRONG_VAR.search(fill) and re.sub(r"\s+", "", color).strip("'\"") != "var(--accent-hover)":
        return (f"text `{color.strip()}` on --accent-tint-strong; only var(--accent-hover) "
                f"clears AA on it in dark mode")
    return None


def fill_lint(rules, scope, family, where) -> list[str]:
    errs = []
    for context, sel, body in rules:
        decls = declarations(body)
        fills = [v for p, v in decls if p in FILL_PROPS and is_accent_fill(v, scope, family)]
        dfills = [v for p, v in decls if p in FILL_PROPS and is_danger_fill(v, scope)]
        sfills = [v for p, v in decls if p in FILL_PROPS and is_status_wash(v, scope)]
        for p, v in decls:
            if p != "color":
                continue
            if sfills:
                e = status_text_error(sfills[0], v, scope)
                if e:
                    errs.append(f"{where}: `{sel}` puts {e}")
            for fv in (fv for fp, fv in decls if fp in FILL_PROPS):
                for e in (tint_strong_error(fv, v), solid_status_error(fv, v)):
                    if e:
                        errs.append(f"{where}: `{sel}` puts {e}")
            if fills and re.sub(r"\s+", "", v) != "var(--on-accent)":
                errs.append(f"{where}: `{sel}` puts text color `{v}` on an accent fill "
                            f"(`{fills[0]}`); use var(--on-accent)")
            if dfills:
                e = danger_fill_error(dfills[0], v)
                if e:
                    errs.append(f"{where}: `{sel}` puts {e}")
    return errs


def css_theme_blocks(path: Path, rel: str, family: list[RGBA]):
    """Return (blocks, root, misplaced-errors, rules). blocks are
    (theme, label, effective custom properties, own properties)."""
    rules = parse_rules(strip_comments(path.read_text()), rel)
    root: dict[str, str] = {}
    for context, sel, body in rules:
        if classify(context, sel) == ("light", ":root"):
            root.update({p[2:]: v for p, v in declarations(body) if p.startswith("--")})
    if not root:
        raise SetupError(f"{rel}: no top-level :root block")
    guarded_names = set(TOKENS) | set(EXTRA_GUARDED)
    blocks, misplaced = [], []
    for context, sel, body in rules:
        props = {p[2:]: v for p, v in declarations(body) if p.startswith("--")}
        kind = classify(context, sel)
        if kind:
            blocks.append((kind[0], kind[1], props))
            continue
        for name, val in props.items():
            accentish = any(is_accent_color(c, family) for c in colors_in(resolve(val, root)))
            if name in guarded_names or accentish:
                ctx = " ".join(context + (sel,))
                misplaced.append(f"{rel}: --{name} is declared in `{ctx}`, which isn't a theme "
                                 f"context the guard recognizes (top-level :root, "
                                 f"[data-theme=light|dark], or :root inside {DARK_MEDIA})")
    out = []
    for theme, label, props in blocks:
        eff = dict(root)  # theme blocks inherit what they leave out
        eff.update(props)
        out.append((theme, label, eff, props))
    return out, root, misplaced, rules


# ---------------------------------------------------------------- inline sources

def html_lint(repo: Path, family: list[RGBA], scope: dict[str, str]) -> list[str]:
    errs = []
    base = repo / DESIGN_HTML_ROOT
    for path in sorted(base.rglob("*.html")):
        rel = str(path.relative_to(repo))
        if rel in DESIGN_HTML_SKIP:
            continue
        text = path.read_text()
        for m in re.finditer(r"<style[^>]*>(.*?)</style>", text, re.S | re.I):
            errs += fill_lint(parse_rules(strip_comments(m.group(1)), rel), scope, family, f"{rel} <style>")
        for m in re.finditer(r'\bstyle\s*=\s*"([^"]*)"', text):
            errs += fill_lint([((), "style=\"…\"", m.group(1))], scope, family, f"{rel} inline style")
    return errs


_JSX_WHITE = re.compile(r"""['"](?:#fff|#ffffff|white)['"]""", re.I)
_JSX_PROP = re.compile(r"\b(background|backgroundColor|backgroundImage|color)\s*:\s*(.+?)(?=,\s*[A-Za-z_$][\w$]*\s*:|$)", re.S)


def jsx_lint(repo: Path, family: list[RGBA], scope: dict[str, str]) -> list[str]:
    errs = []
    for path in sorted(repo.glob(JSX_GLOB)):
        rel = str(path.relative_to(repo))
        text = path.read_text()
        # Innermost object literals: { ... } with no nested braces.
        for m in re.finditer(r"\{([^{}]*)\}", text):
            obj = m.group(1)
            props = {}
            for pm in _JSX_PROP.finditer(obj):
                props.setdefault(pm.group(1), pm.group(2))
            fill = next((props[k] for k in ("background", "backgroundColor", "backgroundImage")
                         if k in props and is_accent_fill(props[k], scope, family)), None)
            line = text.count("\n", 0, m.start()) + 1
            if fill and "color" in props and _JSX_WHITE.search(props["color"]):
                errs.append(f"{rel}:{line}: white text ({props['color'].strip()}) on an accent fill "
                            f"({fill.strip()}); use 'var(--on-accent)'")
            sfill = next((props[k] for k in ("background", "backgroundColor", "backgroundImage")
                          if k in props and is_status_wash(props[k], scope)), None)
            if sfill and "color" in props:
                e = status_text_error(sfill, props["color"], scope)
                if e:
                    errs.append(f"{rel}:{line}: {e}")
            for k in ("background", "backgroundColor"):
                if k in props and "color" in props:
                    e = solid_status_error(props[k], props["color"])
                    if e:
                        errs.append(f"{rel}:{line}: {e}")
                if k in props and TINT_STRONG_VAR.search(props[k]):
                    e = tint_strong_error(props[k], props.get("color", "<none: inherited>"))
                    if e:
                        errs.append(f"{rel}:{line}: {e}")
            dfill = next((props[k] for k in ("background", "backgroundColor", "backgroundImage")
                          if k in props and is_danger_fill(props[k], scope)), None)
            if dfill and "color" in props:
                e = danger_fill_error(dfill, props["color"])
                if e:
                    errs.append(f"{rel}:{line}: {e}")
    return errs


# ---------------------------------------------------------------- Swift sources

def swift_code_only(src: str) -> str:
    """Blank out comments (// and nested /* */) and the text of string literals (plain,
    multi-line triple-quote and #-delimited raw forms), keeping every newline so line
    numbers survive. Code inside a string interpolation is kept and scanned the same way,
    so a nested literal there can't desynchronize the scan. An unterminated comment,
    string or interpolation is a setup error (fail closed)."""
    n = len(src)
    out: list[str] = []
    blank = lambda text: "".join("\n" if c == "\n" else " " for c in text)
    raw_open = re.compile(r'(#*)("""|")')

    def code(i: int, in_interp: bool) -> int:
        """Copy code from i; in an interpolation, stop after its closing paren."""
        depth = 0
        while i < n:
            ch = src[i]
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
            elif src.startswith("/*", i):
                d, j = 1, i + 2
                while j < n and d:
                    if src.startswith("/*", j):
                        d, j = d + 1, j + 2
                    elif src.startswith("*/", j):
                        d, j = d - 1, j + 2
                    else:
                        j += 1
                if d:
                    raise SetupError("unterminated /* comment")
                out.append(blank(src[i:j]))
                i = j
            elif ch == '"' or (ch == "#" and raw_open.match(src, i) and raw_open.match(src, i).group(1)):
                i = string(i)
            else:
                if in_interp:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        if depth == 0:
                            out.append(ch)
                            return i + 1
                        depth -= 1
                out.append(ch)
                i += 1
        if in_interp:
            raise SetupError("unterminated string interpolation")
        return i

    def string(i: int) -> int:
        m = raw_open.match(src, i)
        hashes, quote = m.group(1), m.group(2)
        close, multi = quote + hashes, len(quote) == 3
        escape = "\\" + hashes
        out.append(m.group(0))
        j, start = m.end(), m.end()
        while True:
            if j >= n or (src[j] == "\n" and not multi):
                raise SetupError("unterminated string literal")
            if src.startswith(close, j):
                out.append(blank(src[start:j]) + close)
                return j + len(close)
            if src.startswith(escape, j):
                k = j + len(escape)
                if k < n and src[k] == "(":
                    out.append(blank(src[start:k]) + "(")
                    j = start = code(k + 1, True)
                    continue
                j = k + 1
                continue
            j += 1

    code(0, False)
    return "".join(out)


PROMINENT = re.compile(r"\.(?:bordered|glass)Prominent\b|\b(?:BorderedProminent|GlassProminent)ButtonStyle\b"
                       r"|\.controlProminence\(\s*(?:Prominence)?\.increased\s*\)")
SWIPE = re.compile(r"\.swipeActions\b")
# Swipe-action tints the system's WHITE label clears AA on in BOTH appearances. Anything
# else (a variable, Color("AccentColor"), accent*, brandRust, danger, .red, .gray) fails.
SWIPE_TINT_ALLOWED = {
    "ScarfColor.brandRustDeep",  # #7A2E14 light 9.42:1 / #A6481E dark 5.89:1 (Cron Duplicate)
    "ScarfColor.dangerFill",     # #B83C38 both, 5.61:1 (destructive swipes; system red is 3.55 / 3.41)
}
SWIPE_BUTTON = re.compile(r"\bButton\b(?=\s*[({])")
DANGER_SOLID_FILL = re.compile(r"\.(?:fill|background)\(\s*ScarfColor\.danger\s*[,)]")


DEFAULT_ACTION = re.compile(
    r"\.keyboardShortcut\(\s*(?:KeyboardShortcut)?\.defaultAction\s*\)"
    r"|\.keyboardShortcut\(\s*(?:KeyEquivalent)?\.return\s*,\s*modifiers:\s*\[\s*\]\s*\)")
# The system default-button look (accent fill, white label) is only drawn for the system
# styles (automatic / bordered); any Scarf style draws its own label colors. A default
# action is normally the primary or destructive filled style; Secondary / Ghost are
# allowed for the deliberate "Enter cancels" sheets (Curator prune / purge), whose Cancel
# owns .defaultAction precisely so it doesn't read as the primary action.
SCARF_FILLED_STYLE = re.compile(
    r"^\s*(?:ScarfPrimaryButton|ScarfDestructiveButton|ScarfSecondaryButton|ScarfGhostButton)"
    r"\s*\(\s*\)\s*$")
_OPEN, _CLOSE = "([{", ")]}"
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _blank_directives(code: str) -> str:
    """Blank #if / #elseif / #else / #endif lines (postfix #if chains); both branches'
    modifiers then read as one chain, which is the conservative view."""
    return re.sub(r"(?m)^[ \t]*#(?:if|elseif|else|endif)\b[^\n]*",
                  lambda mt: " " * len(mt.group(0)), code)


def _match_fwd(code: str, i: int, where: str) -> int:
    """code[i] is an opener; return the index just past its matching closer."""
    stack = []
    for k in range(i, len(code)):
        c = code[k]
        if c in _OPEN:
            stack.append(_CLOSE[_OPEN.index(c)])
        elif c in _CLOSE:
            if not stack or stack.pop() != c:
                raise SetupError(f"{where}: unbalanced brackets")
            if not stack:
                return k + 1
    raise SetupError(f"{where}: unbalanced brackets")


def _match_back(code: str, i: int, where: str) -> int:
    """code[i] is a closer; return the index of its matching opener."""
    stack = []
    for k in range(i, -1, -1):
        c = code[k]
        if c in _CLOSE:
            stack.append(_OPEN[_CLOSE.index(c)])
        elif c in _OPEN:
            if not stack or stack.pop() != c:
                raise SetupError(f"{where}: unbalanced brackets")
            if not stack:
                return k
    raise SetupError(f"{where}: unbalanced brackets")


def _ws_back(code: str, i: int) -> int:
    while i >= 0 and code[i].isspace():
        i -= 1
    return i


def _ws_fwd(code: str, i: int) -> int:
    while i < len(code) and code[i].isspace():
        i += 1
    return i


def modifier_chain(code: str, start: int, end: int, where: str) -> tuple[int, int]:
    """Extent of the postfix expression containing code[start:end] (one `.modifier(...)`):
    walk back over `.member`, call parens, trailing closures and `label:` closures to the
    root (`Button`), then forward over the following `.modifier(...) {...}` links."""
    pos = start
    while True:
        j = _ws_back(code, pos - 1)
        if j < 0:
            break
        c = code[j]
        if c in ")]}":
            pos = _match_back(code, j, where)
            continue
        if c == ":" and code[pos] == "{":
            # `} label: {` — a labelled trailing closure belongs to the chain.
            e = _ws_back(code, j - 1)
            k = e
            while k > 0 and (code[k - 1].isalnum() or code[k - 1] == "_"):
                k -= 1
            before = _ws_back(code, k - 1)
            if e >= k and before >= 0 and code[before] == "}":
                pos = k
                continue
            break
        if c.isalnum() or c == "_":
            k = j
            while k > 0 and (code[k - 1].isalnum() or code[k - 1] == "_"):
                k -= 1
            before = _ws_back(code, k - 1)
            if before >= 0 and code[before] == ".":
                pos = before                      # `.member`
                continue
            if code[pos] in "({.":
                pos = k                           # root identifier (`Button`, a variable)
            break
        break
    i = end
    while True:
        j = _ws_fwd(code, i)
        if j < len(code) and code[j] in "({" and code[i - 1] in ")}" and code[j] == "{":
            i = _match_fwd(code, j, where)        # another trailing closure
            continue
        if j < len(code) and code[j] == ".":
            m = _IDENT.match(code, j + 1)
            if not m:
                break
            i = m.end()
            k = _ws_fwd(code, i)
            if k < len(code) and code[k] == "(":
                i = _match_fwd(code, k, where)
            continue
        m = _IDENT.match(code, j)
        if m and code[i - 1] == "}":
            k = _ws_fwd(code, m.end())
            if k < len(code) and code[k] == ":" and _ws_fwd(code, k + 1) < len(code) \
                    and code[_ws_fwd(code, k + 1)] == "{":
                i = _match_fwd(code, _ws_fwd(code, k + 1), where)
                continue
        break
    return pos, i


def chain_from_root(code: str, i: int, where: str) -> int:
    """End of the postfix chain whose root identifier ends at i (`Button` -> its call
    parens, trailing / labelled closures and every following `.modifier(...)`)."""
    k = _ws_fwd(code, i)
    if k < len(code) and code[k] == "(":
        i = _match_fwd(code, k, where)
        k = _ws_fwd(code, i)
    if k < len(code) and code[k] == "{":
        i = _match_fwd(code, k, where)
    return modifier_chain(code, i, i, where)[1] if i > 0 else i


def top_level_args(chain: str, modifier: str, where: str) -> list[str]:
    out, depth, i = [], 0, 0
    while i < len(chain):
        c = chain[i]
        if c in _OPEN:
            depth += 1
        elif c in _CLOSE:
            depth -= 1
        elif depth == 0 and chain.startswith(modifier, i) and \
                not (chain[i + len(modifier):i + len(modifier) + 1].isalnum()):
            k = _ws_fwd(chain, i + len(modifier))
            if k < len(chain) and chain[k] == "(":
                e = _match_fwd(chain, k, where)
                out.append(chain[k + 1:e - 1])
                i = e
                continue
        i += 1
    return out


def top_level_button_styles(chain: str, where: str) -> list[str]:
    """Arguments of every `.buttonStyle(...)` at bracket depth 0 of a chain (so a style
    inside the Button's label closure doesn't count)."""
    out, depth, i = [], 0, 0
    while i < len(chain):
        c = chain[i]
        if c in _OPEN:
            depth += 1
        elif c in _CLOSE:
            depth -= 1
        elif depth == 0 and chain.startswith(".buttonStyle", i):
            k = _ws_fwd(chain, i + len(".buttonStyle"))
            if k < len(chain) and chain[k] == "(":
                e = _match_fwd(chain, k, where)
                out.append(chain[k + 1:e - 1])
                i = e
                continue
        i += 1
    return out


BACKGROUND = re.compile(r"\.background\b")
# A translucent wash of some color: `<receiver>.opacity(<arg>)`, where the receiver is a
# dotted identifier path or a parenthesized expression (a ternary of colors).
OPACITY = re.compile(r"\.opacity\s*\(")
PATH = re.compile(r"(?<![\w.])((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)")
SYSTEM_COLORS = "red|green|orange|yellow|blue|purple|pink|mint|teal|cyan|indigo|brown"
SYSTEM_COLOR_END = re.compile(rf"(?<![\w.])(?:Color)?\.({SYSTEM_COLORS})\s*$")
PATH_END = re.compile(r"(?<![\w.])((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\s*$")
FOREGROUND = re.compile(r"\.(?:foregroundStyle|foregroundColor)\s*\(")
STROKE = re.compile(r"\.(?:stroke|strokeBorder)\s*\(")
SEMANTIC_KINDS = ("success", "warning", "info", "danger", "accent")
# A SOLID status fill under white / onAccent text: `.background(.red)`,
# `.fill(ScarfColor.warning)` (white on system orange is about 2:1, on the dark-mode
# status colors under 3:1). A solid danger surface is dangerFill + onDanger; a status
# pill is <kind> text on <kind>Tint.
SOLID_STATUS = re.compile(
    rf"^\s*(?:(?:Capsule|Circle|Rectangle|RoundedRectangle)\([^()]*\)\s*\.fill\(\s*)?"
    rf"(?P<fill>ScarfColor\.(?:success|warning|info|danger|Tool\.web|Tool\.search)"
    rf"|(?:Color)?\.(?:{'red|green|orange|yellow|blue|purple|indigo|mint|teal|cyan|pink'}))"
    rf"(?:\s*\.opacity\(\s*(?P<alpha>[0-9.]+)\s*\))?"
    rf"\s*\)?\s*(?:,.*)?$", re.S)
# The text colors verified on a solid status / tool fill (check 3: onAccent on each
# status and tool color >= 4.5 in both appearances). A system color has none.
SOLID_ON = re.compile(r"^ScarfColor\.onAccent$")


def _tinted_by(path: str) -> str | None:
    """The color a `<path>.opacity(...)` wash is OF, if the lint cares about it: a raw
    semantic ScarfColor (success / warning / info / danger / accent), or a bare local
    (a parameter like `tint` or `color`, which may hold one: fail closed). Other
    ScarfColor members (Tool.*, foreground*, border*) and SwiftUI statics aren't."""
    if path in {f"ScarfColor.{k}" for k in SEMANTIC_KINDS} | {"ScarfColor.Tool.web", "ScarfColor.Tool.search"}:
        return path
    if "." not in path and path[0].islower() and path != "self":
        return path
    return None


def _mentions(expr: str, path: str) -> bool:
    if "(" in path:  # a call expression: compare whitespace-free text
        return path in re.sub(r"\s+", "", expr)
    if path.startswith("Color.") and path[6:] in SYSTEM_COLORS.split("|"):
        # `.red`, `Color.red` (but not `ScarfColor.red` or `x.red`)
        return re.search(rf"(?<![\w.])(?:Color)?\.{path[6:]}(?![\w])", expr) is not None
    return re.search(rf"(?<![\w.]){re.escape(path)}(?![\w])", expr) is not None


def text_on_tint_lint(code: str, rel: str, line_of) -> list[str]:
    """Text in a semantic color on a wash of the SAME color, in one modifier chain:
    `.foregroundStyle(X)` / `.foregroundColor(X)` anywhere in the chain (the root's
    content closures included) and a `.background(...)` holding `X.opacity(...)`, where
    X is ScarfColor.success / warning / info / danger / accent or a bare local (`tint`,
    `color`).
    The status colors are the darker, text-safe hue: a wash of themselves is muddy and
    drops text under AA (light warning on its own 0.18 wash is 4.12:1 on tertiary).
    Wash with ScarfColor.<kind>Tint / ScarfBadgeKind .fill / ScarfToolTone .wash,
    which check 3 verifies under the text color.
    """
    errs = []
    for m in BACKGROUND.finditer(code):
        where = f"{rel}:{line_of(m.start())}"
        k = _ws_fwd(code, m.end())
        if k >= len(code) or code[k] not in "({":
            continue
        end = _match_fwd(code, k, where)
        k2 = _ws_fwd(code, end)
        if code[k] == "(" and k2 < len(code) and code[k2] == "{":
            end = _match_fwd(code, k2, where)   # .background(alignment:) { ... }
        arg = code[k:end]
        washes: dict[str, set] = {}             # wash color -> its opacity arguments
        # A `.stroke` / `.strokeBorder` outline isn't under the text: skip colors in it.
        strokes = []
        for sm in STROKE.finditer(arg):
            strokes.append((sm.end() - 1, _match_fwd(arg, sm.end() - 1, where)))
        for om in OPACITY.finditer(arg):
            if any(s0 <= om.start() < s1 for s0, s1 in strokes):
                continue
            e = _match_fwd(arg, om.end() - 1, where)
            alpha = re.sub(r"\s+", "", arg[om.end():e - 1])
            j = _ws_back(arg, om.start() - 1)
            if j >= 0 and arg[j] == ")":
                # `(cond ? ScarfColor.danger : ScarfColor.success).opacity(0.1)`: every
                # color path inside the parenthesized receiver is washed.
                k = _match_back(arg, j, where)
                pm = PATH_END.search(arg, 0, k)
                if pm and pm.end() == k:
                    # A call (`statusColor(call: c, result: r).opacity(...)`, `Self.tint(for:
                    # x)`): it returns some color, so match the call expression itself.
                    washes.setdefault(re.sub(r"\s+", "", arg[pm.start(1):j + 1]), set()).add(alpha)
                    continue
                paths = PATH.findall(arg[k:j + 1])
            else:
                sm = SYSTEM_COLOR_END.search(arg, 0, j + 1)
                if sm:
                    # `.orange.opacity(0.1)` / `Color.red.opacity(...)`: a system color.
                    washes.setdefault(f"Color.{sm.group(1)}", set()).add(alpha)
                    continue
                pm = PATH_END.search(arg, 0, j + 1)
                paths = [pm.group(1)] if pm else []
            for path in paths:
                w = _tinted_by(path)
                if w:
                    washes.setdefault(w, set()).add(alpha)
        inner = arg[1:-1] if arg[:1] in "({" else arg
        sm = SOLID_STATUS.match(inner)
        solid = sm is not None and (sm.group("alpha") is None or float(sm.group("alpha")) >= 0.5)
        if not washes and not solid:
            continue
        a, b = modifier_chain(code, m.start(), end, where)
        chain = code[a:b]
        if solid:
            for fm in FOREGROUND.finditer(chain):
                e = _match_fwd(chain, fm.end() - 1, where)
                fg = chain[fm.end():e - 1]
                fgc = re.sub(r"\s+", "", fg)
                if not (sm.group("fill").startswith("ScarfColor.") and SOLID_ON.match(fgc)):
                    errs.append(
                        f"{rel}:{line_of(a + fm.start())}: `{' '.join(fg.split())}` text on a solid "
                        f"status fill (`{' '.join(inner.split())}`, line {line_of(m.start())}) isn't a "
                        f"verified on-color. On a ScarfColor status / tool fill use "
                        f"ScarfColor.onAccent; a danger surface is dangerFill + onDanger; or use a "
                        f"pill (<kind> text on ScarfColor.<kind>Tint)")
            if not washes:
                continue
        for fm in FOREGROUND.finditer(chain):
            e = _match_fwd(chain, fm.end() - 1, where)
            fg = chain[fm.end():e - 1]
            shown = " ".join(fg.split())
            line = line_of(a + fm.start())
            for w, alphas in sorted(washes.items()):
                if _mentions(fg, w):
                    errs.append(
                        f"{rel}:{line}: `{shown}` text sits on a `{w}` wash (background at "
                        f"line {line_of(m.start())}); a color on a wash of itself misses AA. "
                        f"Wash with ScarfColor.<kind>Tint (`.opacity(f)` for a lighter one) "
                        f"or ScarfBadgeKind .fill / ScarfToolTone .wash")
    return errs


def swift_files(repo: Path) -> list[Path]:
    roots = [repo / r for r in SWIFT_ROOTS] + sorted(repo.glob(SWIFT_PACKAGES_GLOB))
    for r in roots[:len(SWIFT_ROOTS)]:
        if not r.is_dir():
            raise SetupError(f"missing Swift source root {r.relative_to(repo)}")
    if len(roots) == len(SWIFT_ROOTS):
        raise SetupError(f"no package sources match {SWIFT_PACKAGES_GLOB}")
    files = []
    for root in roots:
        for path in sorted(root.rglob("*.swift")):
            if SWIFT_SKIP_DIRS.isdisjoint(path.relative_to(root).parts[:-1]):
                files.append(path)
    if not files:
        raise SetupError("no .swift files found to lint")
    return files


TOKEN_OPACITY = re.compile(r"ScarfColor\.[\w.]+?\s*\.opacity\(\s*([0-9]*\.?[0-9]+)\s*\)")


def swift_lint(repo: Path) -> list[str]:
    errs = []
    for path in swift_files(repo):
        rel = str(path.relative_to(repo))
        try:
            # `.`borderedProminent`` is the same identifier; drop identifier backticks
            # (never spans a newline, so line numbers survive).
            code = re.sub(r"`([A-Za-z_][A-Za-z0-9_]*)`", r"\1", swift_code_only(path.read_text()))
        except SetupError as e:
            raise SetupError(f"{rel}: {e}")
        line_of = lambda pos: code.count("\n", 0, pos) + 1
        for m in PROMINENT.finditer(code):
            errs.append(f"{rel}:{line_of(m.start())}: `{m.group(0)}` draws a white label on the "
                        f"accent (2.39:1 in dark mode); use `.buttonStyle(ScarfPrimaryButton())`, "
                        f"which uses ScarfColor.onAccent (ScarfDesign/ScarfComponents.swift)")
        dcode = _blank_directives(code)
        for m in DEFAULT_ACTION.finditer(dcode):
            where = f"{rel}:{line_of(m.start())}"
            a, b = modifier_chain(dcode, m.start(), m.end(), where)
            styles = top_level_button_styles(dcode[a:b], where)
            if not any(SCARF_FILLED_STYLE.match(st) for st in styles):
                got = ", ".join(f".buttonStyle({st.strip()})" for st in styles) or "no .buttonStyle"
                errs.append(f"{where}: a `.keyboardShortcut(.defaultAction)` button ({got}) gets "
                            f"the system default-button look, a white label on the app accent; "
                            f"give it `.buttonStyle(ScarfPrimaryButton())` (or "
                            f"`ScarfDestructiveButton()`) in the same modifier chain")
        for m in SWIPE.finditer(dcode):
            where = f"{rel}:{line_of(m.start())}"
            # The closure is the first `{` after the modifier's argument list.
            j = m.end()
            k = _ws_fwd(dcode, j)
            if k < len(dcode) and dcode[k] == "(":
                j = _match_fwd(dcode, k, where)
            b = _ws_fwd(dcode, j)
            if b >= len(dcode) or dcode[b] != "{":
                raise SetupError(f"{where}: can't find the .swipeActions closure")
            k = _match_fwd(dcode, b, where)
            body = dcode[b + 1:k - 1]
            # Every `.tint(...)` anywhere in the closure must be allowlisted.
            for t in re.finditer(r"\.tint\s*\(", body):
                e = _match_fwd(body, t.end() - 1, where)
                arg = re.sub(r"\s+", "", body[t.end():e - 1])
                if arg not in SWIPE_TINT_ALLOWED:
                    errs.append(f"{rel}:{line_of(b + 1 + t.start())}: swipe action tint `{arg}` isn't "
                                f"in the allowlist ({', '.join(sorted(SWIPE_TINT_ALLOWED))}); the "
                                f"system draws a white label on it, which must clear AA in both "
                                f"appearances")
            # Every swipe Button must carry an allowlisted tint (untinted, the system uses
            # its red / the app tint, both under AA with a white label).
            for bt in SWIPE_BUTTON.finditer(body):
                end = chain_from_root(body, bt.end(), where)
                tints = top_level_args(body[bt.start():end], ".tint", where)
                if not tints:
                    errs.append(f"{rel}:{line_of(b + 1 + bt.start())}: swipe Button has no `.tint(...)`; "
                                f"the system default (red / app tint) is under AA with its white "
                                f"label. Use one of {', '.join(sorted(SWIPE_TINT_ALLOWED))}")
        errs += text_on_tint_lint(dcode, rel, line_of)
        for om in TOKEN_OPACITY.finditer(code):
            if float(om.group(1)) > 1:
                errs.append(f"{rel}:{line_of(om.start())}: `{om.group(0)}`: an opacity above 1 "
                            f"can't add density (a *Tint carries at most its own alpha); use the "
                            f"*Hue token for a stronger stroke or wash")
        for m in DANGER_SOLID_FILL.finditer(code):
            errs.append(f"{rel}:{line_of(m.start())}: `{m.group(0).rstrip(',)')})` fills with the "
                        f"text/icon danger color (white on its dark value is 3.27:1); fill with "
                        f"ScarfColor.dangerFill (+ onDanger for content)")
    return errs


# ---------------------------------------------------------------- checks

def contrast_failures(source: str, theme: str, c: dict[str, RGBA]) -> list[str]:
    errs: list[str] = []
    def need(what: str, fg: RGBA, bg: RGBA, minimum: float) -> None:
        r = contrast(fg, bg)
        if r + 1e-9 < minimum:
            errs.append(f"{source} [{theme}]: {what} is {r:.2f}:1 "
                        f"({hexstr(fg)} on {hexstr(bg)}), needs >= {minimum}:1")
    for state in ("accent", "accent-hover", "accent-active"):
        need(f"--on-accent on --{state}", c["on-accent"], c[state], TEXT_AA)
    for bgname in ("bg", "bg-card"):
        bg = c[bgname]
        for state in ("accent", "accent-hover", "accent-active"):
            need(f"--{state} text on --{bgname}", c[state], bg, TEXT_AA)
        need(f"--accent focus ring / border vs --{bgname}", c["accent"], bg, NON_TEXT)
        # Text-on-tint pairs the products draw: accent text on the tint (code,
        # badges), active text on the tint (app selected rows: accentActive on
        # accentTint), hover text on the strong tint (catalog `.tag`).
        for text, tint in (("accent", "accent-tint"), ("accent-active", "accent-tint"),
                           ("accent-hover", "accent-tint-strong")):
            if tint in c:
                need(f"--{text} text on --{tint} over --{bgname}", c[text], over(c[tint], bg), TEXT_AA)
    if "danger" in c:
        for bgname in ("bg", "bg-card"):
            need(f"--danger text on --{bgname}", c["danger"], c[bgname], TEXT_AA)
    if "danger-fill" in c and "on-danger" in c:
        need("--on-danger on --danger-fill", c["on-danger"], c["danger-fill"], TEXT_AA)
    elif "danger-fill" in c or "on-danger" in c:
        errs.append(f"{source} [{theme}]: --danger-fill and --on-danger must be defined together")
    surfaces = [("--bg", c["bg"]), ("--bg-card", c["bg-card"])]
    if "bg-tertiary" in c:
        surfaces.append(("--bg-tertiary", over(c["bg-tertiary"], c["bg"])))
    for text, tint in TEXT_ON_TINT:
        if tint in c and text not in c:
            errs.append(f"{source} [{theme}]: --{tint} needs --{text}")
            continue
        if text not in c:
            continue
        if c[text][3] < 1:
            errs.append(f"{source} [{theme}]: --{text} must be opaque ({hexstr(c[text])})")
        for name, bg in surfaces:
            need(f"--{text} text on --{name[2:]}", c[text], bg, TEXT_AA)
            need(f"--{text} dot / icon vs --{name[2:]}", c[text], bg, NON_TEXT)
            if tint in c:
                need(f"--{text} text on --{tint} over {name}", c[text], over(c[tint], bg), TEXT_AA)
        if "on-accent" in c:
            need(f"--on-accent on a solid --{text} fill", c["on-accent"], c[text], TEXT_AA)
        if tint in c and not 0 < c[tint][3] < 1:
            errs.append(f"{source} [{theme}]: --{tint} must be a translucent wash ({hexstr(c[tint])})")
    if "bg-tertiary" in c:
        tert = over(c["bg-tertiary"], c["bg"])
        if "danger" in c:
            need("--danger text on --bg-tertiary", c["danger"], tert, TEXT_AA)
        for state in ("accent", "accent-hover"):
            need(f"--{state} text on --bg-tertiary", c[state], tert, TEXT_AA)
        need("--accent focus ring / border vs --bg-tertiary", c["accent"], tert, NON_TEXT)
        for tint in ("accent-tint", "accent-tint-strong"):
            if tint in c:
                need(f"--accent-hover text on --{tint} over --bg-tertiary",
                     c["accent-hover"], over(c[tint], tert), TEXT_AA)
    return errs


def strip_swift_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def run(repo: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    notes: list[str] = []

    # Source of truth.
    truth: dict[str, dict[str, RGBA]] = {}
    for token, asset in TOKENS.items():
        truth[token] = read_colorset(repo / XCASSETS / f"{asset}.colorset")
    tertiary_cs = read_colorset(repo / XCASSETS / "Surface/BackgroundTertiary.colorset")
    for theme in ("light", "dark"):
        c = {t: v[theme] for t, v in truth.items()}
        c["bg-tertiary"] = tertiary_cs[theme]
        notes.append(f"xcassets [{theme}]: " + ", ".join(f"--{t} {hexstr(v)}" for t, v in c.items()))
        errors += contrast_failures("xcassets", theme, c)
    # The neutral badge / "other" tool chip: foregroundMuted on Status/NeutralTint over
    # each surface; and onAccent on every solid status / tool color (the verified
    # on-color for a solid status fill, lint rule below).
    muted = read_colorset(repo / XCASSETS / "Foreground/ForegroundMuted.colorset")
    neutral = read_colorset(repo / XCASSETS / "Status/NeutralTint.colorset")
    for theme in ("light", "dark"):
        surfaces = {"bg": truth["bg"][theme], "bg-card": truth["bg-card"][theme],
                    "bg-tertiary": tertiary_cs[theme]}
        if not 0 < neutral[theme][3] < 1:
            errors.append(f"xcassets [{theme}]: Status/NeutralTint must be translucent")
        for name, bg in surfaces.items():
            r = contrast(muted[theme], over(neutral[theme], bg))
            if r + 1e-9 < TEXT_AA:
                errors.append(f"xcassets [{theme}]: ForegroundMuted on NeutralTint over --{name} "
                              f"(neutral badge, other tool chip) is {r:.2f}:1, needs >= {TEXT_AA}:1")
        for tok in ("success", "warning", "info", "danger", "tool-web", "tool-search"):
            r = contrast(truth["on-accent"][theme], truth[tok][theme])
            if r + 1e-9 < TEXT_AA:
                errors.append(f"xcassets [{theme}]: onAccent on a solid --{tok} fill is {r:.2f}:1, "
                              f"needs >= {TEXT_AA}:1")
    # ScarfBadgeKind.fillAlpha / ScarfToolTone.washAlpha must equal the colorsets'.
    want_alpha = {("fillAlpha", "warning"): "Status/WarningTint", ("fillAlpha", "success"): "Status/SuccessTint",
                  ("fillAlpha", "info"): "Status/InfoTint", ("fillAlpha", "danger"): "Status/DangerTint",
                  ("fillAlpha", "neutral"): "Status/NeutralTint", ("fillAlpha", "brand"): "Accent/AccentTint",
                  ("washAlpha", "execute"): "Status/WarningTint", ("washAlpha", "other"): "Status/NeutralTint",
                  ("washAlpha", "default"): "Status/SuccessTint"}
    alpha_src = strip_swift_comments((repo / COMPONENTS_SWIFT).read_text())
    for (prop, case), asset in want_alpha.items():
        cs = read_colorset(repo / XCASSETS / f"{asset}.colorset")
        pm = re.search(rf"var\s+{prop}\s*:\s*Double\s*\{{(.*?)\n    \}}", alpha_src, re.S)
        got = pm and re.search(rf"(?:case[^\n]*\.{case}\b|{case})[^\n:]*:\s*return\s+([0-9.]+)", pm.group(1))
        if not got or any(abs(float(got.group(1)) - cs[t][3]) > ALPHA_TOLERANCE for t in ("light", "dark")):
            errors.append(f"{COMPONENTS_SWIFT}: {prop} for .{case} is "
                          f"{got.group(1) if got else '?'}, but {asset} has alpha {cs['light'][3]:g}")
    family = read_brand_family(repo, truth)
    DANGER_FAMILY[:] = read_danger_family(repo, truth)
    STATUS_FAMILY[:] = read_status_family(repo)

    # App (system) tint colorsets: see check 2 in the module docstring for why dark differs.
    tertiary = read_colorset(repo / XCASSETS / "Surface/BackgroundTertiary.colorset")
    white = (255, 255, 255, 1.0)
    for rel in APP_ACCENT_COLORSETS:
        cs = read_colorset(repo / rel)
        if not same(cs["light"], truth["accent"]["light"]):
            errors.append(f"{rel} [light] is {hexstr(cs['light'])}, but Accent/Accent is "
                          f"{hexstr(truth['accent']['light'])}")
        tint = cs["dark"]
        if tint[3] < 1:
            errors.append(f"{rel} [dark] is translucent ({hexstr(tint)}); the system tint must be opaque")
        r = contrast(white, tint)
        if r + 1e-9 < NON_TEXT:
            errors.append(f"{rel} [dark]: white glyphs on the system tint are {r:.2f}:1 "
                          f"({hexstr(tint)}), needs >= {NON_TEXT}:1")
        surfaces = (("--bg", truth["bg"]["dark"]), ("--bg-card", truth["bg-card"]["dark"]),
                    ("--bg-tertiary", over(tertiary["dark"], truth["bg"]["dark"])))
        for name, bg in surfaces:
            r = contrast(tint, bg)
            if r + 1e-9 < TEXT_AA:
                errors.append(f"{rel} [dark]: the system tint as text on {name} is {r:.2f}:1 "
                              f"({hexstr(tint)} on {hexstr(bg)}), needs >= {TEXT_AA}:1")
        notes.append(f"{rel} [dark] {hexstr(tint)}: white {contrast(white, tint):.2f}:1, text "
                     + " / ".join(f"{contrast(tint, bg):.2f}" for _, bg in surfaces))

    # ScarfTheme.swift must keep the semantic names bound to the semantic assets.
    if not (repo / THEME_SWIFT).is_file():
        raise SetupError(f"missing {THEME_SWIFT}")
    swift = strip_swift_comments((repo / THEME_SWIFT).read_text())
    for prop, asset in SWIFT_BINDINGS.items():
        pat = rf'\b(?:let|var)\s+{prop}\s*(?::\s*Color\s*)?=\s*(?:ScarfColor\.)?asset\("{re.escape(asset)}"\)'
        hits = re.findall(rf'\b(?:let|var)\s+{prop}\b', swift)
        if not re.search(pat, swift) or len(hits) != 1:
            errors.append(f"{THEME_SWIFT}: ScarfColor.{prop} must be declared once, as "
                          f"`asset(\"{asset}\")` (the semantic colorset), not an alias or a brand color")

    # ScarfBadgeKind and ScarfToolTone (badges, chips and every view that takes a tone)
    # must hand out the verified text-on-tint pairs.
    comp = repo / COMPONENTS_SWIFT
    if not comp.is_file():
        raise SetupError(f"missing {COMPONENTS_SWIFT}")
    csrc = strip_swift_comments(comp.read_text())
    status = {k: (f"ScarfColor.{k}", f"ScarfColor.{k}Tint") for k in STATUS_KINDS}
    tone_maps = (
        ("ScarfBadgeKind", ("text", "fill"), status),
        ("ScarfToolTone", ("color", "wash"), {
            "read": status["success"], "edit": status["info"], "execute": status["warning"],
            "fetch": ("ScarfColor.Tool.web", "ScarfColor.Tool.webTint"),
            "browser": ("ScarfColor.Tool.search", "ScarfColor.Tool.searchTint"),
            "other": ("ScarfColor.foregroundMuted", "ScarfColor.neutralTint")}),
    )
    for enum, props, mapping in tone_maps:
        em = re.search(rf"public enum {enum}\b", csrc)
        if not em:
            raise SetupError(f"{COMPONENTS_SWIFT}: no `public enum {enum}`")
        enum_body = csrc[em.end():csrc.find("\n}\n", em.end())]
        for idx, prop in enumerate(props):
            pm = re.search(rf"\bvar\s+{prop}\s*:\s*Color\s*\{{(.*?)\n    \}}", enum_body, re.S)
            if not pm:
                raise SetupError(f"{COMPONENTS_SWIFT}: {enum} has no `var {prop}: Color`")
            for case, pair in mapping.items():
                want = pair[idx]
                got = re.search(rf"case\s+\.{case}\s*:\s*return\s+([\w.]+(?:\([^)]*\))?)", pm.group(1))
                if not got or got.group(1) != want:
                    errors.append(f"{COMPONENTS_SWIFT}: {enum}.{prop} for .{case} is "
                                  f"`{got.group(1) if got else '?'}`, must be {want} (the pair "
                                  f"check 3 verifies)")

    # CSS mirrors.
    design_root: dict[str, str] = {}
    for rel in CSS_MIRRORS:
        path = repo / rel
        if not path.is_file():
            raise SetupError(f"missing {rel}")
        blocks, root, misplaced, rules = css_theme_blocks(path, rel, family)
        if rel == BRAND_SCALE_CSS:
            design_root = root
        errors += misplaced
        if "dark" not in {b[0] for b in blocks}:
            errors.append(f"{rel}: no dark theme block found")
        # With an unqualified `@media (prefers-color-scheme: dark) { :root {...} }`, a
        # [data-theme="light"] override sits on top of the DARK values when the OS is
        # dark, so it has to restate every token itself rather than inherit.
        dark_media_root = any(lbl == f"{DARK_MEDIA} :root" for _, lbl, _, _ in blocks)
        for theme, label, eff, own in blocks:
            where = f"{rel} {label}"
            if dark_media_root and theme == "light" and label != ":root":
                for token in REQUIRED + tuple(t for t in EXTRA_GUARDED if t in root):
                    if token not in own:
                        errors.append(f"{where}: must set --{token} itself — under OS dark mode it "
                                      f"would inherit the dark value from the media-query :root")
            resolved: dict[str, RGBA] = {}
            for token in tuple(TOKENS) + EXTRA_GUARDED:
                if token not in eff:
                    if token in REQUIRED:
                        errors.append(f"{where}: --{token} is not defined")
                    continue
                col = parse_css_color(resolve(eff[token], eff))
                if col is None:
                    errors.append(f"{where}: --{token}: can't parse `{eff[token]}`")
                    continue
                resolved[token] = col
                if token in TOKENS:
                    want = truth[token][theme]
                    if not same(col, want):
                        errors.append(f"{where}: --{token} is {hexstr(col)}, xcassets "
                                      f"{TOKENS[token]} ({theme}) is {hexstr(want)}")
            if all(t in resolved for t in REQUIRED):
                errors += contrast_failures(where, theme, resolved)
        errors += fill_lint(rules, root, family, rel)

    # Inline styles in the design system's previews and UI kit.
    errors += html_lint(repo, family, design_root)
    errors += jsx_lint(repo, family, design_root)

    # Swift: no system prominent button styles, no accent-tinted swipe actions.
    errors += swift_lint(repo)

    # The UI-kit bundle must carry the current sources. Checked LAST and collected,
    # not raised, so a stale or unreadable bundle never hides the lint results above.
    spec = importlib.util.spec_from_file_location(
        "refresh_ui_kit_bundle", Path(__file__).resolve().parent / "refresh-ui-kit-bundle.py")
    bundle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bundle)
    try:
        stale = bundle.stale_parts(repo)
    except bundle.BundleError as e:
        stale = None
        errors.append(f"{SETUP_PREFIX}ui-kit bundle: {e}")
    if stale:
        errors.append(f"ui-kit bundle is stale — run tools/refresh-ui-kit-bundle.py "
                      f"({', '.join(stale)} differ from design/static-site)")

    return errors, notes


SETUP_PREFIX = "setup error: "


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent,
                    help="repository root (default: this script's parent's parent)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the decoded tokens")
    args = ap.parse_args()
    try:
        errors, notes = run(args.repo.resolve())
    except (SetupError, json.JSONDecodeError, KeyError, ValueError, OSError) as e:
        print(f"check-design-tokens: setup error: {e}", file=sys.stderr)
        return 2
    if args.verbose:
        for n in notes:
            print(n)
    setup = any(e.startswith(SETUP_PREFIX) for e in errors)
    if errors:
        for e in errors:
            print(f"design-token check FAILED: {e}", file=sys.stderr)
        print(f"check-design-tokens: {len(errors)} failure(s). The xcassets under {XCASSETS} are "
              f"the source of truth; mirror them into the CSS, keep contrast at AA.", file=sys.stderr)
        return 2 if setup else 1
    print("check-design-tokens: OK — accent/on-accent/danger/status/bg tokens match the "
          f"xcassets in {len(CSS_MIRRORS)} stylesheets, every contrast pair (status text on "
          "its tint included) clears AA, no text sits on an accent or danger fill without "
          "--on-accent / --on-danger or on a status tint in a raw status color, and no Swift "
          "view uses a system prominent button style, an accent-tinted swipe action, or a "
          "semantic color as text on a wash of itself.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
