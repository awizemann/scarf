---
title: Projects registry is salvage-decoded, quarantined, and empty-save-guarded
type: note
permalink: scarf/architecture/projects-registry-is-salvage-decoded-quarantined-and-empty
tags: [projects, registry, resilience, phase-1, codable]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectRegistrySalvage.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift]
source_paths_inferred: false
source_sha: 0d4741e1e9f141625fd194599a2286fa22a65916
created: 2026-09-03
updated: 2026-09-04
---

Phase 1 of projects-first-class (branch feat/projects-first-class, t-22700ef6), after the 2026-09-02 corruption where an agent wrote a non-UUID string into `ProjectEntry.uuid` and the strict decode emptied every project surface. `~/.hermes/scarf/projects.json` is agent-writable forever, so the READER is where the defense belongs.

## Observations
- [decision] Salvage decode lives in `ProjectRegistry`/`ProjectEntry.init(from:)`, NOT in ProjectDashboardService — `InstalledTemplatesIndex` and `KanbanTenantResolver` decode the registry with their own JSONDecoder and inherit the resilience for free. Bad optional field drops the FIELD, bad row drops the ROW, only a non-registry file throws. #projects
- [gotcha] Rows decode through a private `SalvagedRow` wrapper whose `init(from:)` never throws. Looping over an `UnkeyedDecodingContainer` and catching instead would infinite-loop: a throwing `decode` does NOT advance the container's index. #codable
- [decision] Salvage is reported via a `RegistrySalvageLog` reference passed in `JSONDecoder.userInfo[.projectRegistrySalvage]` — `Decodable.init(from:)` has no other return channel. `loadRegistryDetailed()` exposes `RegistryLoadResult{registry, salvage, quarantinePath, salvaged}` for the Phase-2 banner; plain `loadRegistry()` is unchanged for its ~20 callers. #projects
- [constraint] `saveRegistry` throws `ProjectRegistryError.refusedEmptyOverwrite` on an empty list over a file that still holds projects (or unreadable bytes). Deliberate emptying MUST pass `allowEmpty: true` — only `ProjectsViewModel.removeProject` and `ProjectTemplateUninstaller` do; a new removal path that forgets it will silently fail to remove the last project. #gotcha
- [gotcha] Do NOT add a temp-file+rename dance in registry save code: `transport.writeFile` is atomic on all THREE transports (Local `.atomic`, SSH scp-to-`<path>.scarf-<nonce>.tmp`+`mv`, iOS Citadel SFTP stage+rename). A second layer would add a non-atomic window over SSH, not remove one. CAVEAT: this was only true of the two MAC transports until t-a6f22379 — iOS Citadel truncated the destination in place. See [[Transport atomic-write parity is a per-transport contract, not a property of writeFile]]. #transport

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]


## R1 remediation (commit 7460cf9): the guard moved to the chokepoint, and "empty" got finer

- [decision] `saveRegistry` is now THE registry write guard, not just the empty-save guard: it refuses a write whose on-disk predecessor is LOSSY (`ProjectRegistryError.refusedLossyOverwrite`). `ProjectStore.indexInRegistry` refuses the same way before it appends its row. The rule used to live only in call sites — `ProjectsViewModel.registryForMutation`, the doctor, the MCP tools — leaving five writers unguarded (cockpit `try? save`, `ProjectUpgradeService`, `ProjectTemplateInstaller` ×2, `FleetApplyExecutor`), any of which could persist a salvaged short list. Surviving call-site checks are UX only (a named verb, an alert, an agent-readable message); deleting one costs a nice message, never safety. #projects #dataloss
- [decision] ONE definition of lossy, `RegistryLoss` (in ProjectRegistrySalvage.swift), asked via `RegistryLoadResult.loss`: row loss, quarantine, or unreadable BLOCK; field salvage does NOT. `ProjectDoctorRepairBlock` is now a presentation wrapper over it (`init?(_ loss:)`) so the doctor cannot drift from the enforcement. `RegistryLoadResult.salvaged` survives for the BANNER (any damage worth saying out loud) — do not use it as a write guard again. #projects
- [gotcha] A zero-byte / unreadable `projects.json` is damage, not an empty registry (it used to return clean-empty, which is how a save came to persist the emptiness). ABSENT stays clean and writable — first launch. The discriminator takes PROOF: a confirming `transport.stat` plus a RETRIED read, because on SSH `readFile` is `cat` and a blip would otherwise fabricate damage and freeze every write on a healthy remote. Both probes run only on the read-failure path; a healthy load is still one read. #transport #remote
- [gotcha] Quarantine is a COPY, so the corrupt file stays in place and every write stays refused until a human repairs or deletes `projects.json`. That is deliberate (nothing is destroyed and the bytes exist twice), but there is no in-app escape hatch — the messages name the file and say "repair it, or delete it to start a fresh list". A doctor repair that moves the corrupt file aside is the obvious follow-up and is NOT built. #projects
- [gotcha] If `quarantineRegistry` itself fails to write, the load is reported `unreadable` rather than clean — otherwise a failed copy produced a clean-looking empty result and the next save would overwrite bytes that then existed nowhere.
- [decision] `RegistrySalvageReport.salvaged` is now `[SalvagedField]` (row + field), with `salvagedFields: [String]` computed for the banner signature. Splitting `"<row>.<field>"` back apart is a guess — a project name may contain a `.`.


## D1 (t-3b855719): unknown keys now survive the round-trip

- [decision] `ProjectEntry.extra` and `ProjectRegistry.extra` (`[String: JSONValue]`, swept with `AnyCodingKey`) carry every key the models don't declare through decode → edit → encode — the same contract `HermesCronJob.extra` keeps for `cron/jobs.json`. Until this, ANY save rewrote the file from the model and silently deleted a newer Scarf's field, an agent's own annotation, or the future `bots` binding. `projects.json` is agent-writable by design, so a model round-trip was never safe on it. #projects #codable
- [gotcha] `extra` is excluded from `ProjectEntry`'s hand-written `==`/`hash` for the same reason `uuid` is: logical identity stays name+path+folder+archived, so an unknown key appearing must not deselect the user's project in the sidebar.
- [decision] Registry writes are now serialized across PROCESSES by `RegistryWriteLock` — see [[Registry writes take a reentrant cross-process file lock; remote is best-effort local]]. The lossy refusal above was a TOCTOU against the MCP helper without it.
