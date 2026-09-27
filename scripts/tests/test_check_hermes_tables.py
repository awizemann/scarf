#!/usr/bin/env python3
"""Fail-closed tests for scripts/check-hermes-tables.py.

Run from the repo root:

    python3 -m unittest discover -s scripts/tests -t .

The script's whole value is that its `OK` means something, so these tests are
all about the ways it used to say OK when it should not have:

  * lane 5 returning `{}` for a table that changed SHAPE (the v0.21.1 `ALIASES`
    dict-comprehension trap, one table over);
  * lanes 3 and 4 WARN-skipping on a machine with no models.dev cache while the
    script still printed OK and exited 0 — two of the lanes silently off;
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


class LaneTwoModelNormalizeFailsClosed(unittest.TestCase):
    """Lane 2's second source, `model_normalize._AGGREGATOR_PROVIDERS`.

    Mirroring only providers.py `is_aggregator` missed `nous` (S06-F1), so the
    lane now unions this set in — and it must fail closed exactly like the
    other parsers: a reshaped table is an exit, never a silent empty set.
    """

    def _parse(self, text):
        return cht.parse_normalize_aggregators(
            FakeSource({cht.MODEL_NORMALIZE_PY: text}))

    def test_annotated_frozenset_literal_parses(self):
        self.assertEqual(
            self._parse('_AGGREGATOR_PROVIDERS: frozenset[str] = frozenset({\n'
                        '    "openrouter", "nous", "ai-gateway", "kilocode"})\n'),
            {"openrouter", "nous", "ai-gateway", "kilocode"})

    def test_plain_assignment_and_set_literal_parse(self):
        # v2026.9.24's models_catalog_static.py spells a sibling set this way.
        self.assertEqual(self._parse('_AGGREGATOR_PROVIDERS = {"nous"}\n'), {"nous"})

    def test_absent_file_is_a_skip_not_an_error(self):
        self.assertIsNone(cht.parse_normalize_aggregators(FakeSource({})))

    def test_renamed_table_is_not_a_silent_empty(self):
        with self.assertRaises(SystemExit) as ctx:
            self._parse('_AGGREGATORS: frozenset = frozenset({"nous"})\n')
        self.assertIn("not a literal set", str(ctx.exception.code))

    def test_nonliteral_set_is_not_a_silent_empty(self):
        with self.assertRaises(SystemExit):
            self._parse('_AGGREGATOR_PROVIDERS = frozenset(_BASE | {"nous"})\n')

    def test_empty_set_is_not_a_silent_empty(self):
        with self.assertRaises(SystemExit):
            self._parse('_AGGREGATOR_PROVIDERS = frozenset()\n')


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
        self.assertIn("lanes=6/6", text)
        self.assertIn(f"tag {cht.HERMES_TARGET_TAG}", text)


class LaneTwoCatchesAMissingNous(unittest.TestCase):
    """End to end at the target tag: a Swift set without `nous` must FAIL.

    `nous` is only in `model_normalize._AGGREGATOR_PROVIDERS`, never marked
    `is_aggregator` in providers.py — so this is the case the old lane
    passed while every Nous user saw a false mismatch banner (S06-F1).
    """

    def setUp(self):
        _require_target_checkout(self)
        real = cht.PREFLIGHT_SWIFT
        text = open(real).read()
        self.assertIn('"nous",', text)
        tmp = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False)
        tmp.write(text.replace('"nous",', "", 1))
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        cht.PREFLIGHT_SWIFT = tmp.name
        self.addCleanup(setattr, cht, "PREFLIGHT_SWIFT", real)

    def test_missing_nous_fails_the_aggregator_lane(self):
        out = StringIO()
        with redirect_stdout(out), redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                cht.main([HERMES_CHECKOUT, "--tag", cht.HERMES_TARGET_TAG, "--allow-skip"])
        self.assertEqual(ctx.exception.code, 1, out.getvalue())
        self.assertIn("[aggregators] Hermes aggregators missing", out.getvalue())
        self.assertIn("nous", out.getvalue())


class LaneSixProviderEnvVars(unittest.TestCase):
    """`parse_provider_env_vars` rebuilds `_has_any_provider_configured`'s set
    statically, and exits on any shape it can't read."""

    MAIN = textwrap.dedent("""
        def _has_any_provider_configured(*, strict_profile_scope=False):
            provider_env_vars = {
                "OPENROUTER_API_KEY",
                "OPENAI_BASE_URL",
            }
            for pconfig in PROVIDER_REGISTRY.values():
                pass
    """)
    AUTH = textwrap.dedent("""
        _REGISTRY_ROWS: Tuple[Any, ...] = (
            ProviderConfig("nous", "Nous", "oauth_device_code", inference_base_url="x"),
            ("deepseek", "DeepSeek", "https://x", ("DEEPSEEK_API_KEY",), "DEEPSEEK_BASE_URL"),
            ("bedrock", "AWS", "https://x", ("AWS_THING",), "BEDROCK_BASE_URL", "aws_sdk"),
        )
    """)
    PLUG = '_REGISTRY_PLUGIN_SKIP = frozenset({"openrouter", "custom"})\n'

    class DirSource(FakeSource):
        def __init__(self, files, dirs):
            super().__init__(files)
            self.dirs = dirs

        def listdir(self, relpath):
            return self.dirs.get(relpath, [])

    def _src(self, main=None, auth=None, plug=None, plugins=None):
        files = {cht.MAIN_PY: self.MAIN if main is None else main,
                 cht.AUTH_PY: self.AUTH if auth is None else auth,
                 cht.AUTH_PLUGIN_PY: self.PLUG if plug is None else plug}
        plugins = plugins or {}
        for name, text in plugins.items():
            files[f"plugins/model-providers/{name}/__init__.py"] = text
        return self.DirSource(files, {"plugins/model-providers": sorted(plugins)})

    def test_builtin_rows_and_literal_set(self):
        vars_, ids, warn = cht.parse_provider_env_vars(self._src())
        # aws_sdk rows are not counted; the literal set is.
        self.assertEqual(vars_, {"OPENROUTER_API_KEY", "OPENAI_BASE_URL", "DEEPSEEK_API_KEY"})
        self.assertEqual(ids, {"nous", "deepseek", "bedrock"})
        self.assertEqual(warn, set())

    def test_plugin_mirroring_rules(self):
        plugins = {
            "fireworks": 'p = ProviderProfile(name="fireworks", env_vars=("FIREWORKS_API_KEY", "FIREWORKS_BASE_URL"))\nregister_provider(p)\n',
            # Already a built-in row: never mirrored, even with new vars.
            "deepseek": 'p = ProviderProfile(name="deepseek", env_vars=("OTHER_KEY",))\nregister_provider(p)\n',
            # In _REGISTRY_PLUGIN_SKIP.
            "openrouter": 'p = ProviderProfile(name="openrouter", env_vars=("OR_ONLY",))\nregister_provider(p)\n',
            # Not api_key.
            "oauthy": 'p = P(name="oauthy", auth_type="oauth_external", env_vars=("OAUTHY_KEY",))\nregister_provider(p)\n',
            # Factory: reported, not guessed.
            "kimi": 'k = _kimi("kimi", (), ("KIMI_API_KEY",), "x")\nregister_provider(k)\n',
        }
        vars_, _, warn = cht.parse_provider_env_vars(self._src(plugins=plugins))
        self.assertIn("FIREWORKS_API_KEY", vars_)
        self.assertNotIn("FIREWORKS_BASE_URL", vars_)
        for absent in ("OTHER_KEY", "OR_ONLY", "OAUTHY_KEY"):
            self.assertNotIn(absent, vars_)
        self.assertEqual(warn, {"kimi"})

    def test_a_profile_with_only_url_vars_keeps_them(self):
        # `_api_key_env_fields`: `tuple(non-URL vars) or pp.env_vars`.
        plugins = {"urlonly": 'p = ProviderProfile(name="urlonly", env_vars=("URLONLY_BASE_URL",))\nregister_provider(p)\n'}
        vars_, _, _ = cht.parse_provider_env_vars(self._src(plugins=plugins))
        self.assertIn("URLONLY_BASE_URL", vars_)

    def _exits(self, **kw):
        with self.assertRaises(SystemExit):
            cht.parse_provider_env_vars(self._src(**kw))

    def test_renamed_literal_set_exits(self):
        self._exits(main=self.MAIN.replace("provider_env_vars", "provider_vars"))

    def test_missing_function_exits(self):
        self._exits(main="def something_else():\n    pass\n")

    def test_unknown_row_shape_exits(self):
        self._exits(auth="_REGISTRY_ROWS = (make_row('x'),)\n")

    def test_nonliteral_key_tuple_exits(self):
        self._exits(auth='_REGISTRY_ROWS = (("x", "X", "u", KEYS),)\n')

    def test_missing_skip_set_exits(self):
        self._exits(plug="SOMETHING = 1\n")

    def test_missing_file_exits(self):
        with self.assertRaises(SystemExit):
            cht.parse_provider_env_vars(FakeSource({cht.MAIN_PY: self.MAIN}))


class LaneSixCatchesDrift(unittest.TestCase):
    """End to end at the target tag: dropping a var Hermes counts, or adding
    one it doesn't, must FAIL the provider-env-vars lane."""

    def setUp(self):
        _require_target_checkout(self)
        self.real = cht.CREDENTIALS_SWIFT
        self.text = open(self.real).read()
        self.addCleanup(setattr, cht, "CREDENTIALS_SWIFT", self.real)

    def _run_with(self, text):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False)
        tmp.write(text)
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        cht.CREDENTIALS_SWIFT = tmp.name
        out = StringIO()
        with redirect_stdout(out), redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                cht.main([HERMES_CHECKOUT, "--tag", cht.HERMES_TARGET_TAG, "--allow-skip"])
        return ctx.exception.code, out.getvalue()

    def test_a_missing_var_fails(self):
        self.assertIn('"DEEPSEEK_API_KEY", ', self.text)
        code, out = self._run_with(self.text.replace('"DEEPSEEK_API_KEY", ', "", 1))
        self.assertEqual(code, 1, out)
        self.assertIn("[provider-env-vars] Hermes provider env vars missing", out)
        self.assertIn("DEEPSEEK_API_KEY", out)

    def test_a_missing_plugin_only_var_fails(self):
        # FIREWORKS_API_KEY comes only from the fireworks plugin mirror.
        self.assertIn('"FIREWORKS_API_KEY", ', self.text)
        code, out = self._run_with(self.text.replace('"FIREWORKS_API_KEY", ', "", 1))
        self.assertEqual(code, 1, out)
        self.assertIn("FIREWORKS_API_KEY", out)

    def test_an_extra_var_fails(self):
        code, out = self._run_with(self.text.replace(
            '"ACTUAL_API_KEY", ', '"ACTUAL_API_KEY", "GROQ_API_KEY", ', 1))
        self.assertEqual(code, 1, out)
        self.assertIn("[provider-env-vars] providerEnvVars entries", out)
        self.assertIn("GROQ_API_KEY", out)


if __name__ == "__main__":
    unittest.main()
