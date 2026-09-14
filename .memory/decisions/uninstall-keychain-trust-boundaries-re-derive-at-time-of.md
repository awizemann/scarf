---
title: Uninstall + keychain trust boundaries: re-derive at time-of-use (S1)
type: note
permalink: scarf/decisions/uninstall-keychain-trust-boundaries-re-derive-at-time-of
tags: [security, templates, keychain, uninstall, projects]
source_paths: [scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/scarf/Core/Models/TemplateConfig.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/KeychainEnvMirror.swift, scarf/scarf/Core/Models/ProjectTemplate.swift]
source_paths_inferred: false
source_sha: 92d062bdc2c76f94828de482292db860b4da4cbd
created: 2026-09-04
updated: 2026-09-07
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] Uninstall deletion targets are re-validated by ProjectTemplateUninstaller.PathGuard: lexical containment strictly BELOW the owning root (root itself and "/" refused, no ..), plus a physical check that the candidate's PARENT chain resolves exactly to root-resolved + the lexical components, so any symlinked component refuses. project_files bind to project.path; skills_namespace_dir to <hermes>/skills/templates. Runs at plan time AND again inside uninstall(plan:) #security
- [decision] removeRecursively is symlink-safe: a symlink (even dangling) is UNLINKED and never descended into (stat/listDirectory follow links, so the old walk deleted through <namespace>/x -> ~/Documents); it returns false when anything was skipped so the parent dir is left in place instead of throwing and aborting the cron/memory/registry steps #security
- [decision] TemplateKeychainRef.parse enforces Scarf's own shape (service com.scarf.template.<slug>, account <fieldKey>:<hash>) and belongs(toProjectPath:) binds a ref to the project whose path hash it carries; ProjectConfigService.resolveSecret(ref:for:) and the uninstaller's SecItemDelete both require it, so project A can neither read nor delete project B's item #security
- [gotcha] Path-hash binding means a HAND-MOVED project's refs stop resolving (hash is the old path). Accepted migration: the secret reads as absent and the user re-enters it in the Configuration sheet, re-minting under the current path. acceptableBindingHashes covers spelling variants only (/tmp vs /private/tmp, trailing slash) because Foundation's resolvingSymlinksInPath STRIPS a /private prefix rather than adding one #gotcha
- [fix] KeychainEnvMirror refuses a malformed slug (isMirrorableSlug): block markers carry the slug verbatim on their own line, so an agent-authored slug with a newline could forge a scarf-secrets:end marker and inject arbitrary KEY=value lines into ~/.hermes/.env outside any block Scarf would rewrite #security

## Relations
- relates_to [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]
- relates_to [[Template Configuration Schema (v2)]]
- relates_to [[project-templates-scarftemplate]]


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

The path-hash binding this note described has been replaced; the ref now
uses truncated SHA-256 (16 hex chars) over both template slug and project
path — see `TemplateKeychainRef.bindingHash(templateSlug:projectPath:)` in
`ScarfCore/Services/ProjectConfigKeychain.swift`. The `belongs(toProjectPath:)`
/ `acceptableBindingHashes` spelling-variant behaviour is unchanged and
carried over verbatim — it was always about path SPELLING, not about the hash.
Legacy 8-hex FNV hashes are still accepted on read (so existing secrets don't
vanish), but never minted, so the next user save rotates every legacy field to
the new form.

One migration wrinkle this created: re-minting changes the ACCOUNT, so a
lock entry in the old form goes stale and its re-minted item would
survive an uninstall that claimed a clean removal. `loadUninstallPlan`
therefore queues BOTH for any legacy lock entry — the modern account is
derivable from the ref's own service slug + field key + the project path
it was just bound to, and an item that was never re-minted is simply
absent (`delete` no-ops).


## GW-F1 follow-up (t-ba501bbf): the ORDER of refusals was still an attacker tool

S1/S2/T1 made every destructive decision re-derived from a root Scarf owns.
The E5 audit found the inverse failure: a refusal landing in the WRONG PLACE.
`stripMemoryBlock`'s guarded-read refusal (SEC F1) threw out of
`uninstall(plan:)` between the destructive steps and the cleanup ones — files,
skills and cron jobs already gone, the template's **Keychain items (step 4a),
the registry row (5) and the mini-app grants (6) all skipped**. MEMORY.md
lives in the Hermes home any agent can write, so `chmod 000 MEMORY.md` was a
one-command way to make a user-initiated uninstall PRESERVE the secrets it
promised to remove.

Three rules now hold:

1. **The MEMORY.md proof runs at PLAN time** (`GuardedTextFile.load`, not
   `fileExists` + `try? readFile`), so unreadable is its own answer
   (`TemplateUninstallPlan.memoryUnreadable`) rather than being folded into
   "no block installed", and it is known BEFORE step 1 deletes anything.
2. **At execute time the strip refusal is a warning, never an abort** — same
   shape as `ProjectLifecycleService.cleanUpAfterRemoval`. Step 2's recursive
   skills removal was throwing past the identical set of steps and got the
   same treatment. Only the root refusal (before any deletion) and the
   registry write still throw.
3. **The plan-time policy is a stated warning, not a confirmation gate.** The
   uninstall sheet shows an orange "MEMORY.md couldn't be read, so its
   template section can't be removed — everything else, including this
   template's Keychain secrets, is still removed", matching how the sheet
   already presents refused/already-gone entries. A blocking prompt here would
   re-create the hole: the block is inert markdown, the rest of the uninstall
   is the part with security meaning.

**Ordering beats compensation for the Keychain (DI M3).** The Configuration
sheet wrote secrets and only then asked `config.json` to accept the write, so
a refusal orphaned the item. A compensating delete cannot fix it:
`storeSecret` writes a DETERMINISTIC account (slug, field key, project path),
so rotating a field OVERWRITES the value the surviving `config.json` still
points at, and deleting it would destroy the user's working secret.
`ProjectConfigService.preflightSave(project:)` proves the destination would
accept a write before the first secret is minted;
`TemplateConfigViewModel.commit` calls it whenever there are pending secrets
and reports refusal in a new whole-form `commitError`.

`ProjectTemplateUninstaller` now takes an injectable `ProjectConfigKeychain`
so the attack is testable end to end without touching the login Keychain
(`GwF1RefusalOrderingTests`).
