---
title: Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers
type: note
permalink: scarf/decisions/absent-vs-unreadable-is-the-discriminator-every-scarf-json
tags: [projects, transport, resilience, dataloss, restore]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift]
source_paths_inferred: false
source_sha: feebb3c6a0446ee737233fe1a61621a876c3bc38
created: 2026-09-04
updated: 2026-09-04
---

t-a6f22379. `projects.json` got this discriminator in commit 7460cf9; `project.json` and the restore service's remote rewrites did not, and both destroyed state through the same hole.

## Observations
- [decision] `ProjectStore.loadDetailed` returns `.loaded/.absent/.unreadable`, and `save` REFUSES (`ProjectStoreError.refusedUnreadableRecord`) when the record is stat-confirmed but unreadable. Nearly every caller is shaped `load(…) ?? derive(from: entry)` then `save` — so a blip that nils the load handed `save` a record rebuilt from facets that same blip also failed to read (board, presets, miniApps, secretsScope nulled) and published it as canonical. Guard at the chokepoint, not the five call sites. #projects #dataloss
- [constraint] The probe takes PROOF, never inference: `stat` must CONFIRM the file, then the read is RETRIED once. No stat ⇒ report ABSENT (refuse nothing — the write then fails with the real transport error), because a transport too sick to stat would otherwise freeze first-launch writes forever. One read on the healthy path. #transport
- [gotcha] UNPARSEABLE is not UNREADABLE: a decoded-and-rejected `project.json` reports `.absent` so the writers can rebuild it from facets, while a transport-level read failure blocks the write. Conflating them either freezes rebuilds or resumes the data loss. #projects
- [decision] `RemoteRestoreService` no longer rewrites remote `projects.json` / `cron/jobs.json` via truncating Python `open(path,'w')` behind `try?` — it reads through the transport, mutates the `JSONSerialization` object graph (unknown keys survive), writes a `.bak`, publishes via atomic `writeFile`, and THROWS on every failure. A failed rewrite used to report a successful restore, and a failed cron pause reported "0 paused" — indistinguishable from "nothing to pause" while every restored job stayed armed with the source host's credentials. #restore #dataloss
- [constraint] `ProjectStore.writeRecord` keeps a one-deep `project.json.bak`, and `save` reads ONCE for both the damage probe and the backup bytes — two reads would be two SSH/SFTP round-trips per save. #projects

## Relations
- relates_to [[Transport atomic-write parity is a per-transport contract, not a property of writeFile]]
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]


## D1 (t-3b855719): the discipline became one type, and the adjacent sidecars got it

- [decision] `GuardedJSONStore` (Services/GuardedJSONStore.swift) is now THE implementation of the read-then-write discipline — stat+retry probe, zero-bytes-is-damage, quarantine-with-dedup, one-deep `.bak`, atomic publish — and `miniapp_grants.json`, `session_project_map.json` and iOS `cron/jobs.json` all go through it. `ProjectDashboardService.quarantineRegistry` and `quarantineStamp` now DELEGATE to it, so there is one filename stamp and one dedup rule, not four. #dataloss
- [decision] The two sidecars follow `project.json`'s split, NOT `projects.json`'s: UNREADABLE (stat-confirmed, two failed reads, or zero bytes) REFUSES the write; UNPARSEABLE is quarantined and then rebuilt from empty. Grants are re-grantable by the permission sheet and attributions are re-recorded on the next chat, and the original bytes survive in the `.corrupt-<stamp>` copy — a permanently frozen grants file would be worse than the damage. `projects.json` still refuses forever because its rows exist nowhere else. #projects
- [gotcha] Each store now does ONE inspect that serves both the decode and the write (`mutate { … }`), instead of `load()` then `persist()`. Reverting to load-then-persist reopens the hole even with the guard in place: the write would be checked against a DIFFERENT read than the one it was computed from.
- [decision] `SessionProjectMap` gained optional `touched: [String: String]` (sessionID → ISO-8601) and `prune(limit:)` at `maxMappings = 2000`, applied on every persist. The 1 MB cap with no pruning made total attribution loss a matter of time — past the cap every read returns empty. Entries with no stamp prune first (they predate the field); ties break on session id so two windows prune identically. (SUPERSEDED by G2 below: `SessionProjectMap` now DOES preserve unknown keys, so an older build's write no longer drops `touched`.) #gotcha
- [decision] iOS `IOSCronViewModel` keeps a `baseline` of the exact bytes `load()` saw and REFUSES a save when the file changed underneath — Hermes rewrites `jobs.json` on every tick, and the phone rewrote it whole from an in-memory list. A nil baseline (never loaded) skips only the staleness check, never the damage refusal; the UI always loads first. #dataloss


## W1 (t-e2cd2861): `fileExists` IS the inference — the rule is now writer-side, not file-side

The P8 audit's finding in one line: the D-series guarded FILES, and every writer that
still asked `transport.fileExists(path)` before deciding what the file contained was
running the same absent-vs-unreadable inference under a different spelling. A dropped
round-trip answers `false`, and `false` was read as "nothing there".

- [decision] `ModelPresetService` is the last of the four adjacent stores to go through
  `GuardedJSONStore`. Its load/persist pair collapsed into ONE `mutate` inside one
  detached task, so the write is checked against the read it was computed from.
  Undecodable bytes are NOT quarantined-and-rebuilt here (unlike grants/session map):
  a preset is user-authored and exists nowhere else, so it refuses like `projects.json`.
  New `ModelPresetServiceError.unreadableStore(path:)`; `ModelPresetStoreReader.probe()`
  is proof-based too, so the fleet stops reporting "this host has no presets" about a
  host whose store is right there. #dataloss #projects
- [decision] `ProjectContextBlock.writeBlock` — the AGENTS.md writer that runs on EVERY
  project-scoped chat start on both platforms — is guarded, and the Mac's
  `ProjectAgentContextService.refresh` now DELEGATES its persistence to it instead of
  carrying a second copy of the same splice-and-replace. There was one bug in two files.
- [constraint] UNDECODABLE-AS-UTF-8 IS UNREADABLE, NOT EMPTY. `String(data:encoding:.utf8) ?? ""`
  is the text-file spelling of `try? decode ?? []`: one stray byte collapsed the user's
  AGENTS.md to an empty document and the splice republished it as the Scarf block alone.
  It now throws `WriteError.refusedUndecodableText`. #gotcha
- [gotcha] ZERO BYTES IS DAMAGE FOR A JSON SIDECAR, NOT FOR PROSE. Scarf never writes an
  empty `model_presets.json`, so zero bytes means somebody truncated it — refuse. An empty
  `AGENTS.md` is a file a person made, has nothing to lose, and stays writable;
  `writeBlock` rewrites that one inspection to `.absent` rather than refusing forever.
- [decision] AGENTS.md finally has a `.bak` (its first, via `GuardedJSONStore.write`). It is
  SCARF'S artifact, not the user's content: `ProjectTemplateUninstaller` gained
  `scarfOwnedProjectRootFiles(in:)` — the project-root sibling of `scarfOwnedFiles(in:)` —
  so `AGENTS.md.bak` neither counts as an "extra" that blocks removing the folder nor
  survives an uninstall. Any future root-level Scarf artifact belongs in that set.
- [decision] MCP `project_set_config` reads through `GuardedJSONStore.inspectDecoding` and
  mutates the `JSONValue` graph, so unknown top-level keys survive and a stat-confirmed
  unreadable `config.json` REFUSES. The inspection runs BEFORE the Keychain write, so a
  refusal can't leave a secret in the Keychain that nothing references.
- [constraint] A FAILED RENAME IS NOT PROOF THE DESTINATION IS IN THE WAY. Citadel's
  SFTP publish fallback deleted the destination on ANY rename error; SFTP v3 returns one
  undifferentiated status and a dropped cellular link produces it too. The policy now lives
  in `SFTPRenamePublisher.publish` (testable without a live server, 6 tests): retry the plain
  rename once, then probe the destination, and only a destination that PROVABLY exists is
  displaced. Otherwise the destination is untouched and the staged bytes are named in the
  error, never removed. #ios #transport



## G2 (t-58bc7efe / t-05a7c23d): quarantine parity, `.bak` ordering, and the last two splice holes

- [decision] QUARANTINE PARITY FOR `project.json`. `ProjectStore.inspectRecord` reported
  `.absent` on an undecodable or oversize record — correct, the record is rebuildable — but
  the ONLY copy of the original was then the one-deep `.bak` the next save wrote, and the
  save after that overwrote it. Two derived rewrites and a hand-edited (or newer-Scarf)
  record was gone. It now calls `GuardedJSONStore.quarantine` (the same memoized, deduped,
  pruned helper every sidecar uses), so the bytes land in `project.json.corrupt-<stamp>`.
  #dataloss #projects
- [constraint] A QUARANTINED PREDECESSOR IS NEVER THE `.bak`. `GuardedJSONStore.write` skipped
  nothing, so corruption cost the user BOTH copies: the live file (correctly rebuilt from
  empty) and the last-known-good `.bak` (overwritten with the bytes we had just declared
  unusable, which were already in the `.corrupt-` copy). Both `GuardedJSONStore.write` and
  `ProjectStore.writeRecord` (via `skipBackup:`) now leave the `.bak` alone on a quarantine
  cycle. The one exception is a quarantine copy that FAILED to write — then the `.bak` is the
  only rescue left and still gets refreshed. #dataloss
- [decision] `ScarfProject.extra` and `SessionProjectMap.extra` (`[String: JSONValue]`, swept
  with `AnyCodingKey`) complete the unknown-key contract `ProjectEntry`/`ProjectRegistry` got
  in 7bc27c9. `project.json` is the ONE record documented as PORTABLE — it travels with the
  repo and is read by other builds — so having the weaker guarantee was backwards. `extra` is
  excluded from `ScarfProject`'s hand-written `Equatable`/`Hashable` for the same reason
  `ProjectEntry.uuid` is: a key this build doesn't understand must not disturb selection or
  set membership. #projects
- [constraint] `ProjectStore` is the SOLE writer of `project.json`, and `derive()` never
  rewrites a record that loaded — so `extra` survives the derive-and-save path. A second
  writer that re-encodes `ScarfProject` from facets would silently reintroduce the loss.
- [decision] The two remaining `String(data:encoding:.utf8) ?? ""` splice holes W1 left behind
  are closed the same way: `KeychainEnvMirror`'s `~/.hermes/.env` rewrite (which held BOTH
  halves of the bug — `fileExists`-as-proof and the `?? ""` collapse, so one dropped SSH
  round-trip or one stray byte published a Scarf-block-only `.env`, deleting Hermes's own
  `ANTHROPIC_API_KEY`) and `ProjectTemplateInstaller.appendMemoryIfNeeded`'s MEMORY.md
  appendix (which published `"" + appendix` over the user's notes). Both now inspect through
  `GuardedJSONStore`, refuse undecodable text, and keep a one-deep `.bak`. `GuardedJSONStore.Inspection`
  gained a `public` init so out-of-module prose writers can reclassify zero-bytes as `.absent`.
  #dataloss
- [gotcha] AN UNBOUNDED REGION IS NOT A REGION (SEC-L5). `ProjectTemplateUninstaller.stripMemoryBlock`
  stripped from a begin marker to EOF when the end marker was missing. MEMORY.md is agent-writable,
  so appending a bare begin marker turned the next uninstall — a routine one-click action — into
  "delete the whole file", with no backup and no prompt. It now strips NOTHING, logs, and leaves
  the file for a human. The uninstall PREVIEW was corrected to match: it reports the block present
  only when BOTH markers are found, so it can't promise a removal the strip then refuses.
- [decision] `TransportPrivateMode` derives the mode from the ORIGINAL basename (SEC-L2): it
  strips `.bak` and `.corrupt-<stamp>` suffixes repeatedly before matching. `.env.bak` holds
  exactly the secrets `.env` holds, and under a plain basename match every backup and quarantine
  copy the D-series added landed world-readable on remote hosts — the backup discipline was
  quietly undoing the permission discipline. #security #transport


## Quarantine is a ceiling, so the writer owes the file a prune (t-682b7f47)

`GuardedJSONStore` converts "over the cap" from silent truncation into a visible quarantine, which is strictly better and strictly not enough: `session_project_map.json` is the SOLE record of session↔project attribution and grows one entry per session forever, so a long-lived install eventually crosses `SessionAttributionService.maxSidecarBytes` (1 MB) and every session loses its project at once. iOS over SFTP is the likeliest first casualty.

- [fact] Verified by inspection and by test: BOTH writers reach the prune. `ChatViewModel` (Mac) and `Scarf iOS/Chat/ChatView.swift` are the only non-test callers of `attribute`, and every write verb (`attribute`, `forget`) funnels through `mutate` → `mutateLocked`, which calls `SessionProjectMap.prune()` before encoding. There is no second writer of this file anywhere in the app — the promotion of the whole service to ScarfCore in M9 #4.2 is what makes Mac and iOS share one code path, and it is what makes this a one-place guarantee. #dataloss
- [gotcha] The ONE gap that was real, and is now closed: `attribute` of a session already pointing at the same project reports "no change" and returned BEFORE pruning ran. An install that only ever re-attributes sessions it already knows — every resume of an existing project chat does exactly that — would never trim an over-cap file it inherited from an older Scarf or another device. `mutateLocked` now evaluates the prune even when the body reported no change, and writes when EITHER the body or the prune changed something. An under-cap map that changed nothing still writes nothing (pinned by a byte-identity test).
- [decision] The count cap (`SessionProjectMap.maxMappings` = 2000) is a proxy for the byte cap, so the test asserts the BYTES: a pruned sidecar must be under `maxSidecarBytes` and must still decode afterwards — i.e. the store did not quarantine it. Asserting the entry count alone would pass while the file was being set aside.
- [gotcha] `SessionProjectMap.extra` (unknown top-level keys, carried verbatim so an older Scarf can't delete a newer one's fields) is NOT bounded by pruning. The file is agent-writable, so a large `extra` can still push it over the cap with 2000 legitimate mappings. Not exploited by anything today and not fixed here — recorded so the next person reading "pruning keeps it under the cap" knows the qualifier.
