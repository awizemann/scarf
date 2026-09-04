---
id: t-f227bb0f
title: Projects S1: uninstall + keychain trust boundaries (security HIGHs)
status: done
added: 2026-09-03
priority: urgent
---

## Description

From the P7 security audit (documents/reports/2026-09-03-projects-full-surface-audit.md). Theme: re-derive trust at time-of-use instead of trusting agent-writable records. (1) ProjectTemplateUninstaller (:64-74,160-181): re-validate every lock-driven deletion — projectFiles must resolve under project.path (symlink-resolved), skillsNamespaceDir must resolve under the hermes skills templates namespace; removeRecursively must not stat/list through symlinks (unlink the link like pruneKnownBadSkills does). (2) TemplateKeychainRef.parse (TemplateConfig.swift:204-211): restrict to the com.scarf.template.* namespace AND bind refs to the owning project (path-hash check) before KeychainEnvMirror resolves them; reconcileAll must refuse cross-project refs. (3) Uninstaller SecItemDelete (:207-218): only delete items whose ref belongs to this project's slug/hash. Tests: hostile lock fixtures (absolute paths, symlinked namespace dir, foreign keychain refs) must be refused with the plan surfacing what was skipped.

## Plan



## Artifacts

Done 2026-09-04. All three security HIGHs fixed with one shape: re-derive trust at time-of-use.

- `ProjectTemplateUninstaller.swift` — new nested `PathGuard` (lexical containment strictly below root, `/` and root itself refused, no `..`; plus a physical check that the candidate's PARENT chain resolves exactly to root-resolved + lexical components, so any symlinked component refuses; local-only physical half, remote gets the lexical half with a documented reason). Applied to `project_files` (root = `project.path`) and `skills_namespace_dir` (root = `<hermes>/skills/templates`) at plan time AND again in `uninstall(plan:)`. `removeRecursively` unlinks symlinks instead of descending, re-checks each child, and returns false-on-skip so a skipped entry doesn't throw and abort the cron/memory/registry steps. Keychain deletion now iterates the plan's parsed+bound refs.
- `TemplateConfig.swift` — `TemplateKeychainRef.parse` restricted to `com.scarf.template.<slug>` + `<fieldKey>:<8 lowercase hex>`; new `belongs(toProjectPath:)` / `acceptableHashes` project binding.
- `ProjectConfigService.resolveSecret(ref:for:)` — requires the binding (was `resolveSecret(ref:)`).
- `KeychainEnvMirror` — passes the project through so `reconcileAll()` can't mirror another project's secret; also refuses a malformed slug (marker-forgery/env-injection via the agent-writable manifest slug).
- `ProjectTemplate.swift` — plan gains `refusedEntries` + `keychainItemsToDelete`; `TemplateUninstallSheet` shows a "Skipped — outside this project" section.

Tests: 15 new (hostile lock fixtures: outside path, `..` traversal, symlinked-dir smuggling, skills dir outside the templates root, symlink inside a legit namespace dir, foreign + `com.apple.ssh` keychain uris, PathGuard unit surface, ref namespace/binding, cross-project resolveSecret, env-mirror slug guard). scarfTests 673/673 green; ScarfCore 1998/1998 green; app build green.

Migration note: a hand-moved project's keychain refs no longer resolve (hash is the old path) — user re-enters the secret in the Configuration sheet, which re-mints it. Documented in the decisions note.

