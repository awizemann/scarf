---
title: Hermes v0.20.5 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-20-5-compatibility-decisions
tags: [hermes, compatibility, v0.20.5, decisions]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift, scarf/scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/scarf/Features/Settings/Views/Tabs/VoiceTab.swift]
source_paths_inferred: false
source_sha: c09ee3811bd75bae2d7416178d880f5d5b8c64b6
created: 2026-08-26
updated: 2026-08-26
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations

- [decision] Hermes v0.20.5 parity Phase 1 shipped on branch feat/hermes-v0205-parity (8 commits 5ca7c82..09da74d, 2026-08-26, pending merge). Capability group: isV0205OrLater (patch-level floor via atLeastSemver) + hasVersionFlagFullOutput + hasCronReasoningEffort (declared, unconsumed until the cron editor lands in Phase 2). #gating
- [decision] Version probe strategy (HealthViewModel.probeVersion): warm HermesVersionCache picks argv from hasVersionFlagFullOutput; cold cache probes `--version` first (safe on every host ≥v0.6.0), falls back to bare `version` only when output lacks "commits behind" AND parsed semver < 0.20.5/unparseable; warm path self-corrects a stale ≤0.20.4 cache (bare `version` output unparseable → retry `--version`) because users run `hermes update` inside the 600s TTL. #health
- [decision] max_turns: sentinel 0 = maxTurnsUnlimited; display resolves absent key to unlimited on 0.20.5+, 500 on 0.20.0–0.20.4, 60 older; steppers open the 0 floor ("Unlimited" label) only on isV0205OrLater so Scarf never writes 0 to a host without unlimited semantics; iOS ceiling raised 500→1000 to match macOS. #config
- [decision] stt.provider: parse default "" (absent ≠ "local" since 0.20.5 stopped seeding it); "Auto (unset)" picker row writes via unsetSetting, gated on hasConfigUnset (v0.19+) not isV0205OrLater — absent = "Hermes decides" on every host and it's the only exit from a pin; row hidden pre-v0.19 unless already current; stt.local.* tuning rows stay visible under Auto. #config
- [decision] parseProfileList: 0.20.5 renders the Profile column as `display_name (canonical_id)` (display FIRST — reverse of the audit's guess; suffix only when display set and ≠ name). Parser isolates field 0 by splitting on 2+ spaces, then takes the LAST id-shaped paren group (`^[a-z0-9][a-z0-9_-]{0,63}$` — ids can never contain space/paren) within it, falling back to the first token. Known accepted edge: labels >15 chars collapse the column gap; misparse requires that AND an id-shaped paren token in the model string. Robust fix if ever needed: derive column offsets from the header row. #profiles
- [fact] opencode-free (zero-auth aggregator) added to overlayOnlyProviders/providerAliases(free, opencode_free)/aggregatorProviders; HermesProviderOverlay gained `keyless: Bool` and CredentialPoolsView suppresses the key field + disables Add for keyless providers. NOT a gap: bare `opencode` in aggregatorProviders is correct — providers.py ALIASES maps opencode-zen/zen → opencode (Zen's canonical id IS `opencode`); guarded by new invariant test aggregatorProvidersAreAllCanonicalIDs. #providers
- [gotcha] check-hermes-tables.py must be run against a checkout AT the target tag (temp worktree of v2026.8.19); against the user's live checkout (may lag) it reports spurious FAILs. #ops

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.20.5 Audit Findings]]
- relates_to [[Hermes Version Compatibility Target]]
