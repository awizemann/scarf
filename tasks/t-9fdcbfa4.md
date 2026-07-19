---
id: t-9fdcbfa4
title: TestFlight: NIOCore.ChannelError error 0 on cellular/Tailscale — SSH login timeout retry
status: done
added: 2026-07-18
---

## Description

TestFlight feedback (2026-07-17): Dashboard "Connection issue — NIOCore.ChannelError error 0" over Tailscale on cellular only. Decode: Swift bridges enum error codes by ABI tag (payload cases first), so ChannelError error 0 = connectTimeout, NOT connectPending. Citadel hard-codes loginTimeout .seconds(10) in ClientHandshakeHandler, and the clock starts at channel init — it must cover TCP connect + kex + auth. Cold Tailscale cellular paths (CGNAT → DERP relay) exceed 10s; wifi/LAN is direct. Fix: retry-on-connectTimeout (up to 3 attempts) in ConnectionHolder.openSSH + ACPClient+iOS.openSSHClient — by attempt 2 the tunnel is warm; wrap final failure in a readable TransportError instead of raw "error 0". Follow-up option: pre-connected-channel connect so the 10s window excludes TCP establishment.

## Plan



## Artifacts



