"""Unit tests for tools/build-catalog.py.

Run with:  python3 -m unittest tools.test_build_catalog
Or just:   python3 tools/test_build_catalog.py

Covers the validator's invariants against synthetic template directories
created under a temp dir — no network, no global state, no dependency on
the repo's actual templates/. A separate test at the bottom exercises the
real shipped `templates/awizemann/site-status-checker` bundle to catch
drift between validator + installer.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


# Import tools/build-catalog.py via spec-loader (the dash in the filename
# would otherwise make a plain `import` ugly). Register the module in
# sys.modules BEFORE exec — Python 3.9's dataclass inspection reads
# `sys.modules[cls.__module__].__dict__` and blows up if the module isn't
# there yet (fixed in 3.10+, still matters on system-Python Macs).
_SPEC_PATH = Path(__file__).resolve().parent / "build-catalog.py"
_spec = importlib.util.spec_from_file_location("build_catalog", _SPEC_PATH)
build_catalog = importlib.util.module_from_spec(_spec)
sys.modules["build_catalog"] = build_catalog
_spec.loader.exec_module(build_catalog)


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------


MINIMAL_DASHBOARD = {
    "version": 1,
    "title": "Test",
    "description": "test",
    "sections": [
        {
            "title": "Current Status",
            "columns": 3,
            "widgets": [
                {"type": "stat", "title": "Sites Up", "value": 0},
            ],
        },
    ],
}


def make_fake_repo(tmp_root: Path) -> Path:
    """Create a repo layout: <tmp>/templates/ and (optionally) fake
    site/ dirs on demand. Returns the repo root."""
    (tmp_root / "templates").mkdir(parents=True)
    return tmp_root


def make_template_dir(
    repo: Path,
    author: str,
    name: str,
    manifest: dict | None = None,
    bundle_files: dict[str, bytes] | None = None,
    include_staging: bool = True,
    bundle_name: str | None = None,
) -> Path:
    """Create a template dir under <repo>/templates/<author>/<name>/
    with a built bundle and (optionally) a staging dir whose contents
    match the bundle byte-for-byte. Returns the template dir."""
    template_dir = repo / "templates" / author / name
    (template_dir / "staging").mkdir(parents=True, exist_ok=True)

    manifest = manifest or {
        "schemaVersion": 1,
        "id": f"{author}/{name}",
        "name": name.replace("-", " ").title(),
        "version": "1.0.0",
        "description": "test description",
        "contents": {
            "dashboard": True,
            "agentsMd": True,
        },
    }
    files = bundle_files or {
        "template.json": json.dumps(manifest).encode("utf-8"),
        "README.md": b"# readme\n",
        "AGENTS.md": b"# agents\n",
        "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
    }

    # Write staging/ source tree so the drift check passes by default.
    if include_staging:
        for path, data in files.items():
            full = template_dir / "staging" / path
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_bytes(data)

    # Write the zipped bundle.
    bundle_name = bundle_name or f"{name}.scarftemplate"
    with zipfile.ZipFile(template_dir / bundle_name, "w", zipfile.ZIP_DEFLATED) as zf:
        for path, data in files.items():
            zf.writestr(path, data)

    return template_dir


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class ManifestSlugTests(unittest.TestCase):
    """Mirrors the Swift test of the same name so the two
    implementations stay in sync."""

    def test_sanitizes_punctuation(self):
        self.assertEqual(build_catalog.manifest_slug("alan@w/focus dashboard!"), "alan-w-focus-dashboard")

    def test_falls_back_to_placeholder(self):
        self.assertEqual(build_catalog.manifest_slug("////"), "template")

    def test_preserves_letters_numbers_dash_underscore(self):
        self.assertEqual(build_catalog.manifest_slug("user_1/name-2"), "user_1-name-2")


class ValidationTests(unittest.TestCase):

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.repo = make_fake_repo(Path(self._dir.name))
        self.addCleanup(self._dir.cleanup)

    def test_accepts_minimal_valid_template(self):
        make_template_dir(self.repo, "tester", "minimal")
        records, errors = self._validate_all()
        self.assertEqual(errors, [])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].manifest["id"], "tester/minimal")

    def test_rejects_missing_agents_md(self):
        # Build a bundle that lacks AGENTS.md.
        manifest = {
            "schemaVersion": 1,
            "id": "tester/bad",
            "name": "Bad",
            "version": "1.0.0",
            "description": "missing AGENTS.md",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        make_template_dir(
            self.repo, "tester", "bad",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# readme",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        _, errors = self._validate_all()
        self.assertTrue(any("AGENTS.md" in str(e) for e in errors), errors)

    def test_rejects_content_claim_mismatch(self):
        # Manifest claims cron: 2, bundle ships zero cron jobs.
        manifest = {
            "schemaVersion": 1,
            "id": "tester/claims",
            "name": "Claims",
            "version": "1.0.0",
            "description": "claim mismatch",
            "contents": {"dashboard": True, "agentsMd": True, "cron": 2},
        }
        make_template_dir(
            self.repo, "tester", "claims",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# readme",
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        _, errors = self._validate_all()
        self.assertTrue(any("contents.cron=2" in str(e) for e in errors), errors)

    def test_rejects_manifest_author_mismatch(self):
        # Template lives under /tester/ but manifest id says /other/.
        manifest = {
            "schemaVersion": 1,
            "id": "other/name",
            "name": "Mismatch",
            "version": "1.0.0",
            "description": "author mismatch",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        make_template_dir(
            self.repo, "tester", "name",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# readme",
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        _, errors = self._validate_all()
        self.assertTrue(any("author component" in str(e) for e in errors), errors)

    def test_rejects_oversized_bundle(self):
        # Synthetic bundle > 5MB cap.
        template_dir = self.repo / "templates" / "tester" / "huge"
        (template_dir / "staging").mkdir(parents=True)
        manifest = {
            "schemaVersion": 1,
            "id": "tester/huge",
            "name": "Huge",
            "version": "1.0.0",
            "description": "oversized",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        payload = b"x" * (6 * 1024 * 1024)
        files = {
            "template.json": json.dumps(manifest).encode("utf-8"),
            "README.md": b"# readme",
            "AGENTS.md": b"# agents",
            "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            "ballast.bin": payload,
        }
        with zipfile.ZipFile(template_dir / "huge.scarftemplate", "w", zipfile.ZIP_STORED) as zf:
            for p, data in files.items():
                zf.writestr(p, data)
        _, errors = self._validate_all()
        self.assertTrue(any("exceeds catalog cap" in str(e) for e in errors), errors)

    def test_rejects_unknown_widget_type(self):
        bad_dashboard = {
            "version": 1,
            "title": "Bad",
            "sections": [{"title": "x", "columns": 1, "widgets": [{"type": "hologram", "title": "huh"}]}],
        }
        manifest = {
            "schemaVersion": 1,
            "id": "tester/weird",
            "name": "Weird",
            "version": "1.0.0",
            "description": "unknown widget",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        make_template_dir(
            self.repo, "tester", "weird",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# readme",
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(bad_dashboard).encode("utf-8"),
            },
        )
        _, errors = self._validate_all()
        self.assertTrue(any("unknown type" in str(e) for e in errors), errors)

    def test_rejects_secret_in_bundle(self):
        leaky = b"config:\n  github_token: ghp_" + b"A" * 40 + b"\n"
        manifest = {
            "schemaVersion": 1,
            "id": "tester/leaky",
            "name": "Leaky",
            "version": "1.0.0",
            "description": "has a secret",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        make_template_dir(
            self.repo, "tester", "leaky",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": leaky,
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        _, errors = self._validate_all()
        self.assertTrue(any("github" in str(e).lower() for e in errors), errors)

    def test_detects_staging_vs_bundle_drift(self):
        # Bundle ships an old README; staging/ has an edited one — should fail.
        manifest = {
            "schemaVersion": 1,
            "id": "tester/drift",
            "name": "Drift",
            "version": "1.0.0",
            "description": "staging ahead of bundle",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        template_dir = make_template_dir(
            self.repo, "tester", "drift",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# old",
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        # Edit staging/ AFTER building the bundle.
        (template_dir / "staging" / "README.md").write_bytes(b"# new")
        _, errors = self._validate_all()
        self.assertTrue(any("differs from built bundle" in str(e) for e in errors), errors)

    def test_rejects_missing_bundle(self):
        template_dir = self.repo / "templates" / "tester" / "bare"
        (template_dir / "staging").mkdir(parents=True)
        # No .scarftemplate in the dir.
        _, errors = self._validate_all()
        self.assertTrue(any("no .scarftemplate found" in str(e) for e in errors), errors)

    # --- helpers --------------------------------------------------------

    def _validate_all(self) -> tuple[list, list]:
        records = []
        errors = []
        for tdir in build_catalog._iter_templates(self.repo):
            record, errs = build_catalog.validate_template(tdir)
            errors.extend(errs)
            if record is not None:
                errors.extend(build_catalog._check_staging_matches_bundle(record))
                records.append(record)
        return records, errors


class ConfigSchemaValidationTests(unittest.TestCase):
    """Mirrors the Swift `ProjectConfigServiceTests` schema-validation
    suite. Every rule enforced on the Swift side must be enforced on
    the Python side — schema drift is a catastrophic failure for the
    catalog (CI would accept bundles the app later refuses at install)."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.repo = make_fake_repo(Path(self._dir.name))
        self.addCleanup(self._dir.cleanup)

    def _make_schema_manifest(self, fields, cron: int = 0):
        """Convenience — build a v2 manifest with the given config fields."""
        return {
            "schemaVersion": 2,
            "id": "tester/configured",
            "name": "Configured",
            "version": "1.0.0",
            "description": "test",
            "contents": {
                "dashboard": True,
                "agentsMd": True,
                "cron": cron,
                "config": len(fields),
            },
            "config": {"schema": fields},
        }

    def test_accepts_schemaful_bundle(self):
        manifest = self._make_schema_manifest([
            {"key": "name", "type": "string", "label": "Name", "required": True},
            {"key": "enabled", "type": "bool", "label": "Enabled"},
        ])
        make_template_dir(
            self.repo, "tester", "configured",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# readme",
                "AGENTS.md": b"# agents",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        records = []
        errors = []
        for tdir in build_catalog._iter_templates(self.repo):
            rec, errs = build_catalog.validate_template(tdir)
            errors.extend(errs)
            if rec is not None:
                records.append(rec)
        self.assertEqual(errors, [])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].manifest["schemaVersion"], 2)

    def test_rejects_duplicate_keys(self):
        manifest = self._make_schema_manifest([
            {"key": "same", "type": "string", "label": "A"},
            {"key": "same", "type": "bool", "label": "B"},
        ])
        make_template_dir(
            self.repo, "tester", "dup",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("duplicate key" in str(e) for e in errors), errors)

    def test_rejects_secret_with_default(self):
        manifest = self._make_schema_manifest([
            {
                "key": "api_key", "type": "secret", "label": "API Key",
                "required": True, "default": "sk-leaked-in-template"
            },
        ])
        make_template_dir(
            self.repo, "tester", "secret-default",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("must not declare a default" in str(e) for e in errors), errors)

    def test_rejects_enum_without_options(self):
        manifest = self._make_schema_manifest([
            {"key": "choice", "type": "enum", "label": "Choice", "options": []},
        ])
        make_template_dir(
            self.repo, "tester", "enum-empty",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("at least one option" in str(e) for e in errors), errors)

    def test_rejects_unsupported_field_type(self):
        manifest = self._make_schema_manifest([
            {"key": "wat", "type": "hologram", "label": "W"},
        ])
        make_template_dir(
            self.repo, "tester", "bad-type",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("unsupported type" in str(e) for e in errors), errors)

    def test_rejects_contents_config_count_mismatch(self):
        # Schema has 1 field; contents.config claims 2.
        manifest = self._make_schema_manifest([
            {"key": "only", "type": "string", "label": "Only"},
        ])
        manifest["contents"]["config"] = 2
        make_template_dir(
            self.repo, "tester", "mismatch",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("contents.config=2" in str(e) for e in errors), errors)

    def test_rejects_unsupported_list_item_type(self):
        manifest = self._make_schema_manifest([
            {"key": "items", "type": "list", "label": "Items", "itemType": "number"},
        ])
        make_template_dir(
            self.repo, "tester", "list-type",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertTrue(any("unsupported itemType" in str(e) for e in errors), errors)

    def test_accepts_schemaless_v1_manifest_unchanged(self):
        # Pre-v2.3 bundles without any config block should keep working.
        manifest = {
            "schemaVersion": 1,
            "id": "tester/legacy",
            "name": "Legacy",
            "version": "1.0.0",
            "description": "no config",
            "contents": {"dashboard": True, "agentsMd": True},
        }
        make_template_dir(
            self.repo, "tester", "legacy",
            manifest=manifest,
            bundle_files={
                "template.json": json.dumps(manifest).encode("utf-8"),
                "README.md": b"# r", "AGENTS.md": b"# a",
                "dashboard.json": json.dumps(MINIMAL_DASHBOARD).encode("utf-8"),
            },
        )
        errors = self._collect_errors()
        self.assertEqual(errors, [])

    def _collect_errors(self):
        errors = []
        for tdir in build_catalog._iter_templates(self.repo):
            rec, errs = build_catalog.validate_template(tdir)
            errors.extend(errs)
            if rec is not None:
                errors.extend(build_catalog._check_staging_matches_bundle(rec))
        return errors


class CatalogJsonTests(unittest.TestCase):
    """Shape of the emitted catalog.json must stay stable — the site's
    widgets.js reads these fields by name."""

    def test_catalog_json_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_fake_repo(Path(tmp))
            make_template_dir(repo, "tester", "shape")

            records = []
            for tdir in build_catalog._iter_templates(repo):
                record, errors = build_catalog.validate_template(tdir)
                self.assertEqual(errors, [])
                records.append(record)

            out = Path(tmp) / "catalog.json"
            build_catalog.write_catalog_json(records, out)
            data = json.loads(out.read_text())

            self.assertEqual(data["schemaVersion"], 1)
            self.assertEqual(len(data["templates"]), 1)
            entry = data["templates"][0]
            for required in ["id", "name", "version", "description", "contents",
                             "installUrl", "detailSlug", "bundleSha256", "bundleSize"]:
                self.assertIn(required, entry)
            self.assertTrue(entry["installUrl"].startswith("https://raw.githubusercontent.com/"))
            self.assertEqual(entry["detailSlug"], "tester-shape")


class SiteRenderingTests(unittest.TestCase):
    """Verify the regenerator produces usable HTML + copies dashboard.json
    + README.md into each detail dir for widgets.js to fetch. No browser
    automation — just shape checks so we catch silly breakages
    (missing tokens, stale templates, broken copy)."""

    def test_render_site_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_fake_repo(Path(tmp))
            # Build a couple templates so the grid has more than one card.
            make_template_dir(repo, "alice", "alpha")
            make_template_dir(repo, "bob", "beta")

            # Give the fake repo a site/ dir so render_site produces HTML.
            site_src = repo / "site"
            site_src.mkdir()
            (site_src / "index.html.tmpl").write_text(
                "<h1>Catalog ({{COUNT}} template{{COUNT_PLURAL}})</h1>{{CARDS}}"
            )
            (site_src / "template.html.tmpl").write_text(
                "<h1>{{NAME}}</h1><p>{{DESC}}</p>"
                "<a href=\"{{SCARF_INSTALL_URL}}\">install</a>"
                "<a href=\"{{INSTALL_URL_ENCODED}}\">download</a>"
            )
            (site_src / "widgets.js").write_text("/* test widgets */")
            (site_src / "styles.css").write_text("/* test styles */")

            records = []
            for tdir in build_catalog._iter_templates(repo):
                r, errors = build_catalog.validate_template(tdir)
                self.assertEqual(errors, [])
                records.append(r)

            out = Path(tmp) / "out"
            build_catalog.render_site(records, out, repo)

            # Index: both cards present, plural form flipped for count=2.
            idx = (out / "index.html").read_text()
            self.assertIn("Catalog (2 templates)", idx)
            self.assertIn("alice-alpha/", idx)
            self.assertIn("bob-beta/", idx)

            # Static assets copied.
            self.assertTrue((out / "widgets.js").exists())
            self.assertTrue((out / "styles.css").exists())
            self.assertTrue((out / "catalog.json").exists())

            # Each detail dir has index.html + dashboard.json + README.md.
            alpha = out / "alice-alpha"
            self.assertTrue((alpha / "index.html").exists())
            self.assertTrue((alpha / "dashboard.json").exists())
            self.assertTrue((alpha / "README.md").exists())

            alpha_html = (alpha / "index.html").read_text()
            # Install URL wires through the scarf:// scheme + raw GH URL.
            self.assertIn("scarf://install?url=https://raw.githubusercontent.com/", alpha_html)

    def test_render_index_singular_form_for_one_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_fake_repo(Path(tmp))
            make_template_dir(repo, "alice", "alpha")
            records = []
            for tdir in build_catalog._iter_templates(repo):
                r, _ = build_catalog.validate_template(tdir)
                records.append(r)
            html = build_catalog.render_index("{{COUNT}} template{{COUNT_PLURAL}}", records)
            self.assertEqual(html, "1 template")


class RealBundleTest(unittest.TestCase):
    """Run the validator against the actual shipped Site Status Checker
    bundle. Catches drift between validator + real-world author
    conventions. Skipped if run outside the repo tree."""

    def test_site_status_checker_passes(self):
        repo_root = Path(__file__).resolve().parent.parent
        template = repo_root / "templates" / "awizemann" / "site-status-checker"
        if not template.exists():
            self.skipTest("site-status-checker not present (running outside repo?)")
        record, errors = build_catalog.validate_template(template)
        self.assertIsNotNone(record)
        drift = build_catalog._check_staging_matches_bundle(record)
        self.assertEqual(errors + drift, [], f"errors: {errors}, drift: {drift}")
        self.assertEqual(record.manifest["id"], "awizemann/site-status-checker")


if __name__ == "__main__":
    unittest.main()
