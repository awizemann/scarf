---
title: Project ids are derived from (host, path), never minted on a read
type: note
permalink: scarf/decisions/project-ids-are-derived-from-host-path-never-minted-on-a
tags: [projects, identity, phase-3, uuid, fleet, decision]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectIdentity.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetService.swift, scarf/scarf/Core/Services/ProjectAgentContextService.swift]
source_paths_inferred: false
source_sha: 9be1e2f491a09c9de53ffcd0ca035c32fda4e648
created: 2026-09-03
updated: 2026-09-03
---

Phase 3 of projects-first-class (branch feat/projects-first-class, t-91050c08, commit 9be1e2f). `ProjectStore.derive(from:)` did `entry.uuid ?? UUID()`, so `list()`, the cockpit load and the render-only `ProjectAgentContextService.refresh` each observed a DIFFERENT id for the same unpersisted project. Persisting inside `derive` was rejected: it would write on the render-only chat-start path and push past `save`'s `projectRootMissing` guard. Deriving deterministically fixes the same bug with zero writes.

## Observations
- [decision] `ProjectIdentity.deterministicID(forProjectPath:hostKey:)` is a UUIDv8 (RFC 9562) over SHA-256 of a frozen namespace + host salt + lexically-normalized path. `derive(from:)` uses it whenever the registry row has no `uuid`; a MINTED id (scaffolder/installer random `UUID()`, or one frozen in `project.json`) always wins. Interim ids are never an identity claim — only an id somebody asserted is. #projects #identity
- [constraint] The namespace constant, the host-key format, the normalization rules and the digest layout are a WIRE FORMAT, frozen forever: one Scarf version derives an id that another persists into `project.json`, `[proj:<uuid>]` cron tags and mini-app grants. Normalization collapses `//`, `.` and `..` textually and trims trailing `/` — deliberately NO symlink resolution (derive must stay pure/no-I/O and answer identically for a remote path we cannot stat) and NO case folding. Changing any of it needs a migration, not an edit. #gotcha
- [gotcha] The host salt is load-bearing, not hygiene: every SSH host defaults to the same unexpanded `~/projects` (`ServerContext.defaultProjectsRoot`), so same-named projects on two hosts have byte-identical paths. Unsalted, the eager `derive()` migration would PERSIST one id on both hosts, `FleetService` would then accept it as asserted, and `FleetApplyExecutor` could write presets, tenants and cron jobs to an unrelated machine. `hostKey` is `""` for `.local` and `user@host:port` for `.ssh` — deliberately NOT `context.id`, which is a per-registration random UUID. #fleet #dataloss
- [gotcha] Ids key on PATH, so a path reused on one host (delete the project, hand-add a registry row at the same path) adopts the old project's orphaned `[proj:<uuid>]` cron jobs and surviving mini-app grants. Accepted: unreachable via the scaffolder/installer, which both mint random ids at creation. DETECTION landed in Phase 4 (commit d21211a): `ProjectDoctorService` raises a LOW `pathReuseSuspicion` when a cron job tagged `[proj:<id>]` for a project has a `workdir` pointing at a DIFFERENT folder — the cheap, concrete symptom of jobs left behind by a recycled path's previous occupant. Report-only; prevention is still not attempted. #projects
- [constraint] `ProjectAgentContextService.refresh` now REFUSES to re-create a missing project directory unless the registry still lists the project (throws `projectDirectoryMissing`; every caller treats a failed refresh as non-fatal). With path-derived ids, re-creating the dir let the cockpit's load-or-derive re-register a deleted project under its ORIGINAL id, re-attaching its old cron jobs and grants — a resurrection the random-id era made inert. #gotcha

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[Project mutations report failure; registry damage banner is signature-dismissed]]
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]


## R1 remediation (commit 7460cf9): the hostKey contract, settled before release

`hostKey` was `"\(user ?? "")@\(host):\(port ?? 22)"` with no input normalization, so the same machine spelled two ways derived two ids. The format ships now, so the canonicalization is FROZEN as of this commit — and it deliberately does LESS than the obvious version.

- [decision] Canonical form is unchanged (`<user>@<host>:<port>`). Inputs are TRIMMED of surrounding whitespace (a text-field artefact, never identity) and an omitted port means 22 (SSH's own default, genuinely the same host). Nothing else is normalized. #identity
- [decision] NOTHING is case-folded — not the user, and (deviating from the obvious "hostnames are case-insensitive" fix) not the host either. `SSHConfig.host` is as often an `~/.ssh/config` ALIAS as a DNS name, and OpenSSH matches `Host` patterns case-sensitively, so `Prod` and `prod` may be two different machines. Same reasoning retires trailing-dot stripping (`example.com.` is a valid FQDN spelling AND a legal distinct alias pattern). #gotcha
- [constraint] The governing asymmetry, which decides any future question here: **a COLLISION is catastrophic and a DIVERGENCE is cheap.** Two hosts seeded identically derive one id for two unrelated projects, `FleetService` groups them, and a fleet apply writes presets, tenants and cron jobs to the wrong machine. Two spellings of one host seeded differently cost one extra derived id — visible to the doctor, and moot the moment an id is persisted, since a minted or recorded id always beats a derived one. Normalize only what CANNOT denote a different machine. #fleet #dataloss
- [gotcha] `hostKey` is never persisted or compared as a string anywhere; it is only ever fed into `deterministicID`. The blast radius of a change is derived UUIDs — which is exactly the `[proj:<uuid>]` cron tag / mini-app grant / fleet surface, so "only derived ids" is not a small blast radius.
- Accepted residuals, all the cheap failure: alias vs real hostname, two case-spellings of one host, and a host registered once with an explicit user and once without, each derive a distinct key.
