# Scarf v2.17.2

A point release with one visible theme: **markdown finally renders everything your agents write.** Tables — the one block type Scarf's renderer couldn't draw — now render as real grids everywhere markdown appears, from the Skill editor to chat itself. Both fixes in this release came out of community-filed issues — thank you, [@steveisakson](https://github.com/steveisakson) and [@turnkeysitedesign](https://github.com/turnkeysitedesign).

## Markdown tables render — in the Skill editor and everywhere else

Community-reported: [#134](https://github.com/awizemann/scarf/issues/134) — a SKILL.md with a perfectly ordinary markdown table showed the raw `| pipe | text |` in both the editor and its preview pane.

The root cause was simple: Scarf's hand-rolled markdown block parser had no concept of a table, so pipe rows fell through to plain-paragraph rendering. And because one renderer serves every markdown surface, the gap wasn't just the Skill editor — agent replies in chat, memory notes, and project widgets all showed raw pipes too.

The fix replaces the hand-rolled parser with **[Marker](https://github.com/awizemann/Marker)**, the reusable Markdown engine extracted from TrapperKeeper, pinned at 0.8.1. What you get:

- **GFM tables render as proper grids** — bold header row, per-column alignment from the `:--` / `:-:` / `--:` separator, escaped `\|` inside cells, ragged rows normalized, and inline bold/code/links *within* cells rendered. Cell text is selectable.
- **Task-list checkboxes** — `- [ ]` / `- [x]` items draw a real checkbox glyph instead of literal bracket text. SKILL.md checklists finally look like checklists.
- **Everything else renders exactly as before.** The swap preserves the established semantics line-for-line (paragraph line breaks, quote joining, list indent, frontmatter skipping), pinned by a new test suite so the chat surface didn't shift under anyone's feet.

Streaming chat is untouched: mid-stream rendering stays inline-only for speed, and tables materialize the moment the reply finalizes.

## ScarfGo: two root-caused connection failures (TestFlight build to follow)

Community-reported: [#133](https://github.com/awizemann/scarf/issues/133) — "Couldn't open an SSH session (error 4)" against a macOS host *after* Test Connection passed.

- **SSH keys now resolve per server entry.** Both runtime key providers fetched via a singleton that returned the key of the lexicographically-first server ID across **all** keychain items — and keychain items survive reinstalls and iCloud sync. Any second stored key could shadow the right one, so every connect offered the wrong key and the server rejected it, while onboarding's in-memory Test Connection passed. A new resolver maps each connection back to its own server entry (host / port / user) and loads *that* entry's key.
- **The 10-second SSH login window gets retries on cellular.** Citadel hard-codes a 10s login timeout; a cold cellular Tailscale path (DERP-relayed) can exceed it — wifi never does, which is why this only bit TestFlight users on the go. Connects now retry up to 3× on that specific timeout, and the raw bridged "error N" strings are replaced with actionable failure text in all three funnels (transport, chat, onboarding probe).

These fixes live in the shared iOS package and ship with the next ScarfGo TestFlight build; the Mac app is unaffected by them.

## Under the hood

- **New dependency: [Marker](https://github.com/awizemann/Marker) 0.8.1** (pinned, up-to-next-major) — only the pure Foundation-only core links into Scarf; no editor or syntax-highlighting payload. Integrating it also hardened Marker itself: Scarf's off-main test runner exposed five namespaces that were silently MainActor-isolated (a crash for any background caller), fixed upstream in 0.8.1 alongside the new marker-stripped `contentText` API this integration uses.
- The block-mapping layer is pinned by 10 new parser tests in the Mac suite; Marker's own suite runs 189.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **No Hermes version floor change.** This release touches only Scarf-side rendering and iOS connection plumbing — no Hermes surface is involved.
- **iOS / ScarfGo:** the [#133](https://github.com/awizemann/scarf/issues/133) fixes ride the next TestFlight build, not this Mac release.
