---
title: Architecture-Overview
type: note
permalink: scarf-wiki/architecture-overview
created: 2026-05-29
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore, scarf/scarf/Core, scarf/scarf/Features, scarf/Scarf iOS, scarf/Packages/ScarfDesign
source_paths_inferred: false
---

# Architecture Overview

Scarf is a native multi-window macOS and iOS application that connects to local or remote Hermes instances over plain SSH or embedded Swift SSH (Citadel on iOS). It reads Hermes's SQLite database, launches subprocess connections for real-time chat, and coordinates management operations through the `hermes` CLI. The architecture is built on Swift 6's strict concurrency model and structured as MVVM-Feature: each sidebar section is a self-contained feature module, sharing core services through a unified ScarfCore package.

## System layers

```
┌─────────────────────────────────────────────┐
│ Views (SwiftUI, per-platform)               │
│ macOS: split-view sidebar + detail pane     │
│ iOS: tab navigation w/ adaptive sidebar     │
└─────────────────┬───────────────────────────┘
                  │ binds to @Observable
┌─────────────────▼───────────────────────────┐
│ ViewModels (MVVM, per-feature)              │
│ ChatViewModel, SessionsViewModel, etc.      │
└─────────────────┬───────────────────────────┘
                  │ calls
┌─────────────────▼───────────────────────────┐
│ Services (ScarfCore, transport-agnostic)    │
│ HermesDataService, ACPClient, CuratorService│
└─────────────────┬───────────────────────────┘
                  │ via
┌─────────────────▼───────────────────────────┐
│ ServerContext + Transport                   │
│ Local | SSHTransport | CitadelServerTransport
└─────────────────┬───────────────────────────┘
                  │ reaches
┌─────────────────▼───────────────────────────┐
│ Hermes host (local ~/.hermes or remote)     │
│ state.db | config.yaml | hermes CLI         │
└─────────────────────────────────────────────┘
```

## Feature modules

Each sidebar section is a self-contained feature under `Features/<Name>/`:

```
scarf/scarf/Features/
├─ Chat/                     (Rich ACP chat + terminal mode)
├─ Projects/                 (Dashboards, Kanban, Mini-apps, Templates)
├─ Sessions/                 (Conversation history, search, export)
├─ Kanban/                   (Board view, card management)
├─ Templates/                (Catalog, install, configure, export)
├─ Bots/                     (Bot roster, profiles, conversations)
├─ Platforms/                (Messaging gateway setup, QR pairing)
├─ Settings/                 (Config editor, models, profiles, APIs)
└─ [13 more sections]        (Skills, Cron, Memory, Webhooks, etc.)
```

Features never import sibling features directly — all cross-feature navigation goes through `AppCoordinator`. Each feature exposes a `View` entry point; the coordinator instantiates and presents it.

## Core packages (shared code)

### ScarfCore (`scarf/Packages/ScarfCore/`)

The heart of the app: models, services, and view models that both macOS and iOS reuse byte-for-byte.

| Module | Contains |
|---|---|
| **Models** | `ACPRequest`, `HermesMessage`, `ScarfProject`, `ACPEvent`, `HermesProfile`, and ~60 more |
| **Services** | `HermesDataService`, `ACPClient`, `HermesFileService`, `HermesLogService`, `CuratorService`, `BotsService`, `ModelCatalogService`, `NousSubscriptionService`, and ~10 more |
| **ViewModels** | `ChatViewModel`, `SessionsViewModel`, `ActivityViewModel`, `ConnectionStatusViewModel`, and shared VM logic |
| **Transport** | `LocalTransport`, `SSHTransport`, `ServerContext`, `ServerTransport` protocol |
| **ACP** | `ACPClient` actor, `ACPChannel` protocol, `ACPEventParser`, message stream handling |
| **Parsing** | YAML/JSON parsers for profiles, jobs, approvals, cron schedules, bot peers |
| **Diagnostics** | `ScarfAnalytics`, `ScarfMon` (performance sampling), `ScarfMonBoot` |

**Tests:** `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/` — 107 files covering models, services, transport, and ACP.

### ScarfDesign (`scarf/Packages/ScarfDesign/`)

Typed design-token bundle imported by both targets:

- **Colors:** `ScarfColor.accent` (rust), semantic colors (success, danger, warning, info), tool-call kind tints.
- **Typography:** 11 preset styles via `.scarfStyle()` (title, body, caption, code).
- **Spacing & Radius:** Token helpers for consistent layouts.
- **Components:** `Card`, `Badge`, `TextField` styles, shared SwiftUI modifiers.

### ScarfIOS (`scarf/Packages/ScarfIOS/`)

iOS-specific code isolated for later decoupling:

- `CitadelServerTransport` — pure-Swift SSH (Citadel framework).
- `Ed25519KeyGenerator` — on-device keypair generation.
- `KeychainSSHKeyStore` — iOS Keychain storage.
- `IOSDashboardViewModel`, `NetworkReachabilityService`.

## Transport layer

Scarf speaks to Hermes through a `ServerTransport` abstraction:

| Transport | Environment | Read | Write | Subprocess |
|---|---|---|---|---|
| **LocalTransport** | Mac with `~/.hermes/` | Direct file I/O | Direct file I/O | Fork/exec |
| **SSHTransport** | Mac reaching remote | scp `host:path` to temp | ssh-exec + echo | ssh host -- binary |
| **CitadelServerTransport** | iOS (no system ssh) | SFTP (Citadel) | SFTP | ssh host -- binary |

All are wrapped by `ServerContext`, which routes file reads, CLI execution, and database queries. Callers never know which transport is active.

**Key invariants:**
- Database reads are **read-only** (`PRAGMA query_only = ON`) to avoid WAL contention with Hermes.
- Management actions go through `hermes` CLI (safe) — never direct SQL writes.
- File watching: local uses FSEvents; remote uses 3-second mtime polling.

**Reference:** [[Transport Layer]]

## Data flow — reading Hermes state

1. View `.task` calls `viewModel.load()`.
2. ViewModel calls service method, e.g., `HermesDataService.loadSessions(context:)`.
3. Service:
   - **Local:** Direct SQLite read from `~/.hermes/state.db`.
   - **Remote:** `scp host:~/.hermes/state.db /tmp/snapshot-<uuid>.db` (atomic, cached, temporary).
4. Service parses, dedupes concurrent requests, returns typed result.
5. ViewModel publishes `@Observable` changes; SwiftUI re-renders.

**File watching:** `HermesFileWatcher` observes `~/.hermes/` (local FSEvents) or polls mtimes (remote). When files change, views refresh automatically.

## Data flow — chat and subprocess (ACP)

[[ACP Subprocess]]

1. ViewModel calls `ACPClient.start(context:, sessionID:)`.
2. ACPClient:
   - **Local:** Spawns `~/.hermes/bin/hermes acp` subprocess.
   - **Remote:** SSH: `ssh host -- hermes acp`, pipes stdin/stdout as JSON-RPC.
3. Client sends `session/new` or `session/load` RPC, opens event stream.
4. Hermes emits chunks (text, tool calls, reasoning, permissions, progress).
5. ACPClient parses events; ViewModel upserts observable messages.
6. SwiftUI renders in real-time, throttled to 50ms per batch.

**Resilience:** If the stream dies, ViewModel auto-reconnects via `session/load` on exponential backoff (1→2→4→8→16 seconds). Hermes keeps writing to `state.db` during the outage.

## Multi-server architecture

Scarf is a multi-window app: each window binds to exactly one Hermes server.

- **Local:** Auto-synthesized on app launch; points to `~/.hermes/`.
- **Remote:** Added via **File → Open Server**; saved to `~/Library/Preferences/com.scarf.app.plist`.
- **Per-window isolation:** Each window has its own `AppCoordinator`, feature ViewModels, and ServerContext.

**Reference:** [[Multi-Server Architecture (Scarf 2.0+)]]

## Concurrency model

Strict Swift 6 concurrency throughout:

- **Services** are `actor`-isolated (e.g., `ACPClient`, `HermesDataService`) or `Sendable struct` (e.g., `HermesFileService`).
- **ViewModels** are `@Observable @MainActor` (state binds to SwiftUI).
- **Views** run on `@MainActor` (SwiftUI requirement).
- **Long-running work** (file I/O, SSH, database reads) runs off-main via `Task` or `async` callsites.
- **No data races:** compiler enforces sendability; all cross-isolation calls are explicit `await`.

## Capability gating

Hermes evolves; Scarf detects schema, CLI output, and version tags to capability-gate UI. Unsupported surfaces simply hide on older hosts — no crashes, no errors.

**Pattern:** `HermesCapabilities` (ScarfCore/Services) queries Hermes's version and schema; features check `.isV0204OrLater` before showing v0.20.4-only surfaces.

**Reference:** [[Hermes Capability Gating Pattern]]

## iOS-specific architecture

Both `scarf` (macOS) and `scarf mobile` (iOS) are targets in `scarf/scarf.xcodeproj`, sharing ScarfCore + ScarfDesign.

| Aspect | Mac | iOS |
|---|---|---|
| **Transport** | System SSH (OpenSSH ControlMaster) | Citadel (pure Swift) |
| **SSH keys** | Assumed in `~/.ssh/` | Generated on-device, iOS Keychain |
| **Layout** | Split-view sidebar + detail | Tabs + sidebar (adaptive on iPad) |
| **Localization** | 7 languages | English only (v1) |
| **Push notifications** | Sparkle (manual check) | TestFlight / App Store (future) |

**Reference:** [[ScarfGo iOS Companion App]], [Platform Differences](Platform-Differences)

## Design system

All UI uses typed tokens from ScarfDesign — no hardcoded colors, fonts, or spacing.

**Convention:** Reach for `ScarfColor`, `ScarfFont`, `ScarfSpace`, `ScarfRadius` before custom values. If something isn't tokenized, either add the token or justify the exception inline.

**Reference:** [Design System](Design-System)

## Key invariants

1. **Read-only database** — avoid WAL contention with Hermes.
2. **Safe CLI paths** — all management goes through `hermes` CLI.
3. **Feature isolation** — no direct feature-to-feature imports.
4. **Transport abstraction** — views/services never check transport type directly.
5. **No app sandbox** — entitlements disable it so Scarf can read `~/.hermes/` and spawn `hermes`.
6. **Strict concurrency** — all async code explicitly isolated and sendable.