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
     in loadProviders(), the overlay is dormant fallback); an entry that isn't
     a Hermes overlay at all fails (stale provider). Lane skipped when the
     cache file is absent (fresh machine).

Usage:
    scripts/check-hermes-tables.py [path/to/hermes-agent]

The Hermes checkout defaults to $HERMES_SRC, then ~/.hermes/hermes-agent.
Check the checkout out at the tag Scarf targets (see HermesCapabilities.swift)
before trusting the result. Exits 1 on any FAIL, 0 on PASS/WARN.
"""

import ast
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift")
PREFLIGHT_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift")
DEFAULT_HERMES = os.environ.get(
    "HERMES_SRC", os.path.expanduser("~/.hermes/hermes-agent"))
MODELS_DEV_CACHE = os.path.expanduser("~/.hermes/models_dev_cache.json")

failures = []
warnings = []


def parse_hermes(providers_py):
    """AST-walk providers.py for ALIASES and HERMES_OVERLAYS."""
    tree = ast.parse(open(providers_py).read())
    aliases, overlay_keys, aggregators = {}, [], set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.AnnAssign):
            continue
        name = getattr(node.target, "id", "")
        if name == "ALIASES":
            for k, v in zip(node.value.keys, node.value.values):
                aliases[k.value] = v.value
        elif name == "HERMES_OVERLAYS":
            for k, v in zip(node.value.keys, node.value.values):
                overlay_keys.append(k.value)
                if isinstance(v, ast.Call):
                    for kw in v.keywords:
                        if (kw.arg == "is_aggregator"
                                and isinstance(kw.value, ast.Constant)
                                and kw.value.value is True):
                            aggregators.add(k.value)
    if not aliases or not overlay_keys:
        sys.exit(f"error: could not parse ALIASES/HERMES_OVERLAYS from {providers_py}")
    return aliases, overlay_keys, aggregators


def swift_block(path, header, close_pattern=r"^\s*\]\s*$"):
    """Return the source lines between a declaration header and its closing bracket."""
    lines = open(path).read().splitlines()
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


def main():
    hermes_src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_HERMES
    if len(sys.argv) <= 1:
        # Make checkout drift visible when relying on the default path.
        print(f"using default hermes-agent checkout: {hermes_src}")
        import subprocess
        try:
            desc = subprocess.run(
                ["git", "-C", hermes_src, "describe", "--tags", "--always"],
                capture_output=True, text=True, timeout=10)
            if desc.returncode == 0:
                print(f"checkout version: {desc.stdout.strip()}")
        except OSError:
            pass
    providers_py = os.path.join(hermes_src, "hermes_cli/providers.py")
    if not os.path.exists(providers_py):
        sys.exit(f"error: {providers_py} not found — pass the hermes-agent checkout path")

    aliases, overlay_keys, aggregators = parse_hermes(providers_py)

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
            else:
                failures.append(
                    f"[overlay-only] '{pid}' is not a Hermes overlay at all — stale entry")
    else:
        warnings.append(f"[overlay-only] skipped — {MODELS_DEV_CACHE} not found")

    for w in warnings:
        print(f"WARN  {w}")
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"\n{len(failures)} failure(s) — reconcile the Swift tables against {providers_py}")
        sys.exit(1)
    print(f"OK    aliases={len(swift_aliases)} aggregators={len(swift_aggs)} "
          f"overlays={len(swift_overlays)} checked against {hermes_src}")


if __name__ == "__main__":
    main()
