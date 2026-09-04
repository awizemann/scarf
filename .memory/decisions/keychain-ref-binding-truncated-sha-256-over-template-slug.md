---
title: Keychain ref binding: truncated SHA-256 over (template slug, project path)
type: note
permalink: scarf/decisions/keychain-ref-binding-truncated-sha-256-over-template-slug
tags: [security, keychain, templates, projects, migration]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectConfigKeychain.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/scarf/Core/Services/KeychainEnvMirror.swift, scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPTools.swift]
source_paths_inferred: false
source_sha: 73b775ed43e1947b6632c2a4f134d350ea1c9f2c
created: 2026-09-04
updated: 2026-09-04
---

P8 audit SEC-H2, fixed in T1 (t-09019d73). The cross-project Keychain
isolation S1 introduced was real in shape but not in strength: it rested on
a 32-bit FNV-1a of the project path, with the SERVICE half not bound at all.

A chosen preimage for FNV-1a/32 is seconds of CPU — the T1 test carries a
real one, found by meet-in-the-middle over four characters
(`/Users/x/victim-project` and `/Users/x/cqf90aabq` both hash to
`0x78b03c16`). An agent picks the sibling directory name, gets it
registered, and `belongs(toProjectPath:)` says its `config.json` may read
the victim's item — after which `KeychainEnvMirror` writes that secret into
the attacker's `~/.hermes/.env` block at next launch.

## Observations

- [decision] The account hash is now `bindingHash(templateSlug:projectPath:)` — the leading 64 bits (16 lowercase hex) of SHA-256 over `"scarf-template-keychain-v2\0" + slug + "\0" + path`. The NUL separator can't occur in a slug (`TemplateSlug.derive` emits letters/digits/`-`/`_`) or a POSIX path, so no (slug, path) pair re-parses as another by sliding the boundary #security
- [decision] The SERVICE is bound too, by feeding the slug into the same digest: an account lifted onto `com.scarf.template.<other>` belongs to nobody, so one path collision can no longer reach every template's namespace. `templateSlug` reads the slug back off the service for the compare #security
- [constraint] `TemplateKeychainRef.parse` accepts hash length 16 (current) OR 8 (retired FNV), and `belongs` dispatches on that length. Legacy is READ-side only — `make` mints nothing but the new form, so a field migrates for good the next time the user saves it. Legacy items keep the old weakness until then; that is a deliberate, time-boxed trade against making every configured project's secret vanish at once #security
- [gotcha] Re-minting changes the ACCOUNT, which staled `template.lock.json`'s recorded URI and would have left the live item behind after an uninstall that reported success. `loadUninstallPlan` now queues the derived modern account alongside any legacy lock entry (absent items no-op in `delete`) #gotcha
- [convention] `acceptableBindingHashes` keeps S1's path-SPELLING enumeration verbatim (`/tmp` vs `/private/tmp`, trailing slash, symlinked parent) — that was never about the hash, and dropping it would silently orphan every project whose registry row and install path disagree on `/private` #convention

## Relations
- relates_to [[Uninstall + keychain trust boundaries: re-derive at time-of-use (S1)]]
- relates_to [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]


## F1: the legacy window closes on READ, not on re-save

The deprecation plan said the legacy 8-hex FNV branch would drain because
`make` only mints the new form, so "the next time the user saves that field
in the Configuration sheet it moves over for good". That is a window that
never closes: nobody re-types a working API key. Meanwhile the branch is
the original weakness verbatim — 32 bits of a non-cryptographic hash has
chosen preimages computable in milliseconds, and because the legacy account
carries no slug and `belongs` compares FNV alone, one collision reaches
EVERY template's namespace rather than the minting one's.

**Decision.** Migrate opportunistically on a successful legacy read —
which is an event that actually happens.
`ScarfCore.LegacyKeychainRefMigrator`, called from
`ProjectConfigService.resolveSecret` right after the secret resolves.

**Order is load-bearing: mint → repoint → delete.**
- mint the SHA-256-bound item (a new item nothing references is inert);
- repoint `config.json` through `GuardedJSONStore` — the same guarded RMW
  `project_set_config` uses, so a present-but-unreadable config REFUSES the
  rewrite rather than orphaning every other value, and unknown top-level
  keys survive;
- delete the legacy item LAST, and only if the repoint succeeded. Reverse
  the order and there is a state where the config names an item that no
  longer exists — the user's secret gone, for a migration they never asked
  for. Stopping after the mint costs one duplicate Keychain item and a
  retry on the next read.

Best effort throughout: a migration failure must never turn a working
`resolveSecret` into a failing one. Matching is on the ref URI rather than
the field key — the key a ref is filed under is the thing we would
otherwise have to trust. Each migration is logged.

Each project's exposure now ends at its next USE rather than at its next
re-configuration. The `belongs` legacy branch can be deleted outright once
enough time has passed for reads to have drained it.
