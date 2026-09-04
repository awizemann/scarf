---
title: Project mutations report failure; registry damage banner is signature-dismissed
type: note
permalink: scarf/architecture/project-mutations-report-failure-registry-damage-banner-is
tags: [projects, registry, error-surfacing, phase-2, swiftui]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift, scarf/scarf/Features/Projects/Views/ProjectsView.swift, scarf/scarf/Features/Projects/Views/RegistryDamageBanner.swift]
source_paths_inferred: false
source_sha: 04223db9206630eb927ee0feef42c5525f10b025
created: 2026-09-03
updated: 2026-09-03
---

Phase 2 of projects-first-class (branch feat/projects-first-class, t-5523ab86, commit 30be59d), the user-facing half of the Phase-1 registry hardening. Phase 1 made a corrupt `projects.json` survivable; Phase 2 makes both the survival and the failures visible, because a silently-failed save looked identical to a successful one.

## Observations
- [decision] `ProjectsViewModel` mutators commit in-memory state ONLY after a successful `saveRegistry`. The old `addProject` appended regardless, so a failed write showed a project that worked all session and was gone at relaunch; `removeProject` hid a project still on disk; a failed archive still cleared the selection. Failure now leaves the UI matching what actually persisted, and publishes `ProjectMutationFailure{title,message}` for the view's alert. #projects
- [decision] The registry-damage banner is dismissed by a SET of signatures (`quarantinePath|droppedCount|salvagedFields` — `backupPath` excluded, or a later save creating `.bak` reopens a dismissed banner; a set, or a registry alternating between two bad shapes defeats dismissal), not a bool — a watcher tick reloads the broken file constantly, so a bool would either re-show forever or hide genuinely new damage. A clean load clears banner AND dismissal; `dismissRegistryDamage()` must `guard` on a banner actually showing, or a stray dismiss blanks an earlier dismissal (nil signature matches nothing) and reopens it. #gotcha
- [constraint] `damageNotice(for:service:)` is `nonisolated static` and stats `projects.json.bak` ONLY when the load was already salvaged — that stat is a live SSH round-trip, so `reload()` calls it inside its detached read. Never move it onto the MainActor path of a watcher tick. #transport
- [gotcha] `load()` and the mutation path bump `reloadGeneration` too, not just `reload()`. Without it an older in-flight detached read lands after a user's rename/move and reverts both the list and the banner to pre-mutation data. Safe in the mutators because they run to their commit with no suspension point. #concurrency
- [constraint] A mutation REFUSES a lossy load (`registryForMutation` returns nil when `result.salvaged`). Writing back a salvaged registry makes the damage PERMANENT — dropped rows vanish from `projects.json`. (The second half of this hazard is FIXED as of Phase 3 / commit 9be1e2f: a row rewritten without its `uuid` no longer gets a fresh random one — `ProjectStore.derive` re-derives the id from `(host, path)`, so it re-attaches to its record, cron jobs and fleet siblings instead of detaching. Dropped ROWS are still permanent loss, so the refusal stands.) Phase 1's `refusedEmptyOverwrite` does NOT cover this: it guards emptiness, not partial loss. `removeProject` additionally checks the row is present, because its `allowEmpty: true` bypasses that guard entirely. #projects #dataloss

## Relations
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]
- relates_to [[Never run synchronous transport I/O on the MainActor from a file-watcher tick or view body]]


## View-layer gotchas (macOS Projects)

- A mutation invoked straight from a sheet/dialog callback raises its failure alert inside that sheet's own dismissal transaction, where AppKit can drop the presentation and the user sees nothing. `ProjectsView` runs the add/rename/move/remove mutations in `Task { @MainActor in … }` so the alert lands on the next turn.
- "Remove from List" must only strip the `.env` secrets block (`KeychainEnvMirror.unmirror`) and clear `coordinator.selectedProjectName` AFTER `removeProject` returns true — doing it first leaves a project that is still in the registry but has lost its secrets. Safe to unmirror after the registry write: the slug comes from `<project>/.scarf/manifest.json`, which the removal never touches.
- The alert title is cached in `@State`, because dismissing clears `mutationError` first and the title would collapse to `""` while the alert animates out.


## Phase-4 update (commit d21211a)

- The banner's dead end is CLOSED: `RegistryDamageBanner` now takes an `onOpenDoctor` closure and `ProjectsView` presents `ProjectDoctorSheet` from it. Until Phase 4 the banner told the user something was wrong and offered only "Show in Finder" and dismissal.
- The `registryForMutation` refusal is now shared policy rather than one view model's rule: `ProjectDoctorService` refuses EVERY repair while the decode dropped rows or quarantined the file, for the same reason (a rewrite makes the loss permanent). It splits finer than the VM does — field-level salvage does not block there, because replacing an invalid field is precisely what the uuid repairs do.
- The doctor deliberately does NOT participate in `ProjectsViewModel`'s `reloadGeneration` discipline and holds no lock: a doctor repair and a user mutation each read-modify-write `projects.json`, so the later save wins. Same exposure every registry writer here has always had; a registry-wide write lock belongs with the structured agent write path, not the doctor.


## Phase-5 update (the deferred registry lock is still deferred, and now costs more)

Phase 4 parked a registry-wide write lock with "it belongs with the structured agent write path, not the doctor." Phase 5 built that write path (the bundled `scarf-projects` MCP server) and did NOT land the lock. The reasoning, so the next person doesn't re-derive it:

- The exposure is genuinely WIDER now. Before Phase 5 every registry writer was a thread inside one app process; the MCP server is a SEPARATE PROCESS, so an agent's `project_register` and a user's rename can interleave with no shared state at all. Each individual write is still atomic (`transport.writeFile`), so the failure is a LOST UPDATE, not a corrupt file — and both surfaces re-read from disk, so the loss is visible rather than silent.
- A lock only helps if EVERY writer takes it, and the window to protect is the whole read-modify-write, not the write. That means `ProjectsViewModel`'s six mutators, `ProjectStore.indexInRegistry`, `ProjectTemplateInstaller`/`Uninstaller`, `ProjectDoctorService.repair` and the MCP tools — a phase of its own. Locking only the new writer would be worse than locking nothing: it reads as safety while the app-side race is untouched.
- `ProjectStore.save` (which `project_register` calls) additionally re-reads the registry inside `indexInRegistry`, so the MCP tools' lossy-registry check and that read are not one atomic view. A registry that goes lossy in that millisecond window would be written back salvaged. Narrow, and the same shape of window every existing writer has.

Follow-up, unstarted: one advisory lock file under `~/.hermes/scarf/`, taken around the read-modify-write by every writer above, with the MCP server and the app both honouring it.


## R1 remediation (commit 7460cf9): the refusal is narrower, and it isn't the view model's job

- [decision] `registryForMutation` no longer refuses on `result.salvaged`. It refuses on `result.loss` — the app-wide `RegistryLoss` (row loss / quarantine / unreadable). Refusing every salvage meant ONE row with a hand-typed uuid froze renaming, archiving and folders for every project, while the doctor cheerfully repaired the same file. The constraint recorded above ("a mutation REFUSES a lossy load") stands; what changed is that "lossy" no longer means "field damage". #projects
- [constraint] That check is now UX, not enforcement: `ProjectDashboardService.saveRegistry` refuses the write itself. What the VM adds is the ALERT (the verb the user clicked, before the mutator commits in-memory state), and its message is `loss.message` — the same sentence the doctor's block and the MCP refusal use for the same file.
- [gotcha] Banner copy had to follow the semantics. The quarantine summary said Scarf "started a fresh list", which is now FALSE — nothing is written until the file is repaired. It says "changes are paused" instead. The notice also carries `unreadable` (zero-byte / unreadable file) with its own summary and in its dismissal signature: without it the banner stayed silent while every write was being refused.
- [gotcha] Field salvage no longer blocks, so it must be SAID: `ProjectDoctorService` raises a `registryFieldSalvaged` finding per row naming the dropped fields (medium, report-only). `uuid` is excluded only when `invalidRegistryUUID` was ACTUALLY raised for that row — that finding is withheld for a duplicated path, and a blanket exclusion left a garbage uuid reported nowhere at all.
