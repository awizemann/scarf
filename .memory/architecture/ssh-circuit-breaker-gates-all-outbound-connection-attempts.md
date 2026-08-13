---
title: SSH circuit breaker gates all outbound connection attempts
type: note
permalink: scarf/architecture/ssh-circuit-breaker-gates-all-outbound-connection-attempts
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHConnectionGate.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHScriptRunner.swift]
source_paths_inferred: false
source_sha: 3d296051a875184a3c4d5b0cf42c18593e48af73
created: 2026-08-13
updated: 2026-08-13
---

Every outbound SSH attempt on macOS goes through the per-host circuit breaker `SSHConnectionGate` (gh#138). Rationale: Scarf uses system ssh, so a user's `ProxyCommand` can have side effects per connection attempt — Cloudflare Zero Trust's `cloudflared` opens a browser OAuth tab, Secretive/hardware agents prompt. Background pollers (watchPaths 3s, connection status 15s) must never retry a dead host unboundedly.

Mechanics: 3 consecutive connection-level failures (ssh exit 255, or dial timeout) open the gate; callers then get `TransportError.circuitOpen` instantly with no process spawn. One probe is admitted per backoff window (30s doubling to 300s cap); success closes the gate.

Rules when touching SSH paths:
- Any NEW code path that spawns ssh/scp toward a server must check `SSHConnectionGate.shared.admit` and record outcomes (or route through `SSHTransport.runLocal`, which does it).
- scp is admit-only: its exit codes don't distinguish connection failure (exits 1, not 255) — never feed scp exits into the gate.
- Local-only ControlMaster ops (`-O check` / `-O exit`) are exempt (GatePolicy.none): they never dial and their non-zero "no master" exits would poison the gate.
- Explicit user actions (Test Connection probe, chat Reconnect button, server removal) call `reset` — user intent overrides the backoff.
- ACP `makeProcess` sessions are ungated; ChatViewModel's reconnect loop is already capped at 5 attempts with its own backoff.


## Observations
- [fact] All macOS ssh/scp spawns toward a server must pass SSHConnectionGate.shared.admit; 3 consecutive exit-255/timeout failures open the gate (30s→300s backoff, single probe) #ssh #gh138
- [fact] scp exit codes cannot distinguish connection failure (exits 1, not 255) — scp is admit-only, never feeds the gate #ssh
- [fact] ssh -O check / -O exit are local socket ops — exempt from the gate or they poison it with "no master" non-zero exits #ssh
- [fact] Test Connection, chat Reconnect, and server removal reset the gate — explicit user intent overrides backoff #ux
