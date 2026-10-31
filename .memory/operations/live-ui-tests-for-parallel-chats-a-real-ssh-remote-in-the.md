---
title: Live UI tests for parallel chats: a real SSH remote in the VM, and what they exposed
type: note
permalink: scarf/operations/live-ui-tests-for-parallel-chats-a-real-ssh-remote-in-the
tags: [testing, ui-tests, parallel-chats, vm]
source_paths: [scarf/scarfUITests/ParallelChatsLiveUITests.swift, scripts/ui-gate-vm.sh]
source_paths_inferred: false
source_sha: 79a77949b48a9c24e284aa47aa9f07cefec2ba62
created: 2026-10-30
updated: 2026-10-30
---

## Observations
- [fact] For the Live plan scripts/ui-gate-vm.sh seeds a real SSH remote in scarf-ui: the guest's own sshd on 127.0.0.1, a throwaway key, a copy of the fixture home and one servers.json entry (cmd-2), so budget journeys need no fake #testing #vm
- [gotcha] The sandboxed XCUITest runner can't run ps or pgrep, so the gate writes a once-a-second list of hermes acp processes the tests read via SCARF_UITEST_ACP_PROCS #testing
- [gotcha] Hermes's approval default acts as smart in tests (tool result says auto-approved by smart approval); a test that needs the approval sheet must write approvals.mode manual into its isolated home's config.yaml #testing #hermes
- [gotcha] macOS confirmationDialog shows only three action buttons plus OK, so a dialog with one button per chat hid the fourth chat and Wait; use a sheet when the button count can exceed three #swiftui
- [gotcha] Every chat numbers transcript groups and local messages from the same start, and the bubbles skip their bodies on equal ids, so a transcript view shared across chats paints the last chat's text; ChatTranscriptPane gives the list .id(focusedChat.id) #swiftui


- [gotcha] Delete retries only Hermes's turn-still-running refusals ("Cannot delete active session", "queued or running turn", v0.22.5 only); "No session" on a later chain segment counts as already deleted, because v0.22.5 deletes a gateway-local conversation whole from any segment #hermes
- [fact] An approval raised while the budget sheet is up takes the window from it, and the budget question returns once the approval is answered; neither is lost (covered by testApprovalRaisedBehindTheBudgetSheetAppearsWhenItCloses) #swiftui
- [gotcha] On gateway-backed Hermes a turn outlives its hermes acp viewer unless Scarf sends session/cancel: process count 0 doesn't prove a turn stopped, so wait out the turn and check state.db #hermes #testing
