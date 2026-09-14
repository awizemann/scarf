---
title: Decoding bridged Swift error codes: NIOCore.ChannelError error 0 = connectTimeout; Citadel hard-codes a 10s SSH login timeout
type: note
permalink: scarf/operations/decoding-bridged-swift-error-codes-niocore-channelerror
source_paths: [scarf/Packages/ScarfIOS/Sources/ScarfIOS/SSHClient+ExecCompletion.swift, scripts/verify-ios-transport-pool.sh]
source_paths_inferred: true
source_sha: b114f72fcfbabf7abe398123c841957874af59eb
created: 2026-07-18
updated: 2026-09-14
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

## Observations

- [fact] Swift bridges enum errors to NSError with `code` = the enum's ABI tag, and the ABI numbers PAYLOAD cases first (in declaration order), then no-payload cases. So "NIOCore.ChannelError error 0" is `connectTimeout(TimeAmount)` (ChannelError's first payload case) — NOT `connectPending`, which declaration order would suggest. For payload-free enums the tag equals declaration order: "Citadel.SSHClientError error 4" = `allAuthenticationOptionsFailed` (= the server rejected the offered key and Citadel's one-shot offer list is exhausted). Decode against the vendored source in `scarf/Packages/ScarfIOS/.build/checkouts/` before theorizing. #gotcha #triage
- [fact] Citadel (0.12.x) hard-codes `ClientHandshakeHandler(loginTimeout: .seconds(10))` in `SSHClientSession.addHandlers`, and the timer starts at channel-INIT time — so the 10s window must cover TCP connect + key exchange + auth. A cold Tailscale path on cellular (CGNAT usually starts DERP-relayed until NAT traversal warms) routinely exceeds it → deterministic "error 0" on cellular while wifi/LAN (direct, sub-second) works. `SSHClientSettings.connectTimeout` (30s default) only covers the TCP dial, not the login window. #gotcha #tailscale
- [fact] Fix shipped as `SSHConnectPolicy` (ScarfIOS): retry `SSHClient.connect` up to 3 attempts ONLY on `ChannelError.connectTimeout` (other errors propagate immediately — retrying rejected auth can trip OpenSSH 9.8+ per-source penalties), 1.5s pause; by attempt 2 the tunnel is warm. Applied in all three funnels: `ConnectionHolder.openSSH` (pooled transport), `ACPClient+iOS.openSSHClient` (chat), `CitadelSSHService.runOneShotProbe` (onboarding test). Final failures are wrapped in readable text via `describeConnectFailure` instead of the bridged "error N" forms. CRITICAL when retrying: build a FRESH `SSHAuthenticationMethod` per attempt — it's a stateful class whose offer list is consumed (`removeFirst()`) on use; a reused instance turns a timeout retry into a spurious `allAuthenticationOptionsFailed`. Same trap exists upstream: Citadel's own `recreateSession` (reconnect modes) reuses the consumed instance, so never use `SSHReconnectMode.once/.always` with a single-offer auth method. #pattern
- [todo] Follow-up option if 3×10s still isn't enough for very slow relays: pre-connect the TCP channel ourselves (own ClientBootstrap), then `SSHClient.connect(on:settings:)` so the 10s login window excludes TCP establishment — needs verification that NIOSSH handshakes correctly when handlers are added to an already-active channel. #idea

- [fact] "NIOCore.ChannelError error 6" = `alreadyClosed` (tag order: connectTimeout 0, illegalMulticastAddress 1, multicastNotSupported 2, then no-payload cases connectPending 3, operationUnsupported 4, ioOnClosedChannel 5, alreadyClosed 6, outputClosed 7, inputClosed 8, eof 9). Seen 2026-09-14 on the iOS Dashboard ("Connection issue … error 6") against a HEALTHY host: Citadel's `withExec` (TTY.swift:456) calls `channel.close()` unconditionally after the closure, but the inbound stream only ends at `ExecCommandHandler.handlerRemoved`, i.e. once the child channel is already closed, and NIOSSH fails a close on a closed child channel with `alreadyClosed` (`SSHChildChannel._actuallyClose0`). So every exec whose command finished before the closure returned threw after collecting its output, and a non-zero exit's `CommandFailed` was replaced by the same error. Introduced by P48 (36395fc4, moved both iOS execs onto `withExec` so timeouts close their channel); chat survived only because its channel stays open all session. Fix (717ce959): `SSHClient.withExecTolerantClose` in `SSHClient+ExecCompletion.swift` — closure's own error wins, an `alreadyClosed` from the trailing close is dropped; live regression test `fastExecCompletesInsteadOfThrowingAlreadyClosed` (needs `scripts/verify-ios-transport-pool.sh`-style ephemeral sshd). Rule: never call raw `client.withExec` in ScarfIOS. #gotcha #triage


## Relations
- relates_to [[iOS runtime SSH keys must resolve per server entry — singleton Keychain load() picks the wrong key (gh#133)]]
- relates_to [[iOS transport must be pooled per (ServerID, SSHConfig) — un-pooled makeTransport churns SSH connections]]
