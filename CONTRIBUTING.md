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

## Documentation

Public docs live in the [GitHub wiki](https://github.com/awizemann/scarf/wiki). Small fixes (typos, clarifications) can be made via the "Edit" button on any wiki page — you need push access to the main repo. For larger changes, clone the wiki locally (`git clone git@github.com:awizemann/scarf.wiki.git`) or open an issue describing the proposed change.

## Adding a Language

Scarf ships with English + Simplified Chinese, German, French, Spanish, Japanese, and Brazilian Portuguese. To add another locale (or improve an existing one):

1. **Fork** the repo and create a branch.
2. **Add the locale to `knownRegions`** in `scarf/scarf.xcodeproj/project.pbxproj` — follow the existing list (e.g. add `it` after `"pt-BR"`).
3. **Drop a new JSON file at `tools/translations/<locale>.json`** — copy an existing one (say `tools/translations/es.json`) as a starting point. Each entry maps the English source string to your translation. Keys you omit fall back to English at runtime — do that for proper nouns (Scarf, Hermes, Anthropic, OAuth, SSH, …) and for anything technical that shouldn't translate.
4. **Preserve format specifiers exactly**: `%@`, `%lld`, `%d`, positional `%1$@` / `%2$lld`, etc. If word order needs to change in your language, use positional forms (`%1$@ … %2$@`).
5. **Add your locale to `tools/merge-translations.py`'s `LOCALES` list** and run `python3 tools/merge-translations.py` — this writes your translations into `scarf/scarf/Localizable.xcstrings`.
6. **Translate `scarf/scarf/InfoPlist.xcstrings`** (the macOS microphone-permission prompt) for your locale. Add a new `stringUnit` under `localizations`.
7. **Build** (`xcodebuild -project scarf/scarf.xcodeproj -scheme scarf build`) and **sanity-check in Xcode**: Scheme → Run → App Language → your locale. Walk the main views (Dashboard, Chat, Settings) and look for clipping or obvious leaks.
8. **Open a PR** including the new JSON file, the updated catalog, and the pbxproj / script changes. Mention which routes you spot-checked.

AI translation is fine for the first pass — it's how the initial six locales landed. Native-speaker review improves quality and is always welcome, either as a follow-up PR or as review comments on the initial one.

See [scarf/docs/I18N.md](scarf/docs/I18N.md) for deeper context on the String Catalog setup and which strings are intentionally kept verbatim.

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
