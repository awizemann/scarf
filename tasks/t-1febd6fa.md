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
- ACPMessages.swift:337 + ACPClient.swift:535 — compressionCount confirmed ABSENT from Hermes ACP through v0.21 (usage payload acp_adapter/server.py:2206-2214); rewrite the TODOs to state that fact or remove the plumbing (chip never fires over ACP; tolerant decode defaults 0 and hides it — safe).
- HermesConfig.swift:1482-1490 doc-comment says openrouter.response_cache.enabled; actual key is scalar openrouter.response_cache (parser correct at Parsing/HermesConfig+YAML.swift:574-584; hermes_cli/config_defaults.py:1063-1079).
- HermesFileService.swift:419 comment "mcp add only understands --url" — v0.21 also has --command/--preset (doc drift only; Scarf's surgical YAML insert remains the only path for transport/sse_read_timeout).
- Ed25519KeyGenerator.swift:31 doc line "see the FIXME comments in that file" — the FIXME is gone from CitadelSSHService.swift; fix the dangling reference.

## Plan



## Artifacts



