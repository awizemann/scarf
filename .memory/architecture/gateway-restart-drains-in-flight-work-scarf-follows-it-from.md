---
title: Gateway restart drains in-flight work; Scarf follows it from gateway_state.json
type: note
permalink: scarf/architecture/gateway-restart-drains-in-flight-work-scarf-follows-it-from
tags: [hermes, gateway, restart, c10]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift, scarf/scarf/Core/Services/HermesFileService.swift]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-27
updated: 2026-09-27
---

B05 / S07-F3. A service-managed `hermes gateway restart` is not a bounce: launchd_restart / systemd_restart send SIGUSR1 and the gateway waits for in-flight turns before exiting with the restart code; the service manager starts the replacement. Scarf's restart spawn stays capped at 60 s (C10) and then consults the state file.

## Observations
- [fact] launchd/systemd restart = SIGUSR1 + wait up to restart_drain_timeout + restart_after_turn_timeout (1800 default) + 15 s (`gateway_launchd.py:744-790`, `gateway.py:3303-3335`, `gateway/restart.py:358-361` @ v2026.9.24); KeepAlive SuccessfulExit=false / RestartForceExitStatus=75 revive it, so killing the CLI after SIGUSR1 cancels nothing #gateway
- [gotcha] The CLI's drain announcement (`→ Stopping gateway (PID …) — draining…`) is block-buffered through Scarf's pipe, so a run killed at the timeout usually returns none of it — detect the drain from `gateway_state.json` (`gateway_state: "draining"`, since v2026.4.13; `active_work` units since v2026.7.20 / 0.19), never from output #gateway
- [decision] `HermesGatewayServiceVerdict.judge(drainingAfterTimeout:)` turns a timed-out restart into `.unconfirmed` with `HermesGatewayRestartDrain.pendingNote` only when the caller read `draining` after the timeout; no evidence keeps the old failure verdict, a printed refusal still wins #verdict
- [decision] `GatewayRestartDrainWatcher` (app target) polls the state file off-main every 10 s, phases draining → waiting for service manager → starting → restarted/failed by PID change, bounded by Hermes's budget (announced or 1815 s) + 120 s grace; `Stop Waiting` only ends Scarf's watch. Used by the Gateway pane and Platforms; MCP pane just shows the note #ux

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes gateway multiplex-by-default and parked profiles (v0.21.4 / v0.21.5)]]


## Fresh-eyes corrections (B05)
- [gotcha] `gateway_state: "draining"` is NOT restart evidence on its own: a SIGTERM stop, scale-to-zero (`run_shutdown.py:542`) and a dashboard drain (`:698`) write it too, and before v2026.8.31 `launchd_restart` was SIGTERM + the CLI's own `launchctl kickstart -k`, which Scarf's 60 s kill prevents (gateway stays down). Only `restart_requested: true` (set solely by SIGUSR1 `request_restart`, `run_shutdown.py:1609-1617`) makes it a watched restart — `Snapshot.isDrainingForRestart` #gateway
- [decision] The watcher finishes `.notRevived` 90 s after the old PID is gone with no replacement (units without KeepAlive/RestartForceExitStatus relied on the killed CLI's follow-up `start`/`kickstart`); the budget comes from config.yaml `agent.restart_drain_timeout + restart_after_turn_timeout + 15` when the CLI's buffered announcement never arrived #gateway
- [decision] Pre-v0.21.0 launchd hosts (`hasLaunchdInBandRestart` false; SIGTERM + wait `agent.restart_drain_timeout` + the CLI's own `kickstart -k`, `gateway.py:5537-5584` @ v2026.8.27): `HermesGatewayRestartDrain.restartSpawnTimeout` raises the restart spawn ceiling to drain (180 if unset) + 120 s so the CLI's kickstart isn't killed; 0.21+ keeps 60 s #gateway #capability-gating
