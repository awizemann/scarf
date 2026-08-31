# Scarf v2.22.0

This release makes Scarf a first-class citizen for VoiceOver, Voice Control, and UI automation, and catches the app's translations up in all six languages. Until now almost none of the Mac app's form fields or list rows carried an accessibility label — a screen reader landing on the Add Remote Server sheet heard seven anonymous "edit text" fields. Every form field and list row now announces itself properly, in your language. Streaming chat also got measurably faster, and the Hermes target is unchanged (v0.20.5) — no host-side behavior changes at all.

## Accessibility: the whole app now speaks

- **Every form field announces its label.** SwiftUI never associates a `TextField` with the visible `Text` sitting next to it, so assistive tech — and UI automation — saw `label: ""` on all of them. Roughly 120 explicit accessibility labels landed across the app: the Add Remote Server sheet, project and template sheets, MCP server editors, model pickers, credential pools, kanban, profiles, webhooks, cron, proxy, quick commands, restore sheets, and the search/filter fields. Each label exactly matches the visible text, so Voice Control commands like "click Host" resolve.
- **List rows are no longer anonymous.** Project, server, and skill rows read as one element, name first and state after — "my-app, in Tools, archived", "ScarfBox, alan@host:22", "release-prep, pinned, disabled" — while row controls (default-server star, server actions, Install) stay individually reachable with their own labels. Skill hub results include the description; update rows read the version change.
- These labels double as the hooks UI-automation tools need, so scripted walkthroughs of Scarf work now too. Existing XCUITest identifiers are untouched.

## Localized, all of it

- The string catalog was overdue for a sync: this release extracts and adds ~240 strings that had accumulated since the last catalog update — the new accessibility labels plus recent features (profile routes, curator adoption, allowlist suggestions, and more).
- **The entire app is now translated.** Beyond the new strings, this release clears the whole translation backlog — roughly 940 strings translated in this release alone. Coverage in German, Spanish, French, Japanese, Brazilian Portuguese, and Simplified Chinese now spans ~93% of the catalog; the remainder is proper nouns, code, and placeholders that deliberately stay in English.

## Faster streaming chat

- **Markdown is now parsed incrementally while a reply streams** — the settled prefix is parsed once and only the live tail re-renders, instead of re-parsing the whole message on every delta (gh#140).
- **UI upserts during streaming are throttled to 50ms**, so long replies no longer flood the view with per-token updates.

## Under the hood

- The settings write/read parity gate now covers the `auxiliary.<task>.max_concurrency` keys (a v2.21.0 test-coverage gap) — every written config key is again verified to round-trip through ScarfCore's YAML reader.
- Local Walkabout UI-automation artifacts (`.walkabout/`) are gitignored.
- Accessibility and localization conventions are recorded so new UI keeps the bar (labels match visible text; localized fragments in row-label helpers; the two English plural-hack keys deliberately fall back).

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight; this release requires no iOS-side update.
- Compatible with Hermes v0.6.0 through v0.20.5 — the Hermes target is unchanged from v2.21.0 and host behavior is identical.
