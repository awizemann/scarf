## What's New in 2.1.0

Scarf now speaks seven languages and has a proper slash-command menu in the chat. The language work closes [#13](https://github.com/awizemann/scarf/issues/13) and opens the door for community contributions of additional locales.

### Multi-language support

The UI is now fully translated to **Simplified Chinese, German, French, Spanish, Japanese, and Brazilian Portuguese** on top of the existing English. Scarf respects the system language by default; override per-app from **System Settings → Language & Region → Apps → Scarf**.

- **644 source strings** catalogued. **583 translated per locale** — the remaining ~60 are deliberate fall-throughs to English: proper nouns (Scarf, Hermes, OAuth, MCP, SSH), brand names (Docker, Daytona, Singularity, BlueBubbles), format-only tokens (`%lld`, `·`, `•`), and config-literal placeholders (`my_server`, `npx`, `sk-…`).
- **Locale-aware number and date formatting.** Previous builds hardcoded POSIX-style decimal separators (`$12.34`) and English unit names (`"MB"`, `"K"`, `"M"`). Currency now routes through `.formatted(.currency(code: "USD"))`, byte sizes through `.byteCount(style: .file)`, token counts through `.notation(.compactName)`, and the day-of-week chart through `Calendar.current.shortWeekdaySymbols` — so German users see `15,2 MB`, Japanese users see `15.5万 tokens`, and the activity heatmap starts on the locale's first weekday.
- **Microphone permission prompt localized** — the system dialog that appears the first time you enable voice chat now reads in the user's language.

#### How the translation work shipped

Three stacked PRs to keep each piece independently reviewable, all AI-translated with the bar explicitly set low so native speakers can iterate:

1. **[#22](https://github.com/awizemann/scarf/pull/22) — String Catalog infrastructure.** Added `Localizable.xcstrings` + `InfoPlist.xcstrings`, expanded `knownRegions` with the six new locales, and fixed the locale-aware number formatters mentioned above. No user-visible English-locale change; the groundwork only.
2. **[#24](https://github.com/awizemann/scarf/pull/24) — Audit burn-down.** Swept the codebase for "silently un-localizable" patterns that look fine in Xcode's catalog but leak English at runtime: `Text(cond ? "A" : "B")` routes through the String overload instead of `LocalizedStringKey`, as do `Label(stringVar, systemImage:)`, `.help(stringVar)`, and composite format strings with translatable text suffixes. ~40 sites refactored, covering Chat voice/TTS toggles, Logs pickers, Insights period + day names, MCPServer test result, Profiles, SignalSetup, QuickCommands, ConnectionStatusPill. Without this PR the translations would have landed but ~40 visible strings would still have rendered in English.
3. **[#25](https://github.com/awizemann/scarf/pull/25) — Translations + contributor path.** The six locale JSONs + a 90-line merge script + a "Adding a Language" section in `CONTRIBUTING.md`. The sidebar and Settings tab bar fix also shipped here after smoke-testing revealed they were still missed — `Label(section.rawValue, …)` goes to the String overload just like the audit cases.

#### Contributing a new language

Per-locale source of truth lives in [`tools/translations/<locale>.json`](https://github.com/awizemann/scarf/tree/main/tools/translations). Each entry is a plain `{ "English": "Translation" }` map — keys you omit fall through to English at runtime. Workflow is: fork, drop a JSON, run `python3 tools/merge-translations.py`, open a PR. The full bar is documented in [CONTRIBUTING.md → Adding a Language](https://github.com/awizemann/scarf/blob/main/CONTRIBUTING.md#adding-a-language).

Native-speaker review of the initial six locales is welcome — AI translation gets us most of the way, but idiom and tone are better with someone who actually uses the language. Post a PR against the relevant `<locale>.json` and it'll land as a follow-up.

### Chat slash-command menu

Type `/` in Rich Chat and a floating menu appears above the input with every command the connected agent has advertised via ACP's `available_commands_update`, plus any user-defined `quick_commands:` from `~/.hermes/config.yaml`. ↑/↓ to navigate, Tab or Enter to complete, Esc to dismiss. Commands with argument hints (e.g. `/compress <topic>`) insert a trailing space so you can start typing the argument immediately.

The filter uses pure-prefix match and re-renders on every query — the old menu had a description-fallback filter and a cached child view that together pinned `/help` on-screen regardless of what you typed. The dedicated `/compress` button is hidden once the menu has more than one command; it only surfaces when `/compress` is the single advertised slash command, preserving the v2.0 one-click compression flow for that case.

### Chat UX polish

- **Auto-scroll on send and on completion.** `.defaultScrollAnchor(.bottom)` handles slow streaming fine, but rapid slash-command responses (common once the menu lands) outran the anchor and left the reply off-screen. Now the list explicitly scrolls to the latest message when you submit and again when the prompt finishes.
- **Loading state.** `ChatViewModel.isPreparingSession` is true during Starting / Creating / Loading / Reconnecting. While true, the message list swaps its empty-state placeholder for a spinner — non-blocking, just a view inside the ScrollView.
- **Empty-state centering.** The "Start a new session or resume an existing one" placeholder was positioned with a fixed `.padding(.vertical, 80)` that looked wrong at extreme window sizes. Replaced with Spacers inside `.containerRelativeFrame(.vertical)` so it sits in the true vertical center of the chat pane.
- **Session-load whitespace bug.** Opening a session used to render a blank viewport you'd have to scroll up from — the fix was `LazyVStack` → `VStack` in `RichChatMessageList`. LazyVStack's estimated row heights were fooling `.defaultScrollAnchor(.bottom)` into overshooting real content; VStack measures every row upfront so the anchor has real heights to work with.

### Under the hood

- **String Catalog build pipeline.** `SWIFT_EMIT_LOC_STRINGS` + `STRING_CATALOG_GENERATE_SYMBOLS` are enabled; keys extract automatically on IDE build. Headless builds use `xcrun xcstringstool sync` to merge the per-source `.stringsdata` files into the catalog (wrapped by [`tools/merge-translations.py`](https://github.com/awizemann/scarf/blob/main/tools/merge-translations.py) when applying JSON translations).
- **New docs.** [`scarf/docs/I18N.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/I18N.md) covers the catalog setup, the patterns that silently bypass localization (and their fixes), and which strings are intentionally kept verbatim. Anyone adding UI copy should read the "Guardrails when writing new UI code" section to avoid re-introducing the leaks #24 cleaned up.

### Migrating from 2.0.x

Sparkle will offer the update automatically. No config migration needed. The first launch after update picks up the system locale — if you want English even on a non-English macOS, set **System Settings → Language & Region → Apps → Scarf → English**.

### Thanks

- [Onion3](https://github.com/Onion3) for filing [#13](https://github.com/awizemann/scarf/issues/13) back in April. The single-locale ask turned into a six-locale rollout.
- Future translators: if you spot a weird AI translation in your language, open a PR against `tools/translations/<locale>.json`. The bar is explicitly low — we'd rather have a 95%-correct translation shipped and iterated on than hold everything for perfection.
