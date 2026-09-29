# Open GitHub issues → Scarf 3.5.0 fixes (2026-09-29)

Scope decided with Alan: #146, #147, #148, #145 ship in 3.5.0 (release notes updated). #142 is planned in a separate session. #140/#141 need replies only. Nothing is posted to GitHub or upstream without Alan's approval of the exact text. Charter applies (C1 gating, C3 no state.db writes, C5 verify hermes argv, C10 nothing heavy on main actor).

Each phase runs in its own git worktree/branch; the orchestrator merges into main sequentially. Mac tests run serially (see memory operations/mac-scarftests-run-green-only-serially…).

## P1 — #146 honest resume of non-ACP sessions (Mac + ScarfGo)
Absorbs t-238d2ab3 (iOS swallows every load error) and t-e875803c (old-id Kanban tasks vanish).
- Before session/load, check the session's source (Hermes restores only `source == "acp"`: acp_adapter/session.py:428, server.py:616-624 in the tagged checkout). Reuse the Bot Chat check (BotConversationViewModel.swift ~209-278).
- Non-ACP session: don't attempt load; start a new session and show a PERSISTENT transcript notice naming the source: continues as a new session without the earlier context. Keep the old transcript visible.
- Load failure: fall back only on the specific not-restorable error; other errors surface an error/retry, not a silent new session. Log + analytics parity Mac/iOS.
- Kanban: tasks stamped with the old session id must not vanish silently (query both ids if the CLI supports it per tagged argparse, else an honest notice).
- Sites: ChatViewModel.swift ~1468, ~2337, ~2733; Scarf iOS/Chat/ChatView.swift ~2928, ~3323.

## P2 — #147 slash commands not offered over ACP
- `/title <name>`: client-side command → existing rename (ChatViewModel.renameSession ~3189, `hermes sessions rename`; verify argv against tagged argparse). Add menu row (Mac + iOS).
- `/retry`, `/undo`: never sent to the model; show the existing acpUnhandledSlashNotice-style note ("not available in Scarf chat yet — Hermes doesn't offer it to apps; use the Hermes CLI"). No client-side resend (would duplicate the turn in Hermes's history).
- Update the P34 "deliberately NOT here" comment, wiki/Slash-Commands.md, and task t-todo-retry.

## P3 — #148 total processing time per prompt
- Fix: finalizeStreamingMessage clears currentTurnStart at the first segment, so the pill shows time-to-first-text. Record once at prompt complete / cancel / error on the turn's last assistant message.
- Past sessions: derive from state.db message timestamps (user message → last assistant message of the turn), read-only. No new store.
- Mac + ScarfGo via ScarfCore.

## P4 — #145 mark branched sessions
- Expose branch lineage on HermesSession (reuse HermesDataService branch detection ~384-391, ~466-479; schema probe per C4).
- Badge in Mac Sessions list, chat sidebar session list, ScarfGo list; tooltip names the parent. Fork stays blocked on NousResearch/hermes-agent#124540.

## P5 — Upstream Hermes request (draft only)
Draft an issue asking hermes-agent to add retry, undo, title to acp_adapter/commands.py `_COMMANDS`, cited file:line. Alan approves before posting.

## P6 — Release notes + issue replies (drafts)
Update releases/v3.5.0/RELEASE_NOTES.md; draft replies for #140, #141, #145, #146, #147, #148 in Alan's voice.

## P7 — Orchestrator audit
Audit each phase against this plan, audit the memories agents wrote (keep/merge/retire), final fresh-eyes pass over the merged diff.
