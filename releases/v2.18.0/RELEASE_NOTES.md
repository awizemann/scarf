# Scarf v2.18.0

The Hermes v0.20 parity release. Hermes shipped its two biggest releases of the year back-to-back — v0.19 "Quicksilver" and v0.20 "Herald," ~5,700 commits — and this release keeps Scarf fully compatible with both while adopting the best of what landed: pinned sessions and activity in the sidebar, per-model cost breakdowns, richer session exports, approval-allowlist suggestions, cron run history, and tidy compaction summaries in chat. It also fixes six long-standing bugs the compatibility audit flushed out — including one where uninstalling or updating a Skill from the UI had never actually worked — and ships a community-contributed performance win that makes remote chats load dramatically faster. Everything new is capability-gated: on a pre-0.20 Hermes host, Scarf behaves exactly as before.

## Remote chats load dramatically faster

Community-contributed: [#136](https://github.com/awizemann/scarf/pull/136) by [@LiamVan6868](https://github.com/LiamVan6868) — thank you!

Resuming a remote chat used to pay one SSH round-trip per 5-message page just to hydrate tool-call cards — six round-trips for a 30-message session, before the skeleton and tool-result fetches. Those pages now fold into **a single batched round-trip**, and the JSON row parser was rewritten as a single-pass byte scan (one traversal instead of two, no substring copies). The oversized-blob fallback that isolates "whale" tool calls is preserved intact. On top of that, the remote result parser now bounds-checks batch markers from the wire, so a misbehaving host can no longer crash the app with a malformed response.

## Hermes v0.20 compatibility

Scarf now targets Hermes v0.20.0 (v2026.8.3), with v0.6.0+ still fully supported:

- **`/compress`** — Hermes renamed `/compact`; Scarf's command menu follows suit on 0.20 hosts (and keeps `/compact` on older ones — never both).
- **Curator keeps counting** — Hermes reworded the curator status header; Scarf's parser now reads both generations, plus the new agent-created/bundled split and unmanaged-skills count.
- **Provider catalog refresh** — Vercel AI Gateway is back (with aggregator handling), Fireworks AI and Google Vertex AI join the picker, Upstage Solar gets its alias, and retired DeepSeek models (`deepseek-chat`, `deepseek-reasoner`) resolve to their `deepseek-v4-flash` replacement instead of dangling.
- **Buzz** — Block's Nostr-based messenger, new in Hermes 0.20, appears in the gateway platform roster.
- **Max turns** — Hermes raised the default agent turn limit 60 → 500; Scarf's Settings display follows the connected host's actual default.

## New: session pins, activity, and per-model costs

On a 0.20 host (schema-detected, zero change on older databases):

- **Pinned sessions float to the top** of the chat sidebar with a pin badge, and each row shows Hermes's last-activity description — what the agent actually did most recently, not just a timestamp.
- **The Dashboard breaks cost down by model** — tokens and spend per model across your sessions, from Hermes's new per-model usage ledger.

## New: richer session exports

The export flow gains a format picker on 0.20 hosts: **Markdown, HTML, Quarto, and trace** join JSONL, plus a **"Redact secrets"** toggle that runs Hermes's scrubbing pass. On remote connections the picker offers the streaming formats (JSONL, trace) so exports always land on your Mac, never stranded on the server.

## New: approval suggestions and cron run history

- **Allowlist suggestions** — Hermes 0.20 can mine your approval history into allowlist proposals (`approvals suggest`). Scarf surfaces them in Settings → Security with a one-click Add per proposal — each application is explicit, no bulk auto-apply.
- **Cron run history** — each cron job's detail pane gains a run-history disclosure: past executions with status, source, and error output, straight from Hermes's new execution ledger.

## Chat: compaction summaries, folded

When Hermes compacts a long session, the summary it writes into history now renders as a collapsed **"Conversation compacted"** disclosure row instead of a wall of bracketed text — expand it when you want it, ignore it when you don't. Detection matches Hermes's own summary markers, so it works on every session with persisted summaries.

## Six bugs the audit caught (all pre-existing)

The compatibility audit re-verifies every CLI call, config key, and platform id Scarf uses against Hermes source — and this cycle that sweep found six things that were broken long before 0.20:

- **Skill uninstall/update never worked.** Both passed a `--yes` flag Hermes has never had, so the CLI exited with a usage error every time. Fixed (uninstall also answers Hermes's confirmation prompt properly).
- **The "runtime metadata footer" toggle wrote a key Hermes doesn't read** (`agent.runtime_metadata_footer`); it now writes the real `display.runtime_footer.enabled`.
- **Google Chat and Microsoft Teams used the wrong platform ids** (`google-chat`/`microsoft-teams` vs Hermes's `google_chat`/`teams`), so platform detection and config edits missed. The Google Chat allowlist editor is also gone — Hermes gates that platform by user env, and the key Scarf wrote was never read.
- **The per-platform "busy acknowledgment" toggle was a silent no-op** — Hermes only reads the global `display.busy_ack_enabled`, which Scarf now writes.
- **A "slash command notice TTL" setting wrote a key that doesn't exist** in any Hermes version; removed.
- **iOS Google Chat status** now detects configuration correctly (same mechanism as the Mac app).

## Under the hood

- New v0.20 capability group in `HermesCapabilities` with a full degradation test cluster; every new surface in this release hides itself on pre-0.20 hosts.
- Provider tables are verified mechanically against the Hermes checkout (`scripts/check-hermes-tables.py`, default path now `~/.hermes/hermes-agent`).
- 75 new tests across capabilities, parsers, schema detection, export argv, and compaction classification; the suite now runs 1,065 tests.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **Hermes target: v0.20.0 (v2026.8.3).** Everything new is capability-gated or schema-detected — Hermes v0.6.0 through v0.19.x hosts keep working exactly as before, minus the new 0.20-only surfaces.
- **iOS / ScarfGo:** shares the platform-id and connection fixes via the common package; they ride the next TestFlight build.
