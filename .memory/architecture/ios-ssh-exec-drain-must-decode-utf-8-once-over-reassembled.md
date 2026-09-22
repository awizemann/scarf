---
title: iOS SSH exec drain must decode UTF-8 once over reassembled bytes, never per packet (F5)
type: note
permalink: scarf/architecture/ios-ssh-exec-drain-must-decode-utf-8-once-over-reassembled
source_paths: [scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift]
source_paths_inferred: false
source_sha: 0bc62f678de391d5e1d9fb625443204fb692c5bc
created: 2026-09-18
updated: 2026-09-18
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] Citadel hands `absorb` one `ExecCommandOutput` chunk per SSH data packet, and a multi-byte UTF-8 character (CJK text, emoji — anything non-ASCII in a chat message over roughly 32 KB) routinely lands split across two of them. `ByteBuffer.readString(length:)` decodes via `String(decoding:as: Unicode.UTF8.self)`, which NEVER throws on invalid UTF-8 — it silently substitutes U+FFFD. So a split character became TWO replacement characters with no error anywhere in the call chain: not in `absorb`, not in `runExec`, not in the caller. #gotcha #ios #ssh #utf8
- [decision] Read RAW bytes per chunk (`buf.readBytes(length:)`, not `readString`) and append them straight into the `Data` accumulators (`stdout`, `stderr`, and the `PartialStdout` mirror the timeout arm reads). `ProcessResult.stdout`/`stderr` are `Data`, not `String` — there was never a reason to round-trip through `String` inside the drain loop; any caller that wants text decodes the FULLY reassembled bytes once. `CitadelServerTransport.swift`, the `absorb` static function.
- [convention] The Mac side of this exact principle is already written down in [[Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap]] (round-5 P48: "per-chunk decoding would split a UTF-8 sequence across a pipe read", about `SSHScriptRunner`'s `ProcessOutputInbox`). This note is the iOS/Citadel twin — same defect class, different transport, found later (final audit, phase F5) because it was never swept together with the Mac drains.
- [fact] `ExecCommandOutput` (Citadel, `public enum { case stdout(ByteBuffer), case stderr(ByteBuffer) }`) is a plain public enum constructible in tests with no live SSH host — a fake `AsyncSequence<ExecCommandOutput>` fed straight into `CitadelServerTransport.absorb(_:timeout:midStream:partial:)` (internal, reachable via `@testable import ScarfIOS`) stages the split deterministically. `CitadelServerTransportUTF8SplitTests` (ScarfIOSTests) splits a 3-byte CJK character across two chunks and a 4-byte emoji across four single-byte chunks; asserts byte-exact reassembly and the absence of U+FFFD. Confirmed failing against the pre-fix `readString`-per-chunk code (replacement characters, corrupted byte counts) before restoring the fix — same staging technique `CitadelTransportP53Tests` uses for the timeout race.

## Relations
- relates_to [[Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap]]
- relates_to [[iOS transport must be pooled per (ServerID, SSHConfig) — un-pooled makeTransport churns SSH connections]]
