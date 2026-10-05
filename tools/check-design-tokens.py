#!/usr/bin/env python3
"""Guard the Scarf accent tokens against drift and contrast regressions.

The asset catalog is the source of truth:

    scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfBrand.xcassets
        Accent/Accent, Accent/AccentHover, Accent/AccentActive,
        Accent/AccentTint, Accent/AccentTintStrong   -> --accent, --accent-hover,
                                                        --accent-active, --accent-tint,
                                                        --accent-tint-strong
        Foreground/OnAccent                          -> --on-accent
        Surface/BackgroundPrimary                    -> --bg
        Surface/BackgroundSecondary                  -> --bg-card

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
  2. The two app AccentColor colorsets (macOS + iOS) equal Accent/Accent, and
     ScarfTheme.swift (comments stripped) still binds ScarfColor.accent* / onAccent to
     those assets.
  3. WCAG 2.x contrast: on-accent on accent / hover / active >= 4.5; accent, hover and
     active as text on the page and card backgrounds >= 4.5; accent and active text on
     --accent-tint and hover text on --accent-tint-strong (composited over both) >= 4.5;
     accent as a focus ring / border vs both >= 3.0. Where a stylesheet defines
     --bg-tertiary (composited over --bg if translucent): accent and hover text on it
     >= 4.5, hover text on either tint over it >= 4.5 (tinted accent text on a tertiary
     surface uses the hover step), focus ring >= 3.0.
  4. Fill lint, in the CSS mirrors, the <style> blocks and style="" attributes of
     design/static-site/**/*.html, and the ui-kit .jsx style objects: a rule (or style
     object) whose background / background-color / background-image is an accent fill
     must not set a text color other than var(--on-accent). An accent fill is
     var(--accent|--accent-hover|--accent-active) (any spacing, with or without a
     fallback), anything that resolves to an accent-family color (brand-300..900 from
     colors_and_type.css plus the xcassets accent states), including gradients. The
     brand-50..200 pastels are not accent fills: they take dark text, not --on-accent.
     In .jsx only white text ('#fff' / '#FFF' / '#ffffff' / 'white') is flagged.

  5. The ui-kit bundle (design/static-site/ui-kit/index.html) is fresh: its embedded
     colors_and_type.css (ignoring the inlined @font-face swap for the Google Fonts
     @import) and each embedded .jsx equal the sources in design/static-site. Decoding
     is shared with tools/refresh-ui-kit-bundle.py, which fixes a stale bundle.

Known limitation: the fill lint only pairs declarations within one rule / style object.
A fill set on `.btn:hover` with the text color on `.btn` (or a JSX conditional that
splits them across objects) isn't paired. The ui-kit/index.html bundle is not scanned
(its sources are).

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
BRAND_SCALE_CSS = "design/static-site/colors_and_type.css"
CSS_MIRRORS = (
    "design/static-site/colors_and_type.css",
    "site/landing/styles.css",
    "site/styles.css",
)
DESIGN_HTML_ROOT = "design/static-site"
DESIGN_HTML_SKIP = {"design/static-site/ui-kit/index.html"}  # generated bundle
JSX_GLOB = "design/static-site/ui-kit/*.jsx"

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
}
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


def fill_lint(rules, scope, family, where) -> list[str]:
    errs = []
    for context, sel, body in rules:
        decls = declarations(body)
        fills = [v for p, v in decls if p in FILL_PROPS and is_accent_fill(v, scope, family)]
        if not fills:
            continue
        for p, v in decls:
            if p == "color" and re.sub(r"\s+", "", v) != "var(--on-accent)":
                errs.append(f"{where}: `{sel}` puts text color `{v}` on an accent fill "
                            f"(`{fills[0]}`); use var(--on-accent)")
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
            if fill and "color" in props and _JSX_WHITE.search(props["color"]):
                line = text.count("\n", 0, m.start()) + 1
                errs.append(f"{rel}:{line}: white text ({props['color'].strip()}) on an accent fill "
                            f"({fill.strip()}); use 'var(--on-accent)'")
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
    if "bg-tertiary" in c:
        tert = over(c["bg-tertiary"], c["bg"])
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
    for theme in ("light", "dark"):
        c = {t: v[theme] for t, v in truth.items()}
        notes.append(f"xcassets [{theme}]: " + ", ".join(f"--{t} {hexstr(v)}" for t, v in c.items()))
        errors += contrast_failures("xcassets", theme, c)
    family = read_brand_family(repo, truth)

    # App tint colorsets must equal the semantic accent.
    for rel in APP_ACCENT_COLORSETS:
        cs = read_colorset(repo / rel)
        for theme in ("light", "dark"):
            if not same(cs[theme], truth["accent"][theme]):
                errors.append(f"{rel} [{theme}] is {hexstr(cs[theme])}, but Accent/Accent is "
                              f"{hexstr(truth['accent'][theme])}")

    # ScarfTheme.swift must keep the semantic names bound to the semantic assets.
    if not (repo / THEME_SWIFT).is_file():
        raise SetupError(f"missing {THEME_SWIFT}")
    swift = strip_swift_comments((repo / THEME_SWIFT).read_text())
    for prop, asset in SWIFT_BINDINGS.items():
        pat = rf'\b(?:let|var)\s+{prop}\s*(?::\s*Color\s*)?=\s*asset\("{re.escape(asset)}"\)'
        hits = re.findall(rf'\b(?:let|var)\s+{prop}\b', swift)
        if not re.search(pat, swift) or len(hits) != 1:
            errors.append(f"{THEME_SWIFT}: ScarfColor.{prop} must be declared once, as "
                          f"`asset(\"{asset}\")` (the semantic colorset), not an alias or a brand color")

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

    # The UI-kit bundle must carry the current sources.
    spec = importlib.util.spec_from_file_location(
        "refresh_ui_kit_bundle", Path(__file__).resolve().parent / "refresh-ui-kit-bundle.py")
    bundle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bundle)
    try:
        stale = bundle.stale_parts(repo)
    except bundle.BundleError as e:
        raise SetupError(str(e))
    if stale:
        errors.append(f"ui-kit bundle is stale — run tools/refresh-ui-kit-bundle.py "
                      f"({', '.join(stale)} differ from design/static-site)")

    # Inline styles in the design system's previews and UI kit.
    errors += html_lint(repo, family, design_root)
    errors += jsx_lint(repo, family, design_root)
    return errors, notes


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
    if errors:
        for e in errors:
            print(f"design-token check FAILED: {e}", file=sys.stderr)
        print(f"check-design-tokens: {len(errors)} failure(s). The xcassets under {XCASSETS} are "
              f"the source of truth; mirror them into the CSS, keep contrast at AA.", file=sys.stderr)
        return 1
    print("check-design-tokens: OK — accent/on-accent/bg tokens match the xcassets in "
          f"{len(CSS_MIRRORS)} stylesheets, every contrast pair clears AA, and no text sits "
          "on an accent fill without --on-accent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
