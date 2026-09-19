---
title: Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers
type: note
permalink: scarf/decisions/absent-vs-unreadable-is-the-discriminator-every-scarf-json
tags: [projects, transport, resilience, dataloss, restore]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedJSONStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedTextFile.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedSidecarStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SessionAttributionService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPresetService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/TransportPrivateMode.swift, scarf/scarf/Core/Services/ProjectTemplateInstaller.swift, scarf/scarf/Core/Services/HermesFileService.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-04
updated: 2026-09-07
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
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
- relates_to [[Guarded writes for shared JSON: mutate the graph, one store per file, prove absence before creating]]


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



## GW-E2b (t-59b679c5): `servers.json` — the store that had no transport at all

`ServerRegistry` (Mac target, `scarf/scarf/Core/Persistence/ServerRegistry.swift`) never touched a transport: `load()` answered any read/decode failure with `entries = []`, `save()` published with a bare `Data.write(.atomic)`. Commit 5dd8e409.

- [decision] It now runs `GuardedJSONStore` over `LocalTransport` and REFUSES FOREVER, like `projects.json` and `model_presets.json`: the rows are the user's SSH connections and exist nowhere else (the `.scarfservers` export is opt-in and usually absent). Undecodable bytes are still copied aside via `GuardedJSONStore.quarantine` for the human, but the state is reclassified to `.unreadable` so writes stay refused — `inspect` + a local decode, NOT `inspectDecoding`, whose `.quarantined` is deliberately writable. #dataloss
- [gotcha] `.quarantined` from `inspect` itself (the size cap) needs the same reclassification. A refuse-forever file that accepts a write on the oversize path is still a destroy shape; the store's default is tuned for rebuildable sidecars.
- [constraint] A REFUSAL NOBODY CAN SEE IS A SWALLOWED FAILURE. `ServerRegistry.StoreDamage` is `@Observable` state rendered as a banner in `ManageServersView` (the mutations there report no errors otherwise), telling the user their edit is session-only. Same role `ProjectsViewModel.registryDamage` plays for `projects.json`, minus the watcher/doctor.
- [gotcha] `ServerRegistry` loads ONCE, in `init`, and nothing re-reads the file — so damage is sticky for the process lifetime and clears only on relaunch (or on the first successful save). Acceptable because the banner says exactly that, but any future re-load path must re-inspect rather than trusting the cached inspection.
- [fact] Unknown-key preservation was deliberately SKIPPED: `servers.json` is single-writer (the Mac app; iOS has no registry, Hermes never reads it) and schema-versioned, so there is no other build whose keys could be dropped. Revisit if a second writer or a schema v2 ever appears.


## GW-E3 (t-ecaccef5): the discriminator got an enum, and the enum got enforced

- [decision] The rebuildable-vs-irreplaceable choice this whole ledger keeps restating per file is now `GuardedDamagePolicy` on the `GuardedSidecarStore` protocol — declared per adopter, un-defaulted, and applied by the DEFAULT implementations to both the decode failure and the size cap. `ServerRegistry` (`.refuseForever`), `MiniAppGrantStore` and `ProjectManifestStore` (`.quarantineAndRebuild`) migrated onto it with their suites unedited. Full write-up and the shape/`.bak`/unknown-key guidance live in [[Guarded writes for shared JSON: mutate the graph, one store per file, prove absence before creating]] and in the protocol's own doc comment, which is the adoption guide new stores are pointed at from `GuardedJSONStore`'s header. #dataloss


## GW-F2 (t-01dd696e): the disease also lives in the READS that feed the guards

The GW-E arc guarded the writes; the E5 audit found the same inference one hop upstream, in the reads whose answers DECIDE whether to write. A guard cannot refuse a write it is handed legitimately — so the rule now extends: **a read whose answer decides a write must carry proof; a read that only renders may stay tolerant, and must say so in a comment.**

- [decision] `ProjectManifestStore` gained `readProven(for:)` beside the tolerant `read(for:)`. `KanbanTenantResolver`'s `tenant`/`resolveOrMint`/`setTenant` and `ProjectModelPresetBinding.bind` use the proven one and ABORT on `.unreadable`; only `boundPresetID` (a picker's selection) stays tolerant, with the reason written down. Before: one dropped SSH round-trip answered "no tenant", a fresh `scarf:<slug>` was minted, and every task already on that board was orphaned — the downstream guarded write could not tell, because the value it got looked like a legitimate first mint. `readProven` uses `inspect` (not `inspectDecoding`), so undecodable bytes stay `nil` and QUARANTINE remains the write path's job — a read must not have that side effect. #projects #dataloss
- [constraint] A UNIQUENESS SET IS A PROOF, NOT A BEST EFFORT. `allMintedTenants` answered `[]` for an unreadable `projects.json` and skipped siblings whose manifests failed to load, so a candidate slug "wasn't used" only because we failed to look. It now throws on both; a PROVABLY absent registry (`probeExistence`) still legitimately yields no tenants. Cost: on a bare project the mint path pays the stat+retry probe instead of one `fileExists` — a user-action-only path, never a watcher tick.
- [decision] `HermesFileService.loadMemory`/`loadUserProfile` were `readFile ?? ""`, and the Mac memory editor's conflict check compared the user's baseline against that: a blip presented as `.conflict(onDisk: "")` — "the file changed to empty, reload to take the new version" — and the reload-then-save published emptiness THROUGH the guard, because by then the file read fine. **The guard was being bypassed by the UI it protects.** They now return `GuardedTextFile.Loaded`; a failed read is `.failed`, never a conflict, and `MemoryViewModel.reload` returns `nil` rather than `""`. The conflict check's `Loaded` is threaded into `saveMemory(after:)`, so the save is ONE read (also closes PERF M3's double-read and the window between the two).
- [gotcha] `MemoryViewModel.loadError` never blanks `memoryContent`/`userContent` — the last successfully-read copy stays on screen. It cannot wedge: `load()` runs on appear and on every watcher tick, and a success clears it.
- [decision] `IOSMemoryViewModel` got the proof token (`isLoaded` / `canSave`), mirroring `SkillsViewModel`: a failed load no longer sets `text = ""` with Save one keystroke from re-arming. `hasUnsavedChanges` is `false` without the token, and `save()` refuses at the model level, not just in the toolbar. It deliberately does NOT reuse the load's proof for the write — an editor open for minutes would archive a stale `.bak`.
- [gotcha] A BARE `return` IN A WRITE PATH IS A SILENT SUCCESS. `SkillsViewModel.saveSkillContent`'s containment guard returned without setting `contentError`, and `saveEdit` reads "no error" as "saved" — so a rejected path closed the editor and dropped the edits with a confirmation. Every early return in a save must leave the failure channel set.
- [decision] `ProjectContextBlock.removeBlock` now RETURNS whether it rewrote anything, and `ProjectLifecycleService.cleanUpAfterRemoval` dropped its `fileExists` gate plus the before/after `try?` reads it used to diff. The publisher knows what it did; a caller reconstructing that from two unguarded reads gets "nothing changed" from a failure. An unreadable AGENTS.md is now a reported warning, not a silently clean removal.
- [decision] `ProjectConfigService.loadCachedManifest` inferred `nil` from `fileExists`, and the Configuration sheet renders `nil` as "this project isn't configurable" — a confident false statement about the project, told because a read failed. Proof-based now, with its own `ManifestCacheError.unreadable` rather than `GuardedStoreError`: nothing is being written, so "refusing to overwrite" is the wrong sentence to show someone who only opened a sheet.

- [decision] GW-F5 (SEC F3): the size cap is enforced by a `stat` BEFORE the read, whenever `maxBytes` is finite. A capped inspection therefore costs `stat` + `read` — one extra SSH round-trip on healthy remote loads — accepted because iOS is remote-ONLY, so a local-only rule would jetsam-proof nobody, and the stat is free locally. `maxBytes: Int.max` skips the probe entirely and stays at exactly ONE read. An over-cap file is `.unreadable` with NO bytes and NO `.corrupt-` copy (we never held it), so BOTH damage policies refuse on size — `.quarantineAndRebuild` freezes rather than replacing a file it never saw, which is the accepted availability-for-integrity side of the trade. Uncapped survivors to watch: `ProjectContextBlock.maxAgentsBytes`, `ProjectTemplateInstaller.inspectMemory` #dataloss



## GW-F6 (t-26bf60b8): the last E5 lows — a refusal you can retry, and reads that stop inferring

Commit 10c3475f. Closes DI M5/M6/M7/M8/M10, L1/L2/L4/L5/L6/L8/L9/L10, PERF H1/H2/M2/M5, and the F5 handoff's two `Int.max` caps.

- [decision] A NON-REFUSAL WRITE FAILURE IS ITS OWN STATE. `ServerRegistry.saveFailure` (separate from `storeDamage`) surfaces a save the guard ALLOWED and the filesystem rejected — disk full, read-only volume, permissions. It was a bare `logger.error`, so Scarf became an in-memory registry with no banner and the edit still on screen. Nothing is damaged, there is no quarantine copy to point at and no read to retry, so it gets its own banner and its own remedy (`retrySave()`); conflating it with the refusal banner would tell the user to go find a `.corrupt-` file that does not exist. #dataloss
- [decision] STICKY DAMAGE NEEDS A RETRY, AND THE RETRY MUST RE-INSPECT. `ServerRegistry.retryLoad()` replaces the E2b note's "damage is sticky for the process lifetime" caveat: it runs the full proof-based inspection again (never re-tests the cached verdict — GW-F2's rule), and then either publishes the session's pending edits over the recovered file (with the recovered bytes landing in `.bak`) or, when nothing was pending, adopts the disk. The banner copy "until it can read it again" was a lie until this existed.
- [gotcha] `refusedSave` IS A FACT ABOUT THE SESSION, NOT ABOUT THE INSPECTION. A retry that finds the file still damaged must carry it forward, or the NEXT retry sees "nothing pending", adopts the disk, and discards edits the user was told were safe in memory. Caught by test, not by review.
- [decision] `importEntries` returns `persisted` / `persistFailure` off a new `SaveOutcome`, and the alert says "Imported into this session only" when the save was refused or failed. It used to title "Imported 3 servers" regardless — the green-checkmark-for-failure shape GW-F4 removed everywhere else, surviving in a summary line.
- [decision] `ProjectConfigService` is a `GuardedSidecarStore` conformer with `.refuseForever` DECLARED. Running `GuardedJSONStore` directly meant undecodable bytes arrived as `.quarantined`, `existingRoot` came back nil, and `save` rebuilt from `root = [:]` — every `keychain://` reference gone, with no pointer left to the secrets. This is the M8 case for "declare the policy on the protocol rather than hand-rolling the branches": the same three `if case .unreadable` checks became sufficient the moment the policy was declared. Dead `cacheManifest` (an unguarded installer-era write nothing called) deleted with it. #dataloss
- [gotcha] A JSON OBJECT THAT IS NOT A MANIFEST IS REPAIRED, NOT EXTENDED (L4). `ProjectManifestStore.setField` spliced its key into whatever object it found, producing a file that still would not decode — so the preset binding "succeeded" while the Configuration editor kept reporting the project unconfigurable. It now overlays the caller's sentinel keys when the existing object fails to decode as a manifest, keeping every foreign key. Refusing was the alternative and was rejected: neither caller can offer the user a repair.
- [decision] ENOENT IS POSITIVE PROOF OF ABSENCE (L1). `TransportError.isNoSuchFile` (SSH normalizes its stderr to the phrase; `LocalTransport` maps `NSFileReadNoSuchFileError` onto it) lets `GuardedJSONStore.inspect` answer `.absent` from the read error itself — one round-trip cheaper AND an actual answer, where before absence was two correlated failures over one SSH channel. Everything that is NOT ENOENT still falls through to the stat probe; that residual is now documented in place rather than merely known. #transport
- [gotcha] ZERO BYTES IS DAMAGE FOR JSON AND LEGAL FOR MARKDOWN — INCLUDING IN THE BOOTSTRAP GATES (L2). `SkillBootstrapService` and `SlashCommandBootstrapService` run bundled markdown through `GuardedJSONStore`, so a user who truncated a bundled `SKILL.md` made it permanently un-repairable: unreadable ⇒ skip, forever, on every launch. Both now apply `GuardedTextFile`'s rule 1 (reclassify zero-bytes to `.absent`) exactly as `ProjectContextBlock.writeBlock` and `inspectMemory` already did.
- [decision] `GuardedTextFile.Loaded`'s memberwise init is INTERNAL (L5). It is the proof token `write` consumes; a public init made it forgeable from any module, and a forged one waves through the blank-buffer publish the token exists to prevent. Tests reach it via `@testable`, which is the intended door.
- [fact] `AGENTS.md` and `MEMORY.md` (installer) now carry the 32 MB house cap. `Int.max` was justified as "prose, not an index we decode" — but that argues for a GENEROUS bound, not none, and since F5 `Int.max` additionally SKIPS the stat probe, so an agent-writable file of any size was held whole before anyone could object. The uncapped-survivors list in the F5 note above is now empty.
- [decision] `.env` FORM LOADS TAKE PROOF (L10). `HermesEnvService.loadProven()` throws on a stat-confirmed-unreadable file; `load()` keeps the tolerant `?? [:]` for render-only callers (`PlatformsViewModel`'s "which platforms look configured", commented as such). All 14 platform setup forms go through `PlatformSetupHelpers.loadEnv`, which puts the refusal in the form's existing GW-F4 message bar. The write was already safe — `unset` refuses while the file is unreadable — but the transient case (read blips, write a moment later succeeds) turned a blank form into a commented-out API key.
