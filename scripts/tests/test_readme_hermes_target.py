#!/usr/bin/env python3
"""The README's Hermes target must name the same tag the tooling targets.

Run from the repo root:

    python3 -m unittest discover -s scripts/tests -t .

`HERMES_TARGET_TAG` in `scripts/check-hermes-tables.py` is the ONE
machine-readable record of which Hermes release Scarf is audited against
(charter C2 — a finding is only real when cited at the tag). The README's
"Current target" line is the human-readable copy of the same fact, and it went
three releases stale (v0.20.4 / v2026.8.18 while the script said v2026.9.7)
before anyone noticed, because nothing tied the two together.

This ties them together: the README must name the script's tag, and the
compatibility table must have a row for the release that tag is.
"""

import importlib.util
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "check-hermes-tables.py")
README = os.path.join(REPO, "README.md")


def _target_tag() -> str:
    spec = importlib.util.spec_from_file_location("check_hermes_tables", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.HERMES_TARGET_TAG


def _readme() -> str:
    with open(README, encoding="utf-8") as f:
        return f.read()


class ReadmeHermesTargetTests(unittest.TestCase):
    def test_current_target_line_names_the_scripts_tag(self):
        """`Current target: **vX.Y.Z …** (<tag>)` must quote HERMES_TARGET_TAG."""
        tag = _target_tag()
        lines = [ln for ln in _readme().splitlines() if "Current target:" in ln]
        self.assertEqual(
            len(lines), 1,
            "expected exactly one README line naming the current Hermes target, "
            f"found {len(lines)}")
        self.assertIn(
            tag, lines[0],
            f"README 'Current target' line does not name {tag} "
            f"(scripts/check-hermes-tables.py HERMES_TARGET_TAG):\n  {lines[0].strip()}")

    def test_current_target_row_is_the_last_compatibility_table_row(self):
        """The table row marked the current target must name the same semver."""
        line = next(ln for ln in _readme().splitlines() if "Current target:" in ln)
        semver = re.search(r"\*\*v(\d+\.\d+(?:\.\d+)?)", line)
        self.assertIsNotNone(semver, f"no bolded version in: {line.strip()}")
        marked = [ln for ln in _readme().splitlines()
                  if ln.startswith("| v") and "current target" in ln]
        self.assertEqual(
            len(marked), 1,
            f"expected exactly one table row marked 'current target', found {len(marked)}")
        self.assertIn(
            f"v{semver.group(1)}", marked[0],
            f"the row marked current target is not v{semver.group(1)}:\n  {marked[0].strip()}")


if __name__ == "__main__":
    unittest.main()
