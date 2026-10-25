#!/usr/bin/env python3
"""Tests for scripts/probe-hermes-routable-bands.py's tag handling.

Run from the repo root:

    python3 -m unittest discover -s scripts/tests -t .

From v0.21.6 Hermes tags releases `vX.Y.Z` (pyproject.toml says "0.0.0") and
interleaves release-candidate, canary and abandoned tags; the probe must walk
only the stable tags of both schemes and read a `vX.Y.Z` version off the name.
"""

import importlib.util
import os
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "probe-hermes-routable-bands.py")


def _load():
    spec = importlib.util.spec_from_file_location("probe_hermes_routable_bands", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


probe = _load()


class StableTags(unittest.TestCase):

    # Creator-date order, as `git tag --sort=creatordate` lists them.
    TAGS = [
        "v2026.9.21", "v2026.9.24", "abandoned-rc.6-v0.21.5", "rc.7-v0.21.5",
        "v0.21.4+canary.20260925T065930Z", "inputs-3", "rc.1-v0.21.6", "v0.21.6",
        "v0.21.6+canary.20261010T070026Z", "rc.15-v0.21.7", "v0.21.7",
        "backup/opentui-prestrip-20260616-1950", "v2026.8.16.2", "v0.22.5",
        "v0.22.5+canary.20261024T065630Z",
    ]

    def test_keeps_both_schemes_in_order_and_drops_the_rest(self):
        self.assertEqual(probe.stable_tags(self.TAGS),
                         ["v2026.9.21", "v2026.9.24", "v0.21.6", "v0.21.7",
                          "v2026.8.16.2", "v0.22.5"])

    def test_semver_tag_version_comes_from_the_name(self):
        # No checkout is touched for a `vX.Y.Z` tag: pyproject says 0.0.0 there.
        self.assertEqual(probe.version_of("/nonexistent", "v0.22.5"), (0, 22, 5))
        self.assertEqual(probe.version_of("/nonexistent", "v0.21.6"), (0, 21, 6))

    def test_a_date_tag_is_not_read_as_a_semver(self):
        self.assertIsNone(probe.SEMVER_TAG.fullmatch("v2026.9.24"))
        self.assertIsNotNone(probe.DATE_TAG.fullmatch("v2026.9.24"))


if __name__ == "__main__":
    unittest.main()
