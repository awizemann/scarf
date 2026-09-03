---
title: Build-and-Run
type: note
permalink: scarf-wiki/build-and-run
updated: 2026-09-03
created: 2026-05-29
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/scarf.xcodeproj, scripts/build-detached.sh, scarf/Packages/ScarfCore, scarf/Packages/ScarfDesign
source_paths_inferred: false
---

# Build and Run

Scarf is an Xcode project written in Swift 6. Both the macOS app and iOS app live in one project; they share ScarfCore and ScarfDesign packages.

## Prerequisites

- **Xcode 16.0+** (Xcode 16 or later; earlier versions don't support Swift 6 strict concurrency).
- **macOS 14.6+** (to run the built app).
- **Hermes installed** at `~/.hermes/` (for the local server window on first launch).
- **Git** (to clone the repo).

## Clone and open

```bash
git clone https://github.com/awizemann/scarf.git
cd scarf/scarf
open scarf.xcodeproj
```

Xcode opens. Select the **scarf** scheme (macOS app) from the scheme picker, pick a target Mac, and press **Run** (⌘R).

## Build commands

### Isolated dev build (recommended)

```bash
./scripts/build-detached.sh
```

Builds into an isolated `DerivedData` directory and launches a separate, visually-distinct **Scarf Dev** copy on your Mac. Each run quits the previous dev copy first (but never your production Scarf, if running). This keeps your dev and production instances cleanly separated.

### Raw compile-only

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```

### Unsigned Debug build (no Apple Developer account)

```bash
./scripts/local-build.sh
```

Builds an unsigned Debug binary to `./build/Debug/Scarf.app`. Sign it yourself or run it directly (Gatekeeper may complain once; macOS will still launch it). See [BUILDING.md](https://github.com/awizemann/scarf/blob/main/BUILDING.md) for prerequisites and details.

## Running tests

### ScarfCore tests (fast)

ScarfCore is a Swift Package and tests via SwiftPM:

```bash
swift test --package-path scarf/Packages/ScarfCore
```

Runs ~100 unit tests (models, services, transport, ACP parsing) in ~10 seconds. Use this for fast iteration — much faster than Xcode's full-project test run.

### Full project tests (Xcode)

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug test
```

Runs ScarfCore tests + macOS target tests (UI tests, integration tests) — ~5–10 minutes depending on your machine.

### Specific test target

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarfTests -configuration Debug test
```

### With code coverage

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug test -enableCodeCoverage YES
```

## Building for iOS

### In Xcode

1. Switch the scheme to **scarf mobile** (iOS).
2. Pick an iOS simulator (or a real device).
3. Press **Run** (⌘R).

Builds and launches ScarfGo on the simulator. The first launch walks you through onboarding (host, SSH key generation, test connection).

### For TestFlight upload

See [Release Process](Release-Process) — `scripts/release.sh` automates signing and notarization for macOS; iOS uses Xcode Cloud or manual archive + upload.

## Code organization

```
scarf/
├─ scarf/
│  ├─ scarf.xcodeproj/          macOS + iOS targets
│  ├─ scarf/                    macOS app (11K+ lines)
│  │  ├─ Features/              15+ feature modules (Chat, Projects, Sessions, …)
│  │  ├─ Core/                  Services (ACPClient, HermesDataService, etc.)
│  │  ├─ Navigation/            AppCoordinator, SidebarView
│  │  └─ scarfApp.swift         App entry point
│  ├─ Scarf iOS/                iOS app (9K+ lines)
│  ├─ scarfTests/               macOS unit + UI tests
│  └─ Scarf iOSTests/           iOS unit + UI tests
│
├─ Packages/
│  ├─ ScarfCore/                Shared models, services, ViewModels (~15K lines)
│  │  ├─ Sources/ScarfCore/
│  │  │  ├─ Models/             ACPRequest, HermesMessage, ScarfProject, etc.
│  │  │  ├─ Services/           HermesDataService, ACPClient, CuratorService, …
│  │  │  ├─ ViewModels/         ChatViewModel, SessionsViewModel, …
│  │  │  ├─ Transport/          ServerContext, LocalTransport, SSHTransport
│  │  │  ├─ ACP/                ACPClient, ACPChannel, ACPEventParser
│  │  │  └─ Parsing/            YAML, JSON, cron, approval parsers
│  │  └─ Tests/ScarfCoreTests/  ~100 tests
│  ├─ ScarfDesign/              Design tokens, components (~3K lines)
│  └─ ScarfIOS/                 iOS transport, Keychain, SSH keys (~500 lines)
│
├─ scripts/
│  ├─ build-detached.sh         Isolated dev build (recommended)
│  ├─ local-build.sh            Unsigned Debug build
│  ├─ release.sh                Sign, notarize, upload to GitHub + Sparkle
│  └─ merge-translations.py     Localization pipeline
│
└─ tools/
   ├─ build-catalog.py          Validates + builds template catalog
   └─ translations/             Per-locale JSON files (7 languages)
```

## Zero-warnings build

Scarf compiles with `-Werror` (warnings as errors) in Release mode. In Debug mode from Xcode, warnings are still errors. Before committing:

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build 2>&1 | grep warning
```

If any warnings appear, fix them. The compiler enforces Swift 6 strict concurrency; fix sendability / isolation errors before pushing.

## Development workflow

1. **Branch:** `git checkout -b fix/description-or-feat/feature-name`.
2. **Build:** `./scripts/build-detached.sh` (or Xcode Run).
3. **Test:** Run ScarfCore tests (`swift test --package-path scarf/Packages/ScarfCore`) and UI tests in Xcode.
4. **Format:** Xcode auto-formats on save; run `swift format` manually if needed (`brew install swift-format`).
5. **Commit:** Clear commit message; reference any issues (`fixes #123`).
6. **Push & PR:** Push to your fork, open a pull request against `main`.

## Debugging

### Console output

All production code logs through `os.Logger(subsystem: "com.scarf", ...)`. View logs in:
- **Xcode:** Debug → Console
- **Console.app:** Search for "scarf"
- **Command line:** `log stream --predicate 'process=="Scarf" or process=="Scarf Dev"' --level debug`

### Breakpoints

Set breakpoints in Xcode's editor. When hit, the debugger pauses; inspect variables in the Debug Navigator or LLDB console.

### Remote debugging (SSH context)

To debug a remote (SSH) context:

1. Add logging around the service call, e.g., `Logger(subsystem: "com.scarf", category: "HermesDataService").debug("loading sessions")` — this appears in Xcode's console.
2. Use `po` command in LLDB to inspect objects: `po serverContext.isRemote` → print the context's transport type.

## Common issues

### "Hermes not running" on first launch

Scarf's local window is automatic but expects `~/.hermes/state.db` and the `hermes` binary to exist. If you see "Hermes is not running" on the Dashboard, install Hermes first per the [Hermes README](https://github.com/hermes-ai/hermes-agent).

### Xcode build fails with "unknown error"

1. Clean: **Product → Clean Build Folder** (⇧⌘K).
2. Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/*`.
3. Re-open the project: `open scarf/scarf.xcodeproj`.

### Strict concurrency errors

Swift 6 is strict about sendability and isolation. If you see:
```
error: expression is not Sendable
error: cannot call non-isolated to isolated parameters
```

Check:
- Are closure captures explicitly listed and sendable?
- Is the receiver's isolation declared correctly (`@MainActor`, `nonisolated`, `actor`)?
- Are you passing non-Sendable objects across isolation boundaries?

See the [Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) chapter in The Swift Programming Language for examples.

## Next steps

- **Architecture:** Read [Architecture Overview](Architecture-Overview) to understand how data flows.
- **Contributing:** See [Contributing](Contributing) for PR guidelines and code review expectations.
- **Testing:** Read [Testing](Testing) for how to write tests for a new feature.
