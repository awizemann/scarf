---
id: t-fe471aa5
title: ScarfGo accepts any SSH host key — add host-key pinning
status: done
added: 2026-10-05
priority: urgent
---

## Description

Found 2026-10-05 during the privacy-policy audit. ScarfGo's Citadel SSH paths use hostKeyValidator: .acceptAnything() — scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:1239, ACPClient+iOS.swift:188, CitadelSSHService.swift:147. That leaves it open to man-in-the-middle attacks on untrusted networks. The Mac verifies keys via system ssh StrictHostKeyChecking=accept-new (SSHTransport.swift:218). The old privacy policy claimed "strict host-key verification"; the corrected policy (2026-10-05) discloses the gap. Fix: trust on first use, matching the Mac. Pin the host key per server on first connect (store it alongside the server config, or in the Keychain), reject a mismatch with a clear UI (show the fingerprint and let the user re-trust deliberately), and cover all three call sites. Then update PRIVACY_POLICY.md and its wiki and gh-pages copies to drop the disclosure.

## Plan



## Artifacts



