# Scarf v2.19.0

This release closes out the Hermes 0.20 settings backlog and fixes a browser configuration bug that's been silently broken since the picker shipped: Scarf was writing a config key Hermes has never read. Alongside the fixes, six new settings surfaces land — profile routing rules, secrets sources, voice tuning, and more — every key source-verified against Hermes v2026.8.3 and gated to the Hermes version that actually understands it.

## Fixed: the browser provider picker now actually works

The Settings → Browser backend picker wrote `browser.backend` — a key that, after a source-history audit of every released Hermes version, turns out to have **never existed**. Hermes reads `browser.cloud_provider`. Every selection made in that picker was silently ignored.

The picker now writes the right key with the right values — **Local Browser, Browser Use, Browserbase, Firecrawl, and Camofox** — plus an **Auto-detect** option that genuinely clears the key. That last part matters: `hermes config set key ""` writes an *empty* value rather than removing the key, and an empty `browser.cloud_provider` forces local mode instead of restoring auto-detection. Scarf now uses `hermes config unset` (Hermes 0.19+) for true clearing; on older hosts the picker simply doesn't offer the auto-detect row rather than lying about it.

## New: gateway profile routing rules

A full list editor for `gateway.profile_routes` (Hermes 0.19+): route incoming gateway messages to different profiles by platform, guild, channel, or thread. The editor mirrors Hermes's real matching semantics — rules rank by **specificity** (thread beats channel beats guild), not list order, and the UI shows the effective match order with rank badges so there's no guessing.

Because `hermes config set` can't write lists of objects, this uses Scarf's surgical YAML editor: comments, unknown keys, and everything else in your config survive edits byte-for-byte. The editor also refuses ambiguous configs (like a populated inline flow list) with an explanation instead of writing changes Hermes would ignore. One real corruption bug was caught by the pre-release audit and fixed: a route disabled with `enabled: no`, `off`, or `0` (all valid YAML) previously read back as enabled — and an unrelated edit would have re-enabled it on disk.

## New: settings surfaces across the board

All capability-gated to the Hermes version each key first shipped in — older hosts render exactly as before:

- **Title generation** (Auxiliary tab): provider, model, base URL, API key, timeout, and — on 0.18+ — response language for auto-generated session titles.
- **Per-task reasoning effort** (0.19+): every auxiliary task (vision, compression, curator, …) gets its own thinking-level picker, from `minimal` to `ultra`.
- **Smart approval policy** (0.20, Security tab): free-text guidance for Hermes's LLM approval reviewer, beside the existing allowlist suggestions.
- **Secrets sources** (0.20, Secrets tab): the any-CLI vault helper (`secrets.command`) and Bitwarden's encrypted cache with its staleness ceiling.
- **Voice** (0.19/0.20, Voice tab): global and per-provider STT language, Groq model selection, local-STT VAD anti-hallucination tuning, xAI TTS speed/language/streaming/sample-rate knobs, and DeepInfra TTS model + voice.
- **Advanced** (0.20): the shared-metrics telemetry privacy toggle (default off) and SQLite journal tuning (`journal_mode`, WAL autocheckpoint, journal size limit) for remote and container servers.

Two keys from the original plan were deliberately dropped after source verification showed they don't exist in released Hermes (`tts.xai.text_normalization`, a global `tts.speed`) — Scarf doesn't write keys Hermes won't read.

## Faster, steadier version detection

Scarf detects your Hermes version to decide which features to show. That probe is now **cached, deduplicated, and persisted**: one probe per server connection instead of several per session, the last-known version seeds the UI instantly at launch (marked provisional until the live probe confirms), and a transient probe failure no longer blanks every version-gated surface for the session. Cache entries key on the actual connection — a Docker or SSH host never inherits your Mac's version — and expire after ten minutes so an out-of-band `hermes update` is picked up promptly.

## Under the hood

- Two independent adversarial audits ran before this release: one per phase during development, one fresh-eyes pass across the full diff — the latter validated every claimed key name, default, and version floor against Hermes source at tag v2026.8.3 and found zero mismatches.
- The settings write/read parity gate got stricter: it now also covers `unsetSetting` call sites and the new interpolated writer shapes, so a settings key that saves but doesn't read back fails CI.
- 90+ new tests this release (YAML round-trips incl. comments/CRLF/unknown keys, version-cache lifecycle, capability floors, profile-route semantics); the ScarfCore suite now runs 1,152, plus 301 app-target tests.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **Hermes target unchanged: v0.20.0 (v2026.8.3)**, minimum v0.6.0. New surfaces appear only on hosts that support them (per-key floors at 0.18/0.19/0.20).
- If you had set a browser backend in Settings before this release, re-select it once — the old value was written to a key Hermes never read.
