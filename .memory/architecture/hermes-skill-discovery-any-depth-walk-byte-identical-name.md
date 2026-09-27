---
title: Hermes skill discovery: any-depth walk, byte-identical name collisions, platforms gate
type: note
permalink: scarf/architecture/hermes-skill-discovery-any-depth-walk-byte-identical-name
tags: [skills, hermes, bootstrap, remote, r06]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillsScanner.swift, scarf/scarf/Core/Services/SkillBootstrapService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift, scarf/scarf/Resources/BuiltinSkills.bundle, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-26
---

How Hermes finds and resolves skills, verified at v2026.9.24 during R06 (S10-F1/F3/F5), and the Scarf code that mirrors it.

## Observations
- [fact] Hermes discovers skills by walking skills/ for SKILL.md at any depth with followlinks=True; it prunes EXCLUDED_SKILL_DIRS everywhere, support dirs (references/templates/assets/scripts) only inside a skill root, and walks _org/ only for the org in _org/.active_org (agent/skill_utils.py:23-37,783-800 @ v2026.9.24). SkillsScanner mirrors this; Local and SSH stat describe a symlink, so the scanner follows a link by listing it (FileStat.isSymbolicLink) #skills
- [gotcha] When two skill dirs share a name, skill_view picks one only if their SKILL.md bytes are identical (or one realpath), then the shallower wins; otherwise it refuses with 'Ambiguous skill name' (tools/skills_tool.py:491-535). The Template Author template installs its own scarf-template-author under skills/templates/<slug>/, so ANY change to the bundled skill must also reach that copy: SkillBootstrapService.syncTemplateCopies rewrites an older Scarf-authored copy there to the bundled bytes #bootstrap #gotcha
- [gotcha] A SKILL.md 'platforms:' list is matched against the Hermes host's sys.platform (macos=darwin); a non-matching skill is dropped from the index and skill_view refuses it (agent/skill_utils.py:21,128-145; tools/skills_tool.py:207,604-605). Scarf's bundled skills are copied to remote Linux hosts, so they must not declare platforms: [macos]. Dropped in 2.0.1 / 1.0.1; a content change needs a version bump or the version-gated bootstrap never replaces installed copies #bootstrap #remote
- [fact] Curator pins live per skill in skills/.usage.json (a JSON object keyed by skill name, record field "pinned": true), never in .curator_state, which holds only scheduler keys (tools/skill_usage.py:50-51,345-350,568-574; agent/curator.py:43-56). SkillsViewModel.readPinnedSkillNames reads the sidecar #curator
- [fact] skill_view and cron --skill accept either a bare name or the path below skills/ (tools/skills_tool.py:345-352,575-577), so HermesSkill.id = relative path is a valid cron skill reference at any depth #cron

## Relations
- relates_to [[Which Scarf surface writes which config file (Skills, Models, Settings)]]
- relates_to [[The skill is tool-first and Scarf deletes skills that lie about it]]
