# Scarf v2.18.1

A fast follow to v2.18.0 with one theme: **power settings for Hermes 0.20's best new knobs** — compression tuning, per-model reasoning effort, and provider exclusions — every key verified against Hermes source, and the YAML-writing machinery behind them hardened by an adversarial audit before shipping.

## New: compression tuning

Hermes 0.20 overhauled context compression and exposed real controls. Four of them now live beside the existing threshold slider (on 0.20 hosts):

- **Absolute token threshold** (`compression.threshold_tokens`) — trigger compression at a fixed token count instead of a context-ratio; Hermes uses the lower of the two when both are set. Setting 0 turns it off — a round-trip we verified is lossless against Hermes's own coercion logic.
- **Guaranteed conversation tail** (`compression.min_tail_user_messages`) — your N most recent user messages always survive compaction.
- **Idle compaction** (`compression.idle_compact_after_seconds`) — compact proactively while the session sits idle instead of pausing mid-conversation.
- **Progress notices** (`compression.progress_notices`) — see when compression runs instead of wondering about the pause.

## New: per-model reasoning effort

A **Per-Model Reasoning** table in the Agent tab: pin reasoning effort per model — your heavyweight model thinks at `max` or `ultra` (the new 0.20 tiers, now in the pickers on 0.20 hosts) while your fast model stays at `low`. Matching follows Hermes's own resolver — exact names or common spelling variants (dots/dashes, optional provider prefix), first match wins, overrides beat the global setting.

Under the hood this writes the `agent.reasoning_overrides` dictionary — a key Hermes's own `config set` can't write (dots in model names) — via Scarf's surgical YAML editor: your comments and unknown keys elsewhere in config.yaml are preserved byte-for-byte, and removing the last row removes the key entirely.

## New: excluded providers

A list editor in the Model section for `model_catalog.excluded_providers` — providers you never use disappear from every model picker and from built-in resolution. Free-text entry with suggestions from your live provider catalog; any capitalization works (Hermes lowercases on match — verified).

## Hardened: the YAML writer, adversarially audited

Before cutting this release we ran a fresh-eyes audit against the new write paths and fixed everything it found — including two corruption-class bugs that never shipped:

- **Inline flow syntax is now understood.** The stock Hermes example config ships `reasoning_overrides: {}` inline — the writer previously would have appended a duplicate key instead of replacing that line, and a hand-written inline dict was invisible to the UI while staying silently active. Both fixed: inline dicts/lists are replaced in place and flat inline content is read back into the editor.
- **Section headers with trailing comments and CRLF files are safe.** Either could previously trick the writer into appending a duplicate top-level section — which YAML's last-wins rule would resolve by discarding your entire original section. Fixed in the shared locator, which also hardens the pre-existing gateway allowlist write path; line endings are preserved on output.
- **Hermes's disable aliases are honored.** A hand-edited `disabled`/`false`/`off` effort value is preserved verbatim instead of silently blocking all edits to the section, and any rejected write now shows an error instead of doing nothing.

Every fix carries a regression test; writer output was cross-validated by loading it with PyYAML — the same parser Hermes uses.

## Under the hood

- 25 new tests this release (settings round-trips, quoted-key YAML, flow-dict handling, CRLF, alias values); the suite now runs 1,090.
- All three new surfaces are capability-gated on Hermes v0.20 — on older hosts, Settings renders exactly as v2.18.0.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **Hermes target unchanged: v0.20.0 (v2026.8.3)**, minimum v0.6.0. The new settings appear only against 0.20+ hosts.
- One known limitation: hand-written comments *inside* an existing `reasoning_overrides` block are not preserved when you edit the table (comments everywhere else in config.yaml are untouched).
