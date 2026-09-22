---
title: ScarfGo iOS Companion App
type: note
permalink: scarf/architecture/scarf-go-i-os-companion-app
tags: [ios, scarfgo, ssh]
source_paths: [README.md, scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfDesign, scarf/Packages/ScarfIOS]
source_sha: 904c0e60784d0936f39ccbd47242201c12ef23d0
created: 2026-05-29
updated: 2026-06-25
reviewed: 2026-09-22
reviewed_by: audit:claude-code (background)
---

## Observations
- [structure] ScarfGo is a separate iOS target (`scarf mobile`) in the same Xcode project. Both `scarf` (Mac) and `scarf mobile` import the shared `ScarfDesign` and `ScarfCore` Swift packages under `scarf/Packages/`. #targets
- [design] ScarfGo uses pure-Swift SSH via Citadel — no `ssh` binary on iOS. Generates Ed25519 keypair on device; private key stored in iOS Keychain. Key resolution per-server via `SSHKeyResolver` maps `SSHConfig` to its server entry's stored key, with fallback to legacy singleton for pre-M9 installs (gh#133). Both transport + chat ACP channel use per-server resolution to avoid loading the lexicographically-first key when multiple servers are registered. #security
- [scope] Feature surface: multi-server, project-scoped chat, session resume, memory editor, cron list, skills tree, Kanban board, Curator, settings (read-only), **on-device dictation + Live Voice**. All sessions are scoped to a project via the same Scarf-managed AGENTS.md block the Mac app writes. **Voice playback** speaks assistant replies through the host's configured text-to-speech provider (Hermes v0.20.1+). **Live Voice** (Hermes v0.21.3+ GPT-Live mode) streams voice directly to OpenAI ($0.05/min). #features #voice
- [profiles] Profile switching (#120, Design B): ScarfGo switches WHICH Hermes profile it views per-server WITHOUT mutating the host's `active_profile` (Mac app/terminal undisturbed). File layer scopes via `IOSServerConfig.remoteHome` → `HermesPathSet`; process layer (chat ACP + every hermes CLI) prepends `HERMES_HOME=<root>/profiles/<name>` in `CitadelServerTransport`/`ACPClient+iOS`. Profile selection is persisted per-server via `UserDefaultsProfileSelectionStore` (shared between ScarfCore and iOS/Mac); UI rebuilds on profile switch and ACP session tears down/restarts to load profile-scoped state. #profiles #ios
- [resilience] SSH connect resilience via `SSHConnectPolicy` — retries up to 3x on channel connect timeout only (hard-coded 10s window in Citadel). Actionable error text replaces bridged "error N" strings in transport / chat / onboarding funnels. Cold cellular Tailscale paths (DERP-relayed) exceed the 10s login window; warm tunnel fits easily. (gh#133) #resilience
- [transport-security] Script execution via `streamScript` passes the script directly on stdin using `head -c N | /bin/sh` rather than base64-encoding it into the command line, keeping sensitive script content (e.g. Live Voice SDP offers) out of remote process argv where it would be visible in `ps`. #security
- [distribution] App Store release 2026-09-18: https://apps.apple.com/us/app/scarfgo/id6763763341 (free, primary distribution). Beta: TestFlight at https://testflight.apple.com/join/qCrRpcTz . Requires iOS 18.0+. #distribution
- [constraint] iOS Dynamic Type clamped at scene root in `ScarfIOSApp.swift`: `.dynamicTypeSize(.xSmall ... .accessibility2)`. iOS adopts native `.navigationTitle` + `.large` instead of `ScarfPageHeader` on tab roots. #accessibility

## Relations
- relates_to [[iOS Platform Rules]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- shares_with [[Scarf Design System (ScarfDesign)]]
- documents_fix gh#133
