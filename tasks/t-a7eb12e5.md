---
id: t-a7eb12e5
title: Audit P55: capability floors r6 — hasKanban 0.13, hasMCPIdentityHeader 0.20.1, hasBotChatCreationCLI 0.20.5, /goal /subgoal mirror
status: done
added: 2026-09-12
priority: high
---

## Description

Round-6 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round6.md, capabilities section). Relates t-54ec6eb3 (~47 flags still un-walked). Needs round-6 product decisions 3–5.

- HIGH · PRE · `hasKanban` (`HermesCapabilities.swift:83`) floored 0.12; `hermes_cli/kanban.py` does not exist at v2026.4.30 (0.12.0 — `RELEASE_v0.12.0.md:438` says the board was reverted in #16098); first at v2026.5.7 = 0.13.0 (`commands.py:163`). On a 0.12 host `SidebarView.swift:54`, `ProjectCockpitView.swift:248,270`, `SidebarProjectsWell.swift:499`, iOS `ProjectDetailView.swift:70` light up and every `hermes kanban` argv routes to the agent (C5). Fix: `atLeastSemver(0,13,0)` + four-test group.
- MED · PRE · `hasMCPIdentityHeader` (`:1392`) `isV0204OrLater`; `identity_header`, `strict_redirect_headers`, stdio `cwd` all at v2026.8.13 = 0.20.1 (`tools/mcp_tool.py:40,:1523,:2705`), absent v2026.8.3. Consumer `MCPServerEditorView.swift:67`. Fix: `isV0201OrLater`.
- MED · PRE · `hasBotChatCreationCLI` (`:1576`) `isV021OrLater`; `--query-file` at v2026.8.19 = 0.20.5 (`hermes_cli/_parser.py:307-314`), absent v2026.8.18. Consumer `BotConversationView.swift:27`. Fix: `isV0205OrLater`.
- MED · PRE · `/goal` and `/subgoal` (`ChatViewModel.swift:1325,:1358`; iOS `ChatView.swift:1709,:1737`) are ungated optimistic mirrors (`recordActiveGoal`/`recordSubgoalAdded`, "Goal locked" toast, `SessionInfoBar` pill) for slash names in `_COMMANDS` at NO tag (`acp_adapter/commands.py:44-66` @ v2026.9.7; `server.py:163-173` @ v2026.5.7). The text goes to the LLM verbatim on every host. Decision 3: drop the mirrors + `default:` notice, or keep the pill labelled Scarf-local. Move `maybeTriggerKanbanOnboarding()` with the winner; resolve `TODO(WS-2-Q7)`.
- LOW · PRE · `disableAliases` includes `off` (`PowerSettingsWriter.swift:40`); Hermes's set is `{"none","false","disabled"}` at every tag from v2026.7.7 (`hermes_constants.py:816` … `:885` @ v2026.9.7). Bare `off` is PyYAML `False` → fine; quoted `"off"` is ignored by Hermes (falls to `medium`) and Scarf's reader unquotes so no notice fires. Decision 4.
- LOW · PRE · `hasHermesAudit` doc (`:730`) names `hermes audit` (no such verb; would route to the agent); the verb is `hermes security audit` (`HealthViewModel.swift:818`). Doc fix; floor 0.15 correct.
- LOW · PRE · `hasGatewayAllowlists` (`:262`, v0.13) hides `allowed_channels` (Discord) and `allowed_chats` (Telegram), both present at v2026.4.30 = 0.12 (`gateway/config.py:770-771`); only `allowed_rooms` is v0.13. Consumers `GatewayBehaviorSection.swift:49`, iOS `SettingsView.swift:433`. Decision 5: per-platform floor or accept and document.
- Follow-on: 38 flags re-walked this round (3 wrong, 8%); ~47 remain on t-54ec6eb3. Lesson: the worst defect (`hasKanban`) had nine consumers and a doc citing a RELEASE not a tag.

## Plan



## Artifacts

Commits on `fix/whole-surface-audit-r6`: **`ac135138`** (three re-floored capability flags + the three doc-only decisions), **`a275f59a`** (round-6 decision 3 — the `/goal` and `/subgoal` mirrors, Mac + iOS) and **`9d2c151e`** (the new notice's `Localizable.xcstrings` row + its catalogue test — the P54b trap, caught in the fresh-eyes pass).

Per finding:
- **HIGH `hasKanban` 0.12 → 0.13 — FIXED.** `hermes_cli/kanban.py` absent at v2026.4.30 (0.12.0), `kanban` ×0 in that tag's `commands.py`/`main.py`; present at v2026.5.7 (`commands.py:163`, `main.py:5278`/`:9232-9237`). Moved into the v0.13 MARK group, tombstone left in v0.12's. Five consumers enumerated in the flag doc with the per-range C1 argument.
- **MED `hasMCPIdentityHeader` 0.20.4 → 0.20.1 — FIXED.** `identity_header` (`:40`,`:1335`,`:1389`), `strict_redirect_headers` (`:3035`), stdio `cwd` (`:2705`) all at v2026.8.13; all absent at v2026.8.3. Group header corrected (no member is a genuine v0.20.4 floor now).
- **MED `hasBotChatCreationCLI` 0.21 → 0.20.5 — FIXED.** `--query-file` at `_parser.py:308` @ v2026.8.19, absent v2026.8.18; the rest of the argv present at v2026.8.19.
- **MED `/goal` + `/subgoal` mirrors — FIXED (decision 3).** Mirrors, pill, subgoal badge, toasts, iOS chip and both `case` arms deleted; `RichChatViewModel.acpUnhandledSlashNotice(name:)` (capability-free) fires from `default:`; `maybeTriggerKanbanOnboarding()` moved there behind `ChatViewModel.goalArgumentDescribesATarget`. `TODO(WS-2-Q7)` and `TODO(WS-2-Q1)` resolved by deletion. Filed **`t-e9c464a9`** to gate a real door if a tag adds either name to the ACP `_COMMANDS` table.
- **LOW `off` in `disableAliases` — DELIBERATELY NOT FIXED (decision 4).** One doc paragraph names the quoted-vs-bare PyYAML gap with `hermes_constants.py:816` @ v2026.7.7 / `:885` @ v2026.9.7.
- **LOW `hasHermesAudit` doc — FIXED.** Verb is `hermes security audit` (`main.py:12358`/`:12363`/`:6218-6225` @ v2026.5.28); floor 0.15 re-confirmed (file absent v2026.5.16); `HealthViewModel`'s parser comment now cites the floor tag v2026.5.28 rather than v2026.5.29 (same blob).
- **LOW `hasGatewayAllowlists` — DELIBERATELY NOT FIXED (decision 5).** v0.13 kept; doc carries the walk, and corrects the report: at v2026.4.30 only Discord's `allowed_channels` (`gateway/config.py:770-771`) exists — Telegram has only `group_allowed_chats` there — so the one-release hide costs ONE key, not two.

Tests: ScarfCore full **3173 in 262** (one pre-existing `ProcessDrainP43Tests` load flake; passes in isolation, 14/1); `--filter HermesP55` **22 in 3**; Mac serial `HermesP55GoalArmTests` + `ChatViewModelSendDedupTests` + `HermesP38SourceSweepTests` **13 in 3**, and `HermesP55GoalArmTests` + `HermesP55CatalogueTests` + `BannerCatalogueP54bTests` **10 in 3**; `scarf` Debug and `scarf mobile` build clean. 28 new tests in 5 suites; the Mac behavioural suite recorded 5 issues across 3 tests against a re-planted `case "goal":` arm before the plant was reverted.

Memory: P55 + P55b sections appended to `decisions/hermes-v0-21-1-compatibility-decisions`; edits to `architecture/hermes-capability-gating-pattern`, `architecture/the-acp-adapter-s-slash-roster-is-nine-names-and-has-been`, `architecture/kanban-board-architecture-v2-7-5`, `decisions/bot-mode-phase-a-decisions`, `decisions/Hermes v0.15 Capability Gating Decisions`, and `scarf-wiki/Sidebar-and-Navigation`.

Not widened: the ~47 un-walked flags stay on `t-54ec6eb3`.

