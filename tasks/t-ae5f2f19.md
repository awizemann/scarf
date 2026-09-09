---
id: t-ae5f2f19
title: Audit P16: capabilities/roster hygiene and small dead-code cleanups
status: todo
added: 2026-09-08
---

## Description

From documents/hermes-v0.21.1-whole-surface-audit.md. Brief: documents/hermes-v0.21.1-parity-agent-brief.md.
1. HermesCapabilities.swift:646,652,658,671,680,691,698: v2026.7.30 is 0.19.1 (pyproject.toml), a numbered release; those seven surfaces exist there. Add `isV0191OrLater` and repoint; fix the doc reasoning; tests for a 0.19.1 host.
2. WebToolsBackendRoster.swift:38,51,61: prepend `""` (inherit; config_defaults.py:350-352 defaults) so a stock config doesn't render blank; :65-70 generalise "widen with selected" to every backend, not only tavily.
3. AgentTab.swift:101-109 + HermesServiceTier.swift:102-104: when the probe failed but the stored value is bounded (`auto`/`cold`), fall through to the picker path so the toggle never clobbers it; delete or wire the unreachable old-host branch.
4. HermesCapabilities.swift:751,762,797,808,833,852,858,865,900: re-pin citations past EOF of the modularised main.py (browser → subcommands/browser.py:19; _BUILTIN_SUBCOMMANDS main.py:2595; cron doctor :184, incidents :165, resume flags :146-147, --deliver :31, --reasoning-effort :72,135; is_job_runnable jobs.py:482-485; BUILTIN_PERSONALITIES personality.py:17). Fix :223 (transform_llm_output is not surfaced) and :811 (no cron --reasoning-effort path). Annotate the 32 consumer-less flags "no consumer yet". Truncate the header narrative (:8-23) to a pointer at the MARK sections. HermesTool.swift:171 reference hasPhotonPlatform.
5. HealthViewModel.swift: delete dead loadVersion/parseOutput/splitCheck/iconForSection/runHermes (:528,628,691,707,903-906) and the two doc mentions (:915,:993); add a `screen_recording_capturable` tri-state row (:296-318).
6. PluginsView.swift:33-39,229: hoist compatBanner above the isLoading/isEmpty/list branch.
7. GatewayView.swift:145-149: gate PID on isRunning && !servedByMultiplexer. GatewayViewModel.swift:93,240,311 + GatewayView.swift:72: fix `--json` claim, :6133 citation, target tag. HermesGatewayListService.swift:48-81: remove unreachable platform clauses/empty branch. PlatformsView.swift:187-188 + PlatformsViewModel.swift:142: drop dead `imessage` arms.
8. CredentialPoolsViewModel.swift:413,535-551: send `internalID` as the target when non-empty (credential_pool_admin.py:87-111 resolves id → label → index; a label "2" collides). FleetApplyExecutor.swift:382: all-script-only → `.skipped`, not `.applied`.

## Plan



## Artifacts



