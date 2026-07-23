---
title: ScarfCore-Package
type: note
permalink: scarf-wiki/scarf-core-package
created: 2026-05-29
updated: 2026-05-29
---

# ScarfCore Package

`ScarfCore` is the local SwiftPM package at [`scarf/Packages/ScarfCore/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore) that holds every piece of code shared between the Mac (`scarf`) and iOS (`scarf mobile`) targets — models, services, view-models, the transport protocol, the ACP client, parsers, and security helpers. v2.5 extracted it from the Mac target so iOS could reuse it byte-for-byte instead of duplicating logic.

If you're touching a service, model, or parser that needs to work on both platforms, that's ScarfCore's job. If you're touching something that only compiles on one platform (Sparkle, SwiftTerm, Citadel, KeychainSSHKeyStore), it lives in the per-platform target instead.

## Package layout

```
Packages/
  ScarfCore/                    # platform-agnostic core, no UI
    Sources/ScarfCore/
      ACP/                      # ACP wire types + ProcessACPChannel + SSHExecACPChannel
      Models/                   # HermesSession, HermesMessage, HermesConfig, ProjectEntry, etc.
      Parsing/                  # CronScheduleFormatter, HermesSkillsHubParser
      Persistence/              # Codable structs for JSON sidecars
      Security/                 # OnboardingViewModel, IOSServerConfig, OnboardingState
      Services/                 # HermesDataService, ProjectDashboardService, SkillsScanner, …
      ServerContext/            # ServerContext + ServerTransport protocol + factory
      Transport/                # LocalTransport (Mac), SSHTransport (Mac remote)
      ViewModels/               # IOSDashboardViewModel, IOSCronViewModel, SkillsViewModel, …
    Tests/ScarfCoreTests/       # 163 tests across 12 suites — runs on Linux CI

  ScarfIOS/                     # iOS-only glue
    Sources/ScarfIOS/
      CitadelServerTransport.swift   # ServerTransport via Citadel SSH (replaces system ssh)
      KeychainSSHKeyStore.swift      # iOS Keychain-backed Ed25519 key persistence
      CitadelSSHService.swift        # Pure-Swift keypair gen + connection probes

  ScarfDesign/                  # rust palette, ScarfFont, ScarfSpace, ScarfRadius, components
    Sources/ScarfDesign/        # See: Design System
```

Both `scarf` (Mac target) and `scarf mobile` (iOS target) declare local SPM dependencies on the three packages via `XCLocalSwiftPackageReference` entries in `project.pbxproj`. No registry, no fetch step — they live next to the app code in the repo.

## What lives where

### ScarfCore (both platforms)

**Models** — plain `Codable` `Sendable` structs. `HermesSession`, `HermesMessage`, `HermesSkill`, `HermesConfig`, `HermesProject`, `ProjectEntry`, `ProjectDashboard`, `IOSServerConfig`, `ServerID`, etc. No reference types.

**Services** — actor-isolated or `Sendable struct` services that read/write Hermes state through a transport. See [Core Services](Core-Services) for the catalog.

**ViewModels** — `@Observable @MainActor` classes that drive feature UI. Mac and iOS both consume `IOSDashboardViewModel`, `IOSCronViewModel`, `SkillsViewModel`, `IOSSettingsViewModel`, `RichChatViewModel`, etc. (The `IOS` prefix is historical — the view-models are platform-agnostic now; renaming them is a v2.6 cleanup item.)

**Transport** — `ServerTransport` protocol declaring the I/O surface every backend implements. `LocalTransport` (local file ops + `Process` exec) and `SSHTransport` (system `ssh` via OpenSSH) live here because they don't pull in iOS-specific dependencies. `CitadelServerTransport` lives in `ScarfIOS` because Citadel is iOS-only.

**ACP** — `ACPChannel` protocol + `ACPRequest`/`ACPResponse`/`ACPNotification` types + `ProcessACPChannel` (Mac-spawned subprocess) + `SSHExecACPChannel` (iOS SSH-tunneled JSON-RPC). Both channels surface the same async event stream.

**Parsing** — `HermesSkillsHubParser` (Rich-table parser for `hermes skills browse`/`search` output), `CronScheduleFormatter` (cron string → English).

**Security / Onboarding** — `OnboardingViewModel` (state machine for the iOS onboarding flow), `OnboardingState` enum, `IOSServerConfig` (host/user/port/binaryHint shape).

### ScarfIOS (iOS only)

iOS-specific glue that can't compile on macOS:

- `CitadelServerTransport` — `ServerTransport` implementation via [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.x. Pure-Swift SSH; no `ssh` subprocess dependency. Drives `executeCommandStream` directly so stdout survives non-zero exits, prepends `PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH` so non-interactive sessions resolve `hermes`.
- `KeychainSSHKeyStore` — Ed25519 keypair persistence in the iOS Keychain. Service `com.scarf.ssh-key`, account `server-key:<UUID>`, accessibility `ThisDeviceOnly`. Wraps `SecItemCopyMatching` / `SecItemAdd` / `SecItemDelete` behind a typed API.
- `CitadelSSHService` — pure-Swift keypair generation + connection probes for the onboarding flow.

### ScarfDesign (both platforms)

Tokens + components. See **[Design System](Design-System)**.

## Why `KeychainSSHKeyStore` isn't in ScarfCore

`Security.framework` is available on both Mac and iOS but the **Keychain item attributes that make sense** differ between platforms. Mac uses `kSecClassGenericPassword` with file-protection levels; iOS uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to opt out of iCloud Keychain sync (which doesn't exist on Mac in the same form). Trying to share one type across both led to a parameter explosion.

Mac doesn't need an in-app SSH key store because it uses the system `~/.ssh/` directory and ssh-agent. iOS does need one because there's no system SSH agent. The asymmetry is the reason the type lives in `ScarfIOS` and not `ScarfCore`.

## Adding a new shared service

1. Decide the service is platform-agnostic (no `AppKit` / `UIKit` / `WatchKit` imports, no `Process()` / `NSWorkspace`, no Citadel-specific types). If any of those creep in, the service belongs in the platform target instead.
2. Add a Swift file under `Packages/ScarfCore/Sources/ScarfCore/Services/`.
3. Take a `ServerContext` in `init`, decide isolation (`actor` for stateful, `Sendable struct` for stateless), expose async public methods, route I/O through `context.transport`.
4. Add a corresponding row to [Core Services](Core-Services) so the wiki catalog stays current.
5. Write a `Tests/ScarfCoreTests/<service>Tests.swift` suite. Tests run on Linux CI, so no Foundation-mac-only APIs.

The current breakdown: 30+ services, 12 test suites, 163 tests, three consecutive green runs as of v2.5.0.

## Why we extracted in v2.5

Pre-v2.5, services lived in `scarf/scarf/Core/Services/` and the iOS target either duplicated them or imported them via a brittle `target` membership trick. The duplication path drifted (project context block subtly differed between platforms); the trick path didn't survive Swift 6 strict concurrency. Pulling everything into a proper SPM package solved both: one source of truth, one set of tests, both targets `import ScarfCore`.

The split between ScarfCore (platform-agnostic) and ScarfIOS (iOS glue) keeps the package builds clean — ScarfCore compiles on Linux without dragging Citadel into the dependency tree.

## Related pages

- [Architecture Overview](Architecture-Overview) — high-level layering.
- [Core Services](Core-Services) — service catalog.
- [Transport Layer](Transport-Layer) — `ServerTransport` protocol details.
- [Design System](Design-System) — ScarfDesign package reference.
- [Adding a Service](Adding-a-Service) — full recipe for new shared services.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (initial publication)_