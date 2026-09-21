# Fresh-eyes whole-surface audit — cost/usage, kanban chat-scope, scopedToolsets

Date: 2026-09-21. Repo: `/Users/awizemann/Developer/Scarf` @ `main` = `40a3b5f6`
(merge of `fix/unknown-session-cost`; parent `166b33e2`).
Hermes reference tag: `v2026.9.21` (v0.21.4) in `/Users/awizemann/Developer/hermes-agent-fork`,
read with `git show` only. Live host: Hermes v0.21.3, `~/.hermes/state.db` read with
`sqlite3 -readonly` only. **REPORT-ONLY — no Scarf source was modified.**

Audit standard: the project charter (`charter-hash: 06eb9258538c`), C1–C10.

---

## Ranked findings

### F1 — HIGH — A nil `cost_status` is NOT "a pre-v0.7 host", and the fix's central premise is wrong about it. Modern-host sessions still render a false `$0.00`

**New** (the premise is new, introduced by this merge; the `$0.00` itself is old and was
supposed to be what the merge fixed).

Six places assert that a nil `cost_status` means a pre-v0.7 Hermes host:

- `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/SessionCostDisplay.swift:44-46`
  — *"`cost_status` is nil (a pre-v0.7 Hermes host, where the column sits outside the
  probed `hasV07Schema` tail of the SELECT and decodes to nil)"*
- `scarf/scarf/Features/Sessions/Views/SessionsView.swift:839`
- `scarf/scarf/Features/Sessions/Views/SessionDetailView.swift:79`
- `scarf/scarf/Features/Chat/Views/SessionInfoBar.swift:364`
- `scarf/scarf/Features/Insights/Views/InsightsView.swift:95`
- `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/InsightsViewModel.swift:202-203`
  — *"Zero on any pre-v0.7 host (no `cost_status` → `.legacy`)"*

That is false. Hermes writes the column only from `update_token_counts`
(`v2026.9.21:hermes_state_usage.py:275`) via `cost_status = COALESCE(?, cost_status)`
(`:37`). A session that never completes a priced turn therefore keeps
`cost_status IS NULL` **and** `estimated_cost_usd IS NULL` on a fully current host.

Live evidence (v0.21.3, read-only):

```
sqlite3 -readonly ~/.hermes/state.db \
  "select cost_status, count(*) from sessions group by 1;"
        |9        <- NULL
unknown |34
```

```
select id, source, message_count from sessions where cost_status is null;
20260331_020519_9f786da1            | telegram | 133
cron_7b0812af7000_20260331_220026   | cron     |  10
d45609cd-…                          | acp      |   2
0dec034f-…                          | acp      |   2
afd3d93f-…                          | acp      |   2
cron_6236ba696c6c_20260705_080042   | cron     |   1
c1697e09-… / 3bc5ac5b-… / 2da22b5b- | acp      |   0
```

These rows are **not** filtered out of the list: `sessionListPredicate`
(`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift:249-265`)
filters only on `parent_session_id` and `hidden`, never on `message_count`.

Consequences on a current host:

1. `SessionsView.costLabel` (`scarf/scarf/Features/Sessions/Views/SessionsView.swift:841-853`)
   routes `.legacy` to a literal `"$0.00"` at `:851`. A 133-message Telegram session that
   Hermes never priced still claims it cost nothing — the exact defect this merge set out
   to kill, for 9 of 43 live sessions (~21%).
2. The same row renders **nothing at all** in `SessionInfoBar`
   (`SessionInfoBar.swift:393-401`, `if let amount`) and `SessionDetailView`
   (`SessionDetailView.swift:94-99`). So the list says `$0.00`, the detail says nothing —
   two surfaces disagreeing about the same session.
3. `InsightsViewModel.unknownCostSessionCount` (`InsightsViewModel.swift:204`) counts only
   `.unknown`, so these sessions are invisible to the "partial" tooltip. On a host whose
   sessions are all nil-status, Insights' Total Cost renders a flat `$0.00` with no
   partial marker (`InsightsView.swift:96-99`).

**User impact.** Scarf asserts "this session cost nothing" for sessions Hermes never
priced, on a current Hermes, and does so inconsistently between the list and the detail.
This is the same false-precision defect the merge was written to fix, in its second-most
common form.

**Proposed fix.** Do NOT route nil-status into `.unknown` — that would break C1 and
`SessionCostDisplayTests.nilStatusIsByteIdenticalToBefore`. Instead split the nil case by
what the host actually supports, which Scarf already probes:

- add `hasCostStatusColumn` (the existing `hasV07Schema` probe already implies it) to the
  `SessionCostDisplay` init, or pass it through `HermesSession`;
- when the column EXISTS but the value is NULL **and** there is no amount at all, that is
  "Hermes never priced this" → `.unknown` (the em dash), which is honest and is a change
  only on hosts that have the column;
- when the column is ABSENT (`hasV07Schema == false`), keep `.legacy` verbatim — C1 holds
  for genuinely old hosts, and the existing C1 test keeps passing against that input.

Also correct the six comments above and the corresponding memory note (done, see below).
**Size: S–M** (~30 lines of product code + 2 test rows + comment edits).
**Confidence: high** — live data, tagged source, and the list predicate all read directly.

---

### F2 — MEDIUM-HIGH — The chat Kanban badge never resets, so it shows the previous chat's task count

**Old.**

`kanbanBadgeViewModel` is a single `@State` created once
(`scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift:173-177`) and `liveCount` is
never cleared (`scarf/scarf/Features/Chat/ViewModels/KanbanChatBadgeViewModel.swift:30`,
written only at `:97` and `:104`). Three paths leave it stale:

- When `richChat.sessionId` goes nil (a `/new`, `RichChatViewModel.reset()`), the poll key
  flips, `.task(id:)` restarts, and `ChatTranscriptPane.swift:171` returns at the guard —
  `liveCount` keeps the old number. `SessionInfoBar.swift:242` gates the chip on
  `capabilities.hasKanbanSessionFilter` and `onOpenKanban` only, never on a session
  existing, so the chip renders with the previous chat's count.
- `isInflight` (`KanbanChatBadgeViewModel.swift:42`, `:86-88`) is shared across restarts.
  Session A's in-flight poll makes session B's immediate tick a no-op; A's result then
  lands on `liveCount` for B. `runHermes` uses `Task.detached`
  (`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift:745`), which
  view-task cancellation does not reach, so A can win for up to the 20 s `list` timeout.
- On error the poller sets `liveCount = nil` (`:104`), hiding the badge — so it alternates
  between a wrong number and no number, never "unknown".

**User impact.** The chat header asserts "N tasks live in this chat" for a chat that has
none, immediately after switching or starting a conversation.

**Proposed fix.** Add `reset()` (clear `liveCount`, `isInflight`) called from the
`.task(id:)` body before the guard; stamp each poll with its `sessionId` and discard a
result whose id is no longer current; hide the badge when `richChat.sessionId == nil`
(the dead `shouldRender`, F7, is the natural place). **Size: S** (~30 lines).
**Confidence: high.**

---

### F3 — MEDIUM-HIGH — The chat badge poller has no scene-phase pause; it spawns an SSH process every 5 s forever (C10)

**Old.**

Every other Kanban surface pauses when the window is inactive, explicitly citing C10:
`scarf/scarf/Features/Kanban/Views/KanbanBoardView.swift:16` (`@Environment(\.scenePhase)`)
and `:160-166`; same in `KanbanListView.swift:70` and `KanbanInspectorPane.swift:160`.
`ChatTranscriptPane.swift` has **no** `scenePhase` at all (verified by grep) and its poll
key (`:190-196`) does not include one. The pane lives for the whole life of a chat window,
so `hermes kanban list --json --session=<id>` runs every 5 s indefinitely, including while
Scarf is behind other apps.

**User impact.** On a remote host that is one `ssh` process spawn every 5 s per open chat
window, forever — battery, fan, remote load and log noise for a number nobody is looking
at. This is precisely the regression the board view already fixed.

**Proposed fix.** Mirror `KanbanBoardView.swift:160-166` — add `@Environment(\.scenePhase)`
to `ChatTranscriptPane` and fold it into `kanbanBadgePollKey`. **Size: S** (~10 lines).
**Confidence: high.**

---

### F4 — MEDIUM — The resume fallback silently re-scopes the chat's Kanban board to a new session id; the chat's earlier tasks vanish

**Old** (surfaced by the validation doc; re-confirmed and extended here).

`ChatViewModel.swift:1206-1215` (autostart) and `:1955-1972` (resume) both catch a
`loadSession` failure and call `newSession(cwd:)`, minting a **different** ACP session id,
then `setSessionId(resolvedSessionId)` (`:1238`, `:2020`).

- The badge **does** follow the new id: `kanbanBadgePollKey`
  (`ChatTranscriptPane.swift:190-196`) includes `richChat.sessionId ?? ""`, so `.task(id:)`
  restarts. The wiring is correct.
- Tasks stamped with the OLD id **do** vanish. Hermes stamps `session_id` from
  `HERMES_SESSION_ID` at creation (`v2026.9.21:acp_adapter/server.py:793-794`), so
  `--session=<new id>` cannot match them. The badge drops to 0 and the board's default
  "This chat" scope (`KanbanBoardViewModel.swift:141`) shows an empty board.
- A transient wrinkle: `RichChatViewModel.swift:2705` assigns the **DB** id before
  `ChatViewModel.swift:2020` corrects it to the ACP id, so the poller starts once on the
  wrong id and restarts.
- Asymmetry worth a separate look: the resume path records
  `Analytics.record(.sessionResumeFallback(…))` (`:1971`) and replays transcript
  (`:1985-1988`); the autostart path (`:1212-1214`) does neither.

**Is it a real user-facing defect? Yes, bounded.** The transcript visibly continues while
the task board resets to empty, implying a continuity the scope does not have. The board
at least offers a scope pill escape hatch (`KanbanBoardViewModel.swift:203-209`); the chat
badge offers none and gives no notice.

**Proposed fix.** Carry `priorSessionIds: [String]` on `RichChatViewModel`, appended when
`setSessionId` replaces a non-nil id; minimum viable is a one-shot board notice (reusing
the existing `transientNotice` at `KanbanBoardViewModel.swift:517-523`) when the current
chat fell back. **Size: M** (~40–60 lines). **Confidence: high on the mechanism, medium on
which fix is right — it is a product call.**

---

### F5 — MEDIUM — `KanbanChatSessionIdWiringTests` is brittle theatre: it would break on a reformat and the bug it names slips past it

**New** (added by `b0f9ddc5`).

`scarf/Packages/ScarfCore/Tests/ScarfCoreTests/KanbanChatSessionIdWiringTests.swift` is a
source-text regex sweep — it reads app-target `.swift` files off disk via `#filePath` plus
six `deletingLastPathComponent()` calls (`:33-45`) — not a behavioural test.

Breaks on a legitimate refactor:

- `:68` `#expect(src.contains("KanbanListFilter(session: sessionId)"))` — wrapping that one
  call across two lines fails with no behaviour change.
- `:66-67` `#expect(constructions.count == 1, …)` — adding a second, correct filter fails.
- `:100` `region(src, from: ".task(id: kanbanBadgePollKey)", lines: 16)` — a fixed 16-line
  window. The assertion it needs (`sessionId: sid`) currently sits at
  `ChatTranscriptPane.swift:179`, i.e. line 14 of that window. **Two added comment lines
  push it out and the test fails spuriously.**
- `:76-78` `#expect(!src.contains("UUID("))` — bans the substring anywhere in the file,
  comments included.
- `:87-89` — moving either file to another folder fails at `#require`; renaming the local
  `sid` fails `:101`.

And a real bug slips past. Its own docstring names the risk at `:13-15` (the terminal-mode
DB id that `ChatViewModel` also writes into `RichChatViewModel.sessionId`), then never
tests it. It pins hops 1→3 but asserts **nothing about what `richChat.sessionId` holds** —
a property written from `ChatViewModel.swift:1022` (DB row id, terminal mode),
`RichChatViewModel.swift:2705` (DB id, transiently) and `ChatViewModel.swift:1238/2020`
(ACP id). **F4 above satisfies every assertion in this file.** Hop 3 (`:125-135`) is the
only real test and it only proves `KanbanListFilter` does not mangle a string.

**Proposed fix.** Replace hops 1–2 with a real `RichChatViewModel` test: assert
`setSessionId` / `loadSessionHistory(sessionId:acpSessionId:)` leave `sessionId` holding
the **ACP** id and that the DB id is not left resident. Keep hop 3. **Size: M** (~50 lines).
**Confidence: high.**

---

### F6 — MEDIUM — The chat badge omits `review`, the one status that is waiting on the human

**New in effect** (the two-state count predates v0.15; the v0.15 adoption re-scoped the
filter without revisiting the counted set).

`KanbanChatBadgeViewModel.swift:93-96` counts `running || blocked` only. `review` is a
first-class status with its own column (`HermesKanbanTask.swift:330`).

**User impact.** A task parked in Review for hours shows a badge of 0; the user believes
the chat has no outstanding work — the opposite of the truth, since Review is exactly where
the agent is waiting on them. **Size: XS** (~5 lines; possibly a distinct tint).
**Confidence: high on the fact, medium on whether the omission was intended.**

---

### F7 — LOW — `shouldRender` is dead code and the capability guard behind it is unreachable

**Old.** `KanbanChatBadgeViewModel.shouldRender` (`:34`) is written at `:65` and `:69` and
read by **nobody** (verified by repo-wide grep). `SessionInfoBar.swift:242` gates on the
capability directly and `ChatTranscriptPane.swift:171` already refuses to call `run` on a
capability-negative host, so `run`'s own guard (`:64-68`) can never fail. Cosmetic, but it
makes F2 hard to see and misleads a reader into thinking the VM owns chip visibility.
**Fix:** delete it, or make it the real gate and have `SessionInfoBar` consume it — which
also fixes F2's "chip renders with no session". **Size: XS.** **Confidence: high.**

---

### F8 — LOW — Dashboard's "By model" breakdown is all-time and over a different population, under a "Last 7 days" heading

**Old.**

`HermesDataService.modelUsageSQL` (`:1655-1662`) has **no `since` bound and no
`sessionListPredicate`**, and is issued with no parameters (`:1762`
`statements.append((Self.modelUsageSQL, []))`). `statsSQL` immediately above it
(`:1569-1591`) carries a long comment explaining that exactly these two omissions "made it
lie" and were fixed for the stat cards. `modelUsageSection`
(`scarf/scarf/Features/Dashboard/Views/DashboardView.swift:313`) renders as a sibling
directly under the `statsSection` whose header reads "Last 7 days" (`:271`), with its own
unqualified header "By model" (`:314`).

It is also a different population in a second way: `record_auxiliary_usage`
(`v2026.9.21:hermes_state_usage.py:369-378`) writes vision/compression/title-generation
deltas into `session_model_usage` *"WITHOUT touching the `sessions` summary row"*, so the
By-model costs can exceed the Cost card above them.

**User impact.** Per-model token and cost figures that look like this week's are lifetime
totals over a wider population, sitting immediately below a "Last 7 days" label.
**Proposed fix.** Either add the `since` bound (join to `sessions` on `session_id`) or give
the section its own explicit "All time" label. **Size: S–M.** **Confidence: high** on the
SQL; **medium** on how strongly users read the "Last 7 days" header as covering it.

---

### F9 — LOW — `.legacy` hardcodes an unlocalized `"$0.00"` while `.includedFree` localizes

**Old** (preserved deliberately by the fix).

`SessionsView.swift:851` returns the literal string `"$0.00"`; `:849` formats
`.includedFree` through `.formatted(.currency(code: "USD"))`. In `de`/`fr`/`ja` those render
differently (`0,00 $` vs `$0.00`), so the Cost column mixes two spellings of the same
number. C1 genuinely requires the literal for a true pre-v0.7 host (it is byte-identical to
`166b33e2:…/SessionsView.swift`'s `return "$0.00"`), so this only becomes fixable once F1
narrows `.legacy` to real legacy hosts. **Size: XS, after F1.** **Confidence: high.**

---

### F10 — LOW — `SessionCostDisplay` has no NaN / negative guard

**New.** `SessionCostDisplay.swift:71` tests `amount > 0`, which is false for `NaN`, so a
`NaN` or negative amount falls through to `.legacy(amount:)` and
`SessionInfoBar.swift:394` / `SessionDetailView.swift:96` render it verbatim —
`"NaN"` or `"-$5.00"`. Hermes should never write either (`float(… or 0.0)` at
`hermes_state_usage.py:367`), and the test matrix
(`SessionCostDisplayTests.swift:33` covers `-1.0` with `status: "unknown"` only) does not
cover `NaN` or a negative with a nil status. Defensive only. **Size: XS** (`amount.isFinite`
+ 2 test rows). **Confidence: medium** — I could not produce such a value from Hermes.

---

### F11 — TRIVIAL — Off-by-one in a C2 citation

`SessionCostDisplay.swift:22` (and commit `b0f9ddc5`'s message, and the memory note) cite
`update_token_counts` at `hermes_state_usage.py:274`. At `v2026.9.21` line 274 is blank;
`def update_token_counts(` is at **:275**. Every other citation in the type re-verified
exact (see below). C2 makes the line number the evidence, so it is worth correcting.
**Size: XS.** **Confidence: high.**

---

### F12 — INFO — The pre-0.15 Kanban chip fallback was removed entirely, with no note

The tenant + time-window heuristic **existed and is gone**. It was introduced in
`20eef4b2` (`AppCoordinator.swift:153` `let sessionOpenedAt: Date`;
`KanbanBoardViewModel.swift:59` *"applies a client-side `createdAt >= sessionOpenedAt`
filter"*; `KanbanChatBadgeViewModel.run(tenant:capabilities:)` gated on `hasKanban`) and
removed in `e980b657` (the v0.15 adoption). `grep -rn "sessionOpenedAt" --include="*.swift"`
returns nothing today.

**Consequence:** on a Hermes v0.12–v0.14 host the chat-header Kanban chip that previously
rendered (approximately) now does not render at all. That is **C1-compliant** — absence,
not a lie — and arguably the honest choice, since the heuristic could only ever approximate.
But it is a surface regression for those hosts with no release note and no memory note.
Worth confirming it was deliberate.

Related: `KanbanView.swift:44-45` still carries the stale comment *"so the new tenant +
timestamp take effect"* — there is no timestamp in the handoff any more. One-line fix.

---

### F13 — INFO — `scopedToolsets` readiness: the seam is cheap, one correctness trap

`ScarfProject.scopedToolsets`
(`scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ScarfProject.swift:73`, doc at `:66-72`)
is pure dead storage today — persisted and round-tripped (`:197`, `:216`, `:231`, `:250`,
`:279`, `:312`), read by nobody outside the model and two tests asserting it is empty.

The ACP client is **already free-form**: `ACPClient.newSession` (`:398-416`) and
`loadSession` (`:418-470`) build `params` as `[String: AnyCodable]`, and `ACPRequest`
(`ACPMessages.swift:11-35`) encodes it verbatim — so
`params["_meta"] = AnyCodable(["hermes": ["toolsets": names]])`, omitted when empty, is a
3-line change per method. There is no `session/resume` wrapper, so only two methods need
plumbing. Scarf reads `_meta` on incoming updates today (`ACPMessages.swift:487-500`) but
never sends it.

JSON-RPC errors: `ACPError` decodes `code`/`message`/`data` (`ACPMessages.swift:63-80`) and
`handleMessage` rethrows faithfully (`ACPClient.swift:894-898`), rendering as
`"ACP error <code>: <msg>"` (`:985`, `:994-1002`). Truthful but generic — nothing branches
on a code anywhere, and `ACPErrorHint.classify` keys off message text, so a `-32602` gets no
hint.

**The trap:** `ChatViewModel.swift:1205-1216` catches **every** `session/load` error as
"session not found" and retries with `newSession` — which would carry the same `_meta` and
fail again, surfacing as a raw start failure (and, per F4, silently re-scoping the board).
The same shape repeats at `:1962-1974` and `Scarf iOS/Chat/ChatView.swift:3122-3124`.

Sizing:

| # | Step | Size |
|---|---|---|
| 1 | `hasScopedToolsets` + floor in `HermesCapabilities` (pattern: `:198`, `:129`), test, panel row | S |
| 2 | `newSession`/`loadSession`: `toolsets: [String] = []`, build `_meta` only when non-empty | S |
| 3 | Thread `scopedToolsets` from ~9 call sites (mac `ChatViewModel` ×5, `MiniAppAgentSession`, iOS `ChatView` ×4); a defaulted param keeps all source-compatible | M |
| 4 | Stop the `loadSession` catch misreading `-32602` as "not found"; on `-32602` retry once WITHOUT `_meta` | **M — the one correctness trap**, 3 duplicated catch blocks across 2 platforms |
| 5 | An `ACPErrorHint` case for `-32602` on session start | S |
| 6 | A cockpit "Scope" editor so `scopedToolsets` stops being write-never | L |
| 7 | Wire-shape tests (key present/absent), a `-32602` fake-channel test, capability-gate test | M |

Existing task: `tasks/t-93517390.md`; wire contract already recorded at
`.memory/decisions/phase-1-milestone-1-first-class-project-object-implementation-decisions.md:23`.

---

## Checked and clean

**Cost / usage data path**

- **Column index arithmetic is sound in every SELECT variant.** `sessionColumns`
  (`HermesDataService.swift:153-189`) puts the v0.7 block immediately after index 15, so
  `reasoning_tokens`=16, `actual_cost_usd`=17, `cost_status`=18, `billing_provider`=19 are
  fixed whenever `hasV07Schema`. Every LATER conditional block (`api_call_count`,
  `rewind_count`, `pinned`/`last_activity_*`, `last_read_at`, `last_active`) is appended
  last and read by **column name** through `row.columnIndex`
  (`:2000-2025`), never by position — the comments at `:166-168` and `:172-174` state the
  rule and the code follows it. No index can shift.
- **Both backends decode identically.** The positional accessors are shared (`Row`,
  `SQLValue.swift:33-110`). The remote backend explicitly reconstructs SELECT column ORDER
  from the raw JSON bytes of the first object (`RemoteSQLiteBackend.swift:489-518`,
  `extractFirstObjectKeys`) precisely because `[String: Any]` does not preserve order —
  the hazard the brief flagged is already handled, with a comment naming it.
- **C4 probing.** `PRAGMA table_info(sessions)` locally
  (`LocalSQLiteBackend.swift:286-292`), the same probe plus a `sqlite_master` check for
  `session_model_usage` batched into one SSH round trip remotely
  (`RemoteSQLiteBackend.swift:155`). No `SCHEMA_VERSION` gating of cost anywhere.
- **C3.** Nothing writes `state.db`. `last_read_at` is explicitly read-only with a comment
  saying so (`HermesDataService.swift:184-187`).
- **`costIsActual` with a non-nil zero.** Cannot arise from the SESSIONS row:
  `_token_update_sql` guards it as `actual_cost_usd = CASE WHEN ? IS NULL THEN
  actual_cost_usd ELSE … END` (`v2026.9.21:hermes_state_usage.py:33-36`) in both delta and
  absolute modes, so a `None` never lands as `0.0`. Live: `actual_cost_usd IS NULL` on all
  43 rows. The `float(actual_cost_usd or 0.0)` collapse at `:367` targets
  `session_model_usage`, which never feeds `HermesSession`. The test matrix covers the
  hypothetical anyway (`SessionCostDisplayTests.swift:73-75`, `.legacy(0.0, isActual: true)`).
- **Status comparison lowercasing** (`SessionCostDisplay.swift:76`) is safe — Hermes's
  value set is lowercase literals (`v2026.9.21:agent/usage_pricing.py:48`) and lowercasing
  only widens tolerance.
- **C1 byte-identity for `.legacy` verified by diff** against `166b33e2`:
  `SessionInfoBar` old `if let cost = session.displayCostUSD { … costIsActual ? f : "\(f) est." }`
  ≡ new `.legacy(amount, isActual)` arm; same for `SessionDetailView`; same for
  `SessionsView.costLabel`'s `"$0.00"`.
- **Surfaces deliberately left alone never assert a false zero.** Dashboard Cost card
  (`DashboardView.swift:293-301`, `if cost > 0`), Dashboard session row (`:712`,
  `cost > 0`), Dashboard By-model cost (`:330`, `> 0`).
- **Insights per-model and per-day carry no cost at all.** `computeModelBreakdown`
  (`InsightsViewModel.swift:216-236`) aggregates tokens/sessions only and
  `InsightsView.modelSection` (`:144-181`) renders sessions + tokens; `dailyActivity` /
  `hourlyActivity` are activity histograms, not money. The brief's concern about a missed
  per-model / per-day cost breakdown does not apply — there is none to miss.
- **No double count of `actual_cost_usd`.** `HermesSession.displayCostUSD` is
  `actual ?? estimated` (`HermesSession.swift:154`); `statsSQL` sums the two into separate
  columns and `DashboardView.swift:293` picks one (`totalActualCostUSD > 0 ? … : …`), never
  adds them.
- **Exports (C6) carry no Scarf-rendered cost.** Session export shells
  `hermes sessions export --format …` (`SessionsView.swift:29-41`, capability-gated on
  `hasSessionsExportFormats`/`hasSessionsExportNoRedact`); the artifact's content is
  Hermes's. No Scarf-side CSV/JSON of cost exists anywhere in the repo.
- **ScarfGo iOS has no session-cost surface.** The only `cost` hits are the
  `display.show_cost` Hermes setting proxy (`Scarf iOS/Settings/SettingsView.swift:221,306`,
  `SettingEditorSheet.swift:398-400`), the TTS free/paid badge (`:490-521`) and Live Voice's
  own per-minute estimate (`VoiceLiveSessionSheet.swift:181-198`) — none reads
  `cost_status`. Nothing to fix; nothing was missed.
- **No menu-bar / status-item / widget cost surface** and **no analytics event** carrying
  cost (greps returned nothing).

**Localization / accessibility (C)**

- All three new keys exist with **all six locales, state `translated`**, verified by
  parsing `scarf/scarf/Localizable.xcstrings`: `cost unknown`,
  `Hermes recorded no cost for this session`,
  `Partial — Hermes recorded no cost for ^[%lld session](inflect: true)`. The pre-existing
  `cost %@` (used by `SessionsView.costAccessibilityLabel`) is also complete.
- **Inflection is handled correctly for ja and zh-Hans**: both drop the
  `^[…](inflect: true)` markup and use a bare `%lld` — correct, since neither language
  inflects for grammatical number. de/es/fr/pt-BR keep the markup.
- `python3 tools/validate-catalog.py` → **exit 0**, `schema / parity / state errors: 0`,
  3264 keys.
- The sessions row is a single accessibility element (`SessionsView.swift:727`) whose label
  is composed at `:735-742` and includes `costAccessibilityLabel` (`:858-863`), so VoiceOver
  says "cost unknown" rather than "cost —". `SessionInfoBar.swift:389-390` and
  `SessionDetailView.swift:92-93` each carry `.help` + `.accessibilityLabel` on their em
  dash. (Minor, pre-existing: `modelLabel`'s `"—"` at `:814-816` and `updatedLabel`'s at
  `:882` go into the row label verbatim, so VoiceOver reads a bare dash for a missing model
  — out of scope, not caused by this merge.)

**Kanban (D)**

- **C10 subprocess timeouts: clean.** All 16 `runHermes` call sites in `KanbanService` pass
  an explicit `timeout:` (`list` 20 s `:136`, `diagnostics` 20 s `:179`, `show`/`runs`/
  `stats`/`assign`/`comment`/`block`/`archive`/… 15 s, `create`/`complete`/`promote` 30 s,
  `dispatch` 60 s), threaded through both transports (`SSHTransport.swift:683-692`,
  `LocalTransport.swift:260`).
- **Off-main work: clean.** `runHermes` hops to `Task.detached(priority: .utility)`
  (`KanbanService.swift:745`); JSON decode is on the service actor. Only the small `reduce`
  and the `liveCount` write are on MainActor (`KanbanChatBadgeViewModel.swift:93-98`).
- **C5: clean for this surface.** `ensureSuccess` (`KanbanService.swift:767-782`) refuses on
  any non-zero exit BEFORE stdout is touched; `runHermes` maps a `TransportError` to
  `(-1, "", msg)` (`:756-763`) so transport failure can never read as exit 0; the
  deliberate comment at `:139-144` ("Substring-matching CLI prose is not a protocol; the
  empty array is") is honoured by `list`. JSON decode failures throw
  `KanbanError.decoding` rather than substituting a stub (`:148-152`, `:184-192`,
  `:489-495`).
- **Capability gating is consistent**: chip (`SessionInfoBar.swift:242`), poller
  (`ChatTranscriptPane.swift:171`) and poll key (`:190-196`) all key on
  `hasKanbanSessionFilter` = `atLeastSemver(0, 15, 0)` (`HermesCapabilities.swift:708`),
  and including it in the key means a host upgrade activates the chip without a reload.
  The floor itself was verified against tag history in the prior validation doc.
- **Handoff plumbing: clean.** Set at `ChatTranscriptPane.swift:223-229`, drained once at
  `KanbanView.swift:67-70`, copied to local `@State`; `boardIdentity`/`handoffIdentity`
  (`:74-94`) rebuild correctly on a fresh handoff.
- **Error back-off: clean** — 5 s → 30 s doubling, reset on success
  (`KanbanChatBadgeViewModel.swift:47-49`, `:98`, `:105`). The chip suppresses a zero badge
  (`SessionInfoBar.swift:247`).
- One adjacent nit outside chat scope: `KanbanService.log()` (`:258-266`) turns a non-zero
  exit into an empty-string success when the output contains `"no log"` or `"not found"` —
  substring-matching CLI prose as protocol, which the same file repudiates 120 lines
  earlier. Not reachable from the badge. **Size: XS.**

**Hermes citations re-verified at `v2026.9.21`** (all exact unless noted):
`agent/usage_pricing.py:48` (the `Literal`), `:550` (`amount_usd=None, status="unknown"`),
`:565` (`status="included"`), `:596` (`status: CostStatus = "estimated"`);
`hermes_state_usage.py:29`, `:37`, `:52`, `:56`, `:67`, `:69`, `:367`, `:369-378`;
`acp_adapter/server.py:793-794`; `hermes_cli/kanban_parser.py:227-228`.
**`hermes_state_usage.py:274` is blank — see F11.**

**Tests (F)**

```
cd scarf/Packages/ScarfCore
swift test --filter 'SessionCostDisplayTests|KanbanChatSessionIdWiringTests|\
InsightsViewModel|KanbanModelsTests|HermesCapabilitiesTests|HermesCLIOptionP42Tests'
→ Test run with 196 tests in 7 suites passed after 0.012 seconds.
```

All green, nothing flaky across the run. Per the project's known ScarfCore gotchas these
were run under `--filter`; none is `@MainActor` and none shells out, so none is among the
executor-hogging tests that destabilise a full run. No failures to attribute to the parent
commit `166b33e2`, because there were none.

`SessionCostDisplayTests` is a genuinely good suite — a 15-row status × amount matrix
(`:25-79`), an explicit "unknown ≠ included though the number is identical" test
(`:92-102`), and a C1 proof (`:110-137`) that fails if anything routes a nil status into a
new presentation. Note that this last test is exactly what makes F1 subtle: it correctly
pins C1 for a **pre-v0.7** host, and the fix then mistook that constraint for a statement
about all nil statuses.

---

## Could not verify

1. **A live `'included'` or `'estimated'` cost row.** The live host has only `NULL` (9) and
   `'unknown'` (34) — every model in use is a `:free` route. `.includedFree` and
   `.amount(_, isActual:)` are proven by unit test and by tagged source only, never
   observed on screen.
2. **A positive live match for `kanban list --session`.** Unchanged from the prior
   validation: all 7 live tasks carry `session_id = NULL` because they were created from
   the CLI/dashboard. Producing one requires mutating the user's Hermes state.
3. **Whether Hermes can re-stamp `session_id` on an existing task**, which would give F4 a
   much cheaper fix. I did not find such a verb, but I did not exhaustively read
   `hermes_cli/kanban.py`.
4. **How often the `loadSession` → `newSession` fallback actually fires**, which sets F4's
   real-world frequency. The autostart path records no analytics (`ChatViewModel.swift:1212-1214`),
   so there is no telemetry to consult.
5. **`KanbanTenantResolver.resolveOrMint` timing on a cold remote**, which sets the
   likelihood of the `resolvedTenantForChat` race noted under the Kanban sweep
   (`ChatTranscriptPane.swift:160-165` resolves asynchronously while `handleOpenKanban`
   at `:221-230` reads it synchronously; a very early chip tap hands the board
   `tenant: nil`). Low frequency, low damage, not ranked above.
6. **Whether the v0.12–v0.14 chip removal (F12) was a deliberate product decision** — no
   covering note found in `.memory/`; I did not exhaustively search the wiki tier.
7. **Nothing was built.** `./scripts/build-detached.sh` was not run per the brief, so no
   finding here is confirmed against a running app; all UI conclusions are from source.
8. **The full ScarfCore suite** (~3,500 tests) was not run — only the seven suites above.
   No product code was changed, so there was nothing to perturb.

---

## Memory edits made

One targeted `edit_memory` find_replace on
`scarf/architecture/hermes-stores-an-unknown-cost-as-0-0-cost-status-is-the`: the
`[invariant]` bullet claimed `.legacy` is reached via "a nil `cost_status` (pre-v0.7
host)". Live data contradicts it. The bullet now drops the parenthetical and is followed by
a new observation recording F1 — that nil status occurs on current hosts for any session
that never completed a priced turn, with the live counts, the six code sites that repeat
the wrong framing, and the `:275` vs `:274` correction.

No new notes were written; all findings live in this report.
