---
title: Test-Harness
type: note
permalink: scarf-wiki/test-harness
created: 2026-05-29
updated: 2026-05-29
---

# Test Harness

Each pre-release cycle Scarf runs an end-to-end harness that drives the app against an isolated Hermes home, using a freshly-shipped `.scarftemplate` from the [Template Ideas backlog](Template-Ideas) as fixture data. The act of authoring + installing + exercising a new template *is* the regression test.

This page is for contributors extending the harness. Users wanting to install templates should read [Project Templates](Project-Templates).

## Goal

A pre-release run is a single `xcodebuild test` invocation against the dev Mac. Green = the install / configure / dashboard journey works end-to-end against the new template. Red = a screenshot+log bundle lands under `derivedData/Logs/Test/` for triage.

The harness explicitly does NOT cover:

- **Chat / ACP streaming.** Non-deterministic and depends on a real model API key. Stays a manual smoke step.
- **Real Keychain prompts.** XCUITest can't accept Keychain dialogs. Templates with `secret`-typed config fields are exercised via Layer A only until we add a fake-Keychain shim.
- **Sparkle update checks.** The `--scarf-test-mode` launch arg suppresses them.
- **NSOpenPanel folder picking.** The install-sheet's parent-dir input is a `TextField`; tests type into it directly rather than driving the panel.
- **OAuth device flows.** Same reason — no programmatic accept.

## Architecture (two layers)

### Layer A — programmatic (Swift Testing)

Lives in [`scarf/scarfTests/TemplateE2ETests.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarfTests/TemplateE2ETests.swift).

Two suites:

1. **`HackerNewsDigestTemplateE2ETests`** — unpacks the shipped `.scarftemplate` from `templates/awizemann/hackernews-digest/`, validates manifest + config schema + cron prompt + dashboard against the same `ProjectTemplateService` the app uses at install time, and asserts the resulting `TemplateInstallPlan` would write the right files in the right places. This is what catches "a contributor changed the dashboard widget vocabulary and didn't update the template."
2. **`ScarfHermesHomeOverrideE2ETests`** — proves the `SCARF_HERMES_HOME` env-var override actually steers `ServerContext.local.paths`. Exists because every other test depends on it; if it silently regresses, future UI tests would suddenly start writing to the user's real `~/.hermes`. Detection-cost is one tiny suite that runs in milliseconds.

The pattern for a third template: copy `HackerNewsDigestTemplateE2ETests`, change the bundle name, swap the assertions for the new template's shape. Five-ish minutes per added template.

### Layer B — UI driving (XCUITest)

Lives in [`scarf/scarfUITests/TemplateInstallUITests.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarfUITests/TemplateInstallUITests.swift).

**Layer B drives the dev Mac's real `~/.hermes/` installation, not an isolated tmpdir.** The XCUITest runner is sandboxed (it can read `~/.hermes/` but not write to it), which kills the snapshot-and-restore-from-the-runner pattern. Instead, the harness:

- Reads `~/.hermes/scarf/projects.json` and `~/.hermes/cron/jobs.json` for assertions.
- Drives the install/uninstall through the app's UI — which runs unsandboxed and has full disk access.
- Uses a tagged cron-job-name prefix (`[tmpl:awizemann/hackernews-digest]`) and a tmpdir parent (`/tmp/scarf-uitest-…`) so cleanup-on-crash is bounded: at worst, an orphan project dir under `/tmp` (auto-reaped) and one tagged cron job (`hermes cron remove …` recovers).
- Skips entirely (XCTSkip) on a Mac without `hermes` at `~/.local/bin/hermes`.

Each test launches the Mac app with:

```
launchArguments: --scarf-test-mode
```

The app activates, the harness sends ⌘1 (the "Open Server → Local" menu shortcut) to surface a window — SwiftUI's `WindowGroup(for: ServerID.self)` doesn't auto-open under `XCUIApplication.launch()` and the keyboard shortcut takes the same code path real users hit via Dock click. Then the install/configure/dashboard journey runs via accessibility identifiers, using the v2.8+ in-app [Template Catalog](Template-Catalog) as the entry surface:

```
1. Click the Templates toolbar menu                  (templates.toolbar.menu)
2. Click "Browse Catalog…"                           (templates.browseCatalog)
3. (optional) Type into the catalog search field     (catalog.searchField)
4. Tap the row matching the template under test      (catalog.row.<detailSlug>)
5. Click Install on the detail page                  (catalogDetail.installButton)
6. Type a tmpdir path into the parent directory      (templateInstall.parentDir.field)
7. Click Continue                                    (templateInstall.parentDir.continue)
8. Configure step: leave defaults, click Continue    (config sheet — TODO IDs)
9. Click Install in the confirm sheet                (templateInstall.confirmInstall)
10. Wait for project to surface; verify dashboard rendered
```

Today (v2.7) the suite only covers steps 1–2 of that journey via a smoke test that proves the harness can launch the app and surface a window. v2.8 lands the catalog browser + IDs so steps 3–5 become drivable; v2.9 adds the configure-step IDs to close the gap. Layer A's `TemplateE2ETests`/`CatalogServiceTests`/`CatalogViewModelTests` already cover the non-UI install path end-to-end, so the regression value of the half-driven Layer B today is bounded: launch + window-surface checks only.

Two alternate Layer B entry points (still using the v2.7 IDs) bypass the catalog and go through the older install paths — useful for tests targeting the install pipeline itself rather than the catalog discovery surface:

- **Install from URL** — `templates.toolbar.menu` → `templates.installFromURL` → `templates.installURL.field` → `templates.installURL.confirm`.
- **Install from File** — `templates.toolbar.menu` → `templates.installFromFile` → (NSOpenPanel — not drivable from XCUITest, so this path is for manual smoke tests only).

A single screenshot is captured on success; on failure the test framework auto-attaches the rendered tree, console log, and a screenshot for triage.

## Adding a template to the harness

1. **Create the bundle.** Mirror `templates/awizemann/hackernews-digest/staging/` for shape: `template.json`, `README.md`, `AGENTS.md`, `dashboard.json`, optional `cron/jobs.json`. Run `python3 tools/build-catalog.py --check` until green.
2. **Add Layer A coverage.** In `TemplateE2ETests.swift`, add a new `@Test` function that calls the same parse + plan + assert pattern as `hackernewsDigestParsesAndPlans()`. Adjust assertions to match your template's manifest, config schema, and dashboard shape. ~30 minutes.
3. **Add accessibility IDs only for new widget shapes.** Most templates reuse the dashboard widget vocabulary (`stat`, `list`, `text`, etc.) — those already have IDs. If your template introduces a new install-time UX (e.g. the first secret field, the first OAuth provider), add IDs for the new controls and centralize them in `UITestIdentifiers.swift`.
4. **Extend Layer B only when warranted.** Every shipped template inherits the existing install / configure / dashboard XCUITest. You only need to write new XCUITest code if the install flow itself changes — e.g. a template that introduces a secret field would justify a new test that exercises the fake-Keychain shim once we add it.
5. **Run locally.** `xcodebuild test -scheme scarf -destination 'platform=macOS'` should be green before you open the PR.

## Launch arguments + env vars

| Variable / Argument | Where read | Effect |
|---------------------|------------|--------|
| `SCARF_HERMES_HOME` (env var) | `HermesProfileResolver.resolveLocalHome()` | Pins the resolver to the supplied absolute path. Bypasses both the cache and the `active_profile` lookup. Must be absolute — relative paths are rejected with a warning. **Layer A only** — Layer B drives the real `~/.hermes` because the sandboxed XCUITest runner can't write to a tmpdir-style `SCARF_HERMES_HOME` either. |
| `--scarf-test-mode` (launch arg) | `TestModeFlags.shared.isTestMode` at app init | Currently gates: `UpdaterService` initializes Sparkle inert (no on-launch update prompt). Future gating sites: Hermes capability live-probe, first-run walkthrough — added incrementally as the harness exercises them. |
| `--scarf-test-fake-keychain` (launch arg) | (planned, lands with the first secret-bearing template) `ProjectConfigKeychain` | Routes Keychain reads/writes through a process-local in-memory store so XCUITest can drive secret-field templates without the OS prompting. |

## Failure triage

When an XCUITest fails:

1. Open the latest `.xcresult` bundle under `derivedData/Logs/Test/` in Xcode.
2. The Failures tab shows the assertion + screenshot at the moment of failure.
3. The Activity log under each test step shows the full XCUITest event trace — which accessibility ID was queried, what was found, what the framework saw on the screen.
4. To reproduce interactively: open the test in Xcode, set a breakpoint at the failing step, hit Run. The app launches with the same env vars + launch args, and you can step through the click sequence by hand.

When a Layer A test fails:

1. The error message names the assertion that failed (e.g. `expected 3 fields in config schema, got 2`).
2. Read the new template's `template.json` against the assertion. Almost always the test caught real drift between the bundle and the test's expectations — fix one or the other.

## Why this shape, not other shapes

A few alternatives we considered + rejected:

- **Mocking `hermes` binary.** Too brittle — the binary's behavior changes per release, and we'd be maintaining a parallel implementation to mock. The harness uses the *real* Hermes binary on the dev Mac and assumes a working installation.
- **Isolated `SCARF_HERMES_HOME` for Layer B.** Tried and rejected: XCUITest runners on macOS are sandboxed even when the app under test isn't, so the runner can't populate a fixture tmpdir before launch. The seam still exists for Layer A's unit-level isolation; Layer B drives the real `~/.hermes/` with a tagged-cron-job cleanup story instead.
- **Visual diffing.** Image-diff infrastructure is its own multi-week project. Screenshots get captured for human review only; no pixel asserts.
- **Single-suite unit-test only.** Fast and hermetic but doesn't prove the UI actually renders. The two-layer split keeps the bulk of regression value in fast Layer A while still having a thin "did the install button do what the user thinks?" gate in Layer B.
- **Automating chat / ACP.** Non-deterministic; would block every release on flaky output. Stays a manual smoke step.

## Status

The harness is being built on the [`dogfooding-templates` branch](https://github.com/awizemann/scarf/tree/dogfooding-templates) under issue tracking the v2.7 cycle. Initial scope is Layer A + the env-var seam + the HN Digest fixture. Layer B + accessibility IDs land in the same release.

When this page reads "the harness is in production," you can run the entire pre-release sweep with `xcodebuild test -scheme scarf -destination 'platform=macOS'` and have confidence equivalent to a manual click-through.