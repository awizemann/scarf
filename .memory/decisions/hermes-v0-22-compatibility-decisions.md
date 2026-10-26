---
title: Hermes v0.22 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-22-compatibility-decisions
tags: [hermes, capability-gating, versioning, v022]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/scarf/Features/Plugins/ViewModels/PluginsViewModel.swift]
source_paths_inferred: false
source_sha: 60e38b31e53c0c0db6a6853677d27cfaa2f68ce4
created: 2026-10-25
updated: 2026-10-25
---

Scarf's Hermes v0.21.6 → v0.22.5 parity cycle (2026-10-24/25), branch `feat/hermes-v0225-parity`. Audit + plan: documents/plans/2026-10-24-hermes-v0-22-5-audit-and-plan.md. Seven slices (S1–S7), each built in its own worktree, fresh-eyes audited, then cherry-picked. Tasks t-5a840e26, t-1301c677, t-69cf8a08, t-9b7739c1, t-434180c7, t-ba7bbc57, t-0cf09691, t-7e2da589.

## Observations
- [decision] Flags added: v0.21.6 hasStrictYAMLConfigLoader, hasPluginInstallDepsConsent, hasImportPartialExitNonZero, hasCronInterpreter, hasCatalogMemoryProviders, hasCatalogHomeAssistant, hasStatusSummaryDefault; removals (true BELOW 0.21.6) hasBundledTirith, hasSkillsOrgMirror; v0.21.7 hasSpotifyPluginLogin, hasCatalogHolographicMemory; 0.22.1-or-≥0.22.3 hasGatewayBackedACP, hasGatewayIncompatibleOwnerStatus; ≥0.22.3 hasGatewayLiveSessionGuard, hasGatewayRestartDetach; v0.22.5 hasCatalogSingularity. Windows: hasPluginsCompat 0.21.1–0.21.5, hasCompressionThresholdTokensDefault256K 0.21.4–0.21.5; hasACPStoppedPromptCarriedForward off on gateway-backed ACP. krea-3 and rentahuman gate inline on isV0223OrLater (catalog pattern, no named flag) #capabilities
- [decision] Applied on ALL hosts as bug fixes (Alan's 2026-09-27 rule: byte-identical protects new affordances, not bugs): vllm/llamacpp/llama.cpp/llama-cpp/local → custom provider aliases (false stale-prefix banner); permission options classified by ACP `kind` (clarify `skip` was read as allow); PromptResponse usage replaced not summed (it is a running total since v2026.4.23); tui/desktop session icons; quoting bare y/n when Scarf writes YAML; epoch-bounded last-active SQL #decision
- [gotcha] `hermes status --all` printed API keys UNREDACTED on v2026.3.30–v2026.6.19 (status.py:135,168), was ignored v2026.7.1–v2026.9.24, and means --full from v0.21.6 — so Scarf sends `--all` only on hasStatusSummaryDefault hosts (HermesStatusArgv.full). Never add a flag to an old host just because argparse accepts it #security
- [decision] Consent is never laundered: Scarf passes `gateway stop|restart --yes` only after an explicit confirm on hosts ≥0.22.3, and a live-session refusal never reaches stopHermes's pgrep/SIGTERM fallback on any host. Plugin dependency consent goes through `plugins enable -- <installed name>` (never `install --force --yes-deps`: --force also waives a caution security-scan verdict); memory providers instead get a `hermes memory setup <name>` Terminal hint #safety
- [decision] Known gaps accepted: live events of a turn still running after an ACP reconnect only appear on the next history load; deferred model pick refused at the turn boundary doesn't revert the badge; usage_update/plan ACP notifications unhandled; duplicate-key scan compares key text (1: vs '1': false positive, y:/true: missed); `- - a:` compact nested sequences missed; Bots duplicate refusal shows the generic unsafeToWrite text; on 0.22.1 the incompatible-owner Restart is always refused #todo

## Relations
- relates_to [[Hermes v0.21.4/v0.21.5 Compatibility Decisions]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.22 Wire Verification]]
