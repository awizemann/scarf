---
title: ACP-Subprocess
type: note
permalink: scarf-wiki/acp-subprocess
updated: 2026-07-14
---

# ACP Subprocess

ACP — Agent Client Protocol — is Hermes's chat protocol: JSON-RPC 2.0 over stdio (or its bidirectional equivalent). Scarf's Rich Chat surface speaks ACP end-to-end. There is no SQLite polling involved in chat; tokens, thoughts, tool calls, and permission prompts all stream live from the channel.

## ACPClient + ACPChannel

[`ACPClient`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift) is an `actor` that owns whatever-it-is that ferries JSON-RPC bytes back and forth, and exposes an `AsyncStream<ACPEvent>`. The "whatever-it-is" is abstracted behind the [`ACPChannel`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPChannel.swift) protocol so Mac and iOS share the client without `#if os(...)`:

| Channel | Where it lives | What it wraps |
|---|---|---|
| [`ProcessACPChannel`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ProcessACPChannel.swift) | ScarfCore | A Foundation `Process` running `hermes acp` (local) or `ssh -T host -- hermes acp` (Mac remote). |
| [`SSHExecACPChannel`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfIOS/Sources/ScarfIOS/SSHExecACPChannel.swift) | ScarfIOS | A Citadel SSH exec channel (no Foundation `Process` available on iOS) — bidirectional stdin/stdout streams over the SSH transport. |

ACPClient consumes whichever channel the host provides at init; from there the protocol handling is identical.

## Process channel construction (Mac)

`ProcessACPChannel` is created via `transport.makeProcess(executable: "hermes", args: ["acp"])`:

- **Local:** spawns `hermes acp` with `HermesFileService.enrichedEnvironment()` so MCP servers and shell tools find brew/nvm/asdf binaries on `PATH`. `TERM` is removed so terminal escapes don't pollute JSON-RPC.
- **Remote:** the transport returns `/usr/bin/ssh -T <opts> host -- hermes acp`. `SSH_AUTH_SOCK` is inherited so the GUI-launched Scarf reaches the user's ssh-agent. `TERM` is removed.

`-T` (no PTY) is critical — without it stdin/stdout would be PTY-cooked and the JSON-RPC framing would break.

## SSH exec channel construction (iOS)

`SSHExecACPChannel` opens a Citadel exec channel against the user's configured Hermes host, runs `hermes acp` over it, and surfaces the channel's `inbound` / `outbound` byte streams as the same stdin/stdout abstraction `ACPClient` consumes from `Process`. There's no PTY allocation — Citadel's exec is binary-clean by default.

Because iOS's PATH is stripped on non-interactive SSH (Citadel doesn't source rc files — see [Transport Layer § CitadelServerTransport](Transport-Layer)), the channel inlines `PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"` in front of `hermes acp` exactly the way `runProcess` does. Same fix, same reason.

## Lifecycle

| Phase | What happens |
|---|---|
| `start()` | Creates the event stream first, builds and configures the Process, attaches pipes, installs the termination handler, calls `proc.run()`, starts read loops for stdout/stderr, sends `initialize`, starts a 30-second keepalive ping (`{"jsonrpc":"2.0","method":"$/ping"}`). |
| `newSession(cwd:)` / `loadSession(cwd:sessionId:)` | Two modes: fresh (`session/new`) or load an existing session (`session/load`) — the latter is also the reconnect path. Each updates `currentSessionId`. A `loadSession` that comes back empty means the session isn't restorable; callers fall back to `newSession`. There is no `resumeSession` — it was removed because Hermes's `session/resume` silently creates an orphan server-side session when given an unknown id, while a failed load is detectable (background: repo memory note *chat-session-layer mechanism map and 2026-07-13 diagnosis*). |
| `sendPrompt(sessionId:text:)` | Sends `session/prompt` with the user text; returns `ACPPromptResult` with token usage and stop reason. **No timeout** — streaming may run for minutes. Tokens, thoughts, tool calls, and permission requests arrive as events on the stream while this awaits. |
| `cancel(sessionId:)` | Sends `session/cancel` to interrupt an in-flight prompt. |
| `respondToPermission(requestId:optionId:)` | Sends a JSON-RPC response to an incoming `session/request_permission` request. |
| `stop()` | Cancels background tasks, finishes the event continuation, closes stdin (subprocess sees EOF), sends SIGINT, watchdogs to SIGTERM after 2 seconds, closes pipes. |

## Event stream

Consumers iterate `for await event in client.events`:

```swift
enum ACPEvent: Sendable {
    case messageChunk(sessionId, text)         // assistant token chunk
    case thoughtChunk(sessionId, text)         // reasoning/thinking token chunk
    case toolCallStart(sessionId, call)        // tool invocation began
    case toolCallUpdate(sessionId, update)     // tool invocation finished/updated
    case permissionRequest(sessionId, requestId, request)  // user approval needed
    case promptComplete(sessionId, response)   // session/prompt resolved
    case availableCommands(sessionId, commands)  // /commands the agent advertises
    case connectionLost(reason)
    case unknown(sessionId, type)
}
```

Events are extracted from incoming JSON-RPC notifications matching `method: "session/update"`. The `sessionUpdate` discriminator inside `params` selects the case (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, etc.).

## Permission requests (bidirectional)

Most chat traffic is agent → client. Permission requests reverse direction — the agent sends an incoming JSON-RPC **request** with `method: "session/request_permission"`:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "session/request_permission",
  "params": {
    "sessionId": "...",
    "toolCall": { ... },
    "options": [
      {"optionId": "allow",  "name": "Allow"},
      {"optionId": "deny",   "name": "Deny"}
    ]
  }
}
```

The client emits `ACPEvent.permissionRequest`. The UI (Rich Chat) shows a sheet; once the user clicks an option, `respondToPermission(requestId: 42, optionId: "allow")` sends back:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "outcome": {"kind": "allowed", "optionId": "allow"}
  }
}
```

## Internals

- **Read loop** runs detached: `availableData` → buffer → split on `\n` → JSON-decode each line → `handleMessage`.
- **Stderr loop** captures the subprocess's stderr into a 50-line ring buffer for attaching to user-visible errors.
- **Pending requests dict** maps JSON-RPC `id` → `CheckedContinuation<AnyCodable?, Error>`. Responses resume the matching continuation; the read loop dispatches them by `id`.
- **30-second control-message timeout** fires for `initialize`/`session/new`/etc. There is no timeout on `session/prompt` — that one streams for as long as the model takes.
- **`safeWrite(fd:data:)`** handles partial writes and EPIPE; used for both prompt sends and keepalive pings.
- **Disconnect cleanup** is single-pathed via `performDisconnectCleanup(reason)`. Three callers: stdout EOF (`handleReadLoopEnded`), process termination (`handleTermination`), write failure (`handleWriteFailed`). All three resume pending requests with `processTerminated` and finish the event continuation.

## Error hints

Raw error messages are noisy. `ACPErrorHint` (in the same file) pattern-matches across the error message and the stderr ring buffer to attach actionable hints:

| Pattern matched | Hint surfaced |
|---|---|
| "No credentials found" / `ANTHROPIC_API_KEY` | "Set `ANTHROPIC_API_KEY` in `~/.hermes/.env`" |
| "No such file or directory" + binary name | "Binary not on `PATH`; check `~/.zprofile` exports" |
| "Rate limit" / 429 | "AI provider rate-limited; try again later" |

---
_Last updated: 2026-07-14 — Scarf main (`resumeSession` removed from ACPClient; session attach is `session/new` / `session/load` only. Previously 2026-04-25 / v2.5.0: ScarfCore extraction + ACPChannel abstraction + iOS SSHExecACPChannel section)_