---
title: Testing
type: note
permalink: scarf-wiki/testing
created: 2026-05-29
updated: 2026-05-29
---

# Testing

The bulk of Scarf's automated coverage lives in the **ScarfCore** SwiftPM package — 14 test suites covering the iOS-port milestones (M0–M9) plus dedicated parsers, services, and view-models. The Mac target has 10 additional test suites for Mac-specific surfaces (Tool Gateway, ProjectsViewModel, NousAuthFlow, template config, etc.). UI tests are placeholder-only on both targets; dogfooding fills the gap.

## Frameworks

**Swift Testing** (`@Suite` / `@Test` macros) for all new tests, not XCTest. Per [CLAUDE.md](https://github.com/awizemann/scarf/blob/main/CLAUDE.md):

- Use `@Suite` and `@Test` macros.
- Protocol-oriented services for testability — `ServerTransport` is the mocking seam, with `MockTransport` already in the ScarfCore test target.
- No timing-dependent tests: use polling with early exit, not `Task.sleep` + assertion.
- Singleton state isolation: call cleanup methods + `await Task.yield()` before assertions.
- Cross-suite state contention (e.g. `ServerContext.sshTransportFactory`) goes into a single `.serialized` suite — see `M3TransportTests.swift`. v2.5's test-reliability pass consolidated every factory-touching test there to fix flakes.

## Running

ScarfCore (the main coverage):

```bash
swift test --package-path scarf/Packages/ScarfCore
```

Mac target:

```bash
xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf
```

Or in Xcode: ⌘U with the matching scheme selected.

## ScarfCore test inventory ([`scarf/Packages/ScarfCore/Tests/ScarfCoreTests/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Tests/ScarfCoreTests))

| Suite | Covers |
|---|---|
| `ScarfCoreSmokeTests` | Module imports, public surface visibility. |
| `M0bTransportTests` | `LocalTransport` + `SSHTransport` protocol contract, atomic-write semantics, error classification. |
| `M0cServicesTests` | `HermesFileService`, `HermesEnvService`, `HermesDataService` (against fixture DBs), `ProjectDashboardService`. |
| `M0dViewModelsTests` | `IOSDashboardViewModel`, `IOSSettingsViewModel`, etc. — view-model state machines without UI. |
| `M1ACPTests` | `ACPClient` JSON-RPC framing, event extraction, error-hint pattern matching. |
| `M2OnboardingTests` | iOS onboarding state machine, key generation, paste-import flow. |
| `M3TransportTests` | `.serialized` suite for cross-suite state contention; transport factory swaps. |
| `M4ACPIOSTests` | `SSHExecACPChannel` over a Citadel test fixture. |
| `M5FeatureVMTests` | iOS feature view-models — Memory, Cron, Skills. |
| `M6ConfigCronTests` | YAML config parsing, cron job round-trip, `HermesConfig` field mapping. |
| `M9SlashCommandTests` | Project-scoped slash command parsing, `{{argument}}` substitution, default fallback, AGENTS.md block extension. |
| `SkillsHubParserTests` | `hermes skills browse`/`search` Rich-table parser — every column shape, continuation rows, header skip. |
| `SkillFrontmatterParserTests` | SKILL.md YAML frontmatter parser (`allowed_tools`, `related_skills`, `dependencies`). |
| `CronScheduleFormatterTests` | Cron string → English translator across every recognized shape. |

## Mac target test inventory ([`scarf/scarfTests/`](https://github.com/awizemann/scarf/tree/main/scarf/scarfTests))

| Suite | Covers |
|---|---|
| `ToolGatewayTests` | Tool Gateway routing, `HERMES_OVERLAYS` mirror, Auxiliary tab behavior. |
| `ProjectAgentContextServiceTests` | AGENTS.md `<!-- scarf-project -->` block — idempotency, secret-safe field-name surfacing, preserve-around-block invariant. |
| `SessionAttributionServiceTests` | Sidecar JSON read/write, attribution lookup, refresh cadence. |
| `NousAuthFlowTests` | Device-code flow parser, subscription-required detection, billing URL extraction. |
| `ProjectsViewModelTests` | Mac project sidebar — folder grouping, archive, ⌘1–9 jumps, search. |
| `ProjectRegistryMigrationTests` | v2.2 → v2.3 registry migration. |
| `CredentialPoolsGatingTests` | Per-provider strategy + last-4 preview. |
| `TemplateConfigTests` | Schema validation (string/text/number/bool/enum/list/secret). |
| `ProjectTemplateTests` | `.scarftemplate` install, lock-file accounting, uninstall preserve-user-files invariant. |
| `scarfTests` | Misc. legacy. |

163 tests across 12 suites pre-2.5; v2.5 brought that to **179 tests across 13 suites** (per the release notes), with the slash-command test additions and the cross-suite race fixes.

## Manual verification flows

For changes that touch UI or remote-host behavior, the maintainer runs:

- Open a local Mac window — Dashboard loads, Sessions browser populates, Memory editor opens.
- Open a remote Mac window — same Dashboard / Sessions / Memory, against the dogfooding host (`Mardon` Mac mini).
- Open ScarfGo against the same host — Dashboard / Chat / Skills / System all populate; Browse Hub returns results (regression check on the Citadel `executeCommandStream` v2.5 fix).
- Send a Rich Chat message — streamed response, reasoning shows if the model emits it.
- Edit and save a memory file — change appears in Hermes on next agent turn (Mac + iOS).
- Trigger `hermes memory reset` from the Memory toolbar — destructive confirm, reset runs, view refreshes.
- Run a Cron job — appears in Cron view, schedule renders as human-readable phrase.
- Toggle a tool in Tools — `hermes tools enable/disable` runs and the dot color updates.
- iOS-specific: forget a server, re-onboard, verify Keychain wipe + re-creation; Settings → Quick Edits flips a value via `hermes config set`.

## What's still under-covered

- **UI tests.** `scarfUITests/` and `Scarf iOSUITests/` are placeholder-only. Worth contributing if you have UI-test experience.
- **`HermesLogService.streamLines` remote tail.** Hard to mock SSH stream behavior cleanly; relies on the dogfooding flow today.
- **Sparkle update flow.** The auto-update path is exercised manually before each release (see [Release Process](Release-Process)).

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (179 tests, 13 suites; full inventory)_