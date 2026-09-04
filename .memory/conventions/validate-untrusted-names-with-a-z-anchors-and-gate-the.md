---
title: Validate untrusted names with \A..\z anchors and gate the charset before rendering them
type: note
permalink: scarf/conventions/validate-untrusted-names-with-a-z-anchors-and-gate-the
tags: [security, validation, regex, consent]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectSlashCommand.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppPermission.swift, scarf/scarf/Features/Projects/MiniApp/MiniAppLaunchView.swift]
source_paths_inferred: false
source_sha: 2c964c9894ab73b47b209b5a0395e07b7250a847
created: 2026-09-04
updated: 2026-09-04
---

Two P8 lows (SEC-L1, SEC-L4) with one shape between them: a string that arrives from an agent-written file, passes a validator that doesn't quite mean what it reads, and is then rendered somewhere a person makes a trust decision.

## Observations
- [gotcha] ICU's `$` matches BEFORE a final line terminator even without `.anchorsMatchLines`, so `^[a-z][a-z0-9-]*$` accepted `"deploy\n"` as a slash-command name — and a name that can end a line can forge the one after it, in the on-disk filename, the `/`-menu label, and any line-oriented context. Use `\A…\z`, never `^…$`, for whole-string validation of untrusted input #security
- [decision] Repo-wide sweep done (2026-09-04): every `^…$` validator that guards a filename, argv element, config write, or rendered label is now `\A…\z` — HermesProfileRoutes.HermesProfileName (config.yaml routes), HermesProfileResolver (path component), ProfilesViewModel.parseProfileList (`-p` argv), HermesEnvService.extractKey (.env writes), iOS ProfilesView.isProfileName + WebhooksView name parse. Left as `^…$` deliberately: line-parsers over CLI/log output (HermesPluginList, HermesLogService, NousAuthFlow) and the prefix-only BotRoutinePrefix — cosmetic, never a trust boundary #security
- [convention] Where a Scarf validator MIRRORS a Hermes Python regex (profiles.py `_PROFILE_ID_RE`), tightening to `\A…\z` is a deliberate, commented divergence: Python's `$` has the same trailing-newline hole, but Hermes strips before matching while Scarf's callers validate the raw string they go on to serialize — Scarf may be stricter than Hermes, never looser #convention
- [gotcha] SkillInstallValidator needs no fix — it is character-loop, not regex, and InstallFromURLSheet passes the same trimmed string to argv that was validated. HermesProfileScope.isValidName was already hardened (full-range NSRegularExpression match + normalize-parity check). Regression tests: ProfileRoutesTests.testProfileNameWithTrailingNewlineIsRejected, ProjectsG2HardeningTests.slashCommandNameWithTrailingNewlineIsRejected #testing
- [decision] A `query:<kind>` mini-app permission whose kind is outside `[a-z][a-z0-9._-]{0,63}` is DEMOTED to `.unknown` rather than repaired: the consent sheet renders the kind verbatim ("Read <kind> (read-only)"), and `.unknown` already reads as "will be denied", counts as sensitive, and is never pre-checked. Refusing to parse is safer than sanitizing on the way to the screen #security
- [convention] Round-trip fidelity and display fidelity are different jobs: `.unknown` PRESERVES the original bytes for the re-encode (so a permission this build doesn't model is never deleted) but renders through `MiniAppPermission.displaySafe`, which strips control characters and bidi/format overrides and caps the length #convention
- [gotcha] The same charset gate incidentally removed the comma that made the grant HMAC's permissions field non-injective — an input validator and a payload grammar were relying on each other without either saying so #gotcha

## Relations
- relates_to [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]]
