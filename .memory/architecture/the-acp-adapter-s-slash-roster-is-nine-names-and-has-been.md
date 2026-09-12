---
title: The ACP adapter's slash roster is nine names and has been since v2026.3.17
type: note
permalink: scarf/architecture/the-acp-adapter-s-slash-roster-is-nine-names-and-has-been
tags: [hermes, acp, chat, capability-gating, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: ca6ae1e8832242f31b5c6ccdd3b390186b1af8cb
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-10
reviewed_by: claude-opus-5
---
Scarf's chat composer speaks ACP, so the only slash table that matters for the composer menu is the ACP adapter's — never `hermes_cli/commands.py` (CLI/TUI) and never the gateway's. P34 walked `acp_adapter/` across all 32 `v2026.*` tags.

The dict lives at `acp_adapter/server.py` `_SLASH_COMMANDS` from v2026.3.17 (0.3.0 — the first tag that ships an `acp_adapter/` at all; v2026.3.12 / 0.2.0 has none) through v2026.8.31, and moves to `acp_adapter/commands.py` `SlashCommandsMixin._COMMANDS:44-66` at v2026.9.7, where `_available_commands():69-74` advertises exactly its keys.

Per-tag walk:
- `help model tools context reset version` — present at EVERY tag with an adapter, i.e. below Scarf's v0.6.0 support floor. No capability flag is ever needed for these.
- `steer`, `queue` — added at v2026.5.7 (0.13.0).
- compress command — `compact` through v2026.7.20 (0.19.0), `compress` from v2026.7.30 (0.19.1), no alias either way (`hasACPCompressSpelling`).

Nothing else has ever been an ACP name. `yolo`, `codex-runtime`/`codex_runtime`, `reload-skills` appear NOWHERE under `acp_adapter/` at any tag; `cost` has never existed anywhere in Hermes (the CLI verb is `usage`, `hermes_cli/commands.py:277`); `clear` (`:58`) and `exit` (`:302-303`, alias of `quit`) are `cli_only`; `sessions` (`:148`) and `codex-runtime` (`:156-158`) are CLI/gateway CommandDefs.

## Observations
- [invariant] The ACP adapter's whole slash surface is help/model/tools/context/reset/compact-or-compress/steer/queue/version — nine names, no more, at every v2026.* tag #hermes
- [gotcha] An unknown slash name is not an error over ACP: `_handle_slash_command` returns None and the text falls through to the LLM (acp_adapter/commands.py:88-95 @ v2026.9.7), so a dead menu row silently burns a turn #acp
- [fact] help/model/tools/context/reset/version are in _SLASH_COMMANDS from v2026.3.17 (0.3.0), below the v0.6.0 support floor, so they need no HermesCapabilities flag #capabilities
- [fact] Scarf consumes available_commands_update into RichChatViewModel.acpCommands and dedupes by name, so alwaysAvailableCommands only fills the pre-advertisement gap (session/load, cold start) #scarf
- [constraint] yolo, sessions, codex-runtime, reload-skills, clear, exit are CLI/gateway-only and cost has never existed in Hermes at all — never put them in an ACP menu #hermes

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
