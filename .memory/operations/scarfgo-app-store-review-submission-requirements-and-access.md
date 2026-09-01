---
title: ScarfGo App Store review: submission requirements and access model
type: note
permalink: scarf/operations/scarfgo-app-store-review-submission-requirements-and-access
source_paths: [scarf/Scarf iOS/Info.plist, scarf/Scarf iOS/Scarf_iOS.entitlements, scarf/Scarf iOS/PrivacyInfo.xcprivacy, scarf/Scarf iOS/Onboarding/OnboardingRootView.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift]
source_paths_inferred: false
source_sha: 163bed3a5ff7754d4e880091af7bfdc98b5da69c
created: 2026-08-14
updated: 2026-08-19
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [constraint] ScarfGo has NO standalone/demo/offline mode — every surface reads a live remote Hermes host over SSH, so App Store review requires a live, internet-reachable test server handed to the reviewer. #appstore #review
- [decision] Reviewer onboarding MUST use the 'Import existing key' path: the default flow generates an Ed25519 key on-device that the user must add to the host's authorized_keys, which a reviewer cannot do. We pre-authorize a throwaway keypair (vault 'scarfgo-appstore-review-sshkey') and hand Apple the private half to paste. #onboarding
- [fact] iOS transport is direct Citadel SSHClient.connect(to: host:port) with NO ProxyCommand/jump/cloudflared (CitadelServerTransport.swift, ACPClient+iOS.swift) — a standard Cloudflare Tunnel cannot front it; the reviewer needs a directly reachable public host:port (plain VPS, e.g. DigitalOcean). #transport
- [done] Submission build blockers fixed and verified (BUILD SUCCEEDED, manifest bundled 2026-08-14): added PrivacyInfo.xcprivacy (UserDefaults CA92.1, tracking=false); removed phantom push (UIBackgroundModes + aps-environment); added ITSAppUsesNonExemptEncryption=true and NSLocalNetworkUsageDescription. Files auto-included via PBXFileSystemSynchronizedRootGroup. #config
- [fact] Review kit lives at documents/appstore-review/scarfgo-reviewer-access.md (ASC notes block + walkthrough) and scratchpad review-kit/ (provision-scarfgo-review.sh + review keypair). Test droplet 24.199.89.183, user scarfreview, OpenRouter model, spend-capped. #artifacts

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]

## Provisioning gotchas (verified live on the DO droplet, Hermes v0.20.1, 2026-08-14)
- [gotcha] Writing `authorized_keys` by passing the public key as an `ssh root@host 'bash -s' -- "$PUBKEY"` positional arg TRUNCATES it to `ssh-ed25519` — ssh joins argv into one string the remote shell re-splits on the key's spaces. Pipe the key over stdin (`printf '%s\n' "$PUBKEY" | ssh host 'cat > authorized_keys'`) instead. Symptom: reviewer key → `Permission denied (publickey)`. #ssh
- [gotcha] Hermes installs its CLI to `~/.local/bin`, which is NOT on the default non-login PATH — and ScarfGo runs `ssh host -- hermes …` (non-interactive; never sources ~/.bashrc). Symlink `/usr/local/bin/hermes → ~/.hermes/hermes-agent/venv/bin/hermes` (on the standard non-login PATH) or every surface fails with command-not-found. #path
- [gotcha] Hermes one-shot chat flag is `-z/--oneshot PROMPT` (NOT `-p`/`run -p`). Project seed is `hermes project create NAME [folders...]` (NOT `add`). Cron is `hermes cron create <schedule> [prompt] --name NAME` (positional). `skills install` needs a real identifier (derive via `skills search <q> --json`). #cli
- [gotcha] Hermes `install.sh` ends with an OPTIONAL npm/browser-tools step that can exit non-zero and, under `set -e`, aborts provisioning AND skips the CLI symlink. Run it with `|| true` and gate on `hermes --version`. Pre-install build-essential/python3-dev/libffi-dev as root so the installer never needs an interactive sudo. #install
- [done] Dashboard 'running' needs the gateway up: `hermes gateway install --system --run-as-user scarfreview --start-now --start-on-login` (systemd, survives reboot). #gateway

## Import-key format gotcha (found during reviewer dry-run, 2026-08-19)
- [gotcha] The private key handed to the reviewer for "Import existing key" MUST be ScarfGo's custom PEM, NOT OpenSSH. `ssh-keygen`'s `-----BEGIN OPENSSH PRIVATE KEY-----` fails at connect time with "Stored private key is not in the expected Scarf Ed25519 PEM format" (CitadelSSHService.buildClientSettings → Ed25519KeyGenerator.decodeRawEd25519PEM). #import
- [fact] Expected format = `-----BEGIN SCARF ED25519 PRIVATE KEY-----` / base64( 32-byte raw private seed ‖ 32-byte raw public ) wrapped at 76 cols / `-----END …-----` (Ed25519KeyGenerator.makeRawEd25519PEM). Convert an existing OpenSSH ed25519 key with python cryptography: load_ssh_private_key → private_bytes(Raw,Raw,NoEncryption) ‖ public_bytes_raw, base64, wrap. Same keypair → authorized_keys unchanged. #format
- [fact] Both key forms of the review keypair are vaulted: OpenSSH in `scarfgo-appstore-review-sshkey` (for SSH-verifying from a shell), Scarf PEM in `scarfgo-appstore-review-scarfpem` (what the reviewer pastes). The public line the reviewer pastes stays the standard OpenSSH `ssh-ed25519 …` line. #vault

## RESOLVED: import path fixed (2026-08-19, branch fix/ios-import-openssh-key, commit e03b01f)
- [done] The "Import existing key" path was broken app-wide: import validated+stored OpenSSH but the 3 connect sites decoded ONLY the Scarf raw PEM, so no pasted key could satisfy both. Fixed by SSHPrivateKeyDecoding.curve25519PrivateKey(fromPEM:) accepting BOTH the Scarf PEM (Generate) and OpenSSH (Import, via Citadel `Curve25519.Signing.PrivateKey(sshEd25519:)`); wired into CitadelSSHService/CitadelServerTransport/ACPClient+iOS. Unit-tested + verified E2E in simulator (import OpenSSH → connect → Dashboard live data). #fixed
- [correction] SUPERSEDES the earlier "must hand the reviewer a Scarf PEM" gotcha: with the fix the reviewer pastes a STANDARD OpenSSH ed25519 private key (the Scarf PEM would now FAIL import validation). The fix MUST ship in the submitted build — the pre-fix build accepts neither format at connect. #correction
- [gotcha] Simulator-only artifacts seen while verifying, NOT app bugs: (1) OSStatus -34018 errSecMissingEntitlement on Keychain save when built with CODE_SIGNING_ALLOWED=NO — build signed instead; (2) on-screen keyboard smart-dashes mangle "-----" in a pasted key — a real reviewer pastes (no substitution), so paste via `simctl pbcopy` + long-press Paste to test faithfully. #testing

## Chat model-config + macOS scope (2026-08-19)
- [gotcha] Provisioning set the WRONG model key: `hermes config set model.model` — Hermes' canonical primary-model key is `model.default` (auth.py:7809 `config["model"]["default"]`), and Scarf's HermesConfigReader reads `model.default` (HermesConfigReader.swift:170). Wrong key → Scarf's ModelPreflight reports `.missingModel` ("No primary model is set") and Chat shows the Pick-a-model sheet, even though the agent still answers (Hermes falls back to the provider default). Fix: `hermes config set model.default <model>` (fix the provisioning script's model.model→model.default line). Verified: Chat then connects and the agent replies in-app. #config #provisioning
- [fact] The import-key bug is iOS-ONLY. macOS reaches remotes via system `ssh` with the user's own ~/.ssh / a picked IdentityFile path (AddServerViewModel.pickIdentityFile stores url.path; no SSHKeyBundle, no decodeRawEd25519PEM, no PEM parsing) — system ssh handles OpenSSH keys natively, so there is no Scarf-PEM-vs-OpenSSH mismatch. The bug was unique to iOS/Citadel needing to parse the key into a CryptoKit object. #macos #scope
