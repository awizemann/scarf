---
title: The skill is tool-first and Scarf deletes skills that lie about it
type: note
permalink: scarf/decisions/the-skill-is-tool-first-and-scarf-deletes-skills-that-lie
tags: [projects, skills, mcp, phase-6, agents]
source_paths: [scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md, scarf/scarf/Core/Services/SkillBootstrapService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarfTests/SkillBootstrapServiceTests.swift]
source_paths_inferred: false
source_sha: 2660f501f521ae0d86b2027f5c99d1db141b916a
created: 2026-09-03
updated: 2026-09-03
---

Phase 6 (final) of projects-first-class, branch feat/projects-first-class, task t-2cea158a. Phase 5 gave agents the `scarf-projects` MCP tools; this phase changes what agents are TOLD, which is the half that actually produced the 2026-09-02 corruption. Three surfaces move together, because an agent reads whichever one it happens to hit: the bundled skill, the per-chat AGENTS.md managed block, and the set of installed skills competing for activation.

## Observations
- [decision] `scarf-template-author` 2.0.0 is TOOL-FIRST: a "READ THIS FIRST" table maps each job to its tool (`project_register`, `project_update_dashboard`, `project_add_slash_command`, `project_validate`, `project_list`, `project_get`) with verified argument names; the old step-8 raw `projects.json` append survives only as an explicitly-labelled remote-host fallback that forbids inventing a `uuid`. Steps were RENUMBERED so registration precedes the dashboard — `project_update_dashboard` resolves its target through the registry, so the old order could not work tool-first. #skills #projects
- [constraint] The skill must not over-claim the lossy-registry refusal: only REGISTRY writes (`project_register`) refuse on a damaged registry; project-local writes (dashboard, slash commands) are not blocked, they just can't resolve an unreadable row. Also `project_get` reports a dashboard's path/exists/valid and NOT its contents — an enrich flow reads the file itself. Both were wrong in the first draft and caught by re-reading the handlers. #gotcha
- [decision] `SkillBootstrapService.pruneKnownBadSkills()` deletes denylisted skill directories (`knownBadSkillNames`, founding member `scarf-project-workflows` — a hallucinated skill documenting fake CLI verbs that competed for activation with the real one). Deliberately narrow: exact directory-name matches only, only under the `scarf/` category dir Scarf owns plus the legacy flat path it used to write. Runs AHEAD of the bundled-skills guard, so a build with no `BuiltinSkills.bundle` still cleans. #skills
- [convention] Two C5 fixes fell out of citing rather than assuming: the skill documented `hermes cron list --json`, a flag Hermes's argparse does not define (cron list takes only `--all`), and both the skill and the AGENTS.md block pointed at the pre-v2.10.1 flat skill path `~/.hermes/skills/scarf-template-author/SKILL.md` instead of the `scarf/` category path. #hermes-cli
- [fact] The managed AGENTS.md block gained a `**Project tools.**` bullet in its static platform-reference section. No golden fixtures existed — the idempotency tests are behavioral (render twice, compare) — so nothing had to be weakened; assertions pinning the new bytes were ADDED instead. The renderer is one shared ScarfCore function called only from `ProjectStore`, so Mac and iOS stay byte-identical by construction. #agents-md

## Relations
- relates_to [[scarf-projects MCP server: bundled helper, ScarfCore services, no parallel writers]]
- relates_to [[Agents break projects because there is no structured write path — 2026-09 live evidence]]
- relates_to [[Project Upgrade — one-click structure pass + chat enrichment (deterministic ProjectUpgradeService + skills)]]


## Audit findings the rewrite absorbed (2026-09-03, commit cee8d2f)

A fresh-eyes pass against the handler source found twelve false claims in the skill — four introduced by the rewrite, eight inherited from 1.3.0 and shipped to users for months. All fixed in 2.0.0:

- `project_get` returns a dashboard's path/exists/valid, never its bytes.
- Only REGISTRY writes refuse on a damaged registry; project-local writes resolve through it but aren't blocked.
- `hermes cron list --json` is not a flag Hermes defines (C5 violation, shipped since 1.x).
- Slash-command frontmatter key is `argumentHint`; a `hint` key parses to nothing — the AGENTS.md managed block had said `hint?` since v2.3.
- A hand-authored `cron/jobs.json` is read by NOTHING: `ProjectTemplateExporter` WRITES it from the user's live Hermes jobs. Staging/bundle layout is flat and its manifest is `template.json`, not `.scarf/manifest.json`.
- `schemaVersion` is 1/2/3 (not "must be 2"); slash-command bundles need 3 + `contents.slashCommands`; `contents.cron` must equal the job count or `catalog.sh check` rejects.
- `KeychainEnvMirror` mirrors ONLY secret-typed fields into `~/.hermes/.env` — the worked example referenced a plain URL field's env var that never exists.
- Section `columns` is 1...12 (not 1–4); `chartType: "area"` renders as a LINE (`ChartWidgetView` switches pie/bar/default); ragged table rows are validated nowhere.

**Denylist blast-radius fix from the same pass:** removal now calls `removeFile(dir)` BEFORE any child walk. Locally that is `FileManager.removeItem`, which unlinks a symlink rather than following it; the original child-first order would have deleted the TARGET's contents when the bad-skill name was a symlink into the user's own skills. The walk survives only as the SSH fallback (`rm -f` refuses a populated dir and cannot recurse). Regression test plants a symlink and asserts the target survives.

**Accepted, not fixed:** the skill's `description` frontmatter exceeds the 60-char index truncation, but its first 60 chars already name both modes ("Scaffold a new Scarf project OR enrich an existing one after"), so routing survives.

**Deferred:** `templates/awizemann/template-author/staging/skills/scarf-template-author/SKILL.md` is a stale v1.2.0 copy of this skill, and `tools/widget-schema.json` names THAT path as canonical. Left alone — `templates/` is a Memophant-managed tier (C7). Needs a follow-up to re-sync or repoint.


## R2: the flat level is the USER's, and deleting by name there was never ours to do

t-1a1a9ce3.

- [decision] **`pruneKnownBadSkills` deletes from `~/.hermes/skills/scarf/` freely, and from the FLAT level only on positive proof of Scarf authorship.** The flat level is where Hermes puts every hand-installed skill — around fifty of them on the machine this was found on — and the pass ran there with nothing but a name to go on. A user who wrote their own `scarf-project-workflows` (an entirely plausible name for a skill about Scarf) would have watched Scarf delete it at launch, no undo, no mention. `isScarfAuthoredSkill` requires BOTH `author: Alan Wizemann` and a `github.com/awizemann/scarf` homepage, both inside the frontmatter. #dataloss
- [gotcha] **Consequence, accepted and deliberate:** the founding denylist member was never Scarf-authored, so its flat copy almost certainly does NOT carry the signature — which makes flat-level denylisting effectively inert for exactly the skill that motivated it. That is the correct trade: by our own rule a file we cannot prove is ours is the user's, and deleting fifty innocent skills to catch one liar is the worse failure. The `scarf/` namespace prune (where Scarf's own copy would live) is unaffected.
- [decision] The same gate now gates the flat→`scarf/` MIGRATION in `installSkill`, whose comment used to assert that "the flat path was always a Scarf-owned bootstrap target — never a user-authored skill". Verified against git history before gating: the earliest flat-era bundled skill (`scarf-template-author` v1.1.0, commit 4efd84c) already carried both signature halves, so every flat copy Scarf ever wrote still migrates. A test reads the SHIPPED `BuiltinSkills.bundle` files and asserts each one passes its own signature — the gate has to match the artifact, not a sample the test wrote for itself.
- [gotcha] A companion-file failure used to `throw` out of `installSkill` AFTER `SKILL.md` was written, so the caller logged "couldn't bootstrap" over a perfectly good install — and because the version check then said "current", the missing companions were never retried on any later launch. A companion SUBDIRECTORY triggered exactly that. Companions are now logged and skipped individually; non-files are skipped by design (one level deep).
- [gotcha] `semverCompare` split on "." alone, so `2.0.0-rc1` became `["2","0","0-rc1"]` and its last component compared lexicographically GREATER than `"0"` — an installed release candidate outranked the finished `2.0.0` and blocked the bundled skill forever, which is the one case the gate exists for. Now semver §11: numeric core component-wise, a prerelease ranks BELOW the same core without one, build metadata ignored.
