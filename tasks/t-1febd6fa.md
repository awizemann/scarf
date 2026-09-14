---
id: t-1febd6fa
title: Delete resolved WS-* TODO comments + stale doc comments
status: todo
added: 2026-09-02
priority: low
---

## Description

The 2026-09-02 WS-verify sweep closed WS-2/4/5/6/7/8 against Hermes v0.21 source; ~8 resolved TODO comments remain in code and should be deleted (some files were in another agent's flux at sweep time — re-check line numbers):
- TODO(WS-2-Q7)/TODO(WS-2-Q1): Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:459,768; scarf/Features/Chat/ViewModels/ChatViewModel.swift:1207; Scarf iOS/Chat/ChatView.swift:1666.
- TODO(WS-8) resolved: SettingsViewModel.swift:478; HermesConfig.swift:257. Keys confirmed: tts.xai.voice_id (hermes_cli/setup.py:1318-1320), tts.xai.auto_speech_tags (tools/tts_tool.py:2124-2125).
- ~~ACPMessages.swift:337 + ACPClient.swift:535 — compressionCount TODO~~ **DONE in P49 (commit `c718237d`)** for the `ACPClient.swift` half: `TODO(WS-8-Q1)` is gone, replaced by the walk — the ACP `session/prompt` `Usage` is five keys at every tag (`acp_adapter/server.py:325-336` @ v2026.3.30 = 0.6.0, `:1050-1059` @ v2026.5.7 = 0.13.0, `:917-924` @ v2026.9.7) and carries no compression count, so the chip can never fire over ACP on any host. The tolerant camelCase/snake_case decode and the `hasContextCompressionCount` gate were deliberately KEPT (landing pad for a future gateway/`session/update` path; `SessionInfoBar.swift:380` reads it and the `> 0` test hides a never-sent field). `HermesCapabilities.hasContextCompressionCount` and `RichChatViewModel.acpCompressionCount` doc comments were corrected in the same commit. **Still open: `ACPMessages.swift:337`** — check whether its TODO says the same thing and give it the same citation.
- HermesConfig.swift:1482-1490 doc-comment says openrouter.response_cache.enabled; actual key is scalar openrouter.response_cache (parser correct at Parsing/HermesConfig+YAML.swift:574-584; hermes_cli/config_defaults.py:1063-1079).
- HermesFileService.swift:419 comment "mcp add only understands --url" — v0.21 also has --command/--preset (doc drift only; Scarf's surgical YAML insert remains the only path for transport/sse_read_timeout).
- Ed25519KeyGenerator.swift:31 doc line "see the FIXME comments in that file" — the FIXME is gone from CitadelSSHService.swift; fix the dangling reference.

## Plan



## Artifacts



