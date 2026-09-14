#!/usr/bin/env python3
"""Diff Scarf's hand-mirrored Hermes provider tables against hermes_cli source.

Scarf mirrors three tables out of hermes_cli/providers.py by hand; this script
turns the "reconcile on every Hermes bump" chore into a mechanical gate:

  1. ModelCatalogService.providerAliases   <->  ALIASES
     (identity entries like "lmstudio": "lmstudio" are skipped on the Hermes
     side — Scarf deliberately omits them)
  2. ModelPreflight.aggregatorProviders    <->  HERMES_OVERLAYS entries with
     is_aggregator=True
  3. ModelCatalogService.overlayOnlyProviders keys
                                           <->  HERMES_OVERLAYS keys that are
     absent from the models.dev cache (~/.hermes/models_dev_cache.json).
     "Missing from Scarf" fails (the picker can't reach that provider);
     "in Scarf but now also in models.dev" only warns (the catalog entry wins
     in loadProviders(), the overlay is dormant fallback); an entry that is
     neither a Hermes overlay nor a bundled plugin provider (lane 4's subject,
     which overlayOnlyProviders deliberately mirrors) fails as a stale
     provider. The lane cannot run without the cache file (fresh machine);
     that is a SKIP, and a skip is non-OK unless --allow-skip is passed.
  5. ModelCatalogService.capabilityProviderOverrides (+ providerAliases)
                                           <->  agent/models_dev.py
     PROVIDER_TO_MODELS_DEV. This is the SECOND provider table and it answers
     a different question from ALIASES: which models.dev catalog a provider's
     capability metadata lives in. The lane emulates Swift's
     `modelsDevProviderKey` (overrides, then providers.py-alias resolution,
     then overrides again) and FAILs on any Hermes entry Scarf resolves
     differently — that is how `meta-ai` -> `meta` and `opencode-free` ->
     `opencode` were silently missing. A Scarf override Hermes has no entry
     for only WARNs: `openai-api` used to be exactly that, a deliberate Scarf
     extension.
  4. Plugin-registered providers (plugins/model-providers/<name>/__init__.py)
     that hermes_cli/models_catalog_static.py:356-367 auto-appends to
     CANONICAL_PROVIDERS  <->  Scarf's reachable provider set (models.dev cache
     keys + overlayOnlyProviders + LocalModelProviders). WARNs — never FAILs —
     for a provider Scarf can't reach: these are bundled plugins, so the roster
     moves independently of providers.py and a hard gate here would block a
     release on someone else's plugin drop. A plugin name that is already a
     static CANONICAL_PROVIDERS slug is skipped (Hermes does not auto-append
     it), and reachability resolves through BOTH alias tables in either
     direction.

Usage:
    scripts/check-hermes-tables.py [path/to/hermes-agent]
                                   [--tag <tag> | --worktree] [--allow-skip]

The Hermes checkout defaults to $HERMES_SRC, then ~/.hermes/hermes-agent.

READ MODE. By default every Hermes file is read AT A TAG via
``git -C <checkout> show <tag>:<path>`` — never from the checkout's working
tree, which is whatever the last person left checked out (a reviewer's
`v2026.9.7-385-g9e6c4100cb` tree printed OK and meant nothing). The tag
defaults to ``HERMES_TARGET_TAG`` below, the ONE place this repo records the
tag Scarf targets; ``--tag`` overrides it and ``--worktree`` opts back into
reading the working tree for local development. The checkout is only ever
READ — no command here writes to it or moves its HEAD. The mode is printed in
the verdict line.

FAIL CLOSED. A lane that cannot run does NOT leave the verdict at OK: every
skip prints ``SKIPPED lane N`` and exits non-zero unless ``--allow-skip`` is
passed. A Hermes table that is present but not the shape a lane parses is a
hard error, not a skip — that is how a table rename would otherwise slip
through as a silent pass.

Exits 1 on any FAIL, 2 on a SKIPPED lane without --allow-skip, 0 on PASS/WARN.
"""

import argparse
import ast
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift")
PREFLIGHT_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift")
LOCAL_PROVIDERS_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/LocalModelProviders.swift")
DEFAULT_HERMES = os.environ.get(
    "HERMES_SRC", os.path.expanduser("~/.hermes/hermes-agent"))
MODELS_DEV_CACHE = os.path.expanduser("~/.hermes/models_dev_cache.json")

# The ONE place this repo records the Hermes tag Scarf targets, and the default
# `--tag`. Bump it in the same commit that bumps a capability floor in
# HermesCapabilities.swift; the audit trail for what the tag means lives in the
# `// MARK: vX.Y (<tag>) flags` sections there, not here.
HERMES_TARGET_TAG = "v2026.9.11"

failures = []
warnings = []
skipped = []


class HermesSource:
    """Reads Hermes files either at a git tag or from the checkout's work tree.

    Every lane goes through this instead of `open()` so the read mode is a
    single decision made once, in one place, and cannot be mode-correct in one
    lane and working-tree in another.
    """

    def __init__(self, checkout, tag=None):
        self.checkout = checkout
        self.tag = tag  # None => working tree

    @property
    def mode(self):
        return f"tag {self.tag}" if self.tag else f"WORKING TREE of {self.checkout}"

    def _git(self, *args):
        try:
            proc = subprocess.run(["git", "-C", self.checkout, *args],
                                  capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            sys.exit(f"error: git {' '.join(args)} failed in {self.checkout}: {exc}")
        return proc

    def read(self, relpath):
        """File contents, or None when the path doesn't exist at this revision."""
        if self.tag is None:
            full = os.path.join(self.checkout, relpath)
            if not os.path.exists(full):
                return None
            with open(full) as fh:
                return fh.read()
        proc = self._git("show", f"{self.tag}:{relpath}")
        return proc.stdout if proc.returncode == 0 else None

    def listdir(self, relpath):
        """Sorted entry names directly under `relpath`, or [] when it is absent."""
        if self.tag is None:
            full = os.path.join(self.checkout, relpath)
            if not os.path.isdir(full):
                return []
            return sorted(os.listdir(full))
        proc = self._git("ls-tree", "--name-only", f"{self.tag}:{relpath}")
        if proc.returncode != 0:
            return []
        return sorted(line.rstrip("/") for line in proc.stdout.splitlines() if line)

    def describe(self):
        """`git describe` of whatever is checked out, or None."""
        proc = self._git("describe", "--tags", "--always", "--dirty")
        return proc.stdout.strip() if proc.returncode == 0 else None

    def validate(self):
        """Fail fast on a checkout/tag that can't answer — never read a blank."""
        if not os.path.isdir(self.checkout):
            sys.exit(f"error: {self.checkout} is not a directory — pass the "
                     f"hermes-agent checkout path")
        if self.tag is None:
            return
        if self._git("rev-parse", "--verify", f"{self.tag}^{{commit}}").returncode != 0:
            sys.exit(f"error: tag '{self.tag}' does not exist in {self.checkout} "
                     f"— fetch it, or pass --worktree to read the working tree")


PROVIDERS_PY = "hermes_cli/providers.py"


def parse_hermes(src):
    """AST-walk providers.py for ALIASES and HERMES_OVERLAYS.

    ``ALIASES`` has had two shapes. Through v0.21.0 it was a dict literal
    ``{alias: canonical}``. At v0.21.1 (`hermes_cli/providers.py:117,139`) it
    became a dict COMPREHENSION inverting a new ``_ALIAS_GROUPS``
    ``{canonical: (alias, ...)}`` literal — walking `.keys`/`.values` on an
    `ast.DictComp` raises AttributeError. Both shapes are handled; the literal
    path stays so the script keeps working against older tags.
    """
    text = src.read(PROVIDERS_PY)
    if text is None:
        sys.exit(f"error: {PROVIDERS_PY} not found at {src.mode} — pass the "
                 f"hermes-agent checkout path")
    tree = ast.parse(text)
    aliases, alias_groups, overlay_keys, aggregators = {}, {}, [], set()
    aliases_shape = None
    for node in ast.walk(tree):
        if not isinstance(node, ast.AnnAssign):
            continue
        name = getattr(node.target, "id", "")
        if name == "_ALIAS_GROUPS":
            # {canonical: (alias, ...)} — invert exactly as Hermes does.
            for k, v in zip(node.value.keys, node.value.values):
                if not isinstance(v, (ast.Tuple, ast.List)):
                    continue
                for elt in v.elts:
                    if isinstance(elt, ast.Constant):
                        alias_groups[elt.value] = k.value
        elif name == "ALIASES":
            if isinstance(node.value, ast.Dict):
                aliases_shape = "dict"
                for k, v in zip(node.value.keys, node.value.values):
                    aliases[k.value] = v.value
            elif isinstance(node.value, ast.DictComp):
                # The v0.21.1+ inversion of `_ALIAS_GROUPS` — filled in below
                # (declaration order is not guaranteed here).
                aliases_shape = "comprehension"
            else:
                # A THIRD shape (a `dict(...)` call, a module-level merge, a
                # name alias). Falling through here used to leave `aliases`
                # empty and let the `alias_groups` fallback below quietly
                # substitute a DIFFERENT table's contents — the same
                # silent-substitute hole lane 5 was hardened against in P27.
                aliases_shape = "unknown"
        elif name == "HERMES_OVERLAYS":
            for k, v in zip(node.value.keys, node.value.values):
                overlay_keys.append(k.value)
                if isinstance(v, ast.Call):
                    for kw in v.keywords:
                        if (kw.arg == "is_aggregator"
                                and isinstance(kw.value, ast.Constant)
                                and kw.value.value is True):
                            aggregators.add(k.value)
    if aliases_shape == "unknown":
        sys.exit(f"error: ALIASES in {PROVIDERS_PY} at {src.mode} is neither a "
                 f"dict literal nor the _ALIAS_GROUPS comprehension — its shape "
                 f"changed and this script must be updated, not guessed past")
    if aliases_shape == "comprehension":
        # ONLY the comprehension shape may be answered from `_ALIAS_GROUPS`.
        aliases = alias_groups
    if not aliases or not overlay_keys:
        sys.exit(f"error: could not parse ALIASES/HERMES_OVERLAYS from "
                 f"{PROVIDERS_PY} at {src.mode}")
    return aliases, overlay_keys, aggregators


MODELS_DEV_PY = "agent/models_dev.py"


def parse_models_dev_map(src):
    """``PROVIDER_TO_MODELS_DEV`` from agent/models_dev.py (a plain annotated
    dict literal at v2026.9.7:108; :107 is the section comment above it).

    FAILS CLOSED, exactly as `parse_hermes` does for ALIASES: the only benign
    absence is the whole FILE being missing (a pre-v0.21 checkout), which
    returns None so lane 5 can record a SKIP. A file that exists but whose
    ``PROVIDER_TO_MODELS_DEV`` is gone or is no longer a plain ``ast.Dict``
    (a rename, a comprehension, a `dict(...)` call, a module-level merge) is a
    shape change, and a shape change must never read as "nothing to compare" —
    that is the hole that let the v0.21.1 `ALIASES` comprehension pass.
    """
    text = src.read(MODELS_DEV_PY)
    if text is None:
        return None
    tree = ast.parse(text)
    for node in ast.walk(tree):
        target = node.target if isinstance(node, ast.AnnAssign) else (
            node.targets[0] if isinstance(node, ast.Assign) and node.targets else None)
        if getattr(target, "id", "") != "PROVIDER_TO_MODELS_DEV":
            continue
        if not isinstance(node.value, ast.Dict):
            sys.exit(f"error: PROVIDER_TO_MODELS_DEV in {MODELS_DEV_PY} at {src.mode} "
                     f"is a {type(node.value).__name__}, not a dict literal — the "
                     f"table changed shape; teach lane 5 the new shape")
        pairs = {k.value: v.value for k, v in zip(node.value.keys, node.value.values)
                 if isinstance(k, ast.Constant) and isinstance(v, ast.Constant)}
        if not pairs:
            sys.exit(f"error: PROVIDER_TO_MODELS_DEV in {MODELS_DEV_PY} at {src.mode} "
                     f"parsed to zero literal entries — the table changed shape")
        return pairs
    sys.exit(f"error: PROVIDER_TO_MODELS_DEV not found in {MODELS_DEV_PY} at "
             f"{src.mode} — it was renamed or moved; teach lane 5 where it went")


# auth_type values models_catalog_static.py refuses to auto-append (they need
# bespoke picker UX). Mirrored verbatim from its skip set at v2026.9.7:360-362.
PLUGIN_PROVIDER_SKIP_AUTH = {
    "oauth_device_code", "oauth_external", "external_process", "aws_sdk",
    "copilot", "vertex",
}


def parse_plugin_providers(src):
    """Provider ids registered by bundled model-provider plugins.

    Mirrors `hermes_cli/models_catalog_static.py:356-367`: every provider a
    plugin passes to `register_provider()` whose `auth_type` isn't in the skip
    set is appended to CANONICAL_PROVIDERS at import time, so it reaches
    Hermes's picker with no edit to the static catalog.

    Static AST only — nothing is imported or executed. Returns
    (ids, skipped_plugin_dirs); a plugin whose provider name isn't a string
    literal (e.g. kimi-coding's factory) is reported rather than guessed at.
    """
    root = "plugins/model-providers"
    ids, skipped = [], set()
    for entry in src.listdir(root):
        init = src.read(f"{root}/{entry}/__init__.py")
        if init is None:
            continue
        try:
            tree = ast.parse(init)
        except SyntaxError:
            skipped.add(entry)
            continue
        # module-level `<var> = SomeProfile(name=..., auth_type=...)`
        assigned = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        assigned[target.id] = node.value
        registered_vars = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not node.args:
                continue
            # Both call shapes: the bare `register_provider(p)` every bundled
            # plugin uses today, and the attribute form `ctx.register_provider(p)`
            # the image_gen plugins already use for their own registry. Missing
            # the second would report a live provider as unreachable.
            func = node.func
            if isinstance(func, ast.Name):
                if func.id != "register_provider":
                    continue
            elif isinstance(func, ast.Attribute):
                if func.attr != "register_provider":
                    continue
            else:
                continue
            if isinstance(node.args[0], ast.Name):
                registered_vars.append(node.args[0].id)
            else:
                # Inline construction — no module-level binding to read the
                # name off. Report rather than drop it silently.
                skipped.add(entry)
        for var in registered_vars:
            call = assigned.get(var)
            kwargs = {kw.arg: kw.value for kw in call.keywords} if call else {}
            name_node = kwargs.get("name")
            if not isinstance(name_node, ast.Constant) or not isinstance(name_node.value, str):
                skipped.add(entry)
                continue
            auth_node = kwargs.get("auth_type")
            auth = auth_node.value if isinstance(auth_node, ast.Constant) else "api_key"
            if auth in PLUGIN_PROVIDER_SKIP_AUTH:
                continue
            ids.append(name_node.value)
    return ids, skipped


def parse_static_catalog(src):
    """(static CANONICAL_PROVIDERS slugs, _PROVIDER_ALIASES) from models_catalog_static.py.

    Two things lane 4 cannot get right without this file:

    * A plugin whose provider name is ALREADY a static ``CANONICAL_PROVIDERS``
      slug is NOT auto-appended — `models_catalog_static.py:360` skips any name
      already in ``_canonical_slugs``. ``gemini`` is exactly that case: the
      static row ("gemini", "Google AI Studio") predates the plugin, so
      reporting it as an unreachable *plugin* provider is simply wrong.
    * ``_PROVIDER_ALIASES`` is a SECOND, larger alias table than
      ``providers.py``'s ``ALIASES``, and it is the one that carries
      ``("google", "gemini")``. models.dev ships the provider under the
      ``google`` key (same endpoint, same GOOGLE_API_KEY/GEMINI_API_KEY), so
      Scarf reaches it — under Hermes's alias spelling, which Hermes resolves
      back to ``gemini`` on the way in.

    Returns ([], {}) when the file is absent (pre-v0.21.1 checkout), which
    leaves lane 4 behaving exactly as it did before.
    """
    # v0.21.1 split `hermes_cli/models.py` into models_catalog_static.py et al.
    # Read the new path first, then the old one — checking only the new path
    # against a pre-v0.21.1 checkout reports "absent" for a table that is very
    # much present, which is the exact trap this cycle kept hitting.
    text = next(
        (t for t in (src.read("hermes_cli/models_catalog_static.py"),
                     src.read("hermes_cli/models.py"))
         if t is not None),
        None)
    if text is None:
        return set(), {}
    tree = ast.parse(text)
    slugs, aliases = set(), {}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        name = next((getattr(t, "id", "") for t in targets), "")
        if name == "CANONICAL_PROVIDERS":
            # v0.21.1: [ProviderEntry(*row) for row in ( (slug, label, desc), ... )]
            for tup in ast.walk(node.value):
                if (isinstance(tup, ast.Tuple) and tup.elts
                        and isinstance(tup.elts[0], ast.Constant)
                        and isinstance(tup.elts[0].value, str) and len(tup.elts) == 3):
                    slugs.add(tup.elts[0].value)
            # Pre-v0.21.1: a list of explicit ProviderEntry("slug", ...) calls.
            for call in ast.walk(node.value):
                if (isinstance(call, ast.Call)
                        and getattr(call.func, "id", "") == "ProviderEntry"
                        and call.args and isinstance(call.args[0], ast.Constant)
                        and isinstance(call.args[0].value, str)):
                    slugs.add(call.args[0].value)
        elif name == "_PROVIDER_ALIASES":
            # v0.21.1: dict(( (alias, canonical), ... ))
            for tup in ast.walk(node.value):
                if (isinstance(tup, ast.Tuple) and len(tup.elts) == 2
                        and all(isinstance(e, ast.Constant) and isinstance(e.value, str)
                                for e in tup.elts)):
                    aliases[tup.elts[0].value] = tup.elts[1].value
            # Pre-v0.21.1: a plain {alias: canonical} dict literal.
            if isinstance(node.value, ast.Dict):
                for k, v in zip(node.value.keys, node.value.values):
                    if (isinstance(k, ast.Constant) and isinstance(k.value, str)
                            and isinstance(v, ast.Constant) and isinstance(v.value, str)):
                        aliases[k.value] = v.value
    return slugs, aliases


def swift_block(path, header, close_pattern=r"^\s*\]\s*$"):
    """Return the source lines between a declaration header and its closing bracket.

    Whole-line ``//`` comments are dropped: every lane below reads the block
    with a `"a": "b"` regex, and a doc comment that QUOTES an entry (as
    `capabilityProviderOverrides` does when it explains why `meta-ai` is
    there) is otherwise indistinguishable from the entry itself — deleting
    the real line then leaves the lane silently passing. Only lines that
    START with `//` are removed, so a `"https://…"` doc URL in a value
    survives intact.
    """
    lines = [l for l in open(path).read().splitlines()
             if not l.lstrip().startswith("//")]
    start = next((i for i, l in enumerate(lines) if header in l), None)
    if start is None:
        sys.exit(f"error: '{header}' not found in {path}")
    block = []
    for line in lines[start + 1:]:
        if re.match(close_pattern, line):
            return block
        block.append(line)
    sys.exit(f"error: unterminated block for '{header}' in {path}")


def check(lane, scarf, hermes, missing_msg, extra_msg):
    missing = sorted(set(hermes) - set(scarf))
    extra = sorted(set(scarf) - set(hermes))
    if missing:
        failures.append(f"[{lane}] {missing_msg}: {', '.join(missing)}")
    if extra:
        failures.append(f"[{lane}] {extra_msg}: {', '.join(extra)}")
    return not (missing or extra)


def build_parser():
    p = argparse.ArgumentParser(
        description="Diff Scarf's mirrored Hermes provider tables against hermes source.")
    p.add_argument("checkout", nargs="?", default=DEFAULT_HERMES,
                   help="hermes-agent checkout (default: $HERMES_SRC, then "
                        "~/.hermes/hermes-agent)")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--tag", default=HERMES_TARGET_TAG,
                      help=f"read Hermes files at this git tag via `git show` "
                           f"(default: {HERMES_TARGET_TAG})")
    mode.add_argument("--worktree", action="store_true",
                      help="read the checkout's working tree instead of a tag "
                           "(local development only — the result is only as "
                           "trustworthy as whatever is checked out)")
    p.add_argument("--allow-skip", action="store_true",
                   help="let a lane that cannot run (e.g. no models.dev cache) "
                        "leave the verdict at OK; the default is strict")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    # The verdict accumulators are module-level (every lane appends to them);
    # clear them so a second call in one process can't inherit the first's.
    del failures[:], warnings[:], skipped[:]
    src = HermesSource(args.checkout, None if args.worktree else args.tag)
    src.validate()
    print(f"reading hermes from {src.mode}")
    if src.tag is None:
        # In tag mode the tag IS the provenance; in worktree mode this line is
        # the only record of what was actually measured.
        desc = src.describe()
        if desc:
            print(f"working-tree version: {desc}")

    aliases, overlay_keys, aggregators = parse_hermes(src)

    # Lane 1: providerAliases <-> ALIASES (minus identity entries)
    hermes_aliases = {k: v for k, v in aliases.items() if k != v}
    swift_aliases = dict(
        re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"',
                   "\n".join(swift_block(CATALOG_SWIFT, "let providerAliases"))))
    check("aliases", swift_aliases, hermes_aliases,
          "Hermes ALIASES missing from providerAliases",
          "providerAliases entries not in Hermes ALIASES")
    wrong = {k: (swift_aliases[k], hermes_aliases[k])
             for k in swift_aliases if hermes_aliases.get(k) not in (None, swift_aliases[k])}
    for k, (got, want) in sorted(wrong.items()):
        failures.append(f"[aliases] '{k}' maps to '{got}' in Swift but '{want}' in Hermes")

    # Lane 2: aggregatorProviders <-> is_aggregator=True overlays
    swift_aggs = set(
        re.findall(r'"([^"]+)"',
                   "\n".join(swift_block(PREFLIGHT_SWIFT, "let aggregatorProviders"))))
    check("aggregators", swift_aggs, aggregators,
          "Hermes aggregators missing from ModelPreflight.aggregatorProviders",
          "aggregatorProviders entries Hermes doesn't mark is_aggregator")

    # Plugin-registered providers are lane 4's subject, but lane 3 needs the set
    # too: `overlayOnlyProviders` deliberately mirrors them, and they are not
    # HERMES_OVERLAYS entries, so without this they read as stale entries.
    static_slugs, static_aliases = parse_static_catalog(src)
    registered, plugin_skipped = parse_plugin_providers(src)
    plugin_provider_ids = set(registered)

    # Lane 3: overlayOnlyProviders keys <-> overlays absent from models.dev
    swift_overlays = set(
        re.findall(r'^\s*"([^"]+)"\s*:\s*HermesProviderOverlay\(',
                   "\n".join(swift_block(CATALOG_SWIFT, "let overlayOnlyProviders")),
                   re.MULTILINE))
    if os.path.exists(MODELS_DEV_CACHE):
        catalog_ids = set(json.load(open(MODELS_DEV_CACHE)).keys())
        expected = set(overlay_keys) - catalog_ids
        for pid in sorted(expected - swift_overlays):
            failures.append(
                f"[overlay-only] Hermes overlay '{pid}' isn't in models.dev or "
                f"overlayOnlyProviders — the picker can't reach it")
        for pid in sorted(swift_overlays - expected):
            if pid in overlay_keys:
                warnings.append(
                    f"[overlay-only] '{pid}' is now in models.dev; the Scarf overlay "
                    f"is dormant fallback (deliberate — kept for stale-cache hosts, "
                    f"see the entry's comment in ModelCatalogService.swift)")
            elif pid in plugin_provider_ids:
                pass  # A lane-4 entry: a bundled plugin provider, mirrored on purpose.
            else:
                failures.append(
                    f"[overlay-only] '{pid}' is not a Hermes overlay at all — stale entry")
    else:
        skipped.append(f"lane 3 (overlay-only): {MODELS_DEV_CACHE} not found — "
                       f"Hermes writes it on its first models.dev fetch "
                       f"(agent/models_dev.py), so use this host after Hermes "
                       f"has run once")

    # Lane 4: plugin-registered providers Hermes auto-appends to the picker
    if os.path.exists(MODELS_DEV_CACHE):
        catalog_ids = set(json.load(open(MODELS_DEV_CACHE)).keys())
        # `custom` (and ollama/vllm/llamacpp) are reachable through Scarf's
        # LOCAL-provider surface, not the models.dev picker — LocalModelProviders
        # writes model.provider for them. Counting only the picker would report a
        # provider the app fully supports.
        local_ids = set(re.findall(r'providerID:\s*"([^"]+)"',
                                   open(LOCAL_PROVIDERS_SWIFT).read()))
        reachable = catalog_ids | swift_overlays | local_ids
        # A plugin's own id is often an ALIAS of the canonical id the catalog
        # (and Scarf's picker) actually carries — plugin `ai-gateway` is
        # ALIASES["ai-gateway"] = "vercel". Resolve before reporting, or every
        # such provider is a false alarm. Both alias tables are consulted:
        # providers.py's ALIASES and models_catalog_static's larger
        # _PROVIDER_ALIASES (the one carrying google -> gemini). Aliases are
        # alias->canonical, so reachability is also checked in reverse: an id is
        # reachable when ANY spelling of it is.
        alias_spellings = {}
        for alias, canon in list(aliases.items()) + list(static_aliases.items()):
            alias_spellings.setdefault(canon, set()).add(alias)

        def is_reachable(pid):
            names = {pid, aliases.get(pid, pid), static_aliases.get(pid, pid)}
            names |= alias_spellings.get(pid, set())
            return bool(names & reachable)

        unreachable = {
            pid for pid in registered
            # A name already in the static CANONICAL_PROVIDERS list is not
            # auto-appended at all (models_catalog_static.py:360 skips it), so
            # it is not this lane's subject.
            if pid not in static_slugs and not is_reachable(pid)
        }
        for pid in sorted(unreachable):
            warnings.append(
                f"[plugin-providers] '{pid}' is registered under "
                f"plugins/model-providers/ and auto-appended to Hermes's "
                f"CANONICAL_PROVIDERS, but is absent from models.dev and from "
                f"overlayOnlyProviders — Scarf's picker can't reach it")
        if plugin_skipped:
            warnings.append(
                f"[plugin-providers] {len(plugin_skipped)} plugin(s) skipped (provider "
                f"name not a literal): {', '.join(sorted(plugin_skipped))}")
    else:
        skipped.append(f"lane 4 (plugin-providers): {MODELS_DEV_CACHE} not found — "
                       f"same cache as lane 3")

    # Lane 5: capabilityProviderOverrides <-> PROVIDER_TO_MODELS_DEV
    hermes_models_dev = parse_models_dev_map(src)
    swift_overrides = dict(
        re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"',
                   "\n".join(swift_block(CATALOG_SWIFT, "let capabilityProviderOverrides"))))
    if hermes_models_dev is not None:
        def models_dev_key(pid):
            """Swift `ModelCatalogService.modelsDevProviderKey`, in Python."""
            key = pid.strip().lower()
            if key in swift_overrides:
                return swift_overrides[key]
            canonical = swift_aliases.get(key, key)
            return swift_overrides.get(canonical, canonical)

        for hermes_id, mdev_id in sorted(hermes_models_dev.items()):
            got = models_dev_key(hermes_id)
            if got != mdev_id:
                failures.append(
                    f"[models-dev] '{hermes_id}' resolves to models.dev '{got}' in Swift "
                    f"but PROVIDER_TO_MODELS_DEV says '{mdev_id}' — add it to "
                    f"capabilityProviderOverrides")
        for pid in sorted(set(swift_overrides) - set(hermes_models_dev)):
            warnings.append(
                f"[models-dev] capabilityProviderOverrides['{pid}'] has no "
                f"PROVIDER_TO_MODELS_DEV entry — a deliberate Scarf extension "
                f"(see the table's doc comment) or a stale mirror")
    else:
        skipped.append(f"lane 5 (models-dev): {MODELS_DEV_PY} does not exist at "
                       f"{src.mode} — pre-v0.21 Hermes")

    for w in warnings:
        print(f"WARN  {w}")
    for s_ in skipped:
        print(f"SKIPPED {s_}")
    for f in failures:
        print(f"FAIL  {f}")
    counts = (f"aliases={len(swift_aliases)} aggregators={len(swift_aggs)} "
              f"overlays={len(swift_overlays)} lanes={5 - len(skipped)}/5")
    if failures:
        print(f"\n{len(failures)} failure(s) — reconcile the Swift tables against "
              f"{PROVIDERS_PY} at {src.mode}")
        sys.exit(1)
    # A skipped lane is NOT a pass. Two of five lanes silently disabled is how
    # an OK verdict becomes worthless on a fresh machine; say so and exit 2
    # unless the caller has explicitly accepted a partial run.
    if skipped and not args.allow_skip:
        print(f"\nNOT-OK {len(skipped)} lane(s) could not run — re-run once the "
              f"precondition above is met, or pass --allow-skip to accept a "
              f"partial check. {counts}, read from {src.mode}")
        sys.exit(2)
    verdict = "OK   " if not skipped else "OK*  "
    print(f"{verdict} {counts} read from {src.mode}"
          + (" (partial — --allow-skip)" if skipped else ""))


if __name__ == "__main__":
    main()
