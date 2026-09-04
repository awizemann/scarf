---
id: t-f227bb0f
title: Projects S1: uninstall + keychain trust boundaries (security HIGHs)
status: todo
added: 2026-09-03
priority: urgent
---

## Description

From the P7 security audit (documents/reports/2026-09-03-projects-full-surface-audit.md). Theme: re-derive trust at time-of-use instead of trusting agent-writable records. (1) ProjectTemplateUninstaller (:64-74,160-181): re-validate every lock-driven deletion — projectFiles must resolve under project.path (symlink-resolved), skillsNamespaceDir must resolve under the hermes skills templates namespace; removeRecursively must not stat/list through symlinks (unlink the link like pruneKnownBadSkills does). (2) TemplateKeychainRef.parse (TemplateConfig.swift:204-211): restrict to the com.scarf.template.* namespace AND bind refs to the owning project (path-hash check) before KeychainEnvMirror resolves them; reconcileAll must refuse cross-project refs. (3) Uninstaller SecItemDelete (:207-218): only delete items whose ref belongs to this project's slug/hash. Tests: hostile lock fixtures (absolute paths, symlinked namespace dir, foreign keychain refs) must be refused with the plan surfacing what was skipped.

## Plan



## Artifacts



