---
title: Localization
type: note
permalink: scarf-wiki/localization
created: 2026-05-29
updated: 2026-05-29
---

# Localization

Scarf 2.1 added full UI translations on top of English. Seven languages ship in the box and more can be contributed via a plain GitHub PR — no translation-management tool, no account to create.

> **ScarfGo (iOS) is English-only in v2.5.** The iOS strings are extracted but no translations are contributed yet. Localizing the iOS app is on the [ScarfGo Roadmap](ScarfGo-Roadmap) — most of the strings already exist in `Localizable.xcstrings`, so contributing iOS translations would lean on the same workflow described below.

## Supported languages

| Locale | Name | Status |
|---|---|---|
| `en` | English | Source |
| `zh-Hans` | Simplified Chinese | AI-translated, native-speaker review welcome |
| `de` | German | AI-translated, native-speaker review welcome |
| `fr` | French | AI-translated, native-speaker review welcome |
| `es` | Spanish | AI-translated, native-speaker review welcome |
| `ja` | Japanese | AI-translated, native-speaker review welcome |
| `pt-BR` | Brazilian Portuguese | AI-translated, native-speaker review welcome |

Canadian French users are served by base `fr` — `fr-CA` will be added only if a concrete Québec-specific punctuation/terminology bug surfaces.

## Which language Scarf speaks

Scarf respects the macOS system language by default. To override per-app:

**System Settings → General → Language & Region → Applications → `+` → select Scarf + pick a preferred language.**

The override takes effect on next app launch.

## What's translated vs. what stays verbatim

The catalog has 644 source strings. Of those, 583 are translated per locale. The remaining ~60 deliberately fall through to English at runtime:

- **Brand / proper nouns** — Scarf, Hermes, Anthropic, Claude, Sparkle, OAuth, SSH, MCP, HTTP, URL, API, Docker, Daytona, Singularity, BlueBubbles, Discord, Slack, Telegram, WhatsApp, Signal, Matrix, Feishu, Mattermost, iMessage, Home Assistant.
- **Format-only tokens** — `%lld`, `%@`, `·`, `•`, `%@ → %@`, `••••••••••` (masked-value placeholder).
- **Config-literal placeholders** — `my_server`, `new-name`, `npx`, `sk-…`, `hermes profile show`, `~/.hermes/…`.
- **User / Hermes data passthroughs** — session titles, memory contents, log lines, shell commands shown in UI, file paths.

The rule is: if translating would be wrong (brand names) or meaningless (data passthroughs), the site stays verbatim. Everything else gets localized.

## Contributing a new language

The full step-by-step is in the main repo's [CONTRIBUTING.md → Adding a Language](https://github.com/awizemann/scarf/blob/main/CONTRIBUTING.md#adding-a-language). Summary:

1. **Fork** the repo and create a branch.
2. **Add the locale to `knownRegions`** in `scarf/scarf.xcodeproj/project.pbxproj` (e.g. add `it` after `"pt-BR"`).
3. **Drop a new JSON file at `tools/translations/<locale>.json`** — copy an existing one (say `tools/translations/es.json`) as a starting point. Each entry maps the English source string to your translation. Keys you omit fall back to English at runtime — do that for proper nouns and for anything technical that shouldn't translate.
4. **Preserve format specifiers exactly**: `%@`, `%lld`, `%d`, positional `%1$@` / `%2$lld`, etc. If word order needs to change in your language, use the positional forms.
5. **Add your locale to `tools/merge-translations.py`'s `LOCALES` list** and run `python3 tools/merge-translations.py` — this writes your translations into `scarf/scarf/Localizable.xcstrings`.
6. **Translate `scarf/scarf/InfoPlist.xcstrings`** (the macOS microphone-permission prompt) for your locale. Add a new `stringUnit` under `localizations`.
7. **Build** (`xcodebuild -project scarf/scarf.xcodeproj -scheme scarf build`) and **sanity-check in Xcode**: Scheme → Run → App Language → your locale. Walk the main views (Dashboard, Chat, Settings) and look for clipping or obvious leaks.
8. **Open a PR** including the new JSON, the updated catalog, and the pbxproj / script changes. Mention which routes you spot-checked.

AI translation is fine for a first pass — it's how the initial six locales landed. Native-speaker review improves quality and is always welcome, either as a follow-up PR or as review comments on the initial one.

## Improving an existing translation

Found a weird or wrong translation? Easiest path:

1. Open `tools/translations/<locale>.json` on GitHub.
2. Click the pencil icon to edit in the browser.
3. Change the offending entry.
4. Submit as a PR. No build needed — the `merge-translations.py` script runs as part of the PR-validation flow.

One-liner fixes are welcome. Please don't feel you need to review the whole file before sending a PR for a single weird string.

## Under the hood

Scarf uses Apple's modern [String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) (`.xcstrings`) — unified plural / format / variation support in a single file, exportable to XLIFF if a translator wants to work in their favorite TMS. The source catalog lives at `scarf/scarf/Localizable.xcstrings`; Info.plist keys live at `scarf/scarf/InfoPlist.xcstrings`.

Per-locale JSON under `tools/translations/` is the canonical source of truth for translations. The merge script is idempotent — translators iterate on the JSON and re-merge without worrying about catalog internals.

Deeper dev-facing notes on which SwiftUI patterns silently bypass localization (and how to avoid them when adding new UI) are in [`scarf/docs/I18N.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/I18N.md).

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (added iOS English-only note + ScarfGo Roadmap link)_