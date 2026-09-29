---
title: Project chats on Hermes 0.16+ carry the environment hint and strip the managed block (P3 wiring)
type: note
permalink: scarf/architecture/project-chats-on-hermes-0-16-carry-the-environment-hint-and
tags: [gh142, environment-hint, capabilities, chat]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectEnvironmentHint.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Scarf iOS/Chat/ChatView.swift, scarf/scarf/Core/Services/ProjectAgentContextService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectCronTenantCheck.swift, scarf/scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift, scarf/scarf/Features/Projects/ViewModels/ProjectCockpitViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesYAML.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-29
updated: 2026-09-29
---

Wiring for #142 P3 (Mac, ScarfGo, installer, upgrade, scaffolder, cockpit). The gate is ProjectEnvironmentHint.delivery(for:), which returns the block path for .empty capabilities.

## Observations
- [decision] Capabilities for the gate must be CONFIRMED by a probe. Mac chat and cockpit use HermesCapabilitiesStore.confirmedCapabilities(), which awaits the in-flight probe and returns .empty for a provisional last-known value. ScarfGo uses HermesVersionCache.shared.capabilities(for:). Installer, upgrade and scaffolder use capabilitiesSync. All of these give .empty on a failed probe, so the managed block stays (C1) #capabilities
- [gotcha] The Mac ChatViewModel builds its ACPClient before the async project prep runs, so the hint sits in EnvironmentHintSlot, keyed by project path. The default acpClientFactory (set in init) reads the slot when start() opens the channel. The slot is written only after the startStillCurrent guard, so a superseded start can't overwrite a newer start's value. Reconnect and autostart spawns for the same project reuse the slot. An injected acpClientFactory (tests, BotConversationViewModel) ignores it #chat
- [fact] The migration is ProjectContextBlock.stripForEnvironmentHint. It removes the block from every context file that has one, and deletes an AGENTS.md or agents.md that held only the block. The older removeBlock(forProjectAt:) does NOT delete such files; it leaves them empty. The config hint is agent.environment_hint, read from the target host's config.yaml via context.readText #migration
- [decision] Bots are never project-scoped, so they get no hint. MiniAppAgentSession (P6, Alan's call) gets the SAME hint as a project chat on a confirmed v0.16+ host: MiniAppAgentSession.projectHint runs the chat gate + ProjectEnvironmentHint.prepare (strip included) before the spawn and passes it through the clientFactory's second argument; below v0.16 / unconfirmed it spawns with no hint and still never writes the block. ensureSession checks an isShutDown flag after its awaits so a shutdown mid-prep never leaks a hermes acp. A strip failure is only logged: ScarfGo shows no 'Project context not written' banner on the hint path #scope
- [decision] P6 cockpit: on a confirmed hint host, the Cron panel flags this project's attributed jobs whose prompt creates Kanban tasks without naming the tenant (ProjectCronTenantCheck: `kanban create`/`kanban_create`, case-insensitive, and neither `--tenant` nor the tenant value) and offers a copyable corrected prompt; Scarf never rewrites jobs. The cockpit re-reads via capabilitiesChanged() (LoadReason.capabilities: bypasses the file-signature short-circuit, never runs the doctor) when the view's onChange sees the store's confirmed supportsEnvironmentHint flip #cockpit
- [fact] ProjectEnvironmentHint.configHint mirrors Hermes's `str(value).strip()`: block scalars (ParsedYAML.blockScalarPaths) are taken verbatim (no ` #` cut, no unquote), double-quoted escapes decoded, lists/maps rendered Python-str-like rather than nil, so a set-but-odd user hint is never silently replaced by Scarf's env var. Remaining gaps: typed scalars stay as written (`yes`, not `True`); a bare `environment_hint:` (null, which Hermes reads as "None") returns nil. The remote hint (user's config hint included) is visible in `ps` by accepted decision #parsing
- [convention] Tests that exercise install, upgrade or scaffold AGENTS.md behaviour must pin the host with HermesVersionCache.shared.primeForTesting(.parseLine(...), for: ctx). Otherwise they probe the developer's real hermes, and a 0.16+ install takes the strip path #testing

## Relations
- relates_to [[HERMES_ENVIRONMENT_HINT replaces the AGENTS.md managed block on Hermes 0.16+]]
- relates_to [[HERMES_ENVIRONMENT_HINT must be composed, never set: env replaces config agent.environment_hint]]
