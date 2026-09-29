---
title: Chat /title is client-side rename; /retry and /undo are intercepted, never sent (gh#147)
type: note
permalink: scarf/decisions/chat-title-is-client-side-rename-retry-and-undo-are
tags: [slash-commands, chat, gh147]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Scarf iOS/Chat/ChatView.swift, scarf/scarf/Features/Chat/Views/ChatInspectorPane.swift]
source_paths_inferred: false
source_sha: 4beace9d6d71c2aae455ed7eae5b600642f0f3b0
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] /title <name> is a Scarf client-side slash (ClientSideSlashCommand.renameSession) running `hermes sessions rename -- <id> <title>`; ungated because rename exists at every tag (argparse sessions.py:252-255 @ v0.21.5) #slash #gh147
- [decision] /retry and /undo (RichChatViewModel.cliOnlySlashNames) are intercepted before the wire with cliOnlySlashNotice and NOT listed in the menu; no client-side resend because it would duplicate the turn in Hermes history #slash #gh147
- [gotcha] /title on a chat Hermes hasn't stored yet (no first turn, currentSession nil) must defer via pendingSessionTitle like /new <name>; renaming immediately fails #slash
- [gotcha] Mac intercepts /title and /retry in ChatViewModel.sendText before the no-client branch, else autoStartACPAndSend would spawn a session just to deliver them #slash
- [done] Tool-inspector disabled Re-run button (ChatInspectorPane footer) removed for the same reason #gh147

## Relations
- relates_to [[The ACP adapter's slash roster is nine names and has been since v2026.3.17]]
