---
title: Chat
type: note
permalink: scarf-wiki/chat
updated: 2026-07-14
created: 2026-05-29
---

# Chat

Two modes share the same sidebar item: **Rich Chat** (real-time ACP streaming with iMessage-style bubbles) and **Terminal** (the `hermes chat` CLI rendered with full ANSI color in an embedded terminal). Switch between them in the chat toolbar.

## Rich Chat

Streams tokens, thoughts, and tool calls live via the [ACP subprocess](ACP-Subprocess). No DB polling — when Hermes emits a message chunk, you see it immediately.

**What it renders:**

- Rust-tinted bubbles in the v2.5 design (UnevenRoundedRectangle for the user; bordered card with a sparkles gradient avatar for the assistant). User text in `ScarfColor.onAccent`; assistant in `ScarfColor.foregroundPrimary` over `ScarfColor.backgroundSecondary`.
- Markdown content (links, lists, code blocks, tables).
- **Reasoning / thinking** chunks in a warning-tinted disclosure block ("REASONING" uppercase label) above the answer.
- **Tool calls** as inline cards with kind-tinted borders + uppercase tracked labels (READ / EDIT / EXECUTE / FETCH / BROWSER) using `ScarfColor.success` / `info` / `warning` / `Tool.web` / `Tool.search`. Expanded JSON in a bordered `backgroundSecondary` panel.
- **Permission requests** as modal sheets — Hermes asks before executing risky tools; you choose Allow / Deny. **Numbered keyboard shortcuts** _(v2.5+)_: 1–9 bind to the option buttons on Mac (visible "1. " / "2. " prefixes); approve / deny without reaching for the mouse. iOS shows the same numbered hints as a hierarchy cue without the keyboard binding.
- **Per-turn stopwatch** _(v2.5+)_ — wall-clock duration of each completed assistant turn renders as a compact pill (`4.2s` / `1m 12s`) on the bubble's metadata footer (Mac) or below the bubble (iOS). Resumed sessions loaded from `state.db` show no pill — timing is captured live only.
- **Git branch chip** _(v2.5+)_ — chat header shows the project's current git branch as a tinted chip alongside the project name (e.g. `📂 myproject · main`). One SSH `git rev-parse --abbrev-ref HEAD` per session start; nil-out gracefully on non-git dirs / missing git / SSH errors. Backed by [`GitBranchService`](Core-Services).
- **`/compress`** — when Hermes advertises the command via `availableCommands`, a one-click focus sheet appears in the toolbar.
- **`/steer <prompt>`** _(v2.5+)_ — non-interruptive mid-run guidance. Surfaces in the slash menu as a special command; sending it doesn't flip the "Agent working…" indicator (the agent's still on its current turn) and shows a transient toast above the composer: "Guidance queued — applies after the next tool call."
- **Slash-command menu** — type `/` and a floating menu appears above the input with every command Hermes has advertised via ACP's `available_commands_update`, any user-defined `quick_commands:` from `~/.hermes/config.yaml`, and any **project-scoped slash commands** _(v2.5+)_ from `<project>/.scarf/slash-commands/`. See [Slash Commands](Slash-Commands). ↑/↓ to navigate, Tab or Enter to complete, Esc to dismiss. Commands with argument hints (e.g. `/compress <topic>`) insert a trailing space so you can start typing the argument immediately.

**Session lifecycle:**

- Each new conversation creates a session via `session/new` (cwd = your local working directory if you set one).
- Resume an old conversation: pick from the session picker; Scarf calls `session/load` to replay it. If Hermes reports the session isn't restorable (an empty load result), Scarf falls back to a fresh `session/new` instead of attaching to a dead id.
- Auto-reconnect — if the subprocess dies, Scarf reattaches via `session/load` to pick up where it left off.

**Resilience** _(v2.5.2+, iOS-at-parity)_. Both Mac and iOS recover automatically when the SSH socket drops, the phone sleeps, or the network changes — Hermes keeps writing to `state.db` on the remote during the outage, and Scarf reattaches via `session/load` on a 5-attempt 1→2→4→8→16 s exponential backoff. The ladder is **load-only** — `session/resume` was removed because asking Hermes to resume an id it doesn't know silently creates an orphan server-side session, while a failed load is detectable and falls back to a fresh session (the deeper story is in the repo memory note *chat-session-layer mechanism map and 2026-07-13 diagnosis*). After a successful reconnect, both platforms reconcile from `state.db`: `reconcileWithDB` merges any messages the agent persisted while you were offline, and a "Resynced N new messages" toast surfaces what changed.

- iOS specifically gains a yellow **Reconnecting (n/5)…** banner during recovery and a red **No network** banner while reachability is unsatisfied (driven by `NWPathMonitor`).
- iOS observes scene-phase transitions through `ScarfGoCoordinator` so a chat tab that was unmounted while you were on Dashboard still picks up the background → active edge and verifies channel health on resume.
- Composer drafts persist across force-quit, keyed by `(serverID, sessionID)` in `UserDefaults`; a 7-day janitor at app launch prunes stale slots.

**Pagination** _(v2.5.2+)_. Initial load fetches the most recent 200 messages for a session (500 on the Mac Sessions detail view). Sessions with more on-disk history surface a "Load earlier messages" button at the top of the transcript. Pagination is keyed by message id (monotonic) so streaming-chunk timestamps that collide on the same millisecond never split a page.

**Offline-tolerant snapshots** _(v2.5.2+)_. When a fresh remote `state.db` snapshot pull fails, Scarf falls back to the last cached copy at `~/Library/Caches/scarf/snapshots/<server-id>/state.db` so Dashboard and Sessions stay viewable. The chat history reload path explicitly opts out of this fallback (`forceFresh: true`) — falling back there would silently hide messages the agent streamed during the outage.

**Voice mode controls:** PTT (push-to-talk), TTS playback, STT transcription preferences live in **Settings → Voice**. The chat toolbar exposes the basic toggles.

## Project context — your AGENTS.md in project chats _(v2.15+, Mac)_

Opening a chat **inside a project** now gives the agent that project's context automatically. Scarf spawns `hermes acp` with the **project directory as the process working directory**, and Hermes reads a project's context files (`AGENTS.md` / `CLAUDE.md` / `.cursorrules`, first match) from that working directory on session boot — so the agent starts already knowing the repo, its conventions, and the Scarf-managed project block, with no re-explaining.

This applies to every way a project chat starts — **new, resumed, reconnected, and auto-started** sessions. For resumed/reconnected chats the project path is recovered from the session-attribution sidecar (`SessionAttributionService`) before the subprocess spawns, including over SSH. The chat header's **project chip** (name + git branch) tells you at a glance which project a session is scoped to.

> **A note on trust.** Opening a chat in a project loads that project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` into the agent. Treat a project's context files like its code — **only open chats in projects you trust.** This is inherent to how Hermes works (`cd <repo> && hermes` does the same), and Hermes scans context files for prompt injection before loading them. [Mini-apps](Mini-Apps) deliberately do **not** load these files into their agent sessions, because they run less-trusted web content.

## Multimodal image input _(v2.6+, Hermes v0.12+)_

Hermes v0.12 advertises `prompt_capabilities.image = true` on ACP and accepts image content blocks in `session/prompt`. Scarf wires the producer side on both targets — capability-gated on `HermesCapabilities.hasACPImagePrompts` so v0.11 hosts never see the attachment surface.

- **Mac** — paperclip toolbar button on the composer opens NSOpenPanel multi-pick. Drag-and-drop and paste also work — drop an image (or a Finder file URL) onto the composer and it attaches.
- **iOS** — paperclip opens PhotosPicker (multi-select up to 5 photos).
- **`ImageEncoder`** (ScarfCore) downsamples to 1568px long-edge JPEG q=0.85, **detached only** so encoding never blocks MainActor. A 12 MP screenshot lands under ~300 KB on the wire. Total payload stays under ~2 MB so cellular sends don't time out.
- **Per-attachment chips** above the input field with thumbnail + filename tooltip + X to remove. Hard cap of 5 images per message.
- **Image-only sends are valid** — once at least one attachment is queued, the send button enables even with empty text. Vision models accept "describe this" with no caption.

Hermes routes the prompt to a vision-capable model automatically — no extra Scarf-side work to pick the right aux model. The wire shape is `[{"type":"text","text":...}, {"type":"image","data":"<base64>","mimeType":"image/jpeg"}]` matching `acp.schema.ImageContentBlock`.

## Per-session edit-approval modes _(v2.10.0+, Hermes v0.15+)_

A chat-header chip switches a **live** session between three edit-approval modes via ACP `session/set_mode`:

- **Default** — ask before edits (Hermes prompts on each file mutation).
- **Accept Edits** — auto-allow workspace + `/tmp` edits without prompting.
- **Don't Ask** — auto-allow everything **except sensitive paths**, which always still prompt.

This is **distinct from the global `approvals.mode` / YOLO surface** (Settings → Security and the YOLO warning chip): it scopes only to the current session and doesn't touch `config.yaml`. Sensitive paths (credentials, keys, `~/.hermes/` internals) prompt regardless of mode. Capability-gated on `HermesCapabilities.hasSessionEditAutoApproval` — pre-v0.15 hosts hide the chip and keep the global approval behavior unchanged.

## Chat-scoped Kanban chip _(v2.10.0+, Hermes v0.15+)_

The chat header surfaces a Kanban chip that opens a board filtered to **just the tasks this session created**. v0.15 stamps every Kanban task with the originating ACP `session_id`, so the board it opens uses a precise `--session` filter rather than the old tenant + time-window approximation — session tasks the agent created without tagging the project tenant are no longer dropped. A **"This chat ⇄ All tasks"** scope toggle widens the view to the whole board (the pill renders even for global chats with no project tenant, so a session-scoped board isn't locked to the session filter). Capability-gated on `HermesCapabilities.hasKanbanSessionFilter`; pre-v0.15 hosts fall back to the v2.7.5 tenant-scoped board. See [Sidebar and Navigation](Sidebar-and-Navigation) for the full board surface.

## Per-message TTS playback _(v2.6+, Mac)_

Small speaker glyph in each settled assistant bubble's metadata footer. Tap to read the reply aloud through `AVSpeechSynthesizer` with the user's macOS Spoken Content default voice — works offline. Tap again (or any other bubble's button) to stop. Markdown control characters (`**`, ` ` ` `, `[text](url)`) are stripped before speech so the user doesn't hear "asterisk asterisk bold". The deeper Settings → Voice provider integration (Edge / ElevenLabs / OpenAI / NeuTTS / Piper) is queued as a v2.7 follow-up. Issue [#66](https://github.com/awizemann/scarf/issues/66).

## Background completion notifications _(v2.6+, Mac)_

Sending a long prompt and switching to other work no longer requires polling the chat. New `ChatNotificationService` fires a local `UNUserNotificationCenter` banner on prompt completion when Scarf isn't the foreground app. Body is the assistant reply's first line trimmed to ~140 chars; heading is the active session title. Settings → Display → Feedback → "Notify when Hermes finishes" toggle (default on). `/steer`-style mid-run sends don't notify — they don't end a turn. Issue [#64](https://github.com/awizemann/scarf/issues/64).

## Chat density preferences _(v2.5.1+, Mac)_

**Settings → Display → Chat density** has three Scarf-local controls that change how the chat is rendered. They're independent of the Hermes config flags one section below (`Show Reasoning`, `Show Cost`, `Compact`) — those gate what Hermes EMITS, these gate how Scarf RENDERS what was emitted.

- **Tool calls** — `Full card` (today's expandable card per call), `Compact chip` (one-line tappable chip per call — kind icon + function name + status dot — opening the right-pane inspector with the same details), `Hidden` (per-call rows skipped; the always-visible group summary pill stays and becomes tappable so the inspector is still one click away).
- **Reasoning** — `Disclosure box` (today's yellow box), `Inline (italic)` (italic faded caption text inline above the reply with a small brain prefix — same data, far less vertical space), `Hidden` (reasoning text not rendered; per-message token count stays visible in the bubble's metadata footer).
- **Chat font size** — 85% to 130% slider (5% step). Originally set only `\.dynamicTypeSize`, but ScarfFont tokens are fixed-point so dynamic type didn't reach bubble text, reasoning, tool chips, code blocks, or markdown headings on Mac. v2.6 introduces a separate `\.chatFontScale` env value plumbed from `RichChatView` through `RichMessageBubble`, `MarkdownContentView`, and `CodeBlockView`; `ChatFontScale.{body, caption, captionStrong, caption2, mono, monoSmall, codeBlock, codeInline}(_:)` helpers mirror the ScarfFont base sizes so 100% is byte-for-byte identical to today's UI. The slider now actually moves the visible chat content. Issue [#68](https://github.com/awizemann/scarf/issues/68).

Defaults match today's UI exactly so existing users see no change until they opt in. Per-turn stopwatch, per-message tokens, finish reason, and timestamp stay in the bubble metadata footer in every density mode; SessionInfoBar's input/output/reasoning tokens, USD cost, model, project, and git branch are unaffected. See issues [#47](https://github.com/awizemann/scarf/issues/47) and [#48](https://github.com/awizemann/scarf/issues/48) for the original asks and the full preservation audit.

## Streaming performance _(v2.5.1)_

Pre-2.5.1 long chats progressively bogged down because every streamed ACP token rebuilt the full message-group array AND every `MessageGroupView` / `RichMessageBubble` re-evaluated its body. v2.5.1 caps per-chunk work at O(1) for settled groups via `Equatable` + `.equatable()` short-circuits, plus a trailing-group patch helper that replaces the per-chunk full rebuild. ScarfGo's chat (different rendering path — `LazyVStack` directly over `controller.vm.messages`) gained an iOS-equivalent `MessageBubble: Equatable`. Issue [#46](https://github.com/awizemann/scarf/issues/46).

## Chat-start model preflight _(v2.5.2+, Mac)_

When chat-start hits a server whose `config.yaml` has no `model.default` / `model.provider`, the upstream provider returns an opaque `Model parameter is required` 400 only **after** the user types a prompt and hits send. New `ModelPreflight` (in ScarfCore) catches the missing keys before any ACP work; `ChatView` presents the existing `ModelPickerSheet` via a thin `ChatModelPreflightSheet` wrapper so the picker / validation / Nous-catalog branch stay single-sourced. `ChatViewModel` writes the selection via `hermes config set` and replays the original `startACPSession` arguments — the chat the user originally opened lands without re-clicking the project row. Note: `HermesConfig.empty` and the YAML parser's missing-key fallback both use the literal string `"unknown"`, so the check treats `""` and `"unknown"` as equivalent.

## ScarfGo chat resilience _(v2.5.2+, iOS)_

ScarfGo now survives phone-sleep, network handoffs, and SSH socket drops without losing the agent's work. Hermes already persists messages to `state.db` in real-time; iOS just had no resync path pre-2.5.2.

- **5-attempt exponential reconnect** (1 → 2 → 4 → 8 → 16s) via `session/load` — load-only, no `session/resume` (see **Resilience** above for why). On success, `reconcileWithDB` merges any messages the agent emitted while disconnected, and a *"Resynced N new messages"* toast surfaces above the composer.
- **`NetworkReachabilityService`** (NWPathMonitor singleton) suspends reconnect attempts while offline; kicks a fresh cycle on link-up. Two banner states render slim ScarfDesign-tinted strips above the message list — `.reconnecting` (yellow) and `.offline` (grey) — so the user always knows what the chat is doing.
- **Scene-phase aware** — returning the app to foreground triggers a channel-health check; if dead, reconnect starts immediately rather than waiting for the next interaction.
- **Draft persistence** per (server, session) survives force-quit; UserDefaults-backed with a 7-day janitor at app launch.
- **Cached-snapshot fallback** at the transport layer (`ServerTransport.cachedSnapshotPath`) — `HermesDataService` falls back to the prior snapshot when a fresh pull fails, so Dashboard / Sessions / Activity stay readable while disconnected. `isUsingStaleSnapshot` + `lastSnapshotMtime` surface to views as *"Last updated X ago."*

## Bounded message-history paging _(v2.5.2+)_

`HermesDataService.fetchMessages(sessionId:limit:before:)` paginates by id desc with centralized `HistoryPageSize` constants. `RichChatViewModel.loadEarlier()` walks back through long sessions via `oldestLoadedMessageID` + `hasMoreHistory`. Pre-fix the message fetch was unbounded — sessions with thousands of messages were doing a full-history load on every reconnect.

## Skeleton-then-hydrate chat loader _(v2.8+, Mac)_

Resuming a chat on a slow remote used to fetch every column the bubble might need (`content` + `tool_calls` JSON + `reasoning_content`) in one shot, which routinely tripped the 30s SSH timeout on chats with multi-page tool result blobs. v2.8 splits the load into two phases:

1. **Skeleton.** `fetchSkeletonMessages` selects only user + assistant rows (skips `role='tool'`) with `tool_calls`/`reasoning`/`reasoning_content` hard-NULLed at the SQL level. Wire payload bounded by conversational text alone — typically a few KB. The chat appears in seconds.
2. **Background hydrate.** `RichChatViewModel.startToolHydration()` pages through `hydrateAssistantToolCalls` in 5-id batches to splice tool-call JSON into the existing assistant messages. Tool-result CONTENT is opt-in (Settings → Display → "Load tool results in past chats", default off) — without it, tool call cards still render, and the inspector pane lazy-fetches per-result content via `fetchToolResult(callId:)` when you open it.

The chat header surfaces "Loading tool details…" while hydration is in flight. If a 5-id batch trips the 30s timeout (an oversized `tool_calls` blob — long Edit args, big diffs), an L1 single-id retry isolates the whale so the rest of the batch still hydrates. The whale row stays bare; the assistant message is still readable.

## Partial-result + chat error banners _(v2.8+, Mac)_

When the skeleton fetch itself trips an SSH transport failure (rather than a clean empty result), the chat surfaces "Couldn't load full chat history — the connection to *server* timed out" through the existing `acpError` triplet so the user sees what happened instead of a silent empty transcript. A separate banner detects `model.default` / `model.provider` mismatches in `config.yaml` (e.g. `model.default: anthropic/...` with `model.provider: nous` after switching OAuth providers via Credential Pools) and offers a one-click fix in either direction. The ACP error classifier also recognizes `model_not_found` / `404 messages` / `model is not available` and surfaces "This session was created with a model the provider no longer offers — start a new chat" so the pinned-model failure mode has a clear recovery path.

## Loading-state UX during session boot _(v2.8+, Mac)_

The Mac chat sidebar greys out and disables row taps the moment a session-switch is initiated (synchronously, before `client.start()` returns), with a floating ProgressView showing the current phase: "Spawning hermes acp…" → "Authenticating…" → "Loading session…" → "Loading history…" → "Ready". Pre-fix the sidebar looked engageable while the 5-7 second SSH+ACP boot was still in flight, and the user could queue up a second session-switch behind the first. The new gating prevents that contention.

## SSH cancellation propagation _(v2.8+, Mac)_

Cancelling a Swift Task used to leave the underlying ssh subprocess running for the full 30s SSH timeout — `Task.detached` doesn't inherit cancellation from the awaiting parent, so `proc.terminate()` was never called. This pinned remote sqlite queries and ControlMaster sessions when the user navigated away mid-load. v2.8 wires `withTaskCancellationHandler` through `SSHScriptRunner.run` and `RemoteSQLiteBackend.query`; cancellation now reaches the `Process` within ~100ms (the poll-loop interval). Fires `ssh.cancelled` in ScarfMon traces. Fixes the "third chat hangs" / "dashboard spins after rapid switching" symptom.

## iOS keyboard dismissal _(v2.5.1+)_

Pre-fix the chat composer's `TextField` had no keyboard dismissal at all — the keyboard would rise and stick, hiding the system tab bar (which iOS auto-hides while a keyboard is up) and trapping users in the Chat tab. v2.5.1 adds two redundant dismissal paths:

- `.scrollDismissesKeyboard(.interactively)` on the message list — drag the messages downward to collapse the keyboard with the gesture.
- A `keyboard.chevron.compact.down` button in the keyboard accessory toolbar above the system keyboard.

Either dismisses the keyboard, the system tab bar reappears, and the user can switch tabs again. Issue [#51](https://github.com/awizemann/scarf/issues/51).

## Terminal mode

The full `hermes chat` CLI rendered in an embedded SwiftTerm terminal:

- ANSI color and Rich formatting work as in your shell.
- WhatsApp / Signal pairing flows render their QR codes here for scanning.
- Useful when you need a feature only the CLI exposes (e.g. obscure flags, daemon management).

## Cancellation

The Stop button sends `session/cancel` over the JSON-RPC channel. The model stops generating; any in-flight tool call completes. You can immediately send another prompt without restarting the session.

## Mac 3-pane chat (v2.5)

The Mac chat surface re-laid out as a three-pane composition:

- **Left pane** — sessions sidebar (search + project filter + the 50 most recent sessions). Right-click any row for Rename / Delete (when Hermes advertises those CLIs).
- **Middle pane** — transcript (the bubbles, reasoning, tool cards described above) + composer.
- **Right pane** — live inspector. Surfaces git branch, project chip, model + reasoning effort, total tokens / API calls / tool calls, and the current MCP server status.

iPhone keeps a single-column transcript — three panes don't translate to phone-width screens. iPad inherits the Mac layout via SwiftUI's adaptive sizing but hasn't been polished yet (deferred per [Platform Differences](Platform-Differences)).

## Multi-server chat

Each Mac window is bound to one server, so chat in window A talks to local Hermes while window B talks to a remote one. ScarfGo uses a single-window TabView; switching servers from the Servers list rebuilds the tab root against the new context. Sessions don't cross windows / contexts — they live on the server they were created on.

## Troubleshooting

- **"Spinning forever, no response"** — check the [Logs](Gateway-Cron-Health-Logs) view for ACP errors. Common causes: missing `ANTHROPIC_API_KEY` (Scarf attaches a hint), rate limit, or `hermes` binary not on `$PATH`.
- **Connection lost** — Rich Chat surfaces this banner; click Reconnect to reattach via `session/load`.
- **Permission sheet doesn't appear** — make sure Hermes's `approval_mode` in `config.yaml` is set so it asks (not auto-approve).

## Related pages

- [ACP Subprocess](ACP-Subprocess) for the protocol internals.
- [Memory & Skills](Memory-and-Skills) for editing what Hermes knows about you.
- [Settings — Voice tab](Gateway-Cron-Health-Logs) for TTS/STT configuration (Settings is documented there).

---
_Last updated: 2026-07-14 — Scarf main (reconnect is load-only: `session/resume` dropped from the ladder, reattach reconciles from `state.db`, non-restorable loads fall back to a fresh session. Previously 2026-06-28 / v2.15.0: project chats spawn hermes acp with cwd=project so AGENTS.md / CLAUDE.md / .cursorrules load automatically; trust note added)_