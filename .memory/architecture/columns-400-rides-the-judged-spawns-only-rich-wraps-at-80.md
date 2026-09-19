---
title: COLUMNS=400 rides the judged spawns only — rich wraps at 80 and splits a marker line
type: note
permalink: scarf/architecture/columns-400-rides-the-judged-spawns-only-rich-wraps-at-80
tags: [transport, hermes-cli, verification, round-4]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift]
source_paths_inferred: false
source_sha: 834467ab2ab1d5523097d023b965211259223f3d
created: 2026-09-11
updated: 2026-09-13
reviewed: 2026-09-13
reviewed_by: claude-opus-5
---

Round-4 P40. Scarf judges Hermes runs by matching whole printed lines, and Hermes prints through `rich`. `rich`'s `Console.width` falls back to `COLUMNS` and then to 80 when stdout is not a TTY — and a pipe is never a TTY — so an 80-column wrap can split a marker in half. The live case was `✓ Plugin <name> updated.` (`hermes_cli/plugins_cmd.py:828` @ v2026.9.7), matched as a column-0 `Plugin ` prefix AND an `updated.` tail, which a long plugin name pushes onto two lines.

The value is `LocalTransport.wideColumns` (`"400"`) — wide enough that no marker line Hermes prints comes close, narrow enough to stay a plausible terminal.

## Observations
- [invariant] `COLUMNS` is set ONLY on the spawns Scarf judges by output: `LocalTransport.runProcess(…)` locally, through `subprocessEnvironment(forExecutable:)` — the one-shot CLI path every `HermesCLIVerdict` call site runs through — and every REMOTE command, through the assignment prefix `SSHTransport.composedRemoteCommand` builds #transport
- [gotcha] An ssh client's environment does NOT cross to the remote shell (no `SendEnv` here), so the remote `rich` takes its own 80-column non-TTY default unless `COLUMNS=…` rides the same assignment prefix as `HERMES_HOME`. That prefix is on the shared composer, so the remote ACP spawn gets it too — harmless, and nothing on ACP reads it #transport
- [decision] It is deliberately NOT on the LOCAL streaming spawns — `streamLines`, `streamRawBytes` and `makeProcess` (the ACP spawn). Those inherit the app's environment rather than building one; routing them through `subprocessEnvironment` for `COLUMNS` alone would also move PATH and every enricher key onto the ACP session, a real behaviour change for one setting nothing there reads #decision
- [fact] Nothing streamed is judged by a `rich`-printed marker: `streamLines` tails log files (`HermesLogService`), `streamRawBytes` moves raw bytes (`cat`, `RemoteBackupService`), and ACP is newline-framed JSON-RPC — which is what makes the exclusion safe #transport
- [convention] An explicit `COLUMNS` already in the environment is left alone: the user (or a test) meant it. The guard is `if (env["COLUMNS"] ?? "").isEmpty` #conventions

## Round 6 (P54) — the THIRD spawn family, and the twin that stays without

Round 4 enumerated two spawn families because it was looking at the Mac. The iOS runtime has its own, and it was invisible to the round-4 sweep for the same reason `CitadelServerTransport.runSync`'s unbounded wait was: `scarf/Packages/ScarfIOS/Sources` was in none of the roots.

- [gotcha] **`CitadelServerTransport.asyncRunProcess` is the third judged-spawn family** and had no `COLUMNS` until P54. Citadel's raw exec channel is not a TTY AND forwards none of the client's environment, so it needs the assignment prefix for exactly the reason `SSHTransport.composedRemoteCommand` does — but it builds its own command string (`PATH=… HERMES_HOME=… <argv>`) rather than going through the shared composer, so it did not inherit the round-4 fix. Every judged `runProcess` the iOS runtime makes goes through it #transport
- [gotcha] **A caller that composes its own `/bin/sh -c` script sets it a second time.** `MemoryListView.resetMemory` (`scarf/Scarf iOS/`) builds the whole script itself; the assignment leads, because `sh` reads leading `VAR=value` pairs left to right and stops at the first non-assignment. Both sites read `LocalTransport.wideColumns` rather than writing `400`, so the three families cannot drift to three widths #transport
- [decision] **`_streamScriptImpl` stays WITHOUT it, and that is now pinned by a test.** It pipes a `/bin/sh` script (sqlite3 `-json`, the bots scan) whose output no verdict matches, and the Mac twin `SSHTransport.streamScript` → `SSHScriptRunner` carries none either — the same "nothing streamed is judged by a rich marker" reasoning as the round-4 local exclusion. The test asserts the ABSENCE so a future phase that starts judging script output is told to revisit the decision rather than inheriting the omission #decision
- [gotcha] **The justification written for this fix was wrong about the arithmetic, and a test caught it.** The first draft said the memory-reset marker "is 74 characters and wraps at 80"; it is 66 and does not. The reason to set `COLUMNS` here is the general one round 4 established (a judged spawn, a `rich` emitter, an unknown-length interpolated line) plus parity with the two families that already had it — not a particular line. A number in a comment is a claim nobody executes #verification



## Relations
- relates_to [[Judging a Hermes verb by its output: the exit-0 refusal FAMILY and the anchored-prefix rule]]
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
