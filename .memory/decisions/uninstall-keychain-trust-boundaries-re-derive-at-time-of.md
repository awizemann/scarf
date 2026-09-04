---
title: Uninstall + keychain trust boundaries: re-derive at time-of-use (S1)
type: note
permalink: scarf/decisions/uninstall-keychain-trust-boundaries-re-derive-at-time-of
tags: [security, templates, keychain, uninstall, projects]
source_paths: [scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/scarf/Core/Models/TemplateConfig.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/KeychainEnvMirror.swift, scarf/scarf/Core/Models/ProjectTemplate.swift]
source_paths_inferred: false
source_sha: feebb3c6a0446ee737233fe1a61621a876c3bc38
created: 2026-09-04
updated: 2026-09-04
---
Fix for the three HIGHs in the 2026-09-03 projects full-surface audit (batch S1). One shape for all three: `template.lock.json`, `<project>/.scarf/config.json` and the cached `manifest.json` are AGENT-WRITABLE, so nothing they say is a record of what Scarf did — every destructive or secret-reading decision is re-derived from a root Scarf owns, at the moment of use.

## Observations
- [decision] Uninstall deletion targets are re-validated by ProjectTemplateUninstaller.PathGuard: lexical containment strictly BELOW the owning root (root itself and "/" refused, no ..), plus a physical check that the candidate's PARENT chain resolves exactly to root-resolved + the lexical components, so any symlinked component refuses. project_files bind to project.path; skills_namespace_dir to <hermes>/skills/templates. Runs at plan time AND again inside uninstall(plan:) #security
- [decision] removeRecursively is symlink-safe: a symlink (even dangling) is UNLINKED and never descended into (stat/listDirectory follow links, so the old walk deleted through <namespace>/x -> ~/Documents); it returns false when anything was skipped so the parent dir is left in place instead of throwing and aborting the cron/memory/registry steps #security
- [decision] TemplateKeychainRef.parse enforces Scarf's own shape (service com.scarf.template.<slug>, account <fieldKey>:<8 lowercase hex>) and belongs(toProjectPath:) binds a ref to the project whose path hash it carries; ProjectConfigService.resolveSecret(ref:for:) and the uninstaller's SecItemDelete both require it, so project A can neither read nor delete project B's item #security
- [gotcha] Path-hash binding means a HAND-MOVED project's refs stop resolving (hash is the old path). Accepted migration: the secret reads as absent and the user re-enters it in the Configuration sheet, re-minting under the current path. acceptableHashes covers spelling variants only (/tmp vs /private/tmp, trailing slash) because Foundation's resolvingSymlinksInPath STRIPS a /private prefix rather than adding one #gotcha
- [fix] KeychainEnvMirror refuses a malformed slug (isMirrorableSlug): block markers carry the slug verbatim on their own line, so an agent-authored slug with a newline could forge a scarf-secrets:end marker and inject arbitrary KEY=value lines into ~/.hermes/.env outside any block Scarf would rewrite #security

## Relations
- relates_to [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]
- relates_to [[Template Configuration Schema (v2)]]
- relates_to [[Project Templates (.scarftemplate)]]


## S2 follow-up (t-a2c169f0): the `.env` block slug was still believed

S1 bound `keychain://` refs to their project but left one agent-chosen
string obeyed: `KeychainEnvMirror.unmirror(project:)` recovers the block
slug from `<project>/.scarf/manifest.json`, which the agent working in THAT
project writes. Setting it to another registered project's slug turned
"uninstall my template" into "delete that project's secrets from
`~/.hermes/.env`" — silently; the victim's cron jobs just start failing to
authenticate.

`unmirror(project:)` now strips a block only when NO other registered
project claims the same slug (comparing both the cached-manifest slug and
the name-derived fallback, matching rows out by normalized path rather than
by the renameable display name). A contested slug is left alone and logged:
a stale `.env` block is benign — the uninstall deletes the Keychain items
its keys reference anyway — while deleting the wrong one is unrecoverable
from inside Scarf. Two honest installs of one template legitimately share a
block, and refusing there is also correct: the other install still needs it.


## T1 follow-up (t-09019d73): the ROOT was still believed

S1 re-derived every containment answer from the project root. P8 SEC-H1
found the door that leaves open: the root itself comes from
`projects.json`, which the agent can append to directly, so a row with
`path: "/Users/me"` never met `ProjectRootPolicy` (a REGISTRATION-time
check) and makes every S1 guard pass against the user's home.

`ProjectRootPolicy.refusalAtUse(for:context:)` is now applied wherever a
root is about to anchor a dangerous operation:
`ProjectTemplateUninstaller.loadUninstallPlan` (returns a plan that does
NOTHING, with the reason leading `refusedEntries` and a new
`rootRefused` flag zeroing `totalRemoveCount`), `uninstall(plan:)`
(throws `ProjectTemplateError.inadmissibleProjectRoot` before the first
deletion — a plan is a plain value and may not have come from
`loadUninstallPlan`), `WidgetPathResolver.resolve`
(`.inadmissibleRoot`), and both mini-app surfaces
(`MiniAppSchemeHandler` computes the refusal once at mount and answers
403; `ScarfMiniAppBridge.file.read` refuses with the reason).

**The refusal is on the ACT, never on the row.** Dropping an
inadmissible project from the sidebar was considered and rejected: a
newly-tightened policy that silently disappears projects breaks
legitimate users (a row that predates the policy, a home that genuinely
holds a project folder) far more often than it stops an attacker who,
by hypothesis, can rewrite the file again next tick. Refuse the
dangerous operation, keep the row visible, say why.

`ProjectRootPolicy` is also no longer lexical (SEC-M3) — see the
path-containment convention note.

## T1: the Keychain binding was FNV-1a/32 (SEC-H2)

The path-hash binding this note described has been replaced; see
[[Keychain ref binding: truncated SHA-256 over (template slug, project path)]].
The `belongs(toProjectPath:)` / `acceptableHashes` spelling-variant
behaviour described above is unchanged and carried over verbatim — it
was always about path SPELLING, not about the hash.

One migration wrinkle this created: re-minting changes the ACCOUNT, so a
lock entry in the old form goes stale and its re-minted item would
survive an uninstall that claimed a clean removal. `loadUninstallPlan`
therefore queues BOTH for any legacy lock entry — the modern account is
derivable from the ref's own service slug + field key + the project path
it was just bound to, and an item that was never re-minted is simply
absent (`delete` no-ops).
