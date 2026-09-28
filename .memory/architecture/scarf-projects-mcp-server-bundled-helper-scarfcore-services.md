---
title: scarf-projects MCP server: bundled helper, ScarfCore services, no parallel writers
type: note
permalink: scarf/architecture/scarf-projects-mcp-server-bundled-helper-scarfcore-services
tags: [projects, mcp, phase-5, agents, stdio]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit, scarf/Packages/ScarfCore/Sources/scarf-projects-mcp/main.swift, scarf/Packages/ScarfCore/Package.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/DashboardWidgetCatalog.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift]
source_paths_inferred: false
source_sha: f6fdb87f6cbf0de6dc3f7b0140ac9b4f6317ede8
created: 2026-09-03
updated: 2026-09-27
reviewed: 2026-09-26
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] Every tool wraps an EXISTING ScarfCore service (`ProjectStore`, `ProjectDashboardService`, `ProjectSlashCommandService`, `ProjectDoctorService`) — no tool writes JSON itself. `project_register` is `store.save(store.derive(from: entry))`, which writes `.scarf/project.json` and upserts the registry row in one call, with the id derived from (host, path) per Phase 3. `project_set_config` SHIPPED (2026-09-04) as a seventh tool, now using `GuardedJSONStore` for read-modify-write to refuse writes when config.json is unreadable (preserving the whole object graph and preventing Keychain orphaning). `ProjectConfigKeychain`/`TemplateKeychainRef` (plus `TemplateSlug.derive` helper) were LIFTED into `ScarfCore/Services/ProjectConfigKeychain.swift` as public types, with the app target's originals replaced by `typealias`es pointing back at ScarfCore, so the tool mints/resolves the SAME `com.scarf.template.<slug>` refs through the SAME `SecItem*` calls the Configuration UI uses. The tool cross-checks a field's declared `secret`-ness against the caller's `secret:` argument by reading `<project>/.scarf/manifest.json` as raw `JSONValue` (no dependency on the app-only manifest model); a schema-less project trusts the caller's flag alone. A plaintext `keychain://` value in `value` is always refused — refs are only minted inside the tool via `TemplateKeychainRef.make`. #projects #mcp
- [constraint] The Phase-2 lossy-registry refusal is re-asserted in the tools: a mutation refuses when `loadRegistryDetailed().salvaged` reports dropped ROWS or a quarantine, because `ProjectStore.indexInRegistry` reads through the salvaging decoder and writes the result back. Field-level salvage deliberately does NOT block. Read tools carry a `registry.healthy` block so an agent learns the file is damaged BEFORE a write is refused. #dataloss
- [decision] `project_register` now validates the project root via `ProjectRootPolicy.refusal(for:context:)` to refuse absurd roots (/, $HOME, system dirs, paths at-or-above ~/.hermes) at the one place an agent can mint a root — this gate prevents PathGuard/WidgetPathResolver/MiniAppAssetResolver containment checks from becoming vacuous. #projects #security
- [decision] `DashboardWidgetCatalog` (ScarfCore) is the Swift mirror of `tools/widget-schema.json`, which is a REPO file the shipped app cannot read — so before Phase 5 nothing could check a dashboard before it landed. `ProjectDashboardService.saveDashboard(rawJSON:for:)` is the single writer: decode with the real `ProjectDashboard` types, then catalog-validate, then re-serialize via JSONSerialization (NOT the model encoder — a model round-trip would delete every key the model doesn't declare). #projects #validation
- [gotcha] A tool refusal is a SUCCESSFUL `tools/call` carrying `isError: true`, never a JSON-RPC error — the model is meant to read the reason and fix its input. Only a malformed envelope is a protocol error. Notifications (`id` absent, or explicitly null) are never answered: replying to `notifications/initialized` makes strict clients drop the connection. #mcp
- [gotcha] Xcode builds ScarfCore as a DYNAMIC framework for the app, so the helper copied into the bundle linked `@rpath/ScarfCore.framework` against `…/Build/Products/…/PackageFrameworks` and died at dyld. Fixed with a `-rpath @executable_path/../Frameworks` linker setting on the executable target; `swift build` links statically and ignores it. Also: the test target DEPENDS on the executable, or `swift test` never builds it and the stdio smoke test silently skips. #build #gotcha

## Relations
- relates_to [[Project mutations report failure; registry damage banner is signature-dismissed]]
- relates_to [[Project ids are derived from (host, path), never minted on a read]]
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]
- relates_to [[Project Doctor reconciles three sources of truth and repairs only via existing writers]]


## B03 (blind re-audit S12-F2): the entry is pinned to its profile's home
- [gotcha] Hermes launches stdio MCP servers with a filtered env (PATH/HOME/USER/LANG/LC_ALL/TERM/SHELL/TMPDIR + XDG_* only — `tools/mcp_tool_config.py:74,111-119` @ v2026.9.24), so HERMES_HOME never reaches `scarf-projects-mcp`; unpinned, it fell back to the sticky `active_profile`, and a `hermes -p work` agent wrote into another profile's registry. `ProjectsMCPRegistrar` now pins `args: [--hermes-home, <profile home>]`. #mcp #profiles
- [constraint] The pin is written by `HermesFileService.setMCPServerArgs` (in-place block-list patcher with read-back), NOT `hermes mcp add --args`: `--args` was `nargs="*"` until v2026.6.19 (commit dca11b6650) and rejects `--hermes-home` as an unrecognized argument on older hosts. Creation stays the bare `mcp add --command <path>` every supported host accepts. #C1 #C5
- [decision] `hermes profile create --clone` copies config.yaml (`hermes_cli/profiles.py:35`), carrying the source's pin, so each launch also re-pins EXISTING `scarf-projects` entries in the other local profiles (only when the command is a `scarf-projects-mcp` binary; never adds one). #profiles
