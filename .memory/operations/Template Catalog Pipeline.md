---
title: Template Catalog Pipeline
type: note
permalink: scarf/ops/template-catalog-pipeline
tags:
- templates
- catalog
- gh-pages
source_sha: 8d2293330e574b9e3b4ff42f6fcd155af248ab59
source_paths: tools/build-catalog.py, tools/test_build_catalog.py, scripts/catalog.sh, site/index.html.tmpl, site/template.html.tmpl, site/widgets.js, .github/workflows/validate-template-pr.yml
created: 2026-05-29
updated: 2026-05-29
---

## Observations
- [location] Shipped community templates live at templates/<author>/<name>/. templates/CONTRIBUTING.md explains author submission flow. Catalog site served at awizemann.github.io/scarf/templates/ alongside the Sparkle appcast on gh-pages — disjoint paths #paths
- [validator] tools/build-catalog.py is stdlib-only Python 3.9+. Walks templates/*/*/, validates every .scarftemplate against its manifest claim (mirrors Swift ProjectTemplateService.verifyClaims), enforces 5 MB bundle-size cap, scans for high-confidence secret patterns, checks staging/ matches built bundle byte-for-byte, emits templates/catalog.json. Tested by tools/test_build_catalog.py (16 tests) #validator
- [wrapper] scripts/catalog.sh mirrors scripts/wiki.sh shape: check / build / preview / serve / publish subcommands. `publish` runs SECOND-PASS secret-scan against rendered site before committing + pushing gh-pages #wrapper
- [site] site/index.html.tmpl + site/template.html.tmpl are {{TOKEN}}-substitution templates. site/widgets.js (~300 lines vanilla JS) renders a ProjectDashboard JSON into HTML using the same widget vocabulary the Swift app uses — each template's detail page shows a live preview of its post-install dashboard #site
- [install-url] Install URLs raw-served from main: https://raw.githubusercontent.com/awizemann/scarf/main/templates/<author>/<name>/<name>.scarftemplate. No per-template Releases ceremony #distribution
- [ci] .github/workflows/validate-template-pr.yml runs Python validator + its tests on every PR that touches templates/, the validator, or its tests. Failures post a comment with last 3 KB of validator log #ci
- [maintainer-workflow] On merge to main: `./scripts/catalog.sh build` (regenerate templates/catalog.json + .gh-pages-worktree/templates/) → `./scripts/catalog.sh publish` (secret-scan + commit + push gh-pages). Manual cadence, no auto-deploy — same as scripts/release.sh #workflow
- [isolation-rule] Runs stay isolated: release.sh only touches appcast.xml on gh-pages; catalog.sh only touches templates/ on gh-pages. NEVER push catalog output on a release cadence or vice versa #rules
- [drift-rule] Schema is Swift-primary. When ProjectDashboardWidget.type gains a new case or ProjectTemplateManifest adds a field: update Swift first, then mirror into tools/build-catalog.py (SUPPORTED_WIDGET_TYPES, _validate_manifest, _validate_contents_claim). Python test suite's real-bundle test catches drift on the example template but NOT on the full widget vocabulary — add a synthetic fixture to test_build_catalog.py for any new widget type #maintenance

## Relations
- extends [[Project Templates (.scarftemplate)]]
- complements [[Build and Release Workflow]]