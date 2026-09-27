---
title: Named-profile auth.json falls back to the root per provider — read it the way Hermes does
type: note
permalink: scarf/architecture/named-profile-auth-json-falls-back-to-the-root-per-provider
tags: [hermes, profiles, auth, capability-gating]
source_paths: [scarf/scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift, scarf/scarf/Core/Services/NousSubscriptionService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/NousModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesAuthFallback.swift]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-27
---

Under a named profile (`<root>/profiles/<name>`) Hermes does not read only the profile's auth.json. Scarf's read-only auth views (Credential Pools, NousSubscriptionService, NousModelCatalogService bearer) go through `HermesAuthFallback.load` so they show what Hermes would actually use. Fixed in R03 (S06-F3).

## Observations
- [fact] `credential_pool.<p>` falls back to the root auth.json when the profile has ZERO entries for that provider (profile wins with any entry) — `read_credential_pool`, `hermes_cli/auth.py:870-893` @ v2026.9.24; commit 33bf5f6292, first released v2026.5.7 (0.13.0) → `hasProfileAuthPoolFallback` #auth
- [fact] `providers.<p>` (OAuth state, e.g. nous) falls back to the root when the profile has no dict for it — `_load_provider_state`, `auth.py:755-766` @ v2026.9.24; profile-only at v2026.5.16, fallback at v2026.5.28 (0.15.0) → `hasProfileAuthProviderStateFallback` #auth
- [constraint] `active_provider` is NOT merged — Hermes reads it from the profile's own file (`get_active_provider`, `auth.py:1070-1072`), (Scarf no longer uses `active_provider` for Nous at all: since R18c/T3-F2 'subscribed' = signed in, because Hermes gates the Tool Gateway on sign-in + entitlement, never the provider — `tools/tool_backend_helpers.py:18-28` @ v2026.9.24) #auth
- [convention] Root path = `HermesProfileScope.rootHome(forHome:)` + `/auth.json`, only when `isProfileHome`; default-profile and undetected hosts read only their own file (C1). Inherited pools/providers render an 'inherited from default profile' badge and their Remove / OAuth-remove buttons are DISABLED: run in the profile, `hermes auth remove` never touches the root file (it copies the remaining root entries into the profile, or writes an empty list Hermes ignores) and logout clears only profile state — verified at v0.21.5. The chat 'No AI provider credentials' check (`HermesFileService.hasAnyAICredential`) uses the same fallback #ui
- [gotcha] `HermesAuthFallback.load` calls `HermesVersionCache.capabilitiesSync` via callers — only ever from detached/OffPool work, never the main actor (C10) #concurrency
