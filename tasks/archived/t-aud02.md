---
id: t-aud02
title: **[t-aud02]** Explicit `Task.detached` capture lists — FIXED. Added `[weak self]` + `guard let self` inside each `await MainActor.run` across `MCPServersViewModel` (9 sites) and `PluginsViewModel` (2; `[weak self, fileService]`), matching the house pattern at MCPServersViewModel L63. `RichChatInputBar` is a struct View where `[weak self]` is invalid, so `encode`/`presentImagePicker` were restructured to a `Task {}` (inherits @MainActor for @State) wrapping an inner `Task.detached` capturing only Sendable `data`/`url` — no self across the isolation boundary. Verified: app BUILD SUCCEEDED, zero NEW warnings (the 3 shown all pre-date this change).
status: archived
---

## Description



## Plan



## Artifacts



