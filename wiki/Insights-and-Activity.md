---
title: Insights-and-Activity
type: note
permalink: scarf-wiki/insights-and-activity
created: 2026-05-29
updated: 2026-05-29
---

# Insights & Activity

Three closely related sidebar items live here: **Insights** (analytics roll-up), **Sessions** (conversation browser), and **Activity** (per-tool execution feed). All three read from `~/.hermes/state.db` via [HermesDataService](Core-Services).

## Insights

Aggregated analytics with a time-period selector (7 / 30 / 90 days / all time):

| Section | Content |
|---|---|
| **Overview stats** | Total sessions, messages, tool calls, tokens, active time, average session duration. |
| **Token breakdown** | Input + output + cache-read + cache-write + **reasoning tokens** (v0.7+). |
| **Cost tracking** | Total spend, per-model breakdown, actual vs. estimated when both are available. |
| **Model usage** | Sessions and tokens per model. |
| **Platform breakdown** | CLI vs. Telegram vs. Discord vs. Slack, etc. — sessions and messages per source platform. |
| **Top tools** | Bar chart of the most-called tools with counts and percentages. |
| **Activity heatmap** | Sessions by day-of-week × hour-of-day grid; surfaces "when am I actually using this" patterns. |
| **Notable sessions** | Longest, most messages, most tokens, most tool calls. |

All queries are aggregations over the same `sessions`, `messages`, `tool_calls` tables that drive the other views — no separate analytics pipeline.

## Sessions

The full conversation history browser:

- **List** — every session, ordered by start date DESC. Subagent sessions (those with a `parent_session_id`) are filtered from the main list and accessible by drilling into the parent.
- **Project filter** _(v2.5+)_ — Menu above the list picks **All projects / Unattributed / one entry per registered project**. Each row carries a tinted folder chip when the session is attributed to a project. The filter and the badges share the same `SessionAttributionService` ScarfGo's Sessions tab uses, so cross-platform parity is by construction. See [Projects & Profiles](Projects-and-Profiles).
- **Detail panel** — full message stream: user → assistant → tool calls → tool results, with markdown rendering. **Reasoning blocks** (v0.7+) render in a collapsed section. v0.11+ `messages.reasoning_content` (when present) is preferred over the legacy `reasoning` blob.
- **API call counter** _(v2.5+)_ — each row carries a network-icon chip showing `sessions.api_call_count` (v0.11+). Distinct from `tool_call_count`; counts per-turn API round-trips.
- **Tool call inspector** — pretty-printed arguments, function name, result. Categorized by `toolKind` (read / edit / execute / fetch / browser / other).
- **Search** — full-text via SQLite's `messages_fts` FTS5 virtual table. Limit defaults to 50 hits.
- **Actions** — rename (`hermes sessions rename`), delete (`hermes sessions delete`), JSONL export (`hermes sessions export`). Right-click any row in the v2.5 chat sessions sidebar exposes the same Rename / Delete actions inline.

Click a session in the Dashboard's "Recent" card to land here with that session pre-selected.

## Activity

The per-tool execution feed — what Hermes did, when, and with what arguments:

- **Filterable by kind and session.** "Show me every browser fetch in session X."
- **Detail inspector** — pretty-printed arguments JSON, tool output (when available), `tool_call_id` for cross-referencing back to the Sessions message stream.
- **Live refresh** — same `HermesFileWatcher`; the feed scrolls as Hermes works.

### Skeleton-then-hydrate loader _(v2.8+)_

Activity historically pulled the full message column set for the 200 most recent tool-call rows in one shot, which routinely tripped the 30s SSH timeout on remote contexts (the `tool_calls` JSON column for 200 rows = ~600KB-1MB on the wire). v2.8 splits the load:

1. **Phase 1 — skeleton.** `fetchRecentToolCallSkeleton(limit: 50)` projects only `id` + `session_id` + `role` + `timestamp` (everything fat NULLed at the SQL level). Wire payload ≈ 3 KB. The day-grouped feed renders placeholder rows immediately.
2. **Phase 2 — paged hydrate.** `hydrateAssistantToolCalls` runs in 5-id batches in the background via `startToolCallHydration()`. Each batch splices parsed `[HermesToolCall]` arrays into the existing skeleton; `filteredActivity` swaps the placeholder entry for the real per-call entries on the next observation tick. A "Loading tool details…" pill in the header surfaces hydration progress.

When a 5-id batch trips the 30s timeout (an oversized `tool_calls` blob), an L1 single-id retry isolates the offending row so the rest of the batch still hydrates. Transport-layer failures during the skeleton fetch surface an orange "Couldn't load activity" banner with a Retry button instead of the silent empty state pre-v2.8 left users staring at.

## Live data freshness

All three views observe the file watcher and re-query when `state.db` changes. Remote windows pull a fresh atomic snapshot via `sqlite3 .backup` (deduped by `SnapshotCoordinator` so Dashboard + Insights + Sessions don't each spawn parallel backups). See [Transport Layer](Transport-Layer) for the snapshot mechanics.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (project filter + badges, API call chip, reasoning_content preference)_