---
created: 2026-09-03
updated: 2026-09-03
---

# Code Overview

Scarf is a native macOS + iOS GUI for the Hermes AI agent. The codebase splits into a shared Swift Package (`ScarfCore`) that both platforms use, platform-specific app targets that import it, and a design system (`ScarfDesign`) for consistent UI.

Start here, then pick a module that interests you.

## Module Guides

1. **[ScarfCore Foundation](ScarfCore-Foundation)** — The shared cross-platform package: models, services, transport, and business logic. Read this first if you're touching session state, Hermes integration, or core features.

2. **[Chat & Streaming](Chat-Streaming)** — Rich ACP chat with live streaming, session management, and transcript rendering. Start here for chat protocol questions or UI fixes.

3. **[Services Layer](Services-Layer)** — Business logic and Hermes integration: bot management, config reading/writing, session backends, fleet operations. Read for any config/cron/curator work.

4. **[Features & MVVM-F Architecture](Features-MVVM-F)** — The feature isolation pattern, AppCoordinator routing, and ViewModel patterns. Essential for adding new features or understanding sidebar navigation.

5. **[Projects & Dashboards](Projects-Dashboards)** — Projects as a first-class concept, custom dashboards, mini-apps, and fleet grouping. Start here for project-scoped work.

6. **[Transport & Remoting](Transport-Remoting)** — ServerContext abstraction, local vs. remote, SSH circuit breaker, iOS Citadel. Read for connection handling or remote Hermes work.

7. **[Security & Onboarding](Security-Onboarding)** — SSH key generation, Keychain storage, connection testing, validation. Start here for SSH or iOS setup flows.

8. **[Parsing & YAML](Parsing-YAML)** — Hermes file format readers: bot profiles, cron jobs, approvals, YAML handling. Read when touching Hermes-authored files.

## Shared Packages

- **ScarfCore** (`scarf/Packages/ScarfCore/`) — Swift Package: shared models, services, viewmodels, and logic for both Mac and iOS.
- **ScarfDesign** (`scarf/Packages/ScarfDesign/`) — Design system: typed tokens, colors, and reusable SwiftUI components.
- **ScarfIOS** (`scarf/Packages/ScarfIOS/`) — iOS-specific transport (Citadel SSH) and dashboard logic.

## Platform Targets

- **scarf** (macOS) — `scarf/scarf/` — Main app: `Core/Services`, `Features/`, `Navigation/`.
- **scarf mobile** (iOS) — `scarf/Scarf iOS/` — Companion app: platform-specific views, Citadel SSH transport.

## Architecture Rules

- **MVVM-Feature**: Each feature is a self-contained module under `Features/` with `Views/` and `ViewModels/` subdirs.
- **No sibling imports**: Features never import each other directly; routing goes through `AppCoordinator`.
- **Multi-server**: Each window binds to one Hermes server; `ServerContext` abstracts local vs. remote.
- **Swift 6 strict concurrency**: `@MainActor` by default, `nonisolated` for services.
- **Zero warnings**: All code builds clean.
- **Minimal dependencies**: Only SwiftTerm and Sparkle external; everything else is system frameworks.