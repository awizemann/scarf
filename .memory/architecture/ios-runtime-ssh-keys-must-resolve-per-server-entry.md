---
title: iOS runtime SSH keys must resolve per server entry — singleton Keychain load() picks the wrong key (gh#133)
type: note
permalink: scarf/architecture/ios-runtime-ssh-keys-must-resolve-per-server-entry
created: 2026-07-18
updated: 2026-07-18
---

## Observations

- [root-cause] gh#133 ("Citadel.SSHClientError error 4" after successful Test Connection): onboarding saves one key per server entry (`SSHKeyStore.save(_:for: entryID)`, OnboardingViewModel.swift:154), but BOTH runtime key providers — the transport factory (ScarfIOSApp.swift) and the chat ACP channel (ChatView.makeClient) — fetched via the compat singleton `KeychainSSHKeyStore.load()`, which returns the key of whichever ServerID sorts lexicographically FIRST among ALL `server-key:<uuid>` Keychain items. Keychain items survive app reinstalls and can arrive via iCloud Keychain sync (#52), so a months-old orphan item permanently shadows every new entry. Runtime connects then auth with the wrong private key → sshd rejects publickey → NIOSSH asks the delegate for the next method → Citadel's list is exhausted → `allAuthenticationOptionsFailed` ("error 4"), 100% reproducible, while Test Connection passes (onboarding hands the just-generated in-memory bundle directly to the tester). LAN vs Tailscale irrelevant (client-side); MaxSessions irrelevant. Likely also explains the "SSHClientError error 4" the gh#112 reporter saw on Dashboard. #gotcha #ios #ssh #keychain
- [fix] `SSHKeyResolver` (ScarfIOS): maps the connection's `SSHConfig` back to its server entry by `(host, port ?? 22, user ?? "root")` — exactly the fields `IOSServerConfig.toServerContext` copies — then `load(for: entryID)`; falls back to the singleton pick only when no entry matches (pre-M9 installs whose key lives under a migration-minted random id; the v1→v2 keychain migration mints a random ServerID unrelated to the config entry id, so per-id lookup can NEVER work for them). `remoteHome` deliberately excluded from the match — a #120 profile switch rewrites it, the key doesn't change. Wired: transport factory keyProvider uses `SSHKeyResolver.key(for: config)`; `ACPClient.forIOSApp(keyProvider:)` is now optional, nil (production default) = resolver. Tests: SSHKeyResolverTests. #pattern
- [gotcha] Cannot key the resolver off `ServerContext.id`: several iOS surfaces build contexts with STATIC shared ids (`SettingsView.sharedContextID`, `ScarfGoTabRoot.systemTabContextID`), so the factory's `id` argument is NOT the server entry id. Config-field matching is the only reliable reverse map. #ios
- [residual-risk] Two entries with identical (host, port, user) but different keys: resolver picks the lexicographically-first match. If its pubkey was removed from the host, still fails — but the error is now readable ("rejected this device's SSH key" + fix instructions) instead of "error 4". Trying multiple keys per connect was rejected: repeated failing auths can trip OpenSSH 9.8+ per-source penalties. #risk

## Relations
- relates_to [[iOS transport must be pooled per (ServerID, SSHConfig) — un-pooled makeTransport churns SSH connections]]
- relates_to [[ScarfGo iOS Companion App]]
