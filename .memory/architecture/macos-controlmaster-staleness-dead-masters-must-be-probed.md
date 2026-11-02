---
title: macOS ControlMaster staleness: dead masters must be probed and reset, nothing self-heals (gh#123)
type: note
permalink: scarf/architecture/macos-controlmaster-staleness-dead-masters-must-be-probed
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift]
source_paths_inferred: false
source_sha: 178b92c056ebda6d04e15fb81c822a7fe87e35a4
created: 2026-07-12
updated: 2026-07-12
reviewed: 2026-11-01
reviewed_by: audit:claude-code (background)
---

## Observations

- [root-cause] macOS multiplexes ALL ssh (chat connect, pollers, file reads) through one OpenSSH ControlMaster (`ControlMaster=auto`, `ControlPersist=600`, socket at `/tmp/scarf-ssh-<uid>/%C`, SSHTransport.swift:152-170). When the TCP behind the master dies (sleep/wake, network change) but the master lingers, EVERY subsequent ssh hangs on the corpse for its full timeout; ACP `initialize` blows its 60s budget and the UI sits on the loading screen. #gotcha
- [why-remove-readd-fixed-it] The ONLY pre-fix `-O exit` caller was `ServerRegistry.removeServer` (ServerRegistry.swift:144). Quit+relaunch didn't help because the socket dir persists in /tmp and the launch sweep (`sweepStaleControlSockets`) only removes sockets >30min old; "retried a few times and it worked" = the master's 600s ControlPersist finally expired. #gotcha
- [fix] `SSHTransport.recoverControlMasterIfDead(probeTimeout:)` delegates to read-only `checkControlMaster()`, which runs `-O check` (does a master own the socket? local, fast) → only then a trivial muxed `ssh host true` probe with `gate: .none` → returns `ControlMasterHealth` enum. `recoverControlMasterIfDead` calls `-O exit` only when the probe returns `.dead`. Healthy masters are never dropped — important because a live ACP chat shares the master's TCP; blind `-O exit` on wake would kill healthy chats. #pattern
- [call-sites] (1) ChatViewModel remote start-failure catches + before the reconnect loop (`recoverRemoteTransportAfterFailure`) — makes plain retry/auto-reconnect do what remove/re-add did; (2) `ServerLiveStatusRegistry.observeAppLifecycle` on `NSWorkspace.didWakeNotification` (3s network-settle delay, then probe each registered remote off-main). NSWorkspace notifications post on `NSWorkspace.shared.notificationCenter`, NOT `.default` — a `.default` observer silently never fires. #gotcha
- [zombie-socket-is-harmless] A socket file whose master PROCESS is gone does not hang ssh — OpenSSH prints "disabling multiplexing" and falls back to a direct connection. The dangerous state is a LIVE master with a dead TCP path. `-O check` distinguishes them.

## Relations
- relates_to [[ios-transport-must-be-pooled-per-serverid-sshconfig-un]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
