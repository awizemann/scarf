#!/usr/bin/env python3
"""Scarf template catalog builder + validator.

Walks every `templates/<author>/<name>/` in this repo, validates the
`.scarftemplate` bundle against its manifest claim (same invariants the
Swift `ProjectTemplateService.verifyClaims` enforces at install time), and
produces:

  templates/catalog.json                aggregate index for the site
  .gh-pages-worktree/templates/...      per-template HTML + dashboard.json
                                        (only produced by --build / --publish)

This is stdlib-only Python so it runs in a GitHub Action with zero
dependencies and in under a second even when the catalog has thousands of
templates. Schema drift between this validator and the Swift installer
breaks one of two contracts — add a failing test in both places when you
change anything here.

Usage:
  tools/build-catalog.py --check           validate; no output written
  tools/build-catalog.py --build           validate + write catalog.json + site
  tools/build-catalog.py --preview DIR     render a self-contained preview
                                           site into DIR (for local viewing)

Exit codes:
  0  success
  1  validation failure (one or more templates rejected)
  2  IO / usage error
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Schema + invariants
# ---------------------------------------------------------------------------

SCHEMA_VERSION_V1 = 1   # original v2.2 bundle
SCHEMA_VERSION_V2 = 2   # v2.3 — adds optional manifest.config block
SUPPORTED_SCHEMA_VERSIONS = {SCHEMA_VERSION_V1, SCHEMA_VERSION_V2}
MAX_BUNDLE_BYTES = 5 * 1024 * 1024  # 5 MB cap on submissions; installer is 50 MB
REQUIRED_BUNDLE_FILES = ("template.json", "README.md", "AGENTS.md", "dashboard.json")
SUPPORTED_WIDGET_TYPES = {"stat", "progress", "text", "table", "chart", "list", "webview"}

# Mirror of Swift's TemplateConfigField.FieldType. Order matters only
# for error messages that echo this set.
SUPPORTED_CONFIG_FIELD_TYPES = {"string", "text", "number", "bool", "enum", "list", "secret"}
SUPPORTED_CONFIG_LIST_ITEM_TYPES = {"string"}

# Common secret patterns — keep in sync with `scripts/wiki.sh` and reuse a
# conservative subset. The validator rejects hard matches; the site's
# CONTRIBUTING guide covers the rest.
SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "private key block"),
    (re.compile(r"(?i)\bgh[pousr]_[A-Za-z0-9]{36,}"), "github personal access token"),
    (re.compile(r"(?i)\bxox[abpso]-[A-Za-z0-9-]{10,}"), "slack token"),
    (re.compile(r"(?i)\bAKIA[0-9A-Z]{16}"), "aws access key id"),
    (re.compile(r"(?i)\bsk-[A-Za-z0-9]{32,}"), "openai/anthropic api key"),
]

REPO_ROOT = Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class ValidationError:
    template_path: Path
    message: str

    def __str__(self) -> str:
        # Render a repo-relative path when possible for concise CLI output;
        # fall back to the absolute path when the template lives outside
        # the repo tree (unit tests use temp dirs).
        try:
            rel: Path | str = self.template_path.relative_to(REPO_ROOT)
        except ValueError:
            rel = self.template_path
        return f"{rel}: {self.message}"


@dataclass
class TemplateRecord:
    """One entry in the generated catalog.json. Mirrors the Swift
    ProjectTemplateManifest but with a few derived fields added."""

    path: Path
    manifest: dict
    bundle_path: Path
    bundle_sha256: str
    bundle_size: int
    install_url: str
    detail_slug: str

    def to_catalog_entry(self) -> dict:
        """Subset suitable for catalog.json. Keep fields stable — the
        site's widgets.js reads this shape. The optional `config` key
        mirrors the manifest's `config` block so the site can render
        the Configuration section on the detail page."""
        m = self.manifest
        return {
            "id": m["id"],
            "name": m["name"],
            "version": m["version"],
            "description": m["description"],
            "author": m.get("author"),
            "category": m.get("category"),
            "tags": m.get("tags") or [],
            "contents": m["contents"],
            "config": m.get("config"),          # None for schema-less
            "installUrl": self.install_url,
            "detailSlug": self.detail_slug,
            "bundleSha256": self.bundle_sha256,
            "bundleSize": self.bundle_size,
            "minScarfVersion": m.get("minScarfVersion"),
            "minHermesVersion": m.get("minHermesVersion"),
        }


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def manifest_slug(manifest_id: str) -> str:
    """Mirror of Swift `ProjectTemplateManifest.slug`. Non-alphanumeric
    runs collapse to single hyphens; empty collapses to 'template'."""
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", manifest_id).strip("-")
    return cleaned or "template"


def _iter_templates(repo_root: Path) -> Iterable[Path]:
    """Yield every `templates/<author>/<name>/` directory (those that hold
    a `template.json` or a built `.scarftemplate`). Authors whose dirs
    only hold a README are silently skipped."""
    root = repo_root / "templates"
    if not root.is_dir():
        return
    for author_dir in sorted(root.iterdir()):
        if not author_dir.is_dir() or author_dir.name.startswith("."):
            continue
        for template_dir in sorted(author_dir.iterdir()):
            if not template_dir.is_dir():
                continue
            if (template_dir / "staging").is_dir():
                yield template_dir


def _validate_manifest(manifest: dict, template_dir: Path, errors: list[ValidationError]) -> None:
    required = ["schemaVersion", "id", "name", "version", "description", "contents"]
    for field in required:
        if field not in manifest:
            errors.append(ValidationError(template_dir, f"manifest missing required field: {field}"))
    if manifest.get("schemaVersion") not in SUPPORTED_SCHEMA_VERSIONS:
        errors.append(ValidationError(
            template_dir,
            f"unsupported schemaVersion: {manifest.get('schemaVersion')} "
            f"(supported: {sorted(SUPPORTED_SCHEMA_VERSIONS)})"
        ))
    # Manifest id must match the directory layout.
    mid = manifest.get("id", "")
    if "/" not in mid:
        errors.append(ValidationError(template_dir, f"manifest id must be owner/name, got {mid!r}"))
    else:
        expected_author = template_dir.parent.name
        author_part, _, _ = mid.partition("/")
        if author_part != expected_author:
            errors.append(ValidationError(
                template_dir,
                f"manifest id {mid!r} author component does not match directory "
                f"({expected_author!r})"
            ))


def _validate_contents_claim(
    manifest: dict,
    bundle_files: set[str],
    cron_job_count: int,
    template_dir: Path,
    errors: list[ValidationError],
) -> None:
    """Mirrors Swift `ProjectTemplateService.verifyClaims`. Rejects any
    mismatch between what the manifest says and what's actually in the
    bundle so the catalog site can't misrepresent a template."""
    contents = manifest.get("contents", {})

    for required in REQUIRED_BUNDLE_FILES:
        if required not in bundle_files:
            errors.append(ValidationError(template_dir, f"bundle missing required file: {required}"))

    # Optional instructions/ dir — claim must match presence exactly.
    claimed_instructions = contents.get("instructions") or []
    claimed_full = {f"instructions/{p}" for p in claimed_instructions}
    present_instructions = {f for f in bundle_files if f.startswith("instructions/")}
    for claim in claimed_full:
        if claim not in bundle_files:
            errors.append(ValidationError(template_dir, f"contents.instructions claims {claim} but file is missing"))
    for present in present_instructions - claimed_full:
        errors.append(ValidationError(
            template_dir,
            f"bundle has {present} but it's not listed in contents.instructions"
        ))

    # Skills — each claimed skill name must exist as a subdir with at least
    # one file; extra skill dirs not listed are rejected.
    claimed_skills = set(contents.get("skills") or [])
    present_skills = set()
    for f in bundle_files:
        if f.startswith("skills/"):
            rest = f[len("skills/"):]
            if "/" in rest:
                present_skills.add(rest.split("/", 1)[0])
    for skill in claimed_skills:
        if not any(f.startswith(f"skills/{skill}/") for f in bundle_files):
            errors.append(ValidationError(template_dir, f"contents.skills claims {skill!r} but skills/{skill}/ is empty"))
    for extra in present_skills - claimed_skills:
        errors.append(ValidationError(template_dir, f"bundle has skills/{extra}/ not listed in contents.skills"))

    # Cron — numeric count must match bundle.
    claimed_cron = int(contents.get("cron") or 0)
    if claimed_cron != cron_job_count:
        errors.append(ValidationError(
            template_dir,
            f"contents.cron={claimed_cron} but bundle contains {cron_job_count} cron jobs"
        ))

    # Memory appendix — claim must match file presence.
    claimed_memory = bool((contents.get("memory") or {}).get("append"))
    has_memory_file = "memory/append.md" in bundle_files
    if claimed_memory != has_memory_file:
        errors.append(ValidationError(
            template_dir,
            f"contents.memory.append={claimed_memory} disagrees with memory/append.md presence={has_memory_file}"
        ))

    # Config (schemaVersion 2+) — claim field-count must match schema
    # field count. `None`/`0` on both sides means schema-less, which is
    # always legal.
    claimed_config = int(contents.get("config") or 0)
    schema = manifest.get("config")
    schema_field_count = len((schema or {}).get("schema") or []) if schema else 0
    if claimed_config != schema_field_count:
        errors.append(ValidationError(
            template_dir,
            f"contents.config={claimed_config} but config.schema has {schema_field_count} field(s)"
        ))


def _validate_config_schema(manifest: dict, template_dir: Path, errors: list[ValidationError]) -> None:
    """Mirrors Swift `ProjectConfigService.validateSchema`. Structural
    invariants only — user-value validation happens in the app at
    commit time, not at catalog-build time."""
    schema = manifest.get("config")
    if schema is None:
        return
    if not isinstance(schema, dict):
        errors.append(ValidationError(template_dir, "manifest.config must be an object"))
        return
    fields = schema.get("schema")
    if not isinstance(fields, list):
        errors.append(ValidationError(template_dir, "manifest.config.schema must be a list"))
        return

    seen_keys: set[str] = set()
    for i, field in enumerate(fields):
        if not isinstance(field, dict):
            errors.append(ValidationError(template_dir, f"config.schema[{i}] must be an object"))
            continue
        key = field.get("key")
        ftype = field.get("type")
        label = field.get("label")
        if not isinstance(key, str) or not key:
            errors.append(ValidationError(template_dir, f"config.schema[{i}] missing/empty key"))
            continue
        if key in seen_keys:
            errors.append(ValidationError(template_dir, f"config.schema has duplicate key: {key!r}"))
            continue
        seen_keys.add(key)
        if not isinstance(label, str) or not label:
            errors.append(ValidationError(template_dir, f"config.schema[{key}] missing/empty label"))
        if ftype not in SUPPORTED_CONFIG_FIELD_TYPES:
            errors.append(ValidationError(
                template_dir,
                f"config.schema[{key}] uses unsupported type {ftype!r} "
                f"(supported: {sorted(SUPPORTED_CONFIG_FIELD_TYPES)})"
            ))
            continue
        # Type-specific rules.
        if ftype == "enum":
            options = field.get("options") or []
            if not isinstance(options, list) or not options:
                errors.append(ValidationError(
                    template_dir,
                    f"config.schema[{key}] (enum) must declare at least one option"
                ))
            else:
                seen_values: set[str] = set()
                for opt in options:
                    if not isinstance(opt, dict):
                        errors.append(ValidationError(
                            template_dir,
                            f"config.schema[{key}] option must be an object"
                        ))
                        continue
                    val = opt.get("value")
                    if not isinstance(val, str) or not val:
                        errors.append(ValidationError(
                            template_dir,
                            f"config.schema[{key}] option missing/empty value"
                        ))
                        continue
                    if val in seen_values:
                        errors.append(ValidationError(
                            template_dir,
                            f"config.schema[{key}] has duplicate option value: {val!r}"
                        ))
                    seen_values.add(val)
        elif ftype == "list":
            item_type = field.get("itemType", "string")
            if item_type not in SUPPORTED_CONFIG_LIST_ITEM_TYPES:
                errors.append(ValidationError(
                    template_dir,
                    f"config.schema[{key}] (list) uses unsupported itemType {item_type!r}"
                ))
        elif ftype == "secret":
            if "default" in field:
                errors.append(ValidationError(
                    template_dir,
                    f"config.schema[{key}] is a secret field and must not declare a default"
                ))
    # modelRecommendation — preferred must be non-empty when present.
    rec = schema.get("modelRecommendation")
    if rec is not None:
        if not isinstance(rec, dict):
            errors.append(ValidationError(template_dir, "config.modelRecommendation must be an object"))
        else:
            preferred = rec.get("preferred")
            if not isinstance(preferred, str) or not preferred.strip():
                errors.append(ValidationError(
                    template_dir,
                    "config.modelRecommendation.preferred must be a non-empty string"
                ))


def _validate_dashboard(zf: zipfile.ZipFile, template_dir: Path, errors: list[ValidationError]) -> None:
    """Decode dashboard.json against the widget-type vocabulary the Swift
    renderer knows. An unknown widget type means the app will render an
    'unknown widget' placeholder — that's a bad catalog experience."""
    try:
        dashboard = json.loads(zf.read("dashboard.json"))
    except Exception as e:
        errors.append(ValidationError(template_dir, f"dashboard.json failed to parse: {e}"))
        return
    if dashboard.get("version") != 1:
        errors.append(ValidationError(template_dir, f"dashboard.version must be 1, got {dashboard.get('version')}"))
    sections = dashboard.get("sections") or []
    if not isinstance(sections, list):
        errors.append(ValidationError(template_dir, "dashboard.sections must be a list"))
        return
    for section in sections:
        for widget in section.get("widgets") or []:
            widget_type = widget.get("type")
            if widget_type not in SUPPORTED_WIDGET_TYPES:
                errors.append(ValidationError(
                    template_dir,
                    f"dashboard widget {widget.get('title')!r} has unknown type {widget_type!r}"
                ))


def _scan_for_secrets(zf: zipfile.ZipFile, template_dir: Path, errors: list[ValidationError]) -> None:
    """Refuse bundles containing obvious secret patterns. Conservative —
    matches only high-confidence substrings (no keyword-only warnings)."""
    for info in zf.infolist():
        if info.is_dir() or info.file_size > 256 * 1024:
            continue  # skip big binaries
        try:
            data = zf.read(info.filename).decode("utf-8", errors="replace")
        except Exception:
            continue
        for pattern, label in SECRET_PATTERNS:
            if pattern.search(data):
                errors.append(ValidationError(
                    template_dir,
                    f"bundle file {info.filename} matches {label} pattern — refusing"
                ))
                break


def _parse_cron_jobs(zf: zipfile.ZipFile, template_dir: Path, errors: list[ValidationError]) -> int:
    """Parse cron/jobs.json if present; return the job count. Logs a
    validation error on a malformed file."""
    if "cron/jobs.json" not in set(zf.namelist()):
        return 0
    try:
        data = json.loads(zf.read("cron/jobs.json"))
    except Exception as e:
        errors.append(ValidationError(template_dir, f"cron/jobs.json failed to parse: {e}"))
        return 0
    if not isinstance(data, list):
        errors.append(ValidationError(template_dir, "cron/jobs.json must be a JSON array"))
        return 0
    for i, job in enumerate(data):
        if not isinstance(job, dict):
            errors.append(ValidationError(template_dir, f"cron/jobs.json[{i}] must be an object"))
            continue
        if "name" not in job or "schedule" not in job:
            errors.append(ValidationError(
                template_dir,
                f"cron/jobs.json[{i}] missing required field (name, schedule)"
            ))
    return len(data)


def _bundle_files(zf: zipfile.ZipFile) -> set[str]:
    """Unique regular-file paths in the bundle, excluding dir entries and
    macOS __MACOSX/ metadata."""
    return {
        info.filename
        for info in zf.infolist()
        if not info.is_dir() and not info.filename.startswith("__MACOSX/")
    }


def validate_template(template_dir: Path) -> tuple[TemplateRecord | None, list[ValidationError]]:
    """Validate one template dir and return a (record, errors) pair.
    record is None when errors are fatal enough that we can't build a
    catalog entry at all."""
    errors: list[ValidationError] = []

    # Find the bundle. By convention it's `<dir>/<dir-basename>.scarftemplate`
    # or any single .scarftemplate in the dir.
    bundles = sorted(template_dir.glob("*.scarftemplate"))
    if not bundles:
        errors.append(ValidationError(template_dir, "no .scarftemplate found in template directory"))
        return None, errors
    if len(bundles) > 1:
        errors.append(ValidationError(
            template_dir,
            f"more than one .scarftemplate present: {[b.name for b in bundles]}"
        ))
    bundle_path = bundles[0]

    bundle_size = bundle_path.stat().st_size
    if bundle_size > MAX_BUNDLE_BYTES:
        errors.append(ValidationError(
            template_dir,
            f"bundle size {bundle_size} exceeds catalog cap of {MAX_BUNDLE_BYTES} bytes"
        ))

    try:
        with zipfile.ZipFile(bundle_path, "r") as zf:
            bundle_files = _bundle_files(zf)
            if "template.json" not in bundle_files:
                errors.append(ValidationError(template_dir, "bundle is missing template.json"))
                return None, errors
            try:
                manifest = json.loads(zf.read("template.json"))
            except Exception as e:
                errors.append(ValidationError(template_dir, f"template.json failed to parse: {e}"))
                return None, errors

            _validate_manifest(manifest, template_dir, errors)
            _validate_config_schema(manifest, template_dir, errors)
            cron_count = _parse_cron_jobs(zf, template_dir, errors)
            _validate_contents_claim(manifest, bundle_files, cron_count, template_dir, errors)
            _validate_dashboard(zf, template_dir, errors)
            _scan_for_secrets(zf, template_dir, errors)
    except zipfile.BadZipFile:
        errors.append(ValidationError(template_dir, "bundle is not a valid zip archive"))
        return None, errors

    # Compute the catalog-ready record.
    sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()
    author = template_dir.parent.name
    short_name = template_dir.name
    install_url = (
        "https://raw.githubusercontent.com/awizemann/scarf/main/"
        f"templates/{author}/{short_name}/{bundle_path.name}"
    )
    detail_slug = manifest_slug(manifest.get("id", f"{author}/{short_name}"))

    record = TemplateRecord(
        path=template_dir,
        manifest=manifest,
        bundle_path=bundle_path,
        bundle_sha256=sha,
        bundle_size=bundle_size,
        install_url=install_url,
        detail_slug=detail_slug,
    )
    return record, errors


# ---------------------------------------------------------------------------
# Staging/bundle drift check — keeps authors honest
# ---------------------------------------------------------------------------


def _check_staging_matches_bundle(record: TemplateRecord) -> list[ValidationError]:
    """If the template dir has a staging/ source tree, rebuild the bundle
    in memory and diff against the committed one. Catches the common
    failure mode of an author editing staging/ but forgetting to
    regenerate the .scarftemplate."""
    errors: list[ValidationError] = []
    staging = record.path / "staging"
    if not staging.is_dir():
        return errors

    committed = {}
    with zipfile.ZipFile(record.bundle_path, "r") as zf:
        for info in zf.infolist():
            if info.is_dir() or info.filename.startswith("__MACOSX/"):
                continue
            committed[info.filename] = zf.read(info.filename)

    source = {}
    for path in staging.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(staging).as_posix()
        if rel.startswith(".") or "/.DS_Store" in rel or rel.endswith("/.DS_Store") or rel == ".DS_Store":
            continue
        source[rel] = path.read_bytes()

    missing_in_bundle = sorted(set(source) - set(committed))
    if missing_in_bundle:
        errors.append(ValidationError(
            record.path,
            f"staging has files not in the built bundle: {missing_in_bundle} "
            "(rebuild with `zip -qq -r <name>.scarftemplate .` from staging/)"
        ))
    missing_in_source = sorted(set(committed) - set(source))
    if missing_in_source:
        errors.append(ValidationError(
            record.path,
            f"bundle has files not in staging/: {missing_in_source} "
            "(commit them to staging/ or rebuild the bundle from staging/)"
        ))
    diff = [name for name, data in source.items() if name in committed and committed[name] != data]
    if diff:
        errors.append(ValidationError(
            record.path,
            f"staging content differs from built bundle: {diff} "
            "(rebuild the bundle from staging/)"
        ))
    return errors


# ---------------------------------------------------------------------------
# Build: write catalog.json (site rendering comes in a later commit)
# ---------------------------------------------------------------------------


def write_catalog_json(records: list[TemplateRecord], out_path: Path) -> None:
    catalog = {
        # The aggregate catalog itself is versioned independently of
        # individual bundle manifests — bumping template manifest schema
        # from 1 → 2 doesn't change the catalog.json shape.
        "schemaVersion": 1,
        "generated": True,  # human reminder; a timestamp would churn the diff every run
        "templates": [r.to_catalog_entry() for r in records],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="validate every template; don't write output")
    group.add_argument("--build", action="store_true", help="validate + write catalog.json")
    group.add_argument("--preview", metavar="DIR", help="render a self-contained site preview into DIR")
    parser.add_argument("--only", metavar="PATH", action="append", default=[],
                        help="validate only the given template dir (may repeat); useful for PR-diff runs")
    parser.add_argument("--repo", metavar="PATH", default=str(REPO_ROOT),
                        help="repo root to operate on (default: auto-detect)")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo).resolve()
    template_dirs = list(_iter_templates(repo_root))
    if args.only:
        only = {Path(p).resolve() for p in args.only}
        template_dirs = [t for t in template_dirs if t.resolve() in only]

    if not template_dirs:
        if args.only:
            print(f"no templates matched --only filter", file=sys.stderr)
            return 2
        print("no templates found under templates/ — nothing to do", file=sys.stderr)
        return 0

    records: list[TemplateRecord] = []
    all_errors: list[ValidationError] = []
    for tdir in template_dirs:
        record, errors = validate_template(tdir)
        all_errors.extend(errors)
        if record is not None:
            all_errors.extend(_check_staging_matches_bundle(record))
            records.append(record)

    if all_errors:
        print(f"✗ {len(all_errors)} validation error(s):", file=sys.stderr)
        for err in all_errors:
            print(f"  {err}", file=sys.stderr)
        return 1

    print(f"✓ {len(records)} template(s) validated", file=sys.stderr)
    for r in records:
        rel = r.path.relative_to(repo_root)
        print(f"  {rel} — {r.manifest['id']} v{r.manifest['version']}")

    if args.check:
        return 0

    catalog_path = repo_root / "templates" / "catalog.json"
    write_catalog_json(records, catalog_path)
    print(f"wrote {catalog_path.relative_to(repo_root)}", file=sys.stderr)

    if args.preview:
        preview_dir = Path(args.preview).resolve()
        render_site(records, preview_dir, repo_root)
        print(f"preview site rendered to {preview_dir}", file=sys.stderr)

    if args.build:
        # --build renders into .gh-pages-worktree/templates/ so the
        # maintainer's publish step just has to commit + push gh-pages.
        gh_pages = repo_root / ".gh-pages-worktree" / "templates"
        render_site(records, gh_pages, repo_root)
        print(f"site rendered to {gh_pages.relative_to(repo_root)}", file=sys.stderr)

    return 0


def render_site(records: list[TemplateRecord], out_dir: Path, repo_root: Path) -> None:
    """Render the catalog site. Defined here as a stub so --build and
    --preview both have a landing spot; the real HTML templates ship in
    the next commit (Phase 3)."""
    site_src = repo_root / "site"
    if not site_src.is_dir():
        # Phase 2: no site/ yet. Write just catalog.json into out_dir so
        # the preview mode is still demonstrable (and --build stays
        # idempotent).
        out_dir.mkdir(parents=True, exist_ok=True)
        write_catalog_json(records, out_dir / "catalog.json")
        return

    out_dir.mkdir(parents=True, exist_ok=True)

    index_tmpl = (site_src / "index.html.tmpl").read_text(encoding="utf-8")
    template_tmpl = (site_src / "template.html.tmpl").read_text(encoding="utf-8")

    # Copy static site assets (widgets.js, styles.css, assets/).
    for name in ("widgets.js", "styles.css"):
        src = site_src / name
        if src.exists():
            shutil.copy2(src, out_dir / name)
    assets_src = site_src / "assets"
    if assets_src.is_dir():
        assets_dst = out_dir / "assets"
        if assets_dst.exists():
            shutil.rmtree(assets_dst)
        shutil.copytree(assets_src, assets_dst)

    # Catalog index
    (out_dir / "index.html").write_text(
        render_index(index_tmpl, records),
        encoding="utf-8",
    )

    # Per-template detail pages + dashboard.json copies
    for r in records:
        detail_dir = out_dir / r.detail_slug
        detail_dir.mkdir(parents=True, exist_ok=True)
        (detail_dir / "index.html").write_text(
            render_detail(template_tmpl, r),
            encoding="utf-8",
        )
        # Copy the unpacked dashboard.json, README.md, and template.json
        # (as manifest.json so the site can fetch the config schema for
        # the Configuration section without conflicting with any file
        # named `template.json` somewhere else in the served tree).
        with zipfile.ZipFile(r.bundle_path, "r") as zf:
            (detail_dir / "dashboard.json").write_bytes(zf.read("dashboard.json"))
            if "README.md" in zf.namelist():
                (detail_dir / "README.md").write_bytes(zf.read("README.md"))
            # Only copy the manifest when the template has a config
            # schema — avoids bloating the served tree for schema-less
            # templates and makes the 404 fallback in widgets.js a
            # meaningful signal ("no config to show here").
            if r.manifest.get("config"):
                (detail_dir / "manifest.json").write_bytes(zf.read("template.json"))

    # The aggregate catalog.json is copied in so the frontend can fetch
    # /templates/catalog.json without reaching back into the repo.
    write_catalog_json(records, out_dir / "catalog.json")


def render_index(tmpl: str, records: list[TemplateRecord]) -> str:
    """Very light string substitution — the site's JS does most of the
    rendering from catalog.json at page load."""
    cards = []
    for r in records:
        m = r.manifest
        author = (m.get("author") or {}).get("name", "")
        tags_html = "".join(f'<span class="tag">{t}</span>' for t in (m.get("tags") or []))
        cards.append(
            '<a class="card" href="{slug}/">'
            '<h3>{name}</h3>'
            '<p class="desc">{desc}</p>'
            '<div class="meta"><span class="author">{author}</span>'
            '<span class="version">v{version}</span></div>'
            '<div class="tags">{tags}</div>'
            '</a>'.format(
                slug=_html_escape(r.detail_slug),
                name=_html_escape(m["name"]),
                desc=_html_escape(m["description"]),
                author=_html_escape(author),
                version=_html_escape(m["version"]),
                tags=tags_html,
            )
        )
    count = len(records)
    return (
        tmpl.replace("{{CARDS}}", "\n".join(cards))
            .replace("{{COUNT}}", str(count))
            .replace("{{COUNT_PLURAL}}", "" if count == 1 else "s")
    )


def render_detail(tmpl: str, record: TemplateRecord) -> str:
    m = record.manifest
    author = m.get("author") or {}
    author_html = _html_escape(author.get("name", ""))
    author_url = author.get("url") or ""
    if author_url:
        author_html = f'<a href="{_html_escape(author_url)}">{author_html}</a>'
    tags_html = "".join(f'<span class="tag">{_html_escape(t)}</span>' for t in (m.get("tags") or []))
    install_url = record.install_url
    tokens = {
        "ID": m["id"],
        "NAME": m["name"],
        "VERSION": m["version"],
        "DESC": m["description"],
        "AUTHOR_HTML": author_html,
        "CATEGORY": m.get("category") or "",
        "TAGS_HTML": tags_html,
        "INSTALL_URL_ENCODED": install_url,
        "SCARF_INSTALL_URL": f"scarf://install?url={install_url}",
    }
    out = tmpl
    for k, v in tokens.items():
        out = out.replace("{{" + k + "}}", _html_escape(v) if k != "TAGS_HTML" and k != "AUTHOR_HTML" else v)
    return out


def _html_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
         .replace('"', "&quot;")
         .replace("'", "&#39;")
    )


if __name__ == "__main__":
    sys.exit(main())
