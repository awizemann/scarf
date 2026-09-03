---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/scarf/Features/Chat, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP
source_paths_inferred: false
---

# Chat & Streaming — Rich ACP Protocol and Session Management

Chat is Scarf's primary interface to Hermes. The rich chat mode streams messages via the Agent Client Protocol (ACP) — live markdown, tool-call visualization, reasoning display, and permission prompts. A terminal mode alternative (`hermes chat` in a real terminal) also exists.

## ACP Protocol & ACPClient

`ACPClient` (`ScarfCore/ACP/ACPClient.swift:67`) is the chat protocol engine. It:
- Spawns a subprocess running `hermes acp` via `ProcessACPChannel` (`ACPClient.swift:312`).
- Sends `session/prompt` and `session/update` RPC calls as JSON-RPC 2.0 messages.
- Streams `ACPEvent` variants (text chunks, tool calls, permissions, etc.) parsed from the subprocess output.
- Handles approval-mode message flows (user must OK each tool call).

**Turn completion is `sendPrompt`'s return, not a stream event** — the event stream never yields `.promptComplete`. [[acp-turn-completion-is-sendprompt-s-return]]

## Chat Views (macOS)

`ChatSessionListPane` and `ChatTranscriptPane` (`scarf/Features/Chat/Views/`) render the conversation. Key views:
- **ActivityBubbleView** (`ActivityBubble.swift:23`) — A live-status card showing an in-flight tool call or reasoning block, with badges for retry count and a spinner.
- **ChatInspectorPane** (`ChatInspectorPane.swift:10`) — Tabbed inspector for session metadata, tool results, and model config.
- **ChatModelPreflightSheet** (`ChatModelPreflightSheet.swift:16`) — Model mismatch warnings before chat starts.

## Chat ViewModel (macOS)

`ChatViewModel` (`Features/Chat/ViewModels/ChatViewModel.swift:8`) orchestrates the chat:
- Receives user input from the view.
- Calls `ACPClient.sendPrompt()` with the message and attachments.
- Updates observable `messageGroups: [MessageGroup]` as ACP events arrive.
- Handles approval-mode permissions and tool-call rendering.
- Persists sessions to `state.db` after each turn.

**UI upsert throttling** — ACP chunks arrive ~30µs apart (tens of thousands/sec in bursts); per-chunk observable mutations would peg CPU. The view model throttles upserts to 50ms. [[streaming-chat-ui-upserts-are-throttled]]

## Transcript Segmentation

Assistant messages (markdown text + tool calls + reasoning) are partitioned into **segments** for cleaner rendering:
- `MessageGroup.transcriptItems(coalesceText:)` partitions messages into text bubbles and `ChatActivitySegment` runs (tool-call or reasoning blocks).
- Presentation-only; storage in `state.db` is untouched.

[[chat-transcript-activitybubble-segmentation]]

## Session Resume (Mac + iOS)

When reopening a session:
- `ACPClient` calls `session/load` to fetch the transcript from `state.db`.
- If the session is non-ACP-persisted (cron-created or CLI-created), `session/load` returns empty by design; Scarf falls back to `newSession`. [[ios-session-resume-must-fall-back-to-newsession]]
- Project chats load project context (AGENTS.md, CLAUDE.md, .cursorrules) by spawning `hermes acp` with `cwd=project.path`.

## iOS Chat (ScarfGo)

`ChatView` (`scarf/Scarf iOS/Chat/ChatView.swift:24`) is the iOS companion. Differences:
- Inline message composer (no detached sheet), keyboard-dismiss button.
- Same ACP backend; same session persistence.
- No project context (process-cwd gap unfixed on iOS). [[scarfgo-ios-does-not-load-project-context]]

## Testing Chat

`ACPClientTests.swift` (107 test files under `Tests/ScarfCoreTests/`) covers idempotence, bot-mode phases, and error handling via mock `GatedChannel` and `SpawnLedger` actors.