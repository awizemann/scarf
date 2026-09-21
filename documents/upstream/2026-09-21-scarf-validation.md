# Scarf validation against three landed Hermes changes

Task: t-b10d9fa6. Date: 2026-09-21. Report-only — no Scarf source was modified.

Hermes reference: tag `v2026.9.21`, which is Hermes **v0.21.4**
(`v2026.9.21:pyproject.toml`, `version = "0.21.4"`). Live install for the
behaviour tests: **Hermes Agent v0.21.3 (2026.9.14)** at `~/.hermes/hermes-agent`
(`hermes --version`). The live host is therefore one patch BELOW the tag, which
matters only for item 3.

All `state.db` access in this report was read-only (`sqlite3 -readonly`). No
kanban task was created and nothing in the user's Hermes state was mutated.

---

## Item 1 — Kanban session filter

### Verdict: CORRECT, with one behavioural risk worth a follow-up.

#### (a) The argv Scarf emits matches the tagged argparse

Scarf builds the filter suffix in
`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanFilters.swift:65-67`:

```swift
if let session, !session.isEmpty {
    args.append(HermesCLIOption.joined("--session", session))
}
```

`HermesCLIOption.joined` produces the single joined token `--session=<value>`
(`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesCLIOption.swift:38-41`).

Hermes declares the option at
`v2026.9.21:hermes_cli/kanban_parser.py:227-228`:

```python
_arg("--session",
     help="Filter by originating chat/agent session id (set on tasks created from inside an ACP loop)"),
```

This is a plain single-value `add_argument` with no `nargs`, so argparse's
`_parse_optional` accepts the joined `--session=value` spelling identically to
the two-token `--session value` spelling. The joined form is in fact the safer
one here, because a session id is opaque text. **Option name, value arity and
spelling all match.**

Position is also right. `--session` is registered inside the `list` subcommand's
option list, so it must follow the `list` verb; `--board` is registered on the
top-level kanban parser (`v2026.9.21:hermes_cli/kanban_parser.py:457`) so it must
precede it. Scarf assembles exactly that ordering at
`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift:128-130`:

```swift
nonisolated static func listArgv(board: String? = nil, filter: KanbanListFilter) -> [String] {
    prefix(board: board, ["list"]) + filter.argv()
}
```

`prefix(board:)` emits `["kanban", "--board=<slug>", "list"]`, and the filter's
`--session=...` lands after `list`.

Hermes consumes the parsed value at `v2026.9.21:hermes_cli/kanban.py:432-434`,
passing it straight through as the `session_id` filter to `kb.list_tasks`.

#### (b) The capability floor is correct

Scarf's flag:
`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift:708`

```swift
public var hasKanbanSessionFilter: Bool { atLeastSemver(0, 15, 0) }
```

Verified against the tag history rather than against release notes, per C2:

- The option is introduced by commit `31fe229039` ("feat(kanban): stamp
  originating ACP session_id on tasks", 2026-05-18).
- `git tag --contains 31fe229039`, filtered to release tags, gives
  `v2026.5.28` as the **first** release tag containing it.
- `v2026.5.28:pyproject.toml` → `version = "0.15.0"`.
- The preceding release tag `v2026.5.16` is `version = "0.14.0"`, and
  `git grep -- '"--session"' v2026.5.16 -- hermes_cli/` returns only unrelated
  hits in `hermes_cli/main.py` (a node bridge `--pair-only --session` and one
  other) — **no kanban `--session`**. At `v2026.5.28` the option is present at
  `hermes_cli/kanban.py:381`.

So the first Hermes release carrying the option is exactly 0.15.0, and Scarf's
floor of `atLeastSemver(0, 15, 0)` is exactly right — not one release early, not
one late.

(Note: a second commit `fddbcf2b94` carries the same subject line and an earlier
date, but is contained in no release tag — it is a superseded copy. The floor
must be, and is, derived from `31fe229039`.)

#### (c) The JSON field name, and tolerant decoding

The wire field is `session_id`. Hermes's task dataclass declares it at
`v2026.9.21:hermes_cli/kanban_db.py:730`
(`session_id: Optional[str] = None  # originating HERMES_SESSION_ID; NULL from CLI/dashboard`),
and it is included in the JSON projection field list at
`v2026.9.21:hermes_cli/kanban_output.py:23`.

Scarf decodes it at
`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanTask.swift`:

- `:57` — `public let sessionId: String?`
- `:196` — `case sessionId = "session_id"`
- `:235` — `self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)`

`decodeIfPresent` into an optional means an older host that omits the key, or a
CLI/dashboard-created task whose value is NULL, decodes to `nil` rather than
throwing. **Correct, and tolerant of absence.**

#### (d) Scarf passes the right id — it does match what Hermes stamps

This was the part most likely to be wrong, so it was traced end to end.

Hermes side: the ACP adapter sets the environment variable that `kanban_create`
reads, at `v2026.9.21:acp_adapter/server.py:793-794`:

```python
stack.callback(_restore_env, "HERMES_SESSION_ID", os.environ.get("HERMES_SESSION_ID"))
os.environ["HERMES_SESSION_ID"] = session_id
```

The `session_id` in scope there is the adapter's own ACP session id — the same
value bound as `session_key`/`session_id` a few lines above at `:768-770`, and
the same value returned to the client from `session/new` and `session/load`.

Scarf side: `richChat.sessionId` is only ever set from what an ACP call
returned. In `ChatViewModel.startACPSession`/`autoStartACPAndSend`
(`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:1204-1217`):

```swift
resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: existing)
...
resolvedSessionId = try await client.newSession(cwd: cwd)
```

and `:1240` `richChatViewModel.setSessionId(resolvedSessionId)`.

That id is what the badge and the handoff use —
`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift:171-181`
guards on `richChat.sessionId` and passes it into
`KanbanChatBadgeViewModel.run(sessionId:capabilities:)`
(`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Chat/ViewModels/KanbanChatBadgeViewModel.swift:59-62, 83`),
and `handleOpenKanban` at `ChatTranscriptPane.swift:224-233` puts the same id on
the `KanbanHandoff`.

So Scarf passes the ACP session id, and the ACP session id is what Hermes
stamps. **No mismatch on the normal path.**

**The one real risk (resume fallback).** At
`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:1209-1217`,
when `loadSession` throws, Scarf logs "Session … not found in ACP, creating new
session" and calls `newSession`, which mints a **different** ACP session id.
Scarf then adopts that new id. Everything downstream is internally consistent,
but from the user's point of view they "resumed" a chat and the Kanban chip's
count silently resets to zero, because tasks stamped with the old id no longer
match. This is not a correctness bug in the filter — it is a UX cliff that only
becomes visible now that the filter works. Severity: low.

There is a second, narrower path worth naming:
`ChatViewModel.resumeSession` at `:1021-1023` takes a non-ACP branch
(`richChatViewModel.setSessionId(sessionId); launchTerminal(...)`) where the id
set is a **Hermes DB session id**, not an ACP session id. That branch only runs
when `displayMode != .richChat`, and the Kanban chip lives on
`ChatTranscriptPane`/`SessionInfoBar`, which are the rich-chat surfaces — so in
practice the terminal-mode id never reaches the filter. I could not construct a
live path where it does, but it is the kind of adjacency that a future refactor
could turn into a real mismatch, so it is listed under proposed fixes as a
guard-rail, not a defect.

#### (e) Live behaviour

Against the live v0.21.3 host:

```
$ hermes kanban list --session=__nope__ --json
[]
EXIT=0

$ hermes kanban list --session=64c89a0a-5877-4920-bb53-2ecf469129d1 --json
[]
EXIT=0
```

A bogus session id is **not** an error — it is an empty array with exit 0, which
is exactly what `KanbanService.list` expects (it decodes `[]` and never
substring-matches CLI prose; see the deliberate comment at
`KanbanService.swift:139-144`).

**I could not positively confirm a non-empty match.** The live board has 7
tasks and **zero** of them carry a `session_id`:

```
total tasks: 7
with session_id: 0
```

(Every one was created from the CLI or dashboard, where Hermes correctly writes
NULL.) The `session_id` key *is* present on every returned task object, which
confirms the field name and the projection; only the positive-filter case is
unproven live. See "Things I could not verify".

#### (f) A host below the floor

On a pre-0.15 host the option does not exist and argparse rejects the whole
invocation. Reproduced with a synthetic unknown option on the live host:

```
$ hermes kanban list --sessionZZ=x --json
hermes: error: unrecognized arguments: --sessionZZ=x
(non-zero exit)
```

Two things make this safe:

1. Scarf never sends the flag below the floor — every surface is gated.
   `KanbanChatBadgeViewModel.swift:64` returns early (`shouldRender = false`),
   `SessionInfoBar.swift:237` hides the chip, and `ChatTranscriptPane.swift:171`
   refuses to start the poller. A pre-0.15 host renders exactly as it did
   before the feature existed, which satisfies C1.
2. Even if it were sent, `KanbanService.list` calls
   `ensureSuccess(code:stdout:stderr:verb:)` at
   `KanbanService.swift:137` **before** touching stdout, so an argparse error
   can never be parsed as success. That satisfies C5.

---

## Item 2 — ACP token and cost data in state.db

### Verdict: MOSTLY CORRECT. Column probing is exemplary. One real cost-display defect (not ACP-specific) and two stale comments.

#### Hermes writes these columns; live ACP sessions have real data

The canonical column names at the tag are in
`v2026.9.21:hermes_state.py:1516-1521`:

```python
"input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens",
...
_TOKEN_DELTA_COST_FIELDS = ("estimated_cost_usd", "actual_cost_usd")
...
"model", "cost_status", "cost_source", "pricing_version", "billing_provider", "billing_base_url",
```

The ACP write path runs through `queue_token_counts`
(`v2026.9.21:agent/turn_usage.py:257-272`, calling
`v2026.9.21:hermes_state_usage.py:344`), which is invoked for **any**
`session_id`, explicitly so that non-CLI runs cannot lose accounting.

Live confirmation, read-only:

```
source   | sessions | input>0 | output>0 | cost>0
acp      |    19    |   13    |    13    |   0
cli      |    16    |   16    |    16    |   0
cron     |     7    |    5    |     5    |   0
telegram |     1    |    0    |     0    |   0
```

and a sample of recent ACP rows:

```
id                                   | input  | output | cache_read | reasoning | est_cost | cost_status
64c89a0a-5877-4920-bb53-2ecf469129d1 |  24106 |    997 |      14848 |       376 | 0.0      | unknown
09b9fe25-2c48-465b-ac21-53372749c4db | 136875 |  40853 |   19352896 |      4157 | 0.0      | unknown
ded4f463-602e-43e8-a4cf-dfff3f252557 | 368865 |  63562 |   44141419 |      6645 | 0.0      | unknown
```

**ACP sessions now carry real token counts.** Cost is a separate story, below.

#### Column probing follows C4 — no SCHEMA_VERSION anywhere

Scarf probes with `PRAGMA table_info`, never by version:

- `/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/LocalSQLiteBackend.swift:286-292` —
  `sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", ...)`, and
  `if column == "reasoning_tokens" { hasV07Schema = true }`. That single probed
  column is what unlocks the v0.7 tail of the SELECT.
- `/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/RemoteSQLiteBackend.swift:151-156` —
  the same probe batched into one SSH round trip, plus a
  `sqlite_master` existence check for `session_model_usage`.
- `/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift:1459-1466` —
  the service-level helper, whose own comment names the rule:
  "Scarf never assumes a schema by Hermes version — the charter is detection".
  Note it returns `false` on a thrown query, so absence is tolerated rather than
  fatal.

The SELECT is assembled conditionally from those probes at
`HermesDataService.swift:153-166`: the base column list ends at
`estimated_cost_usd`, and only `if hasV07Schema` does it append
`", reasoning_tokens, actual_cost_usd, cost_status, billing_provider"`.
The aggregate at `HermesDataService.swift:1570-1585` has a matching pre-v0.7
branch that drops the two v0.7 cost columns.

**C4 is satisfied.** I found no `SCHEMA_VERSION` gating of token or cost data
anywhere.

#### The ACP special-casing that exists is additive, and still justified

There is exactly one piece, and it is a *fallback*, not a "no data" message.
`RichChatViewModel` accumulates per-prompt token counts returned over ACP
(`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:619-623`,
accumulated at `:2402-2412`, reset at `:1779-1785`), and `SessionInfoBar` prefers
the DB value whenever it is non-zero
(`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Chat/Views/SessionInfoBar.swift:319-320`):

```swift
let inputToks = session.inputTokens > 0 ? session.inputTokens : acpInputTokens
let outputToks = session.outputTokens > 0 ? session.outputTokens : acpOutputTokens
```

This should **stay**. It is correct on current hosts (the DB wins as soon as it
has a value) and it is the only thing that shows live counts mid-turn, because
`state.db` is only written at turn boundaries. It is also what keeps the bar
populated on a pre-v0.21.x host that did not write ACP tokens. Removing it would
violate C1.

What I did **not** find, having searched for it specifically: any "no token data
for ACP" string, any placeholder dash in a token or cost cell, any
estimate-from-message-count or estimate-from-character-count fallback, any
`source == "acp"` comparison anywhere near token or cost rendering (the four
`source == "acp"` sites are all resume-path or icon-mapping), and any
localized-string key about unavailable tokens. `Localizable.xcstrings` has only
the generic `"%@ tokens"` / `"%lld tokens"` keys.

Docs are clean too. The nearest sentence is
`wiki/Dashboard.md:47`, which blames schema age rather than ACP:
"Token/cost are zero but you've used Hermes — the schema may predate v0.7." That
is still accurate. No wiki or README text claims ACP sessions lack tokens.

#### The real defect: `$0.00` is shown for a cost Hermes says it does not know

Hermes distinguishes three cost outcomes
(`v2026.9.21:agent/usage_pricing.py`):

- `:550` — `CostResult(amount_usd=None, status="unknown", source=source, label="n/a", ...)`
- `:565` — `amount_usd=_ZERO, status="included", ...` (a subscription-included
  call that genuinely cost nothing)
- `:596` — `status: CostStatus = "estimated"`

But the amount is persisted through
`v2026.9.21:hermes_state_usage.py:367` as
`float(estimated_cost_usd or 0.0)` — so an **unknown** cost is stored as `0.0`,
indistinguishable from a real zero by the number alone. `cost_status` is the only
thing that tells them apart. That is precisely what the live data shows:
`estimated_cost_usd = 0.0` with `cost_status = 'unknown'` on every recent ACP row.

Scarf **selects and decodes `cost_status`** —
`HermesDataService.swift:161` (SELECT) and `:2044`
(`costStatus: hasV07Schema ? row.optionalString(at: 18) : nil`), carried on the
model at
`/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesSession.swift:22`
— **but nothing consumes it.** A repo-wide search for `costStatus` outside the
build products returns only the model, the decoder, and test fixtures that pass
`nil`.

The consequence is visible in the session list, at
`/Users/awizemann/Developer/Scarf/scarf/scarf/Features/Sessions/Views/SessionsView.swift:820-826`:

```swift
private var costLabel: String {
    if let c = session.displayCostUSD, c > 0 {
        return c.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
    return "$0.00"
}
```

Every ACP session whose cost Hermes recorded as unknown renders a confident
**`$0.00`**. That is false precision — it asserts "this cost nothing" where
Hermes said "I don't know". The same applies to CLI and cron sessions; this is
**not an ACP-specific bug**, but it surfaces most on ACP because ACP is Scarf's
chat transport.

The chat info bar is better but not immune
(`SessionInfoBar.swift:355-360`): it hides the cost entirely when
`displayCostUSD` is nil, but `displayCostUSD` is
`actualCostUSD ?? estimatedCostUSD` (`HermesSession.swift:152`), and
`estimatedCostUSD` here is a non-nil `0.0` — so the label renders
`$0.0000 est.` rather than hiding.

Note that the Dashboard is already correct by accident: its Cost card is only
rendered when `cost > 0` (`DashboardView.swift:293-301`), so an unknown cost
simply does not appear.

#### Two stale comments

Both now assert something that stopped being true at Hermes v2026.7.1:

- `RichChatViewModel.swift:619` — `// Cumulative ACP token tracking (ACP returns tokens per prompt but DB has none)`.
  The DB has them now.
- `SessionInfoBar.swift:8` — `/// Fallback token counts from ACP prompt results (DB may have zeros for ACP sessions).`
  "may have zeros" is now only true for pre-v0.21.x hosts and for the
  mid-turn window.

The **code** in both places is right and should not change; only the comments
mislead the next reader into thinking the fallback is load-bearing on current
hosts.

---

## Item 3 — "payment / credit error" wording

### Verdict: CORRECT — nothing in Scarf depends on the wording.

What actually changed upstream. At the previous release `v2026.9.14` (v0.21.3,
which is what the live host runs) the phrase was baked into the log format
string — `v2026.9.14:agent/auxiliary_client.py:2968`:

```python
"Auxiliary: marking %s unhealthy for %ds (payment / credit error). "
```

At `v2026.9.21` (v0.21.4) it became a **default argument**, with the reason and
the log level now both parameters —
`v2026.9.21:agent/auxiliary_client.py:3093-3118`:

```python
_AUX_UNHEALTHY_PAYMENT_REASON = "payment / credit error"

def _mark_provider_unhealthy(
    provider: str, ttl: Optional[float] = None, *, base_url: Optional[str] = None,
    reason: str = _AUX_UNHEALTHY_PAYMENT_REASON, level: int = logging.WARNING,
) -> None:
    """... absent credentials are an expected state (DEBUG), a confirmed 402 is a fault
    (WARNING) — the old fixed payment wording sent local-only users chasing billing (#64144)."""
```

Callers now pass the real reason where it is not a payment problem, e.g.
`:2343` `_mark_provider_unhealthy("nous", ttl=60, reason="no Nous authentication found", level=logging.DEBUG)`.
So the string still exists — it is just no longer applied to merely-absent
credentials.

Scarf sweep. Searching the whole repo for `payment / credit` and `payment/credit`
returns **no Swift source, no test, no `.xcstrings` entry, no log-viewer filter,
no health or diagnostics code**. The only hits are:

- `.memory/architecture/local-provider-config-keys-hermes-reader-verified-v0-17-0.md:93` and `:109`
- `documents/plans/2026-07-14-v2.17.0-release-prep.md:32`
- `documents/hermes-v0.20.0-audit-report.md:66`
- `tasks/t-b10d9fa6.md:16` (this task's own ticket)

All are Memophant-managed narrative tiers, not product code, and the memory note
at `:109` **already** records the upstream fix correctly, including that Scarf
parses none of this wording and needed no change.

A broader case-insensitive sweep for `unhealthy` across Scarf finds only
unrelated uses: an ACP channel-health comment
(`scarf/Scarf iOS/Chat/ChatView.swift:2592`), an SSH teardown comment
(`ScarfCore/Transport/StreamingChild.swift:93`), a stale iOS plan doc
(`scarf/docs/IOS_PORT_PLAN.md:442`), and Scarf's own service-health UI kit
(`design/static-site/ui-kit/Health.jsx:57`, which counts Scarf's own services and
has nothing to do with Hermes auxiliary providers).

**Nothing to fix.** Scarf never matched on this wording, so the change is a pure
upstream improvement with no client-side surface.

---

## Test results

Run from `/Users/awizemann/Developer/Scarf/scarf/Packages/ScarfCore`:

```
swift test --filter 'HermesCLIOptionP42Tests|SectionAuditF5KanbanTests|KanbanModelsTests|HermesCapabilitiesTests'
→ Test run with 209 tests in 6 suites passed after 0.016 seconds.
```

All green. Per the project's known test gotchas, these were run under `--filter`
rather than as part of the full suite; none of them are `@MainActor` and none
shell out, so they are not among the executor-hogging tests that destabilise the
full run.

### Are these real tests or checkbox tests?

**Mostly real.** Specifically:

- `KanbanModelsTests.listFilterSessionPasses` (`Tests/ScarfCoreTests/KanbanModelsTests.swift:315-320`)
  asserts both the positive (`HermesCLIOption.value(of: "--session", in: argv) == "acp-sess-123"`)
  **and** that the default empty filter never emits the flag. Testing the
  negative is what makes it worth having.
- `listFilterEmptySessionDropped` (`:322-…`) pins the empty-string guard, which
  is a real behavioural decision (empty means "no session", not "match empty").
- `HermesCLIOptionP42Tests.kanbanListFilterCarriesEveryUserTextValueInOneToken`
  (`Tests/ScarfCoreTests/HermesCLIOptionP42Tests.swift:98-110`) is the strongest
  of the set: it passes deliberately hostile dash-leading values
  (`session: "-s"`), asserts the joined token `--session=-s`, and then asserts
  the **absence** of the bare two-token spelling for all five flags. That is a
  genuine regression guard against the argparse failure mode it was written for.
- `KanbanModelsTests.decodeSessionId` (`:111-124`) and the `sessionId == nil`
  assertion at `:50` together cover both the present and absent wire cases —
  the tolerant-decode contract from C4's spirit.
- `HermesCapabilitiesTests` at `:323`, `:357`, `:403` covers the flag on, off,
  and patch-still-on, matching the cluster pattern the charter's guardrails ask
  for.

The one genuine weakness: **every one of these is a pure string/decoder test.**
Not a single test asserts that the id Scarf puts in `--session` is the ACP
session id rather than some other id. The traceability in item 1(d) is real but
rests entirely on reading the code; nothing would fail if a future refactor fed
`KanbanChatBadgeViewModel` a Hermes DB session id. That is the gap worth closing.

---

## Proposed fixes, ranked by severity

Product code was not modified. These are proposals for follow-up tasks.

### 1. MEDIUM — Stop rendering `$0.00` for a cost Hermes recorded as unknown

`SessionsView.swift:820-826` returns a literal `"$0.00"` whenever
`displayCostUSD` is nil or zero, and `SessionInfoBar.swift:355-360` renders
`$0.0000 est.` for the same rows, because `estimatedCostUSD` is a non-nil `0.0`.
Live data shows every recent ACP session sits in exactly this state
(`estimated_cost_usd = 0.0`, `cost_status = 'unknown'`).

Scarf already has the information it needs: `cost_status` is selected
(`HermesDataService.swift:161`), decoded (`:2044`) and carried on the model
(`HermesSession.swift:22`) — it is simply never read.

Suggested shape: add a derived property on `HermesSession` alongside
`displayCostUSD` / `costIsActual` that treats `costStatus == "unknown"` as
"no cost known", and have both surfaces render an em-dash (the session list
already uses `"—"` for a missing model at `SessionsView.swift:817`) instead of a
currency value. `costStatus == "included"` should keep rendering `$0.00`,
because there that figure is true.

Must be gated so it degrades correctly per C1: `costStatus` is nil on any
pre-v0.7 host (it is inside the `hasV07Schema` branch), and a nil status must
keep today's behaviour exactly.

### 2. LOW — Add a test that pins *which id* reaches `--session`

The existing tests prove the flag is spelled correctly; nothing proves the value
is the ACP session id. A test that drives `KanbanChatBadgeViewModel` (or, more
cheaply, asserts that the only writer of `richChat.sessionId` on the rich-chat
path is an ACP `newSession`/`loadSession` return) would close the gap identified
above, and would catch the `ChatViewModel.swift:1021-1023` terminal-mode branch
if it ever became reachable from a Kanban surface.

### 3. LOW — Correct two now-stale comments

- `RichChatViewModel.swift:619` — "DB has none" became false at Hermes
  v2026.7.1. Reword to say the DB now carries ACP tokens, and that this
  accumulator remains for the mid-turn window and for pre-v0.21.x hosts.
- `SessionInfoBar.swift:8` — same correction for "DB may have zeros for ACP
  sessions".

Comments only; the code in both places is correct and should not change.

### 4. LOW / optional — Surface the resume-fallback session change

When `loadSession` fails and Scarf silently mints a new ACP session
(`ChatViewModel.swift:1209-1217`), the Kanban chip's count resets with no
explanation. A one-line note in the transcript, or simply leaving the chip's
count as `nil` rather than `0` for a freshly-minted fallback session, would stop
this reading as data loss. Cosmetic; no correctness impact.

---

## Things I could not verify

1. **A positive live match for `--session`.** The live board has 7 tasks and
   none carries a `session_id`, because all were created from the CLI or
   dashboard, where Hermes correctly writes NULL. I verified the empty-result
   and bogus-id cases live, and I verified the field name is present on every
   returned object, but I never saw the filter return a non-empty array.
   Producing one would require creating a kanban task from inside an ACP chat
   turn, which is a mutation of the user's Hermes state and out of scope for
   this task. The filter's server-side implementation was read at the tag
   (`hermes_cli/kanban.py:432-434` → `kb.list_tasks(..., session_id=...)`), but
   I did not read `kb.list_tasks`'s SQL itself, so the positive path is verified
   by source-reading only, not by execution.

2. **Item 3 against a running v0.21.4.** The live host is v0.21.3, which still
   has the old fixed wording. The v0.21.4 behaviour is verified from tagged
   source only. This does not weaken the conclusion — the conclusion is that
   Scarf matches on nothing, which is a fact about Scarf, not about Hermes — but
   the new DEBUG-level log lines were never observed in practice.

3. **Whether every Hermes write path for ACP token counts is covered.** I traced
   `agent/turn_usage.py:257-272` → `hermes_state_usage.py:344`, and confirmed
   the outcome empirically in `state.db`. I did not exhaustively enumerate every
   caller of `update_token_counts` / `queue_token_counts`, so I cannot rule out
   an ACP sub-path (compression, sub-agents) that accounts differently.

4. **ScarfGo iOS token/cost surfaces beyond the Dashboard.** The search found a
   Tokens stat card and no cost surface at all on iOS. I verified the absence by
   search rather than by building and running the iOS target, so an
   indirectly-constructed surface could have been missed.

5. **The full ScarfCore suite.** Only the four filtered suites (209 tests) were
   run. I did not run the full ~3,500-test suite, so I cannot claim this
   validation did not perturb anything elsewhere — though no product code was
   changed, so there was nothing to perturb.
