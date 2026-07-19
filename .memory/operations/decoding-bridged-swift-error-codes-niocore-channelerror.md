---
title: Decoding bridged Swift error codes: NIOCore.ChannelError error 0 = connectTimeout; Citadel hard-codes a 10s SSH login timeout
type: note
permalink: scarf/operations/decoding-bridged-swift-error-codes-niocore-channelerror
created: 2026-07-18
updated: 2026-07-18
---

## Observations

- [fact] Swift bridges enum errors to NSError with `code` = the enum's ABI tag, and the ABI numbers PAYLOAD cases first (in declaration order), then no-payload cases. So "NIOCore.ChannelError error 0" is `connectTimeout(TimeAmount)` (ChannelError's first payload case) — NOT `connectPending`, which declaration order would suggest. For payload-free enums the tag equals declaration order: "Citadel.SSHClientError error 4" = `allAuthenticationOptionsFailed` (= the server rejected the offered key and Citadel's one-shot offer list is exhausted). Decode against the vendored source in `scarf/Packages/ScarfIOS/.build/checkouts/` before theorizing. #gotcha #triage
- [fact] Citadel (0.12.x) hard-codes `ClientHandshakeHandler(loginTimeout: .seconds(10))` in `SSHClientSession.addHandlers`, and the timer starts at channel-INIT time — so the 10s window must cover TCP connect + key exchange + auth. A cold Tailscale path on cellular (CGNAT usually starts DERP-relayed until NAT traversal warms) routinely exceeds it → deterministic "error 0" on cellular while wifi/LAN (direct, sub-second) works. `SSHClientSettings.connectTimeout` (30s default) only covers the TCP dial, not the login window. #gotcha #tailscale
- [fact] Fix shipped as `SSHConnectPolicy` (ScarfIOS): retry `SSHClient.connect` up to 3 attempts ONLY on `ChannelError.connectTimeout` (other errors propagate immediately — retrying rejected auth can trip OpenSSH 9.8+ per-source penalties), 1.5s pause; by attempt 2 the tunnel is warm. Applied in all three funnels: `ConnectionHolder.openSSH` (pooled transport), `ACPClient+iOS.openSSHClient` (chat), `CitadelSSHService.runOneShotProbe` (onboarding test). Final failures are wrapped in readable text via `describeConnectFailure` instead of the bridged "error N" forms. CRITICAL when retrying: build a FRESH `SSHAuthenticationMethod` per attempt — it's a stateful class whose offer list is consumed (`removeFirst()`) on use; a reused instance turns a timeout retry into a spurious `allAuthenticationOptionsFailed`. Same trap exists upstream: Citadel's own `recreateSession` (reconnect modes) reuses the consumed instance, so never use `SSHReconnectMode.once/.always` with a single-offer auth method. #pattern
- [todo] Follow-up option if 3×10s still isn't enough for very slow relays: pre-connect the TCP channel ourselves (own ClientBootstrap), then `SSHClient.connect(on:settings:)` so the 10s login window excludes TCP establishment — needs verification that NIOSSH handshakes correctly when handlers are added to an already-active channel. #idea

## Relations
- relates_to [[iOS runtime SSH keys must resolve per server entry — singleton Keychain load() picks the wrong key (gh#133)]]
- relates_to [[iOS transport must be pooled per (ServerID, SSHConfig) — un-pooled makeTransport churns SSH connections]]
