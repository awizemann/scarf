# Scarf full-UI release gate — plan (2026-09-08)

## Where we are

- **XCUITest target `scarfUITests`**: 5 tests in 4 files. Real coverage is ONE journey (template catalog → install → sidebar → uninstall) plus launch smoke. The isolation base class (`ScarfUITestCase`: throwaway `SCARF_HERMES_HOME` + sentinel marker + `--scarf-test-mode`, every launch via `makeApp()`) is solid and load-bearing. Keep it.
- **Accessibility identifiers**: 45 total, all on Projects / Templates / Catalog / Bots / New Project. 30 sidebar sections exist (`AppCoordinator.swift`); ~25 have zero identifiers.
- **`--scarf-test-mode`** gates only the Sparkle updater today. The isolated home is empty except copied config/auth, so most sections would render empty states.
- **Release**: `scripts/release.sh` runs no tests. The only CI workflow is `validate-template-pr.yml`. The `scarf` scheme's test action bundles unit + UI tests; no `.xctestplan` files.
- **Journey test hazards**: depends on network (raw.githubusercontent) and a real `hermes` binary; uses `Thread.sleep`; the ⌘1 window-surface dance is copy-pasted per test.

## Harness — what it is and isn't for this

- Harness "replay" is a **viewer** of a finished run's `events.jsonl`, not a re-executor. Autonomous runs are LLM-driven, non-deterministic, and cost tokens. Great for exploratory UX-friction passes; wrong as a pass/fail release assertion.
- Harness MCP **step-level sessions** (`start_ui_session` macOS with `launch_args`/`env` — the docs literally use Scarf as the example — plus `observe_ui`/`act_ui`, no LLM, no key) are deterministic when scripted, but there is no scripted-walkthrough runner: we would be writing one (a second framework, in another repo, targeting AX labels instead of stable identifiers). Don't.

## Recommendation: two tiers, one fixture

**Tier 1 — release gate (deterministic, blocking): XCUITest.** Assertions, stable identifiers, Xcode result bundles with screenshots, same machine as the release build, isolation already solved.

**Tier 2 — pre-release exploratory (non-blocking): Harness.** One Application entry for the Scarf Dev build with `--scarf-test-mode` + fixture home, a persona set, and an action chain per section. Output is a friction report a human reads. Also the right tool for Claude to *author* new XCUITest journeys (observe the live app, find labels) and for ad-hoc QA.

**Shared enabler — a seeded fixture Hermes home.** Without data, a sweep only proves empty states render. Build it with the installed `hermes` CLI (`scripts/make-ui-fixture.sh`: a few sessions, memories, cron jobs (paused), kanban cards, a skill, a project), cache under the runner tmp, copy per test. Generating via the CLI keeps the state.db schema matched to the Hermes the app actually faces, and respects C3 (Scarf never writes state.db; the fixture script does, through hermes). Never check in a state.db.

## Section tiering

- **A — file/state.db backed, no live process** (gate): Dashboard, Sessions, Memory, Skills, Personalities, Quick Commands, Models, Profiles, Cron, Kanban, Logs, Activity, Insights, Health, Tools, MCP Servers, Plugins, Webhooks, Credential Pools, Platforms, Peers, Settings, Projects, Templates.
- **B — live process / provider key** (opt-in "Live" plan, skips cleanly without hermes+creds): Chat over ACP, Gateway, Proxy, Bots, Curator.
- **C — SSH/multi-server**: local server only in automation; SSH stays manual.

## Test shape

1. **Section sweep** (one parameterized test): for each `AppSection`, click `sidebar.section.<x>`, wait for `<section>.root`, assert no error banner, attach screenshot. Cheap, catches crashes and blank views across all 30 sections.
2. **Journeys** for the top flows: new project; template install/uninstall (existing, switch to a local `.scarftemplate` via `templates.installFromFile` to drop the network dependency); cron create/pause/delete; kanban card create/move; skill install; settings change persists across relaunch; model preset switch; chat send/receive (Live plan).
3. **Identifier lint** (unit test, same pattern as the unguarded-write scan test): every `AppSection` case must have a `<section>.root` identifier in source. Fails the build when a new section is added without one.

## Infrastructure

- Move the activate/⌘1/wait dance into `ScarfUITestCase.launchAndSurface()`; replace `Thread.sleep` with `waitForExistence`/predicates.
- Three `.xctestplan`s: `Smoke` (sweep, target < 5 min), `Full` (journeys), `Live` (Group B). Unit tests keep their own fast path per the existing convention note.
- `release.sh` gains a gate: run `Smoke` + `Full` against the same DerivedData before archive, `--skip-ui-tests` escape hatch that is logged loudly. Unit tests too.
- CI: a self-hosted macOS runner is required (hermes binary, Screen Recording for Harness). GitHub-hosted runners can run unit + sweep only if hermes is installed in the workflow; defer.

## Phases

1. Fixture home + section sweep + identifier lint + test plans. Biggest coverage per effort.
2. Journeys (Group A first), existing journey de-networked.
3. `release.sh` gate; measure wall time; decide on CI runner.
4. Harness exploratory chain + persona set; wire Harness MCP into `.mcp.json` so Claude can author journeys against the fixture.

## Decisions (Alan, 2026-09-08)

- The gate runs inside `release.sh`; 10–15 minutes or more is acceptable for a pre-release pattern.
- Real credentials, real Hermes: the fixture home is rebuilt per run by the `hermes` CLI, with credentials and model config copied from the developer's own `~/.hermes` (the existing `ScarfUITestCase` copy step). Contributors who want to run the gate bring their own Hermes install and keys. The Live plan (Chat, Gateway, Proxy, Bots, Curator) skips cleanly when hermes or credentials are absent. No ACP stub.
- Harness is dropped from the plan (adds a second framework and LLM cost, no gate value). Tier 2 and phase 4 below are void; tasks filed as UI gate phases 1–3.
