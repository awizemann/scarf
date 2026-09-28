#!/usr/bin/env python3
"""Measure, per Hermes tag, which `model.provider` names Hermes can route, and
check `HermesRoutableProviders.olderBands` against it (S06-F1).

`scripts/check-hermes-tables.py` lane 8 gates the CURRENT band statically. The
older bands can't be derived that way: the resolver changed shape several times
(no plugin registry before v2026.5.7, no `auth_plugin_providers.py` before
v2026.9.21). So this script asks each tag's OWN resolver. For every tag from
`--from-tag` on it:

  1. extracts the tag with `git archive` into a temp dir (the checkout is only
     read — no worktree, no checkout, nothing written to it);
  2. imports that tree's `hermes_cli.runtime_provider` with `--python` (a Hermes
     venv; one venv serves every tag so far), in a scratch HERMES_HOME with an
     empty environment, and calls `resolve_runtime_provider(requested=name)` for
     every candidate name: the models.dev cache keys, every name Scarf's tables
     mention, that tag's own registry and alias keys, and every id-shaped
     string literal in its resolver modules (older tags kept the alias table
     as a function local, invisible to attribute lookup);
  3. counts a name as routable unless it fails with "Unknown provider" /
     code `invalid_provider` (a missing-credential error means the name
     routed).

Then it rebuilds each tag's set from the Swift table and FAILS on any
difference. `--emit` prints the Swift `olderBands` literal instead.

Slow (a minute or so per tag) and needs a Hermes venv, so it is not part of
the fast gate. Released tags never change: re-run it only when adding a band,
i.e. when the current band moves (lane 8 fails) at a new Hermes tag.

Usage:
    scripts/probe-hermes-routable-bands.py --python ~/.hermes/hermes-agent-v0215/.venv/bin/python
        [--checkout ~/.hermes/hermes-agent] [--from-tag v2026.3.30] [--emit]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROUTABLE_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesRoutableProviders.swift")
CATALOG_SWIFT = os.path.join(
    REPO, "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift")
MODELS_DEV_CACHE = os.path.expanduser("~/.hermes/models_dev_cache.json")

PROBE = r'''
import json, logging, os, signal, sys
signal.alarm(300)
logging.disable(logging.CRITICAL)
sys.path.insert(0, os.getcwd())
names = set(json.load(open(sys.argv[1])))
from hermes_cli import auth
from hermes_cli import runtime_provider as rp
names |= set(getattr(auth, "PROVIDER_REGISTRY", {}))
try:
    names |= set(auth._plugin_aliases())
except Exception:
    pass
# Older tags kept the alias table as a LOCAL of resolve_provider, where no
# attribute lookup finds it. Over-include instead: every id-shaped string
# literal in the resolver's modules is probed (a non-provider is just
# "Unknown provider").
import ast, glob, re
ID = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,40}$")
for path in ["hermes_cli/auth.py", "hermes_cli/providers.py"] + glob.glob("hermes_cli/runtime_provider*.py"):
    if os.path.exists(path):
        for node in ast.walk(ast.parse(open(path).read())):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and ID.match(node.value):
                names.add(node.value)
routable = []
for name in sorted(names):
    try:
        rp.resolve_runtime_provider(requested=name)
    except Exception as exc:
        if "Unknown provider" in str(exc) or getattr(exc, "code", "") == "invalid_provider":
            continue
    routable.append(name)
print(json.dumps(routable))
'''


def git(checkout, *args):
    return subprocess.run(["git", "-C", checkout, *args], capture_output=True,
                          text=True, timeout=120, check=True).stdout


def version_of(checkout, tag):
    text = git(checkout, "show", f"{tag}:pyproject.toml")
    match = re.search(r'^version = "(\d+)\.(\d+)\.(\d+)', text, re.M)
    if not match:
        sys.exit(f"error: no version in {tag}:pyproject.toml")
    return tuple(int(p) for p in match.groups())


def swift_tables():
    """(current set, [(below, tag, added, removed)]) parsed from the Swift file."""
    text = open(ROUTABLE_SWIFT).read()
    current = text[text.index("static let providerIDs: Set<String> = ["):]
    current = set(re.findall(r'"([^"]+)"', current[:current.index("\n    ]")]))
    bands = []
    for m in re.finditer(
            r'below: \.init\(major: (\d+), minor: (\d+), patch: (\d+)\), tag: "([^"]+)",'
            r'\s*added: \[(.*?)\],\s*removed: \[(.*?)\]', text, re.S):
        bands.append(((int(m[1]), int(m[2]), int(m[3])), m[4],
                      set(re.findall(r'"([^"]+)"', m[5])), set(re.findall(r'"([^"]+)"', m[6]))))
    if not current or not bands:
        sys.exit(f"error: couldn't parse providerIDs / olderBands in {ROUTABLE_SWIFT}")
    return current, bands


def swift_set_for(version, current, bands):
    ids = set(current)
    for below, _, added, removed in bands:
        if version < below:
            ids -= added
            ids |= removed
    return ids


def candidates(current, bands):
    names = set(current)
    for _, _, added, removed in bands:
        names |= added | removed
    names |= set(re.findall(r'^\s*"([^"]+)"\s*:\s*HermesProviderOverlay\(',
                            open(CATALOG_SWIFT).read(), re.M))
    if not os.path.exists(MODELS_DEV_CACHE):
        # Fail closed: without it the models.dev keys an old tag routes are
        # never probed, and the check could pass on a partial universe.
        sys.exit(f"error: {MODELS_DEV_CACHE} not found — run Hermes once so it "
                 f"writes the models.dev cache, then re-run")
    return names | set(json.load(open(MODELS_DEV_CACHE)))


def probe(checkout, tag, python, cands_path):
    with tempfile.TemporaryDirectory(prefix="hermes-band-") as tmp:
        src, home = os.path.join(tmp, "src"), os.path.join(tmp, "home")
        os.makedirs(src)
        os.makedirs(home)
        archive = subprocess.run(["git", "-C", checkout, "archive", tag],
                                 capture_output=True, timeout=300, check=True).stdout
        subprocess.run(["tar", "-x", "-C", src], input=archive, check=True, timeout=300)
        script = os.path.join(tmp, "probe.py")
        with open(script, "w") as fh:
            fh.write(PROBE)
        env = {"PATH": "/usr/bin:/bin", "HOME": home, "HERMES_HOME": home,
               "AWS_EC2_METADATA_DISABLED": "true", "NO_PROXY": "*"}
        proc = subprocess.run([python, script, cands_path], cwd=src, env=env,
                              capture_output=True, text=True, timeout=600)
        if proc.returncode != 0:
            sys.exit(f"error: probe failed at {tag}:\n{proc.stderr[-2000:]}")
        return set(json.loads(proc.stdout.strip().splitlines()[-1]))


def swift_list(names, indent):
    """A Swift string-array literal wrapped at ~104 columns, as checked in."""
    if not names:
        return "[]"
    lines, line = [], indent + "    "
    for name in names:
        token = f'"{name}", '
        if len(line) + len(token) > 104:
            lines.append(line.rstrip())
            line = indent + "    "
        line += token
    lines.append(line.rstrip().rstrip(","))
    return "[\n" + "\n".join(lines) + "\n" + indent + "]"


def emit(tags, sets, versions):
    """Print the `olderBands` body exactly as HermesRoutableProviders.swift holds it."""
    rows, ind = [], " " * 8
    for prev, tag in zip(tags, tags[1:]):
        added, removed = sorted(sets[tag] - sets[prev]), sorted(sets[prev] - sets[tag])
        if added or removed:
            major, minor, patch = versions[tag]
            rows.append(
                f"{ind}Band(\n{ind}    below: .init(major: {major}, minor: {minor}, patch: {patch}), "
                f'tag: "{tag}",\n{ind}    added: {swift_list(added, ind + "    ")},\n'
                f"{ind}    removed: {swift_list(removed, ind + '    ')}\n{ind}),")
    print("\n".join(reversed(rows)))
    latest = tags[-1]
    print(f"// providerIDs at {latest}: {len(sets[latest])} names", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--python", required=True, help="python of a Hermes venv")
    ap.add_argument("--checkout", default=os.path.expanduser("~/.hermes/hermes-agent"))
    ap.add_argument("--from-tag", default="v2026.3.30")
    ap.add_argument("--emit", action="store_true", help="print olderBands instead of checking")
    args = ap.parse_args()

    tags = [t for t in git(args.checkout, "tag", "--sort=creatordate").split()
            if re.fullmatch(r"v\d{4}\.\d+\.\d+(\.\d+)?", t)]
    if args.from_tag not in tags:
        sys.exit(f"error: {args.from_tag} is not a tag in {args.checkout}")
    tags = tags[tags.index(args.from_tag):]
    current, bands = swift_tables()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(sorted(candidates(current, bands)), fh)
        cands_path = fh.name
    try:
        versions = {t: version_of(args.checkout, t) for t in tags}
        sets = {}
        for tag in tags:
            sets[tag] = probe(args.checkout, tag, args.python, cands_path)
            print(f"{tag} ({'.'.join(map(str, versions[tag]))}): {len(sets[tag])} routable",
                  file=sys.stderr)
    finally:
        os.unlink(cands_path)
    if args.emit:
        emit(tags, sets, versions)
        return
    failures = 0
    for tag in tags:
        want, got = sets[tag], swift_set_for(versions[tag], current, bands)
        if want != got:
            failures += 1
            print(f"FAIL  {tag}: missing {sorted(want - got)} extra {sorted(got - want)}")
    if failures:
        sys.exit(1)
    print(f"OK    {len(tags)} tags from {tags[0]} to {tags[-1]} match HermesRoutableProviders")


if __name__ == "__main__":
    main()
