---
title: The ACP adapter's slash roster is nine names and has been since v2026.3.17
type: note
permalink: scarf/architecture/the-acp-adapter-s-slash-roster-is-nine-names-and-has-been
tags: [hermes, acp, chat, capability-gating, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-10
updated: 2026-09-13
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
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
- [gotcha] Gating the MENU is only half the gate — the user can still type the name. P44: one predicate (RichChatViewModel.nonInterruptiveSlashIsDispatched) serves both the roster filter and the send path, which must not paint an optimistic mirror or suppress the working indicator for a name the adapter will hand to the LLM #acp
- [gotcha] `/queue` on an IDLE session does NOT run "after the current turn". `_queue_prompt` appends unconditionally (`acp_adapter/commands.py:33-36` @ v2026.9.7; `:285-290` is `_cmd_queue`) and the ONLY drain is the tail of a running turn (`server.py:908-915`), so an idle `/queue` would run two turns later. P44b: both send paths snapshot the working state BEFORE the local echo (`addUserMessage` raises the flag itself), and `RichChatViewModel.idleQueueFallbackText` sends the ARGUMENT as an ordinary prompt with a localized `idleQueueNotice` — leaving the `/queue` prefix on the wire would hand it straight back to `_cmd_queue`. An empty argument is left to Hermes's own `Usage:` line #acp
- [gotcha] `/steer <args>` on an IDLE session is an ORDINARY TURN. Hermes's `_rewrite_prompt_for_interrupt` (acp_adapter/server.py:667-689 @ v2026.9.7) strips the prefix when idle (`:686`), leaving the text to run as a real turn through `_run_agent_turn`, so an optimistic message treating it as steering would suppress the working indicator over a real turn. P46: `RichChatViewModel.idleSteerIsOrdinaryPrompt` guards the treatment when idle with non-empty args; `idleSteerNotice` paints a localized notice and the ARGUMENT runs as an ordinary prompt (no fallback-message pattern like `/queue`). An EMPTY argument is left to `_cmd_steer` untouched and returns Hermes's own `Usage:` line #acp
- [fact] `hasACPSteerOnIdle` is RETIRED (round-4 decision 14, P44). It was `hasACPSteer` expressed a second time — the idle fallback shipped in `/steer`'s own commit (`server.py:812-820` @ v2026.5.7) — and since P37 the roster hides `steer` below that floor, so its only reader (the idle-steer grey-out arm) was unreachable. `HermesP44Tests.hasACPSteerOnIdleIsGoneFromTheCapabilitySurface` pins the removal #capabilities
- [fact] help/model/tools/context/reset/version are in _SLASH_COMMANDS from v2026.3.17 (0.3.0), below the v0.6.0 support floor, so they need no HermesCapabilities flag #capabilities
- [fact] Scarf consumes available_commands_update into RichChatViewModel.acpCommands and dedupes by name, so alwaysAvailableCommands only fills the pre-advertisement gap (session/load, cold start) #scarf
- [constraint] yolo, sessions, codex-runtime, reload-skills, clear, exit are CLI/gateway-only and cost has never existed in Hermes at all — never put them in an ACP menu #hermes

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]


- [fact] **P49 deleted `hasYOLOSlashCommand`** (round-5 decision 10). It had no consumer after P34 removed the slash-menu row, and `yolo` still appears nowhere under `acp_adapter/` at any tag — so no ACP surface could ever gate on it. Its verified floor is preserved as a comment in `HermesCapabilities.swift`: `CommandDef("yolo", …)` is absent from `hermes_cli/commands.py` at v2026.3.30 (0.6.0) and first appears at `hermes_cli/commands.py:96` @ **v2026.4.3 (0.7.0)**, `:181` @ v2026.9.7. `hasSessionsSlashCommand` and `hasCodexRuntimeSlashCommand` survive with their v0.14 floors and their doc comments no longer link the deleted symbol #capability-gating
- [fact] **`session/set_model` is NOT a roster question and never had a floor.** `set_session_model` is a method on the adapter, not a slash name: `acp_adapter/server.py:466` @ v2026.3.17 (0.3.0, the earliest tag with an `acp_adapter/`), `:482` @ v2026.3.30 (0.6.0, Scarf's supported minimum, with a working body that rebuilds the agent and saves the session), `:929` @ v2026.9.7. P49 retired `hasACPSetSessionModel` on that walk #capability-gating


- [fact] **P55 dropped the `/goal` and `/subgoal` optimistic mirrors** (round-6 decision 3, 2026-09-13). Both ARE real Hermes commands — `/goal` in the TUI/gateway from `hermes_cli/commands.py:103` @ v2026.5.7 and `/subgoal` from v2026.5.16 — which is why the pill survived five audit rounds; but neither has ever been in the ACP table at ANY tag (`_SLASH_COMMANDS` `acp_adapter/server.py:163-173` @ v2026.5.7, `_COMMANDS` `acp_adapter/commands.py:44-66` @ v2026.9.7 — nine names each, and NOT the same nine: `compact` at v2026.5.7 is `compress` by v2026.9.7. Neither roster ever carried `goal` or `subgoal`, which is the claim that matters here; "the same nine names" was a P55 overstatement corrected in P55b), so over ACP the text was always an ordinary prompt. Gone: `RichChatViewModel.activeGoal`/`activeSubgoals`/`recordActiveGoal`/`recordSubgoal*`/`parseGoalArgument`/`parseSubgoalArgument`/`truncatedToastGoal`, the `HermesActiveGoal` model, the `SessionInfoBar` pill (+ `truncatedGoal`/`goalTooltip`/`onClearGoal`), the iOS `goalChip` + `supportsActiveGoal`, and both `case` arms on Mac and iOS. In their place `RichChatViewModel.acpUnhandledSlashNotice(name:)` — capability-free, because no host version answers differently — fires from the `default:` arm alongside P44's `subFloorSlashNotice`. `TODO(WS-2-Q7)` and `TODO(WS-2-Q1)` are resolved by deletion. A real door needs a new floor at the tag that adds the name to the ACP table: `t-e9c464a9` #acp #capability-gating
- [gotcha] **"It is a real Hermes command" is not the question — "is it on the ACP table" is.** The `/goal` mirror outlived four audits because every check confirmed the verb exists in Hermes (it does, from 0.13) and none asked which SURFACE Scarf speaks to. For a chat feature the roster that matters is `acp_adapter/`'s alone, and for a CLI feature it is argparse's; a command that is real in the TUI is still an ordinary prompt over ACP #acp #verification
