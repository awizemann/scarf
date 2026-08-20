---
id: t-67ddfa05
title: Fix ScarfGo import-key: connect path must accept OpenSSH keys
status: done
added: 2026-08-19
priority: high
---

## Description

The "Import existing key" onboarding path can never succeed. `OnboardingViewModel.importKey` validates the pasted key as OpenSSH (`isLikelyValidOpenSSHPrivateKey`) and stores the raw OpenSSH PEM, but all three connect sites decode ONLY the app's own "SCARF ED25519 PRIVATE KEY" raw PEM via `Ed25519KeyGenerator.decodeRawEd25519PEM`. So: paste OpenSSH → connect fails "not in expected Scarf Ed25519 PEM format"; paste Scarf PEM → import rejects "doesn't look like an OpenSSH private key". Generate works only because it emits Scarf PEM. Found during App Store review dry-run on device (2026-08-19).

Fix: connect path accepts BOTH formats. Citadel already provides `Curve25519.Signing.PrivateKey(sshEd25519:)`. Add a shared decoder in ScarfIOS that tries decodeRawEd25519PEM (Generate) then the OpenSSH parser (Import), and wire it into the 3 sites: CitadelSSHService.buildClientSettings, CitadelServerTransport.openSSH, ACPClient+iOS.openSSHClient. Add unit tests for both formats. Verify end-to-end in simulator: import an OpenSSH id_ed25519 → connect to the review droplet → surfaces load.

## Plan



## Artifacts



