---
title: Phase-1 Milestone 2: Mini-apps — implementation decisions
type: note
permalink: scarf/decisions/phase-1-milestone-2-mini-apps-implementation-decisions
tags: [projects, phase-1, milestone-2, miniapps, decision, security, webkit, acp]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppBridge.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppAssetResolver.swift, scarf/scarf/Features/Projects/MiniApp/ScarfMiniAppBridge.swift, scarf/scarf/Features/Projects/MiniApp/MiniAppSchemeHandler.swift]
source_paths_inferred: false
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
created: 2026-06-16
updated: 2026-06-16
reviewed: 2026-09-03
reviewed_by: audit:claude-code (background)
---

## Observations
- [architecture] A mini-app is web content (HTML/JS/CSS) in `<project>/.scarf/miniapps/<id>/`, rendered in a `WKWebView` over a versioned `window.scarf` bridge. Served via a directory-scoped `scarf-miniapp://` `WKURLSchemeHandler` (NOT file://). Discovered by `MiniAppService` (dir name forced as canonical id). Registered in `ScarfProject.miniApps`. #architecture
- [trust-boundary] The spine is pure + unit-tested in ScarfCore: `MiniAppBridgeMethod` (method→required-permission + implemented flag), `MiniAppBridgeDispatcher.preflight` (DEFAULT-DENY; permission checked BEFORE implementation status so a future surface can't be probed). The Mac `ScarfMiniAppBridge` (`WKScriptMessageHandlerWithReply`) only runs a surface after preflight passes. #security
- [grants] Per-machine grants in `~/.hermes/scarf/miniapp_grants.json` (`MiniAppGrantStore`), keyed (projectId, miniAppId) — deliberately NOT in the portable `project.json` (a clone re-approves). The `MiniAppPermissionPreview` sheet is the user's trust decision: sensitive perms (`prompt`, `net`, `file:write`, `kanban:write`, unknown) default OFF for `generated:true` (agent-written) apps. #security
- [agent-channel] `scarf.prompt`/`onEvent` bind a DEDICATED, project-scoped `hermes acp` session per mini-app (`MiniAppAgentSession`, own `ACPClient`, cwd=project root), lazy-started on first prompt, torn down on host dismantle (incl. `.id`-driven recreation when grants narrow). Chosen because the cockpit launch has no chat session to bind to + matches the self-contained-surface vision. prompt() resolves from accumulated messageChunks on `promptComplete`; `MiniAppRateLimiter` (pure, sliding-window) caps runaway loops; ACP permission requests are AUTO-DENIED (no human UI in a mini-app session → would hang). `onEvent` streams via `evaluateJavaScript(window.__scarfEmit(...))`. #acp
- [data-channel] `scarf.file.read` (read-only, contained to project root via the symlink-hardened `MiniAppAssetResolver.containedFilePath`, 4MB/UTF-8 cap) and `scarf.query("kanban.tasks")`/`scarf.kanban.read` (KanbanService scoped to the project tenant; `HermesKanbanTask` is Codable). query's permission is the kind-specific `query:<kind>`, enforced in the handler. #data
- [hardening] `containedFilePath` resolves symlinks on BOTH base + candidate (the M2-review HIGH fix — see [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]); `minBridgeVersion` enforced at mount (`MiniAppBridge.satisfiesMinBridgeVersion`); CSP `connect-src 'none'`; navigation locked to the scheme. #security
- [deferred] (1) `.scarftemplate` mini-app DISTRIBUTION — packaging `miniapps/<id>/` through the installer/exporter/validator/lock pipeline. Not built; it's a cross-cutting change in the security-sensitive template subsystem. Mini-apps ship today via agent-generation (primary) + manual drop. (2) PRIVACY-sensitive query kinds — `sessions`/`messages`/`cron.jobs`/`insights.tokens` return `not_implemented`; exposing chat content to untrusted/agent-generated web needs a deliberate privacy decision. (3) `kanban:write`, `net` allowlist — perms exist, surfaces don't (read-only v1 per design Decision). #deferred
- [tests] ScarfCore ~671 green incl. MiniApp* suites (manifest/permission/resolver/bridge/grant/store/rate-limiter). MiniAppAgentSession now has runtime regression tests (scarfTests/MiniAppAgentSessionTests — 9 tests via an injected ACPClient + in-memory FakeACPChannel) and a completion bug was fixed there (see [[ACP turn completion is sendPrompt's return, not a stream .promptComplete event]]). ScarfMiniAppBridge (WKScriptMessageHandlerWithReply) + JS shim + WKWebView host remain build-verified only — testing the bridge needs a dispatch seam since WKScriptMessage isn't constructible in tests. #testing

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]
