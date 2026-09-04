---
title: Transport atomic-write parity is a per-transport contract, not a property of writeFile
type: note
permalink: scarf/architecture/transport-atomic-write-parity-is-a-per-transport-contract
tags: [transport, atomicity, projects, ios, dataloss]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/TransportPrivateMode.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift]
source_paths_inferred: false
source_sha: feebb3c6a0446ee737233fe1a61621a876c3bc38
created: 2026-09-04
updated: 2026-09-04
---

t-a6f22379 (Projects D3), from the P7 transport-divergence probe. Every projects-data guard — salvage, quarantine, lossy/empty refusal, `.bak` — assumes `transport.writeFile` publishes atomically. Two of the three implementations honored that; nobody had checked the third, and two writers bypassed `writeFile` entirely.

Verified by `TransportAtomicityParityTests` (14 tests, ScarfCore).

## Observations
- [constraint] `ServerTransport.writeFile` MUST stage to a NONCE-suffixed sibling and rename; a new transport owes this before any upstream guard means anything. Local `.atomic`; SSH scp→`<path>.scarf-<nonce>.tmp`+`mv`; iOS Citadel SFTP stage+rename. iOS Citadel opened the DESTINATION with `.truncate` and streamed 32KB chunks until t-a6f22379 — a dropped cellular link left AGENTS.md / session map / cron jobs.json a fragment, and no guard can see damage it caused itself. #transport #dataloss
- [gotcha] SFTP v3 `SSH_FXP_RENAME` is NOT POSIX rename: OpenSSH's sftp-server FAILS when the destination exists, so Citadel falls back to remove-then-rename — but ONLY after two proofs (t-e2cd2861, P8 DI-H1): the plain rename is retried once, then the destination is probed for existence. The first version displaced the destination on ANY rename error, so a dropped link deleted the user's file and then failed the retry too. That policy now lives in `SFTPRenamePublisher.publish` (same file), closure-injected so it is unit-tested without a live SFTP server. If the second rename fails the staged temp is the ONLY copy of the bytes — it is deliberately LEFT on the far side and named in the thrown error, never cleaned up. #ios
- [gotcha] A CONSTANT staging name (`path + ".scarf.tmp"`) makes the publish atomic and the staging shared: two writers interleave bytes in one temp file and the second `mv` atomically publishes corruption. Every transport's temp name carries a per-write nonce. #transport
- [constraint] `TransportPrivateMode.shouldEnforce` (public, ScarfCore) is the ONE 0600 basename list for all three transports, applied chmod-BEFORE-publish so the file is never observable at its real path in a loose mode. Citadel enforced no mode at all before t-a6f22379. Non-private remote replaces now carry the destination's existing mode over to the staged copy (best effort) so `scp`'s umask can't re-permission a file. #security
- [gotcha] Every SSH exec path needs `-T`; `runRemoteShell` (readFile/stat/ls/mv/watch) lacked it, so a user's `RequestTTY yes` or a chatty `~/.zshenv` interleaved banner text into `cat` output — read as corruption, quarantined a healthy registry, churned `.bak` per save. #remote

## Relations
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]
- relates_to [[Project mutations report failure; registry damage banner is signature-dismissed]]
