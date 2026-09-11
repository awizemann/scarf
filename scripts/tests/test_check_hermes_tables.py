#!/usr/bin/env python3
"""Fail-closed tests for scripts/check-hermes-tables.py.

Run from the repo root:

    python3 -m unittest discover -s scripts/tests -t .

The script's whole value is that its `OK` means something, so these tests are
all about the ways it used to say OK when it should not have:

  * lane 5 returning `{}` for a table that changed SHAPE (the v0.21.1 `ALIASES`
    dict-comprehension trap, one table over);
  * lanes 3 and 4 WARN-skipping on a machine with no models.dev cache while the
    script still printed OK and exited 0 — two of five lanes silently off;
  * reading the hermes checkout's WORKING TREE, so the verdict described
    whatever someone had left checked out rather than the tag Scarf targets.
"""

import importlib.util
import os
import subprocess
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "check-hermes-tables.py")


def _load():
    """Import the hyphenated script as a module."""
    spec = importlib.util.spec_from_file_location("check_hermes_tables", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cht = _load()


class FakeSource:
    """Minimal HermesSource stand-in: a path -> text map."""

    mode = "fake"

    def __init__(self, files):
        self.files = files

    def read(self, relpath):
        return self.files.get(relpath)

    def listdir(self, relpath):
        return []


class LaneFiveFailsClosed(unittest.TestCase):
    """`parse_models_dev_map` must exit non-zero on any shape it can't parse."""

    def _exit_code(self, source_text):
        src = FakeSource({cht.MODELS_DEV_PY: source_text})
        with self.assertRaises(SystemExit) as ctx:
            cht.parse_models_dev_map(src)
        # sys.exit("message") carries the string; its process exit status is 1.
        return ctx.exception.code

    def test_dict_literal_parses(self):
        src = FakeSource({
            cht.MODELS_DEV_PY: 'PROVIDER_TO_MODELS_DEV: dict = {"meta-ai": "meta"}\n'})
        self.assertEqual(cht.parse_models_dev_map(src), {"meta-ai": "meta"})

    def test_dict_call_is_not_a_silent_empty(self):
        # `dict(...)` is an ast.Call, not an ast.Dict — the old code `continue`d
        # past it and the lane WARNed "not found" while exiting 0.
        code = self._exit_code('PROVIDER_TO_MODELS_DEV: dict = dict([("a", "b")])\n')
        self.assertNotEqual(code, 0)
        self.assertIn("not a dict literal", str(code))

    def test_dict_comprehension_is_not_a_silent_empty(self):
        code = self._exit_code(
            'PROVIDER_TO_MODELS_DEV: dict = {k: v for k, v in _PAIRS}\n')
        self.assertNotEqual(code, 0)
        self.assertIn("not a dict literal", str(code))

    def test_renamed_table_is_not_a_silent_empty(self):
        code = self._exit_code('PROVIDER_TO_MODELS_DEV_V2: dict = {"a": "b"}\n')
        self.assertNotEqual(code, 0)
        self.assertIn("not found", str(code))

    def test_nonliteral_entries_are_not_a_silent_empty(self):
        code = self._exit_code(
            'PROVIDER_TO_MODELS_DEV: dict = {**_BASE}\n')
        self.assertNotEqual(code, 0)

    def test_absent_file_is_a_skip_not_an_error(self):
        # Only the whole FILE being gone is benign (pre-v0.21 checkout); the
        # caller turns None into a SKIPPED lane.
        self.assertIsNone(cht.parse_models_dev_map(FakeSource({})))


class AliasesShapeFailsClosed(unittest.TestCase):
    """Lane 1's `ALIASES` arm has the hole lane 5's was hardened against.

    Through v0.21.0 `ALIASES` is a dict literal; at v0.21.1 it is a dict
    comprehension inverting `_ALIAS_GROUPS`. A THIRD shape used to fall
    through the `elif` silently, leaving `aliases` empty — and the
    `if not aliases: aliases = alias_groups` fallback below then supplied a
    DIFFERENT table's contents, so the lane compared Scarf against
    `_ALIAS_GROUPS` while reporting on `ALIASES`.
    """

    OVERLAYS = 'HERMES_OVERLAYS: dict = {"o": Overlay()}\n'

    def _parse(self, aliases_src, groups_src=""):
        return cht.parse_hermes(FakeSource({
            cht.PROVIDERS_PY: groups_src + aliases_src + self.OVERLAYS}))

    def test_dict_literal_is_used_verbatim(self):
        aliases, _, _ = self._parse('ALIASES: dict = {"ai-gateway": "vercel"}\n')
        self.assertEqual(aliases, {"ai-gateway": "vercel"})

    def test_comprehension_is_answered_from_alias_groups(self):
        aliases, _, _ = self._parse(
            "ALIASES: dict = {a: c for c, g in _ALIAS_GROUPS.items() for a in g}\n",
            '_ALIAS_GROUPS: dict = {"vercel": ("ai-gateway",)}\n')
        self.assertEqual(aliases, {"ai-gateway": "vercel"})

    def test_a_third_shape_is_not_silently_answered_from_alias_groups(self):
        # `dict(...)` is an ast.Call. Before the fix this returned
        # `_ALIAS_GROUPS`'s contents — a wrong table, reported as `ALIASES`.
        with self.assertRaises(SystemExit) as ctx:
            self._parse('ALIASES: dict = dict(_PAIRS)\n',
                        '_ALIAS_GROUPS: dict = {"vercel": ("ai-gateway",)}\n')
        self.assertNotEqual(ctx.exception.code, 0)
        self.assertIn("neither a dict literal", str(ctx.exception.code))

    def test_a_renamed_table_is_not_silently_answered_from_alias_groups(self):
        with self.assertRaises(SystemExit) as ctx:
            self._parse('ALIASES_V2: dict = {"a": "b"}\n',
                        '_ALIAS_GROUPS: dict = {"vercel": ("ai-gateway",)}\n')
        self.assertNotEqual(ctx.exception.code, 0)

    def test_an_empty_dict_literal_is_still_an_error_not_a_substitution(self):
        # `ALIASES = {}` is a shape we understand but a table we cannot use;
        # it must not be back-filled from `_ALIAS_GROUPS` either.
        with self.assertRaises(SystemExit) as ctx:
            self._parse("ALIASES: dict = {}\n",
                        '_ALIAS_GROUPS: dict = {"vercel": ("ai-gateway",)}\n')
        self.assertNotEqual(ctx.exception.code, 0)


def _git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True,
                   capture_output=True, text=True)


class TagReadsFromGitShow(unittest.TestCase):
    """`--tag` must read the TAGGED blob, never the working tree."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.addCleanup(self.tmp.cleanup)
        os.makedirs(os.path.join(self.repo, "hermes_cli"))
        os.makedirs(os.path.join(self.repo, "plugins/model-providers/tagged-plugin"))
        self._write("hermes_cli/providers.py", '''
            _ALIAS_GROUPS: dict = {"vercel": ("ai-gateway",)}
            ALIASES: dict = {a: c for c, group in _ALIAS_GROUPS.items() for a in group}
            HERMES_OVERLAYS: dict = {"tagged-overlay": Overlay(is_aggregator=True)}
        ''')
        self._write("plugins/model-providers/tagged-plugin/__init__.py", "x = 1\n")
        _git(self.repo, "init", "-q")
        _git(self.repo, "config", "user.email", "t@example.com")
        _git(self.repo, "config", "user.name", "t")
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-qm", "tagged state")
        _git(self.repo, "tag", "v-test")
        # Now make the working tree diverge — this is the reviewer's checkout.
        self._write("hermes_cli/providers.py", '''
            _ALIAS_GROUPS: dict = {"worktree-canon": ("worktree-alias",)}
            ALIASES: dict = {a: c for c, group in _ALIAS_GROUPS.items() for a in group}
            HERMES_OVERLAYS: dict = {"worktree-overlay": Overlay()}
        ''')
        os.makedirs(os.path.join(self.repo, "plugins/model-providers/worktree-plugin"))
        self._write("plugins/model-providers/worktree-plugin/__init__.py", "x = 1\n")

    def _write(self, relpath, body):
        with open(os.path.join(self.repo, relpath), "w") as fh:
            fh.write(textwrap.dedent(body))

    def test_tag_mode_sees_the_tagged_blob(self):
        src = cht.HermesSource(self.repo, "v-test")
        src.validate()
        aliases, overlays, aggregators = cht.parse_hermes(src)
        self.assertEqual(aliases, {"ai-gateway": "vercel"})
        self.assertEqual(overlays, ["tagged-overlay"])
        self.assertEqual(aggregators, {"tagged-overlay"})
        self.assertEqual(src.listdir("plugins/model-providers"), ["tagged-plugin"])
        self.assertIn("tag v-test", src.mode)

    def test_worktree_mode_sees_the_working_tree(self):
        src = cht.HermesSource(self.repo, None)
        aliases, overlays, _ = cht.parse_hermes(src)
        self.assertEqual(aliases, {"worktree-alias": "worktree-canon"})
        self.assertEqual(overlays, ["worktree-overlay"])
        self.assertEqual(src.listdir("plugins/model-providers"),
                         ["tagged-plugin", "worktree-plugin"])
        self.assertIn("WORKING TREE", src.mode)

    def test_unknown_tag_exits_rather_than_reading_a_blank(self):
        src = cht.HermesSource(self.repo, "v-does-not-exist")
        with self.assertRaises(SystemExit) as ctx:
            src.validate()
        self.assertIn("does not exist", str(ctx.exception.code))

    def test_the_checkout_is_never_written_to(self):
        before = subprocess.run(["git", "-C", self.repo, "status", "--porcelain"],
                                capture_output=True, text=True).stdout
        head = subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout
        src = cht.HermesSource(self.repo, "v-test")
        src.validate()
        cht.parse_hermes(src)
        cht.parse_plugin_providers(src)
        cht.parse_static_catalog(src)
        self.assertEqual(
            before,
            subprocess.run(["git", "-C", self.repo, "status", "--porcelain"],
                           capture_output=True, text=True).stdout)
        self.assertEqual(
            head,
            subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"],
                           capture_output=True, text=True).stdout)


HERMES_CHECKOUT = cht.DEFAULT_HERMES


def _target_tag_available():
    if not os.path.isdir(HERMES_CHECKOUT):
        return False
    return subprocess.run(
        ["git", "-C", HERMES_CHECKOUT, "rev-parse", "--verify",
         f"{cht.HERMES_TARGET_TAG}^{{commit}}"],
        capture_output=True).returncode == 0


# The script's own policy is that a lane which cannot run is NOT a pass unless
# the operator opts in with `--allow-skip` (P27). These tests are the same
# claim one level up: on a machine with no hermes-agent checkout at the target
# tag, `skipUnless` used to make the whole run print OK — a green suite that
# exercised none of the end-to-end lanes, which is exactly the "skip reads as
# pass" hole P27 closed inside the script. So the missing checkout FAILS, and
# `SCARF_ALLOW_SKIP=1` is the test-runner spelling of `--allow-skip`.
ALLOW_SKIP = os.environ.get("SCARF_ALLOW_SKIP") == "1"


def _require_target_checkout(case):
    if _target_tag_available():
        return
    reason = (f"needs a hermes-agent checkout at {HERMES_CHECKOUT} carrying "
              f"{cht.HERMES_TARGET_TAG}; set SCARF_ALLOW_SKIP=1 to accept a "
              f"partial run")
    if ALLOW_SKIP:
        case.skipTest(reason)
    case.fail(reason)


class SkippedLaneIsNotAPass(unittest.TestCase):
    """A lane that cannot run must make the overall verdict non-OK by default."""

    def setUp(self):
        _require_target_checkout(self)
        self._real_cache = cht.MODELS_DEV_CACHE
        # Point the models.dev cache at a path that cannot exist: lanes 3 and 4
        # then cannot run, exactly as on a fresh machine.
        cht.MODELS_DEV_CACHE = os.path.join(
            tempfile.gettempdir(), "check-hermes-tables-absent-cache.json")
        self.assertFalse(os.path.exists(cht.MODELS_DEV_CACHE))
        self.addCleanup(setattr, cht, "MODELS_DEV_CACHE", self._real_cache)

    def _run(self, *flags):
        out, err = StringIO(), StringIO()
        code = 0
        with redirect_stdout(out), redirect_stderr(err):
            try:
                cht.main([HERMES_CHECKOUT, "--tag", cht.HERMES_TARGET_TAG, *flags])
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
        return code, out.getvalue() + err.getvalue()

    def test_missing_cache_is_non_zero_by_default(self):
        code, text = self._run()
        self.assertNotEqual(code, 0, text)
        self.assertIn("SKIPPED lane 3", text)
        self.assertIn("SKIPPED lane 4", text)
        self.assertIn("NOT-OK", text)

    def test_allow_skip_accepts_the_partial_run(self):
        code, text = self._run("--allow-skip")
        self.assertEqual(code, 0, text)
        self.assertIn("SKIPPED lane 3", text)
        self.assertIn("partial", text)

    def test_full_run_at_the_target_tag_is_ok(self):
        cht.MODELS_DEV_CACHE = self._real_cache
        if not os.path.exists(cht.MODELS_DEV_CACHE):
            reason = ("no models.dev cache on this machine; set "
                      "SCARF_ALLOW_SKIP=1 to accept a partial run")
            if ALLOW_SKIP:
                self.skipTest(reason)
            self.fail(reason)
        code, text = self._run()
        self.assertEqual(code, 0, text)
        self.assertIn("lanes=5/5", text)
        self.assertIn(f"tag {cht.HERMES_TARGET_TAG}", text)


if __name__ == "__main__":
    unittest.main()
