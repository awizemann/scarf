---
id: t-93ddfdc4
title: ScarfGo accepts any SSH host key — design trust-on-first-use known-hosts
status: todo
added: 2026-09-26
priority: high
---

## Description

Found by the 2026-09-26 surface audit. `hostKeyValidator: .acceptAnything()` at ScarfIOS ACPClient+iOS.swift:161, CitadelServerTransport.swift:1170, CitadelSSHService.swift:147 — ScarfGo trusts any host key, so a network attacker can impersonate the Hermes host (MITM) and capture prompts/outputs. Needs design: TOFU pinning per server stored in the Keychain, a first-connect fingerprint confirmation, a clear mismatch error with a deliberate "trust new key" path, and migration for existing saved servers (pin on next successful connect). Check how the Mac side validates host keys (system ssh + known_hosts) for parity.

## Plan



## Artifacts



