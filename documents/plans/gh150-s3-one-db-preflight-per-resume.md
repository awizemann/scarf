# gh#150 S3 — fewer database round trips when reopening a chat

Validated against the code on 2026-11-24 (main @ 4e80a38f), not from memory.

## What a reopen does today (remote host)
Each remote database step is one SSH exec (`RemoteSQLiteBackend`, `transport.streamScript`). `open()` = 1 exec (sqlite3 version + `PRAGMA table_info(sessions|messages)` + JSON1 probe, `RemoteSQLiteBackend.swift:141-196`). There is no snapshot on remote: queries are always live (`:9`, `:199-211`).

| Step | Code | Execs |
|---|---|---|
| Source lookup | `SessionResume.fetchSource` (`ACP/SessionResume.swift:243-249`): new `HermesDataService`, `open()`, `fetchSession` | 2 |
| Folder lookup (gateway-backed, non-project only) | `SessionResume.fetchCwd` (`:180-186`): new service, `open()`, `fetchSessionCwd` → `sessionsTableHasColumn("cwd")` runs its own `PRAGMA table_info(sessions)` (`HermesDataService.swift:2482-2489`) then the query (`:2067-2077`) | 3 |
| History | `RichChatViewModel.loadSessionHistory` (`:4055`): `refresh(forceFresh: true)` re-runs the preflight, then the page queries | 1 + queries |

So a gateway-backed (Hermes v0.22.3+) reopen of a non-project chat runs **3 preflights + 1 redundant PRAGMA** before history queries. Callers: iOS `Scarf iOS/Chat/ChatView.swift:3790, 3807` (and `:3323` reconnect); Mac `scarf/Features/Chat/ViewModels/ChatSession.swift:3792, 3805` (and `:3186`).

## Change
1. **One lookup per reopen.** Add a small `SessionResume` helper that opens one private `HermesDataService` lazily, answers `source(id)` and `cwd(id)` from it, and closes it at the end. Use it in the iOS and Mac reopen paths (the two call sites each). Keep `fetchSource` / `fetchCwd` as one-shot wrappers for the reconnect paths. Still a private service, so it can't close the chat view model's own connection (the reason `fetchSource` is separate today).
2. **No extra PRAGMA for `cwd`.** The preflight already reads `PRAGMA table_info(sessions)`; record a `hasSessionsCwdColumn` flag there (both backends, same as the existing `has…Column` flags) and use it in `fetchSessionCwd`. Still detects the column by `table_info` (C4).

Saves 2 SSH execs per gateway-backed reopen (5 → 3 for source + folder) and 1 per reopen-in-place elsewhere that calls `fetchCwd`. Mac benefits too.

## Deliberately not changed
- **The history step's forced preflight** (`RichChatViewModel.swift:4047-4055`). Its comment says it avoids a stale snapshot, which no longer exists on remote, so on remote it only re-reads the schema. Dropping it would save 1 more exec, but it is shared with the Mac, runs on every history load, and is the escape hatch after a Hermes upgrade. Separate decision; not in this slice. Fix the misleading comment only if Alan agrees.

## Honest size of the win
On a LAN each exec is roughly 0.1–0.3 s (login-shell + sqlite3 start), so this saves well under a second. It is not the 30 s from #150; the reporter's timings will show where that went. Worth doing because it is small, shared, and removes duplicated work — not because it fixes the report.

## Blast radius
- `SessionResume` (shared Mac + iOS), `HermesDataService.fetchSessionCwd`, both SQLite backends' preflight (one new flag), iOS + Mac reopen call sites.
- Behaviour must be identical: same source, same cwd, same fallbacks. Tests: existing SessionResume tests unchanged + new tests that the lookup opens once and answers both, and that `fetchSessionCwd` returns nil when the column is absent.
- No state.db writes (C3); column detection stays `table_info` (C4); no Hermes-version gate needed (C1).

## Real test
Simulator over a throwaway localhost sshd: reopen an existing chat, compare `ios.resume.fetchSource` + `ios.resume.sessionLoad` before/after; count execs via `ssh.streamScript` in ScarfMon. Mac: reopen a remote chat, transcript and folder unchanged.
