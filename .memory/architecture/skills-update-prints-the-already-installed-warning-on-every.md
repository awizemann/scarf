---
title: skills update prints the already-installed warning on every skill — its failure set is not the install set
type: note
permalink: scarf/architecture/skills-update-prints-the-already-installed-warning-on-every
tags: [hermes, skills, cli, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesSkillsHubParser.swift]
source_paths_inferred: false
source_sha: df6993cd705c900a653c8d90b7059b5e6c20256f
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-12
reviewed_by: audit:claude-code (background)
---

`hermes skills update` runs `do_install(..., force=True)` per skill, and `do_install` prints its already-installed warning BEFORE it looks at `force` — so on the update path that line is printed for every skill, including the ones that update perfectly. Scarf therefore judges update refusals with `HermesCLIMarkers.skillsUpdateFailure` (the install set minus that pair), not `skillsInstallFailure`.

## Observations
- [gotcha] `do_install` prints `Warning: '<name>' is already installed at <path>` (hermes_cli/skills_hub.py:682) unconditionally when the lock has an entry, and only then checks `if not force` (:683) — an update always has a lock entry #skills
- [fact] `do_update` calls `do_install(entry['identifier'], …, force=True, …)` at skills_hub.py:868, so `Use --force to reinstall.` (:684) is unreachable on the update path #skills
- [decision] `skillsUpdateFailure` = `skillsInstallFailure` minus `is already installed at` and `Use --force to reinstall.`; the install set keeps both, where an already-installed skill genuinely IS the refusal #verification
- [gotcha] `failureDetail` takes the FIRST matching line, so one always-printed warning at the top of the output masks every real reason below it #verification

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
