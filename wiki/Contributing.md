---
title: Contributing
type: note
permalink: scarf-wiki/contributing
created: 2026-05-29
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/scarf.xcodeproj, scarf/Packages/ScarfCore, CONTRIBUTING.md
source_paths_inferred: false
---

# Contributing to Scarf

Scarf is open source and welcomes contributions. This page covers the workflow, code standards, and guidance for different kinds of contributions.

## Getting started

1. **Fork** the repo on GitHub.
2. **Clone** your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/scarf.git
   cd scarf
   ```
3. **Build:** See [Build and Run](Build-and-Run) for prerequisites (Xcode 16+, Hermes at `~/.hermes/`).
4. **Branch:** Create a feature or fix branch:
   ```bash
   git checkout -b fix/bug-description
   git checkout -b feat/feature-name
   ```
5. **Test:** Run tests before committing (see [Testing](Testing)).
6. **Commit:** Clear, single-topic commits. Reference issues in the message: `fixes #123`.
7. **Push & PR:** Push to your fork and open a pull request against `main`.

## Code standards

### Zero warnings

Scarf builds with `-Werror` (warnings are errors). Before pushing, ensure a clean build:

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```

If warnings appear, fix them. The compiler enforces **Swift 6 strict concurrency** — all async code must have explicit isolation (`@MainActor`, `nonisolated`, `actor`) and sendable parameters.

### Style

- **Naming:** PascalCase for types, camelCase for functions/properties.
- **Access:** Default to `private`; use `public` only for package-level APIs.
- **Comments:** Omit comments that restate the code. Add comments only when the **why** is non-obvious (hidden constraints, workarounds, performance reasoning).
- **No TODOs or dead code:** If you're unsure about code, remove it or open an issue — don't commit it.
- **Formatting:** Xcode auto-formats on save. For manual formatting, run `swift format` if installed.

### Concurrency

Every async operation must be explicitly isolated:

```swift
// ✓ Correct
func load() async {
    // runs on MainActor (implicit from @Observable @MainActor class)
    let result = await dataService.fetch()
    self.items = result
}

// ✗ Wrong
func load() {
    Task {
        let result = await dataService.fetch()  // Implicit MainActor, sendability unclear
        self.items = result
    }
}
```

Services are `actor`-isolated or `Sendable struct`. Closures passed to them must be `@Sendable`:

```swift
Task.detached { [weak self] in  // explicit capture list
    guard let self else { return }
    await self.service.doWork()
}
```

### Database access

Hermes's `state.db` is **read-only**. Scarf opens it with `PRAGMA query_only = ON` and never writes to it. For state changes, use the `hermes` CLI:

```swift
// ✓ Correct
let output = try await context.runHermes(["session", "delete", sessionID])

// ✗ Wrong
let db = try await context.readFile(paths.stateDB)
db.execute("DELETE FROM sessions WHERE id = ?")
```

## Architecture rules

Read [[Scarf Architecture Rules]] for the MVVM-Feature pattern:

1. **Feature isolation:** Features never import sibling features. Cross-feature navigation goes through `AppCoordinator`.
2. **Service-first:** Services are the data layer; ViewModels coordinate them; Views consume ViewModels.
3. **Transport abstraction:** Code never checks `if context.isLocal` — use the `ServerContext` API (read, run, readText, etc.).
4. **Testing:** Test services independently with injected contexts; test ViewModels with mock services.

## Adding a feature

See [[Adding a Feature Module]] for the step-by-step.

1. **Plan:** Open an issue describing the feature. Discuss scope and design.
2. **Create the module:** Add `Features/YourFeature/{Views,ViewModels}/` under `scarf/scarf/`.
3. **Wire navigation:** Add a case to `AppCoordinator.selectedSection`; add a sidebar entry.
4. **Implement views & VM:** Follow existing feature patterns (e.g., `ChatView` + `ChatViewModel`).
5. **Test:** Add unit tests for the ViewModel; UI tests for the View if critical.
6. **Document:** Update [Core Services](Core-Services) or [Architecture Overview](Architecture-Overview) if your feature uses new services.

## Adding a service

See [[Adding a Service]] for the step-by-step.

Services live in `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/`. They are `actor`-isolated or `Sendable struct` and take a `ServerContext`:

```swift
public actor MyDataService {
    public nonisolated func load(context: ServerContext) async throws -> [Item] {
        let text = try await context.readText("path/to/file")
        return parse(text)
    }
}
```

Both macOS and iOS reuse the same service code — no platform-specific logic inside services.

## Localization (i18n)

Scarf ships in 7 languages: English, Simplified Chinese, German, French, Spanish, Japanese, Portuguese (Brazil).

For adding a new language, see [[Localization Workflow]]:

1. Add the locale to `knownRegions` in `project.pbxproj`.
2. Create `tools/translations/<locale>.json` (copy an existing one, translate values).
3. Run `python3 tools/merge-translations.py` to update the String Catalog.
4. Translate `scarf/scarf/InfoPlist.xcstrings` (macOS permission prompt).
5. Test in Xcode: Scheme → Run → App Language → your locale.
6. Open a PR including the JSON file and pbxproj changes.

AI translation is fine for the initial pass — native-speaker review strengthens it.

## Testing

See [[Testing]] for detailed guidance.

### ScarfCore tests (fast iteration)

```bash
swift test --package-path scarf/Packages/ScarfCore
```

Runs ~100 unit tests for models, services, transport, and ACP parsing in ~10 seconds.

### Xcode tests (full suite)

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug test
```

Includes ScarfCore + macOS target UI tests. ~5–10 minutes.

### Writing tests

- **Unit tests** for ViewModels (mock services, verify state changes).
- **Integration tests** for Services (use real local Hermes context).
- **UI tests** for critical user journeys (e.g., adding a server, chatting).
- **No checkbox tests:** A test that always passes is worse than no test.

## Pull request checklist

Before opening a PR:

- [ ] Code builds with zero warnings (`xcodebuild -scheme scarf build`).
- [ ] Tests pass (`swift test --package-path scarf/Packages/ScarfCore` and Xcode UI tests).
- [ ] One feature or fix per PR — no scope creep.
- [ ] Commits are clear and reference issues (`fixes #123`).
- [ ] No commented-out code, TODOs, or deferred work.
- [ ] Documentation updated if needed (wiki, [Architecture Overview](Architecture-Overview), code comments for non-obvious logic).

The repo runs a GitHub Actions workflow on every PR to verify the build and tests. If it fails, the workflow log shows why — fix and push again.

## Code review expectations

Reviews focus on:

1. **Correctness:** Does the code do what the PR claims? Any off-by-one errors, race conditions, or data flow issues?
2. **Architecture:** Does it follow MVVM-Feature? Is transport abstraction respected? Are services reusable?
3. **Testing:** Are critical paths tested? Do tests exercise the feature, not just the happy path?
4. **Performance:** Any N+1 queries, unbounded loops, or main-thread I/O?
5. **Concurrency:** Are all async boundaries explicit? Sendability correct?
6. **Style:** Consistent with codebase conventions?

Reviews are collaborative — if feedback suggests a change, it's a suggestion (not a demand). If you disagree, explain your reasoning and we'll discuss.

## Reporting issues

Open an issue with:

- **What you expected** to happen.
- **What actually happened** (include error message, stack trace, or screenshot).
- **Environment:** macOS version, Hermes version (`hermes --version`), Scarf version.
- **Steps to reproduce:** Exact sequence that triggers the issue.

Search existing issues first — duplicates clutter the tracker.

## Community

- **Discussions:** GitHub Discussions on the repo — great for questions, design feedback, or brainstorming.
- **Releases:** Latest Scarf is [v3.0.1](https://github.com/awizemann/scarf/releases); Hermes compatibility target is v0.20.4 "Herald".
- **Wiki:** [github.com/awizemann/scarf/wiki](https://github.com/awizemann/scarf/wiki) — architecture deep dives, troubleshooting, design decisions.

## License

All contributions are licensed under [MIT](https://github.com/awizemann/scarf/blob/main/LICENSE). By submitting a PR, you agree to this license.

Thanks for contributing to Scarf! 🎉