---
title: Architecture-Overview
type: note
permalink: scarf-wiki/architecture-overview
created: 2026-05-29
updated: 2026-05-29
---

# Architecture Overview

Scarf is a SwiftUI app organized around **MVVM-F** (Model-View-ViewModel-Feature). Each user-facing capability is a self-contained feature module; cross-feature concerns flow through shared services. There are no third-party UI dependencies — system SQLite3, Foundation JSON, and SwiftUI's `AttributedString` markdown carry the load.

## Layering at a glance

```
Mac target (scarf):
  scarf/Features/         SwiftUI views + @Observable ViewModels (one per capability)
  scarf/Navigation/       AppCoordinator (single source of truth for nav state)
  scarf/Core/Services/    Mac-only services (SwiftTerm bridge, Sparkle wrapper)
  scarf/Core/Persistence/ Server registry (Codable plist)

iOS target (scarf mobile):
  Scarf iOS/App/          ScarfGoTabRoot, ScarfGoCoordinator, theme glue
  Scarf iOS/Onboarding/   SSH key generation, paste-public-key, connection test
  Scarf iOS/<feature>/    Dashboard, Chat, Projects, Skills, Memory, Cron, Settings, Servers, Notifications

Shared (Packages/):
  ScarfCore               Models, services, view-models, transport protocol, ACP
                          client, parsers, security helpers — consumed by both
                          targets via local SPM package.
  ScarfIOS                Citadel-backed SSH transport, KeychainSSHKeyStore, the
                          iOS-specific bits that can't compile on macOS.
  ScarfDesign             Rust palette, ScarfFont scale, ScarfSpace/Radius/Shadow
                          tokens, reusable components (PageHeader, Card, Badge,
                          TextField, four button styles). Linked into both targets.
```

See [Core Services](Core-Services), [Data Model](Data-Model), [Transport Layer](Transport-Layer), [ScarfCore Package](ScarfCore-Package), [Design System](Design-System), and [Sidebar & Navigation](Sidebar-and-Navigation) for the detail per layer.

## Key invariants

- **Features never import sibling features.** Cross-feature operations go through `AppCoordinator` (for navigation state) or a service (for data).
- **Read-only DB access.** Scarf never writes to `~/.hermes/state.db`. The only files Scarf writes are memory files (`MEMORY.md`, `USER.md`), cron job definitions, `.env`, `config.yaml`, and per-server snapshot caches.
- **Sandbox disabled.** Scarf needs to read `~/.hermes/` directly, so the App Sandbox entitlement is intentionally off. There are no extra entitlements beyond standard macOS.
- **Swift 6 strict concurrency.** `@MainActor` is the default isolation; services use `nonisolated` async methods and route results back to MainActor for UI updates.
- **No external runtime dependencies.** Sparkle (for updates) is the only SPM dependency.

## Navigation model

A single `@Observable AppCoordinator` holds `selectedSection: SidebarSection`, `selectedSessionId`, and `selectedProjectName`. It is injected into the view tree via `.environment()`. The sidebar reads/writes the selection; feature views observe it. This keeps "where are we" in one place rather than scattered across views.

The sidebar groups capabilities into four sections: **Monitor**, **Interact**, **Configure**, **Manage**. See [Sidebar & Navigation](Sidebar-and-Navigation) for the full section list.

## Multi-server: one window per server (Mac) / one tab root per server (iOS)

Scarf 2.0 is multi-window on Mac. Each window binds to exactly one **`ServerContext`** — either the local `~/.hermes/` (synthesized automatically) or a remote SSH host. Windows are independent; opening a second window for a different server gives you side-by-side state.

ScarfGo (iOS) uses the same `ServerContext` abstraction but with a single-window TabView. Switching servers from the Servers list rebuilds the `ScarfGoTabRoot` against the new context — same effect as opening a different window on Mac.

Server state lives in the `ServerRegistry` (Mac: Codable plist in `~/Library/Preferences/com.scarf.app`; iOS: `UserDefaults` under `com.scarf.ios.servers.v2` + per-server SSH keys in the iOS Keychain). A window's `ServerContext` is built once and provides the unified API services use:

- `context.readText(path)` / `writeText(path, body)` — file I/O via the active transport.
- `context.runHermes(args…)` — invokes `hermes` locally or `ssh host -- hermes` remotely.
- `context.openInLocalEditor(path)` — pulls remote files local first, then opens (Mac only).
- `context.transport` — `LocalTransport` (Mac local), `SSHTransport` (Mac remote, OpenSSH-driven), or `CitadelServerTransport` (iOS, pure-Swift Citadel). All three implement `ServerTransport`.

Services receive a `ServerContext`, never raw `FileManager`, `Process`, or `NSWorkspace.open` for Hermes paths. See [Transport Layer](Transport-Layer) for the protocol details.

## Chat — ACP subprocess

The Rich Chat surface speaks the Hermes Agent Client Protocol (ACP) — a JSON-RPC dialect over stdio. `ACPClient` spawns `hermes acp` (locally) or `ssh -T host -- hermes acp` (remote) and exposes an async event stream. No SQLite polling is involved — chat is end-to-end real-time. See [ACP Subprocess](ACP-Subprocess).

## File watching

`HermesFileWatcher` reacts to changes under `~/.hermes/` so the Dashboard, Sessions browser, Activity feed, and Memory viewer refresh without manual reload. Local windows use FSEvents (`DispatchSourceFileSystemObject`); remote windows use mtime polling tunneled over the SSH ControlMaster. **v2.7+** also watches each registered project's `<project>/.scarf/` directory (both local FSEvents and remote polling), so file-reading dashboard widgets (`markdown_file`, `log_tail`, `image`) refresh automatically when the cron job updates their underlying file.

## Updates

`UpdaterService` is a thin wrapper around Sparkle. The appcast lives at `https://awizemann.github.io/scarf/appcast.xml` (gh-pages branch); each entry is EdDSA-signed by the release script. See [Release Process](Release-Process).

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (ScarfCore + ScarfIOS + ScarfDesign extraction)_