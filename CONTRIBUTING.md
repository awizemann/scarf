# Contributing to Scarf

Thanks for your interest in contributing to Scarf.

## Getting Started

1. Fork and clone the repo
2. Open `scarf/scarf.xcodeproj` in Xcode 26.3+
3. Build and run (requires macOS 26.2+ and Hermes installed at `~/.hermes/`)

## Architecture

Scarf uses the MVVM-Feature pattern. Each feature is a self-contained module under `Features/`:

```
Features/FeatureName/
  Views/          SwiftUI views
  ViewModels/     @Observable view models
```

Rules:
- Features never import sibling features directly
- Cross-feature navigation goes through `AppCoordinator`
- Services in `Core/Services/` are shared across features
- Models in `Core/Models/` are plain structs

## Guidelines

- Keep it simple. Minimal dependencies, no over-engineering.
- No commented-out code, TODOs, or deferred functionality in PRs.
- All code must build with zero warnings.
- Follow existing patterns — look at how similar features are built before adding new ones.
- The app only reads from `~/.hermes/state.db` (never writes). Memory files are the exception.
- Swift 6 strict concurrency: `@MainActor` default isolation, `nonisolated` for service methods.

## Reporting Issues

Open an issue with:
- What you expected to happen
- What actually happened
- macOS version and Hermes version
- Steps to reproduce

## Pull Requests

- Open an issue first to discuss the change
- One feature or fix per PR
- Include a clear description of what changed and why
- Ensure the project builds with `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf build`
