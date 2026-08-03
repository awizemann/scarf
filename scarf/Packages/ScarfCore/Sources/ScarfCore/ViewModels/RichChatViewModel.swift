// Gated on `canImport(SQLite3)` — `RichChatViewModel` reads message
// history from `HermesDataService`, which is SQLite-gated. iOS + macOS
// compile this unchanged; Linux CI skips it.
#if canImport(SQLite3)

import Foundation
import Observation
import SwiftUI

public enum ChatDisplayMode: String, CaseIterable {
    case terminal
    case richChat
}

public struct MessageGroup: Identifiable {
    public let id: Int
    public let userMessage: HermesMessage?
    public let assistantMessages: [HermesMessage]
    public let toolResults: [String: HermesMessage]

    public var allMessages: [HermesMessage] {
        var result: [HermesMessage] = []
        if let user = userMessage { result.append(user) }
        result.append(contentsOf: assistantMessages)
        return result
    }

    public var toolCallCount: Int {
        assistantMessages.reduce(0) { $0 + $1.toolCalls.count }
    }

    /// Aggregated `ToolKind → count` over all assistant tool calls in
    /// this group. Lives on the model so SwiftUI's Equatable
    /// short-circuit (issue #46) covers it — previously this was a
    /// `MessageGroupView` computed property that re-walked O(m × k)
    /// per group on every body re-evaluation.
    public var toolKindCounts: [ToolKind: Int] {
        var counts: [ToolKind: Int] = [:]
        for msg in assistantMessages where msg.isAssistant {
            for call in msg.toolCalls {
                counts[call.toolKind, default: 0] += 1
            }
        }
        return counts
    }

    /// Render-side coalescing of consecutive pure-text assistant
    /// messages into a single bubble. A "pure-text" assistant has no
    /// `toolCalls`; consecutive runs of those collapse into one
    /// bubble so the user reads what was logically one reply as one
    /// bubble — even when Hermes recorded it as multiple `assistant`
    /// rows (a tool call may have run between them, or some thinking
    /// models emit one turn as multiple messages).
    ///
    /// Invariants:
    ///  - Tool-bearing assistants (any `toolCalls`) and tool-result
    ///    rows always render as their own bubbles — they're meaningful
    ///    boundaries, never merged.
    ///  - The streaming bubble (`id == 0`) is never coalesced into
    ///    its predecessors. Coalescing across the streaming boundary
    ///    would let mid-stream `body` re-evals churn the merged
    ///    content; keep it standalone until finalize, then the
    ///    next render naturally folds it into the run.
    ///  - The synthesized bubble inherits the LAST source message's
    ///    id, timestamp, finishReason, and tokenCount so the
    ///    metadata footer stays accurate and SwiftUI identity stays
    ///    stable through finalize.
    public var coalescedAssistantBubbles: [HermesMessage] {
        var output: [HermesMessage] = []
        var run: [HermesMessage] = []

        func canCoalesce(_ msg: HermesMessage) -> Bool {
            msg.isAssistant && msg.toolCalls.isEmpty && msg.id != 0
        }

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                output.append(run[0])
            } else {
                output.append(Self.merge(run))
            }
            run = []
        }

        for msg in assistantMessages {
            if canCoalesce(msg) {
                run.append(msg)
            } else {
                flushRun()
                output.append(msg)
            }
        }
        flushRun()
        return output
    }

    /// Merge a run of pure-text assistant messages into one synthesized
    /// `HermesMessage`. Content and reasoning channels are joined with
    /// blank-line separators; structural fields take the last source's
    /// values so the metadata footer reflects turn-end state.
    private static func merge(_ run: [HermesMessage]) -> HermesMessage {
        precondition(!run.isEmpty, "merge requires at least one message")
        let last = run[run.count - 1]
        let content = run.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let reasoning = run
            .compactMap(\.reasoning)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let reasoningContent = run
            .compactMap(\.reasoningContent)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return HermesMessage(
            id: last.id,
            sessionId: last.sessionId,
            role: last.role,
            content: content,
            toolCallId: nil,
            toolCalls: [],
            toolName: nil,
            timestamp: last.timestamp,
            tokenCount: last.tokenCount,
            finishReason: last.finishReason,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent
        )
    }
}

@Observable
public final class RichChatViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        // Quick-commands load happens in `reset()`, which every chat-start
        // path calls before the user can interact (iOS: ChatController.start;
        // Mac: ChatViewModel.startNewSession/resumeSession/continueLastSession).
        // Calling it here too caused two parallel SFTP reads of config.yaml
        // on iOS chat startup.
    }


    public var messages: [HermesMessage] = []
    public var currentSession: HermesSession?
    public var messageGroups: [MessageGroup] = []
    /// Trailing-window cap on how many `messageGroups` the chat list
    /// renders at once. Sits on top of `HistoryPageSize.initial` (which
    /// bounds DB I/O): even when `messageGroups` grows past this during
    /// a long live session, only the trailing slice materializes in the
    /// eager `VStack`. The "Load earlier" button bumps this in
    /// `RenderWindow.step` chunks via `extendRenderWindow()` before
    /// falling through to the DB-paging path.
    public var renderWindow: Int = RenderWindow.initial
    /// Trailing slice of `messageGroups`. Critical: this windows the
    /// existing groups array — do NOT rebuild groups from a windowed
    /// `messages` slice or `groupIndex` will renumber and break the
    /// `MessageGroupView.==` equatable short-circuit.
    public var visibleGroups: [MessageGroup] {
        guard messageGroups.count > renderWindow else { return messageGroups }
        return Array(messageGroups.suffix(renderWindow))
    }
    /// True when the in-memory `messageGroups` has more entries than
    /// the current `renderWindow` exposes — chat list shows the
    /// "Load earlier" button and tapping it grows the window before
    /// falling through to a DB hop.
    public var hasHiddenInMemoryGroups: Bool { messageGroups.count > renderWindow }
    /// Reveal another `RenderWindow.step` groups from the existing
    /// in-memory `messageGroups`. Pure derived-property change — no
    /// group rebuild, no I/O. Group ids stay stable so `ForEach`
    /// prepends old groups without recreating the visible tail.
    public func extendRenderWindow(by delta: Int = RenderWindow.step) {
        renderWindow = min(renderWindow + delta, messageGroups.count)
    }
    /// True while the v2.8 two-phase loader's background hydration
    /// (tool_calls JSON + tool result rows) is in flight. Chat header
    /// shows "Loading tool details…" so the user knows the bare
    /// transcript they're looking at will fill in. Cleared once both
    /// hydration passes finish or the session-id changes underneath.
    public var isHydratingTools: Bool = false
    @ObservationIgnored
    private var hydrationTask: Task<Void, Never>?

    /// UserDefaults key controlling whether the chat resume path
    /// auto-fetches the CONTENT of tool result rows (`role='tool'`) for
    /// past messages. Defaults false — a single tool result blob
    /// (file dump, stack trace) can be hundreds of KB; bulk-fetching
    /// all of them during chat resume on a slow remote can blow past
    /// the 30s SSH timeout. The Mac Settings → Display tab exposes
    /// the toggle (mirror string in `ChatDensityKeys`).
    public static let loadHistoricalToolResultsKey = "scarf.chat.loadHistoricalToolResults"
    /// True from the moment the user sends a prompt until the ACP
    /// `promptComplete` event arrives. Covers the whole round-trip
    /// including auxiliary post-processing (title generation, usage
    /// accounting, etc.). UIs should prefer the `isGenerating` /
    /// `isPostProcessing` pair below — they distinguish "agent is
    /// thinking about your message" from "agent is closing out" and
    /// avoid the misleading "spinner after the reply has landed" UX
    /// we saw in pass-1 (M7 #4).
    public var isAgentWorking = false
    public var pendingPermission: PendingPermission?
    /// Mutated to trigger a scroll-to-bottom in the message list.
    public var scrollTrigger = UUID()

    /// True while the assistant hasn't yet emitted a complete reply
    /// for the latest user prompt. Renders the prominent "Agent is
    /// thinking…" indicator in the chat. Flips false as soon as we've
    /// finalized an assistant message with content — even if the ACP
    /// `promptComplete` event hasn't arrived yet (Hermes auxiliary
    /// work like title generation delays that event).
    public var isGenerating: Bool {
        isAgentWorking && !isPostProcessing
    }

    /// True while ACP hasn't closed out the prompt but the assistant
    /// has already finalized a reply the user can see. Renders a
    /// subtle "Finishing up…" pill instead of the prominent spinner.
    /// Avoids the pass-1 M7 #4 UX where users stared at "Agent is
    /// working…" forever because `promptComplete` was held up by
    /// auxiliary server-side work.
    public var isPostProcessing: Bool {
        guard isAgentWorking else { return false }
        guard let last = messages.last else { return false }
        return last.isAssistant && !last.content.isEmpty
    }

    // MARK: - Error banner state (shared macOS + iOS)

    /// Human-readable error message shown in the chat's error banner.
    /// Nil = no active error. Populated from `recordACPFailure(...)`
    /// (throws from ACP ops) and from `handlePromptComplete` when the
    /// response's `stopReason` is `"error"` (non-retryable provider
    /// failures like Nous Portal HTTP 404 for an unknown model —
    /// pass-1 M7 #2).
    public var acpError: String?

    /// Short hint derived from the error + stderr tail (e.g.
    /// "set ANTHROPIC_API_KEY" or "pick a different model — this
    /// one isn't in the provider's catalog"). Shown above the raw
    /// error in the banner when present. Classified by
    /// `ACPErrorHint.classify(errorMessage:stderrTail:)`.
    public var acpErrorHint: String?

    /// Tail of stderr captured from `hermes acp` at the time of the
    /// failure. Shown in a collapsible "Show details" section so
    /// users can copy-paste the raw output into a bug report.
    public var acpErrorDetails: String?

    /// Lowercase OAuth provider name (`"nous"`, `"claude"`, …) when the
    /// most recent failure was an OAuth refresh-revocation Hermes asked
    /// the user to fix via re-authentication. Drives the chat banner's
    /// "Re-authenticate" button. Nil for any other failure mode.
    public var acpErrorOAuthProvider: String?

    /// Optional stderr-tail provider the controller can hook up when it
    /// creates the ACPClient. Used by `handlePromptComplete` to enrich
    /// the error banner on non-retryable stopReasons. The closure is
    /// called async so callers can await `ACPClient.recentStderr`
    /// without blocking the MainActor. Defaults to nil (no stderr in
    /// banner, just the hint fallback).
    public var acpStderrProvider: (@Sendable () async -> String)?

    /// Clear the error triplet. Call on session reset / new chat /
    /// successful new prompt so stale errors don't linger.
    public func clearACPErrorState() {
        acpError = nil
        acpErrorHint = nil
        acpErrorDetails = nil
        acpErrorOAuthProvider = nil
    }

    /// Populate the error triplet from a thrown Error + the ACPClient
    /// we can query for recent stderr. Safe to call from anywhere
    /// that catches an ACP op failure.
    ///
    /// Swallows `CancellationError` silently — it's how Swift's task
    /// tree signals cooperative cleanup (e.g. when startResuming
    /// tears down a prior live session via stop(), the event-task
    /// awaits throw as they unwind). That's expected plumbing, not a
    /// user-visible failure — showing "The operation couldn't be
    /// completed (Swift.CancellationError)" in the chat banner would
    /// alarm users whose session actually loaded fine. Pass-2 UX fix.
    public func recordACPFailure(_ error: Error, client: ACPClient?) async {
        if error is CancellationError { return }
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
            return
        }
        let msg = error.localizedDescription
        let stderrTail = await client?.recentStderr ?? ""
        let cls = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
        acpError = msg
        acpErrorHint = cls?.hint
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
        acpErrorOAuthProvider = cls?.oauthProvider
    }

    /// Populate the error triplet when `handlePromptComplete` sees a
    /// non-`end_turn` stopReason (i.e. the provider rejected the
    /// prompt and Hermes correctly surfaced it via ACP). The hint
    /// classifier reads the stderr tail; for stopReason="error" cases
    /// the tail typically contains the provider's HTTP status + reason.
    public func recordPromptStopFailure(stopReason: String, client: ACPClient?) async {
        let msg = "Prompt ended without a response (stopReason: \(stopReason))."
        let stderrTail = await client?.recentStderr ?? ""
        let cls = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
        acpError = msg
        acpErrorHint = cls?.hint ?? Self.fallbackHint(for: stopReason)
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
        acpErrorOAuthProvider = cls?.oauthProvider
    }

    /// Same as `recordPromptStopFailure` but pulls stderr from the
    /// `acpStderrProvider` closure the controller registered. Used by
    /// `handlePromptComplete` where we don't have direct ACPClient
    /// access.
    private func recordPromptStopFailureUsingProvider(stopReason: String) async {
        let msg = "Prompt ended without a response (stopReason: \(stopReason))."
        let stderrTail = await acpStderrProvider?() ?? ""
        let cls = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
        acpError = msg
        acpErrorHint = cls?.hint ?? Self.fallbackHint(for: stopReason)
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
        acpErrorOAuthProvider = cls?.oauthProvider
    }

    private static func fallbackHint(for stopReason: String) -> String? {
        switch stopReason {
        case "error":    return "The provider returned an error. Check the details below — often the configured model isn't in the provider's catalog."
        case "refusal":  return "The session may have been cleared on the server. Start a new chat to continue."
        case "max_tokens": return "The response was cut off before any content was produced. Try a shorter prompt or raise the max-tokens limit in Settings."
        default: return nil
        }
    }

    // Cumulative ACP token tracking (ACP returns tokens per prompt but DB has none)
    public private(set) var acpInputTokens = 0
    public private(set) var acpOutputTokens = 0
    public private(set) var acpThoughtTokens = 0
    public private(set) var acpCachedReadTokens = 0
    /// Running count of context compactions Hermes has performed on this
    /// session. Surfaced as the `🗜 ×N` chip in `SessionInfoBar` when > 0
    /// and `HermesCapabilities.hasContextCompressionCount` is true. Each
    /// `session/prompt` response carries the latest server-side total, so
    /// we replace (with a `max` guard) rather than accumulate.
    public private(set) var acpCompressionCount = 0

    /// Slash commands advertised by the ACP server via `available_commands_update`.
    public private(set) var acpCommands: [HermesSlashCommand] = []
    /// User-defined commands parsed from `config.yaml` `quick_commands`.
    public private(set) var quickCommands: [HermesSlashCommand] = []
    /// Project-scoped, Scarf-managed commands at
    /// `<project>/.scarf/slash-commands/<name>.md`. Loaded by
    /// `loadProjectScopedCommands(at:)` when a project chat starts; cleared
    /// on `reset()`. The full `ProjectSlashCommand` payload is kept here
    /// (not just the surface metadata) because expansion happens in
    /// `ChatViewModel.sendPrompt` and needs the body + model override.
    public private(set) var projectScopedCommands: [ProjectSlashCommand] = []

    /// Global Scarf-managed commands at `~/.hermes/scarf/slash-commands/<name>.md`.
    /// Populated from `BuiltinSlashCommands.bundle` on app launch by
    /// `SlashCommandBootstrapService` and refreshed on each session start
    /// via `loadGlobalScopedCommands()`. Available in EVERY chat (pre-
    /// session, global, project-scoped), not just project chats — that's
    /// the whole point of the global vs. project-scoped split. Per-project
    /// commands of the same name win over global via `availableCommands`'
    /// dedup logic.
    public private(set) var globalScopedCommands: [ProjectSlashCommand] = []

    /// Hardcoded ACP-native commands that don't interrupt the current
    /// turn. v2.5 ships `/steer` as the flagship — applies user
    /// guidance after the next tool call without aborting. Fronted by
    /// Hermes v2026.4.23+ but listed here unconditionally so older
    /// hosts that don't advertise it still surface the trigger; the
    /// agent will respond appropriately or no-op gracefully.
    ///
    /// v2.8 / Hermes v0.13 adds `/goal` (lock the agent on a target
    /// across turns) and `/queue` (queue a prompt for after the current
    /// turn). Both ride the same `.acpNonInterruptive` source — Hermes
    /// parses them server-side, the wire shape is plain
    /// `session/prompt`, and the chat UI keeps the "Agent working…"
    /// indicator off when they're sent. They're listed unconditionally
    /// here; capability filtering happens in `availableCommands` so
    /// pre-v0.13 hosts don't see `/goal` or `/queue` in the slash menu.
    // TODO(WS-2-Q7): verify against a real v0.13 ACP host that `/goal`
    // is in fact non-interruptive on the wire. If Hermes treats it as a
    // regular prompt that flips "Agent working…", drop it from this
    // list and route it through the standard send path (the pill
    // bookkeeping in `recordActiveGoal` is independent of the
    // interruptive classification).
    // NOTE: `/goal` and `/subgoal` are NOT advertised here. They are
    // gateway-only verbs — the ACP adapter does not advertise them in its
    // command set (re-verified against Hermes v0.16), so surfacing them in
    // the ACP slash menu showed rows that no-op against an ACP host. The
    // optimistic goal/subgoal pill plumbing (`recordActiveGoal`,
    // `activeSubgoals`, the `SessionInfoBar` pill) is left intact for the
    // typed-command path and for any future gateway-fronted surface.
    public static let nonInterruptiveCommands: [HermesSlashCommand] = [
        HermesSlashCommand(
            name: "steer",
            description: "Nudge the agent mid-run (applies after the next tool call)",
            argumentHint: "<guidance>",
            source: .acpNonInterruptive
        ),
        HermesSlashCommand(
            name: "queue",
            description: "Queue a prompt to run after the current turn",
            argumentHint: "<text>",
            source: .acpNonInterruptive
        )
    ]

    /// Static fallback commands Hermes ACP always supports but only
    /// advertises via `available_commands_update` after `session/new` —
    /// not after `session/load`. Without this fallback, resumed sessions
    /// (and "no active session" cold starts) showed an artificially
    /// sparse menu. With this list, the menu is discoverable everywhere;
    /// when the ACP-advertised version arrives, dedupe-by-name in
    /// `availableCommands` ensures the canonical (richer description,
    /// authoritative argument hint) entry wins.
    ///
    /// The set splits on whether a session is active:
    /// - **Always** (no session AND active session): `/new`. It's the
    ///   "open a session" affordance and arms the v0.13+ `[<name>]`
    ///   argument hint via `hasNewWithSessionName`.
    /// - **Active-session-only**: `/clear`, `/compact` (`/compress` on v0.20+), `/cost`, `/model`,
    ///   `/tools`, `/reload-skills`, `/help`, `/exit`. Each requires a
    ///   live session; surfacing them pre-session would mislead.
    public static func alwaysAvailableCommands(
        capabilities: HermesCapabilities,
        hasActiveSession: Bool
    ) -> [HermesSlashCommand] {
        var result: [HermesSlashCommand] = [
            HermesSlashCommand(
                name: "new",
                description: "Start a new chat session",
                argumentHint: capabilities.hasNewWithSessionName ? "[<name>]" : nil,
                source: .alwaysAvailable
            )
        ]
        // P2 of the projects-feature fix: pre-session, surface the agent
        // commands too — greyed out in the menu (the chat view supplies
        // `disabledCommandNames` from `sessionRequiredCommandNames`) so the
        // user sees what's available once they open a chat instead of an
        // apparently-empty menu. Hiding them entirely made the menu look
        // broken on fresh app launches.
        result.append(contentsOf: [
            HermesSlashCommand(
                name: "clear",
                description: "Clear the current conversation",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: capabilities.hasCompressCommand ? "compress" : "compact",
                description: "Compress the conversation history",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "cost",
                description: "Show cost breakdown for this session",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "model",
                description: "Switch the active model",
                argumentHint: "[<model>]",
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "tools",
                description: "Manage tool availability",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "reload-skills",
                description: "Reload the skills index",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "help",
                description: "Show available commands",
                argumentHint: nil,
                source: .alwaysAvailable
            ),
            HermesSlashCommand(
                name: "exit",
                description: "End the current session",
                argumentHint: nil,
                source: .alwaysAvailable
            )
        ])
        // v0.14 — append optional commands when the connected host advertises
        // them. Filtered here rather than in `availableCommands` so the
        // capability-gating logic stays co-located with the command shape.
        if capabilities.hasYOLOSlashCommand {
            result.append(HermesSlashCommand(
                name: "yolo",
                description: "Toggle YOLO mode (skip all dangerous approvals)",
                argumentHint: nil,
                source: .alwaysAvailable
            ))
        }
        if capabilities.hasSessionsSlashCommand {
            result.append(HermesSlashCommand(
                name: "sessions",
                description: "Browse and resume previous sessions",
                argumentHint: nil,
                source: .alwaysAvailable
            ))
        }
        if capabilities.hasCodexRuntimeSlashCommand {
            result.append(HermesSlashCommand(
                name: "codex-runtime",
                description: "Toggle Codex app-server runtime for OpenAI/Codex models",
                argumentHint: "[auto|codex_app_server]",
                source: .alwaysAvailable
            ))
        }
        return result
    }

    /// Capability snapshot the chat surface uses to filter
    /// `availableCommands`. Set by the chat controller (Mac
    /// `ChatViewModel`, iOS `ChatController`) at session-start time and
    /// kept fresh via the `HermesCapabilitiesStore` env binding. Default
    /// `.empty` means "no v0.13 surfaces" — pre-v0.13 hosts and harness
    /// scenarios (Previews, smoke tests) never expose `/goal` or
    /// `/queue` until the controller publishes a real capabilities
    /// value. `@ObservationIgnored` so capability refreshes don't trash
    /// the streaming-message render budget; controllers call
    /// `publishCapabilities(_:)` once per refresh tick.
    @ObservationIgnored
    public var capabilitiesGate: HermesCapabilities = .empty

    /// Optimistic local mirror of the agent's currently-locked goal.
    /// Set by `recordActiveGoal(text:)` the moment the user sends
    /// `/goal …`; cleared on `/goal --clear` or `reset()`. Pre-v0.13
    /// hosts can't reach this code path (the slash menu hides `/goal`),
    /// but a typed-out `/goal foo` against an older host would still
    /// land here briefly until Hermes' "unknown command" reply lands —
    /// see WS-2 plan "Inconsistency caveat".
    public private(set) var activeGoal: HermesActiveGoal?

    /// Optimistic mirror of prompts the user has queued via `/queue …`
    /// while a turn is in flight. Hermes is the authoritative owner
    /// server-side; this list drives the chat-header chip + popover and
    /// drains FIFO via `popQueuedPrompt()` when a turn completes.
    /// Best-effort: if Hermes' server-side queue gets out of sync
    /// (deferred prompt aborted, dropped on disconnect) the user sees a
    /// stale chip until their next interaction.
    public private(set) var queuedPrompts: [HermesQueuedPrompt] = []

    /// Transient hint shown above the composer, e.g. "Guidance queued —
    /// applies after the next tool call." for `/steer`. The chat view
    /// auto-clears it after a short delay (handled in the view); the
    /// model just owns the value.
    public var transientHint: String?

    /// Wall-clock start time of the current agent turn. Set when a fresh
    /// user prompt enters an idle session (not for `/steer` which sends
    /// during an active turn); cleared on `finalizeStreamingMessage`
    /// after the duration is captured. Used to compute the per-turn
    /// stopwatch displayed below assistant bubbles. v2.5.
    private var currentTurnStart: Date?

    /// Wall-clock duration of completed assistant turns, keyed by the
    /// finalised assistant message's local id. Render the value in the
    /// chat UI as a small "4.2s" pill below the bubble. Map grows
    /// alongside the message list; cleared on `reset()`.
    public private(set) var turnDurations: [Int: TimeInterval] = [:]

    /// Look up a completed turn's duration. Nil for the streaming
    /// placeholder (still in flight) and for any assistant message
    /// that pre-dates the v2.5 stopwatch (e.g., loaded from state.db
    /// for a resumed session).
    public func turnDuration(forMessageId id: Int) -> TimeInterval? {
        turnDurations[id]
    }

    /// Format a duration as a compact stopwatch label used by the chat
    /// UI: `0.8s`, `4.2s`, `1m 12s`. Sub-second values render with one
    /// decimal place; ≥60s switches to `<m>m <s>s`.
    public static func formatTurnDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return "\(minutes)m \(remainder)s"
    }

    /// Merged slash-menu list. Precedence: **ACP > project-scoped >
    /// global Scarf > quick_commands** (most specific source wins).
    /// De-duplicated by name. Non-interruptive ACP commands (`/steer`)
    /// are always appended at the end so they don't crowd the more
    /// frequently-used options.
    public var availableCommands: [HermesSlashCommand] {
        let acpNames = Set(acpCommands.map(\.name))
        let projectAsHermes: [HermesSlashCommand] = projectScopedCommands
            .filter { !acpNames.contains($0.name) }
            .map { cmd in
                HermesSlashCommand(
                    name: cmd.name,
                    description: cmd.description,
                    argumentHint: cmd.argumentHint,
                    source: .projectScoped
                )
            }
        let projectNames = Set(projectAsHermes.map(\.name))
        // Global Scarf commands sit BELOW project-scoped in the
        // precedence chain — a project that authors its own `scarf-help`
        // wins over the bundled one. Surface them with the same
        // `.projectScoped` source for now (no UI distinction between
        // project and global yet); add a dedicated `.globalScarf`
        // source enum case if/when we want to differentiate them in
        // the row chrome.
        let globalAsHermes: [HermesSlashCommand] = globalScopedCommands
            .filter { !acpNames.contains($0.name) && !projectNames.contains($0.name) }
            .map { cmd in
                HermesSlashCommand(
                    name: cmd.name,
                    description: cmd.description,
                    argumentHint: cmd.argumentHint,
                    source: .projectScoped
                )
            }
        let globalNames = Set(globalAsHermes.map(\.name))
        let quicks = quickCommands.filter {
            !acpNames.contains($0.name)
                && !projectNames.contains($0.name)
                && !globalNames.contains($0.name)
        }
        let occupied = acpNames
            .union(projectNames)
            .union(globalNames)
            .union(Set(quicks.map(\.name)))
        // Capability gate: `/queue` is a v0.13+ surface; hide it when the
        // connected host is older. `/steer` is surfaced unconditionally —
        // it works on v0.11+ during an active turn; idle-session greying
        // for pre-v0.13 hosts is the input bar's concern (it reads
        // `hasACPSteerOnIdle`). `/goal` and `/subgoal` are deliberately
        // NOT in `nonInterruptiveCommands` (gateway-only, not advertised
        // by the ACP adapter), so they never reach this filter.
        let supported: [HermesSlashCommand] = Self.nonInterruptiveCommands.filter { cmd in
            switch cmd.name {
            case "queue":   return capabilitiesGate.hasACPQueue
            // P2 of the projects-feature fix: /steer used to be filtered
            // out pre-session, which made the menu look empty on fresh
            // app launches. Now it stays visible and `disabledSlash-
            // CommandNames` greys it (with a "Available once a chat is
            // open" tooltip) when sessionId is nil — same treatment as
            // the other agent-side commands. v0.13's hasACPSteerOnIdle
            // still controls the active-session-but-idle case downstream.
            default:        return true
            }
        }
        let nonInterruptive = supported.filter { !occupied.contains($0.name) }
        // Static fallbacks. `/new` always shows; the rest of the agent-
        // level command set (`/clear`, `/compact`/`/compress`, `/cost`, `/model`,
        // `/tools`, `/reload-skills`, `/help`, `/exit`) only when a
        // session is active — Hermes ACP doesn't re-emit
        // `available_commands_update` after `session/load`, so without
        // this fallback resumed sessions showed an artificially sparse
        // menu. Deduped against ACP / project / quick names so once a
        // session starts and the ACP server advertises its richer
        // versions, the ACP-sourced entry wins.
        let alwaysAvailable = Self.alwaysAvailableCommands(
            capabilities: capabilitiesGate,
            hasActiveSession: sessionId != nil
        ).filter { !occupied.contains($0.name) }
        return acpCommands + projectAsHermes + globalAsHermes + quicks + nonInterruptive + alwaysAvailable
    }

    /// Publish a fresh capabilities snapshot from the controller.
    /// Called whenever `HermesCapabilitiesStore.capabilities` changes
    /// (initial detection, post-refresh, server switch). The chat input
    /// bar's slash menu re-reads `availableCommands` lazily, so this is
    /// just a stored-value swap — no observable churn.
    public func publishCapabilities(_ caps: HermesCapabilities) {
        capabilitiesGate = caps
    }

    /// Optimistic write triggered when the user sends `/goal <text>`.
    /// Pass `nil` (or empty) to clear (the `/goal --clear` path). The
    /// pill renders synchronously off this state; there is no
    /// authoritative server read-back in v2.8.0 — see WS-2 plan Q1.
    // TODO(WS-2-Q1): hook a Hermes-supplied goal-state read-back path
    // here once we know whether v0.13 exposes goal state via an ACP
    // session-startup notification, a session-sidecar JSON field, or a
    // `/goal --status` reply. Until then `activeGoal` is purely
    // user-set and does not survive a session resume.
    public func recordActiveGoal(text: String?) {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeGoal = HermesActiveGoal(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                setAt: Date()
            )
        } else {
            activeGoal = nil
        }
    }

    /// Append an optimistically-queued prompt to the local mirror
    /// (driven by `/queue <text>`). No-op for empty / whitespace input.
    public func recordQueuedPrompt(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedPrompts.append(HermesQueuedPrompt(text: trimmed))
    }

    /// Optimistic local mirror of subgoals layered onto the active goal
    /// via `/subgoal <text>` (v0.14+). Order matches the order they were
    /// added; `/subgoal remove N` drops the Nth (1-indexed) entry;
    /// `/subgoal clear` empties the list. Hermes owns the authoritative
    /// state server-side — this mirror just drives the trailing line of
    /// the goal pill in `SessionInfoBar`.
    public private(set) var activeSubgoals: [String] = []

    /// Per-session edit auto-approval mode (Hermes v0.15+ ACP
    /// `session/set_mode`). Optimistic mirror — the chat-header picker
    /// flips this immediately on tap and `ChatViewModel.switchApprovalMode`
    /// reverts it if the RPC fails. Defaults to `.default` (ask before
    /// edits); reset on every session boundary so a resumed/new session
    /// doesn't inherit a stale mode. Hermes owns the authoritative value
    /// server-side.
    ///
    /// **Known limitation:** this is a local indicator, not synced from the
    /// `session/new`/`session/load` response. A fresh session genuinely
    /// starts at `.default` (correct), but a *resumed* session whose mode
    /// was changed elsewhere (a prior Scarf run, the TUI) will display
    /// `.default` until the user re-selects. This is display-only —
    /// actual edit prompting is driven by Hermes regardless of this chip.
    /// Syncing from the response would require surfacing the advertised
    /// `modes`/current-mode out of `ACPClient.newSession` (deferred).
    public var activeApprovalMode: ACPApprovalMode = .default

    /// Parse the argument slug from a `/subgoal …` invocation. Pure
    /// function — exposed for unit tests. The chat dispatch uses the
    /// result to apply the right optimistic mutation before the prompt
    /// is sent verbatim to Hermes.
    public enum SubgoalCommandArgument: Equatable {
        case add(String)
        case remove(Int)
        case clear
        /// User typed `/subgoal` with no argument — Hermes will reply
        /// with usage; Scarf shows a neutral hint and doesn't touch
        /// the local mirror.
        case empty
    }

    public static func parseSubgoalArgument(_ raw: String) -> SubgoalCommandArgument {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let lowered = trimmed.lowercased()
        if lowered == "clear" || lowered == "--clear" { return .clear }
        // `remove N` form. Accept any whitespace-separated single integer
        // following the verb; reject negatives or non-numeric inputs by
        // falling through to .add (which is harmless — Hermes will
        // reject server-side and the mirror won't move).
        if lowered.hasPrefix("remove ") || lowered.hasPrefix("rm ") {
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let idx = Int(parts[1]), idx > 0 {
                return .remove(idx)
            }
        }
        return .add(trimmed)
    }

    /// Append a subgoal to the local mirror. Optimistic — Hermes owns
    /// the canonical list server-side. No-op for empty input.
    public func recordSubgoalAdded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeSubgoals.append(trimmed)
    }

    /// Drop the Nth subgoal (1-indexed) from the local mirror, matching
    /// Hermes's `/subgoal remove N` semantics. Out-of-range indices are
    /// silently ignored.
    public func recordSubgoalRemoved(_ oneBasedIndex: Int) {
        let zeroIdx = oneBasedIndex - 1
        guard activeSubgoals.indices.contains(zeroIdx) else { return }
        activeSubgoals.remove(at: zeroIdx)
    }

    /// Clear all subgoals from the local mirror.
    public func recordSubgoalsCleared() {
        activeSubgoals.removeAll()
    }

    /// Drain the next queued prompt off the local mirror, FIFO. Called
    /// from `handlePromptComplete` once a turn settles — Hermes runs
    /// the actual queued prompt server-side; popping here keeps the
    /// header chip count honest. Returns the popped prompt for any
    /// caller that wants to log it; the chat UI ignores the return.
    @discardableResult
    public func popQueuedPrompt() -> HermesQueuedPrompt? {
        queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
    }

    /// Parse the argument slug from a `/goal …` invocation. Pure
    /// function — exposed for unit tests. The chat dispatch reads this
    /// to decide whether to set, clear, or no-op the optimistic pill.
    public enum GoalCommandArgument: Equatable {
        case set(String)
        case clear
        /// User typed `/goal` with no argument — Hermes will reply
        /// with usage; Scarf shows a neutral hint and doesn't touch
        /// the pill state.
        case empty
    }

    public static func parseGoalArgument(_ raw: String) -> GoalCommandArgument {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        // Accept `--clear`, `clear`, and case-insensitive variants so
        // typos don't accidentally lock the goal text to literal
        // "Clear". `--clear` is the canonical form (matches Hermes
        // CLI flag style).
        let lowered = trimmed.lowercased()
        if lowered == "--clear" || lowered == "clear" { return .clear }
        return .set(trimmed)
    }

    /// True when `text` is a non-interruptive command that should NOT
    /// flip `isAgentWorking` to true on send. Used by the Mac/iOS chat
    /// view models to skip the "agent working" overlay change for
    /// `/steer` (the agent's still on its current turn).
    public func isNonInterruptiveSlash(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let withoutSlash = trimmed.dropFirst()
        let name: String
        if let space = withoutSlash.firstIndex(of: " ") {
            name = String(withoutSlash[..<space])
        } else {
            name = String(withoutSlash)
        }
        return Self.nonInterruptiveCommands.contains { $0.name == name }
    }

    /// Look up the full project-scoped command payload by slash trigger.
    /// `ChatViewModel.sendPrompt` calls this when the input matches a
    /// `.projectScoped` source and needs the body for client-side
    /// expansion. Searches project commands first (a project that
    /// authors `/scarf-help` should win over the bundled global one),
    /// then falls back to the global store so `/scarf-*` commands work
    /// in non-project chats too.
    public func projectScopedCommand(named name: String) -> ProjectSlashCommand? {
        if let cmd = projectScopedCommands.first(where: { $0.name == name }) {
            return cmd
        }
        return globalScopedCommands.first { $0.name == name }
    }

    // MARK: - Shared slash menu helpers

    /// Pull `(name, argTail)` out of a `/<name> [args]` invocation.
    /// Returns `(nil, "")` for non-slash input. Used by both the Mac and
    /// iOS send paths to special-case `/goal`, `/queue`, `/steer` before
    /// the wire send.
    public static func parseSlashName(_ text: String) -> (name: String?, args: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return (nil, "") }
        let withoutSlash = trimmed.dropFirst()
        if let space = withoutSlash.firstIndex(of: " ") {
            return (
                name: String(withoutSlash[..<space]),
                args: String(withoutSlash[withoutSlash.index(after: space)...])
            )
        }
        return (name: String(withoutSlash), args: "")
    }

    /// Cap goal text in transient toasts so a 1 KB user-typed goal
    /// doesn't blow out the hint pill. The header pill applies its
    /// own 33-char cap; the toast is shorter so the hint stays
    /// glanceable.
    public static func truncatedToastGoal(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(57)) + "…"
    }

    /// Slash commands Scarf handles entirely on the client and that
    /// MUST NOT be forwarded to the ACP server. Hermes's ACP adapter
    /// does not intercept these — sending them as prompts routes them
    /// to the LLM, which responds in-character ("/new is a TUI slash
    /// command, type it in the TUI prompt"). Reported in TestFlight
    /// feedback ADyrlh (2026-05-11).
    public enum ClientSideSlashCommand: Sendable, Equatable {
        /// `/new [<name>]` — start a fresh chat session on the
        /// client. `name` is the trimmed argument tail; nil when the
        /// user typed bare `/new`. Pre-v0.13 hosts ignore the name
        /// even when Hermes does honor it.
        case newSession(name: String?)
    }

    /// Classify input text against the client-side slash command set.
    /// Returns nil for plain prompts, project-scoped commands,
    /// non-interruptive (`/steer` / `/goal` / `/queue`), and
    /// ACP-handled commands — all of which keep their existing wire
    /// paths.
    public static func clientSideSlashCommand(for text: String) -> ClientSideSlashCommand? {
        let parsed = parseSlashName(text)
        switch parsed.name {
        case "new":
            let trimmed = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            return .newSession(name: trimmed.isEmpty ? nil : trimmed)
        default:
            return nil
        }
    }

    // MARK: - Non-vision image heads-up (t-31img / gh#113)

    /// The session's effective model — the same resolution the
    /// `ChatModelBadge` displays: the per-session preset override when
    /// one is set, else the global `config.yaml` default
    /// (`model.provider` + `model.default`). Nil when neither yields a
    /// usable (provider, model) pair — e.g. fresh installs, or the
    /// Local tab's legal empty-`model.default` auto-detect config —
    /// which callers must treat as capability-unknown, never as
    /// "not vision-capable".
    ///
    /// `""` and the YAML parser's `"unknown"` fallback both mean unset,
    /// matching `ModelPreflight`.
    public static func resolveActiveModel(
        preset: ModelPreset?,
        configProvider: String,
        configModel: String
    ) -> (providerID: String, modelID: String)? {
        if let preset {
            return (preset.providerID, preset.modelID)
        }
        func unset(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty || trimmed == "unknown"
        }
        guard !unset(configProvider), !unset(configModel) else { return nil }
        return (
            configProvider.trimmingCharacters(in: .whitespacesAndNewlines),
            configModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Whether the composer should render the "this model can't see
    /// images" heads-up. Only a confident `.no` warns — `.unknown`
    /// covers local models and custom endpoints that models.dev doesn't
    /// mirror (`llama3.2-vision` exists; don't false-positive), and
    /// `.yes` obviously doesn't. Never blocks sending: Hermes may still
    /// handle the image via its auxiliary vision fallback.
    public static func shouldShowNonVisionImageHint(
        attachmentCount: Int,
        capability: ModelCatalogService.VisionCapability
    ) -> Bool {
        attachmentCount > 0 && capability == .no
    }

    /// Copy for the heads-up row. Kept here (not inline in the View) so
    /// the wording is pinned by ScarfCore tests alongside the decision
    /// logic.
    public static func nonVisionImageHint(modelDisplayName: String) -> String {
        "\(modelDisplayName) can't see images natively — Hermes will describe them via its vision fallback; results may be lossy. Pick a vision model to send pixels."
    }

    /// True when config.yaml overrides Hermes's models.dev-based image
    /// routing in a way that makes a confident catalog `.no` verdict
    /// unreliable — the composer heads-up must stay quiet then, because
    /// its copy ("Hermes will describe them via its vision fallback")
    /// would be false:
    ///
    /// - `agent.image_input_mode: native` — `decide_image_input_mode`
    ///   returns `"native"` before any capability lookup; Hermes
    ///   attaches pixels unconditionally.
    /// - `model.supports_vision: <true token>` — the user declared the
    ///   active model vision-capable; `_lookup_supports_vision` honors
    ///   the override before models.dev, so auto mode routes native.
    ///
    /// Token handling mirrors Hermes (`image_routing.py`): the mode
    /// must equal `native` exactly (`_coerce_mode` treats anything else
    /// as no override for our purposes), and the vision override
    /// accepts `_TRUE_TOKENS` = true/yes/on/1. A false-token or absent
    /// value keeps the catalog verdict. Per-provider per-model
    /// overrides (`providers.<p>.models.<m>.supports_vision`) are NOT
    /// mirrored — those describe custom/local models, which already
    /// resolve `.unknown` and never warn.
    public static func nonVisionHintSuppressedByConfig(configYAML: String) -> Bool {
        let values = HermesYAML.parseNestedYAML(configYAML).values
        func scalar(_ key: String) -> String {
            HermesYAML.stripYAMLQuotes(values[key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        if scalar("agent.image_input_mode") == "native" { return true }
        return ["true", "yes", "on", "1"].contains(scalar("model.supports_vision"))
    }

    /// Slash menu visibility predicate: show only while the user is
    /// typing the command token (text starts with `/` and contains no
    /// whitespace). Once a space or newline appears the user is typing
    /// arguments and the menu hides.
    public static func shouldShowSlashMenu(text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        return !text.contains(" ") && !text.contains("\n")
    }

    /// Strip the leading `/` so the slash menu can prefix-match the
    /// remaining query against command names.
    public static func slashMenuQuery(text: String) -> String {
        guard text.hasPrefix("/") else { return "" }
        return String(text.dropFirst())
    }

    /// Case-insensitive prefix match on command names. Empty query
    /// returns the full list unchanged.
    public static func filterSlashCommands(_ commands: [HermesSlashCommand], query: String) -> [HermesSlashCommand] {
        let q = query.lowercased()
        if q.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(q) }
    }

    /// Names of slash-menu rows that should render greyed-out + ignore
    /// taps.
    ///
    /// Two grey-out conditions:
    /// - **No active session** (P2 of the projects-feature fix): every
    ///   agent-side command (`/clear /compact(/compress) /cost /model /tools
    ///   /reload-skills /help /exit`, plus capability-gated `/yolo
    ///   /sessions /codex-runtime` and non-interruptive `/steer /goal
    ///   /queue /subgoal`) needs a live ACP session to do anything.
    ///   Surfacing them greyed gives the user a visible "what's
    ///   coming once you open a chat" instead of an empty menu.
    /// - **Pre-v0.13 idle session**: `/steer` silently no-ops on
    ///   pre-v0.13 hosts when the agent isn't mid-turn, so we grey it
    ///   in that specific window even when a session is active.
    public static func disabledSlashCommandNames(
        isAgentWorking: Bool,
        hasActiveSession: Bool,
        capabilities: HermesCapabilities
    ) -> Set<String> {
        var disabled: Set<String> = []
        if !hasActiveSession {
            disabled.formUnion(Self.sessionRequiredCommandNames)
        }
        if hasActiveSession && !isAgentWorking && !capabilities.hasACPSteerOnIdle {
            disabled.insert("steer")
        }
        return disabled
    }

    /// Slash commands that need a live ACP session to do anything. Used
    /// by `disabledSlashCommandNames` to grey-out the menu rows when the
    /// user is looking at the input bar pre-session. Kept in one place
    /// so the menu and any future enable/disable checks stay in sync.
    /// Includes both `compact` and `compress` since this set is a static,
    /// capability-independent membership check — `alwaysAvailableCommands`
    /// only ever emits one of the two spellings depending on
    /// `hasCompressCommand`, so the unused name here is inert.
    public static let sessionRequiredCommandNames: Set<String> = [
        "clear", "compact", "compress", "cost", "model", "tools",
        "reload-skills", "help", "exit",
        "yolo", "sessions", "codex-runtime",
        "steer", "queue"
    ]

    /// Tooltip / inline help text shown next to disabled rows. Returns
    /// nil when no rows are disabled. Phrased generically so the same
    /// string applies to both the pre-session "open a chat first" case
    /// and the pre-v0.13 "wait for the agent's turn" case — both are
    /// "this command needs a state we're not in yet".
    public static func disabledSlashCommandReason(
        isAgentWorking: Bool,
        hasActiveSession: Bool,
        capabilities: HermesCapabilities
    ) -> String? {
        if !hasActiveSession {
            return "Available once a chat is open. Press Return on `/new` (or click an existing session) to start one."
        }
        let disabled = disabledSlashCommandNames(
            isAgentWorking: isAgentWorking,
            hasActiveSession: hasActiveSession,
            capabilities: capabilities
        )
        guard !disabled.isEmpty else { return nil }
        return "Use `/steer` while the agent is working — your Hermes version doesn't support steering on idle sessions."
    }

    /// Expand `/<name> args` when `<name>` matches a loaded project-
    /// scoped command. Falls through (returns the input unchanged) for
    /// non-slash input, unknown names, ACP-advertised commands, and
    /// quick_commands — those go to Hermes literally. The caller
    /// provides the `ServerContext` so the expansion service can read
    /// the project sidecar through the right transport.
    public func expandIfProjectScoped(
        _ text: String,
        context: ServerContext
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return text }
        let withoutSlash = String(trimmed.dropFirst())
        let name: String
        let argument: String
        if let space = withoutSlash.firstIndex(of: " ") {
            name = String(withoutSlash[..<space])
            argument = String(withoutSlash[withoutSlash.index(after: space)...])
        } else {
            name = withoutSlash
            argument = ""
        }
        guard !name.isEmpty,
              let cmd = projectScopedCommand(named: name)
        else { return text }
        return ProjectSlashCommandService(context: context).expand(cmd, withArgument: argument)
    }

    public var supportsCompress: Bool { availableCommands.contains { $0.name == "compress" } }

    /// True when the menu carries more than just `/compress` — used to hide
    /// the dedicated compress button in favor of the full slash menu.
    public var hasBroaderCommandMenu: Bool { availableCommands.count > 1 }

    public var hasMessages: Bool { !messages.isEmpty }

    public func requestScrollToBottom() {
        scrollTrigger = UUID()
    }

    public private(set) var sessionId: String?
    /// Wall-clock timestamp of when this view model attached to its
    /// The original CLI session ID when resuming a CLI session via ACP.
    /// Used to combine old CLI messages with new ACP messages.
    public private(set) var originSessionId: String?
    /// Smallest DB id currently loaded for the *current session* (i.e.
    /// `sessionId`). Drives `loadEarlier()`: page back with
    /// `before: oldestLoadedMessageID`. `nil` when nothing has been
    /// loaded yet or the session has no DB-persisted messages.
    public private(set) var oldestLoadedMessageID: Int?
    /// Whether the most recent fetch suggests there are more older
    /// messages on disk that haven't been loaded into `messages` yet.
    /// Set to `true` when the initial fetch returned exactly `limit`
    /// rows (a strong hint the table has more). Drives the "Load
    /// earlier" button visibility in chat views.
    public private(set) var hasMoreHistory: Bool = false
    /// Cleared during a `loadEarlier()` fetch so the UI can show a
    /// spinner and we don't fan out duplicate page requests.
    public private(set) var isLoadingEarlier: Bool = false
    private var nextLocalId = -1

    /// Issue #63: locally-created user messages awaiting state.db
    /// persistence, keyed by session id. ACP roundtrips Hermes' DB
    /// write asynchronously, so a user who sends a prompt and
    /// immediately switches to another session triggers `reset()`
    /// before Hermes flushes the row — `loadSessionHistory` then reads
    /// from a DB that doesn't have the message yet, and the bubble
    /// renders blank or vanishes on return. We hold a per-session
    /// copy here that survives `reset()` so `loadSessionHistory` can
    /// re-inject anything still in flight, and clean entries out as
    /// soon as a matching DB row appears.
    private var pendingLocalUserMessages: [String: [HermesMessage]] = [:]

    private var streamingAssistantText = ""
    private var streamingThinkingText = ""
    private var streamingToolCalls: [HermesToolCall] = []

    /// True while a turn is in flight, has emitted thought-stream
    /// bytes, but has NOT yet produced any visible assistant text.
    /// Surfaces the user-facing "Thinking…" status promotion (the
    /// model is reasoning before answering — Hermes reasoning models
    /// commonly take 3–8 s here, which the ScarfMon `firstThoughtByte`
    /// vs `firstByte` split makes visible). Becomes false the moment
    /// the first message chunk arrives or the turn ends.
    public var isStreamingThoughtsOnly: Bool {
        currentTurnStart != nil
            && !streamingThinkingText.isEmpty
            && streamingAssistantText.isEmpty
    }

    // DB polling state (used in terminal mode fallback)
    private var lastKnownFingerprint: HermesDataService.MessageFingerprint?
    private var debounceTask: Task<Void, Never>?
    private var resetTimestamp: Date?
    private var userSendPending = false
    private var activePollingTimer: Timer?
    /// Replay-suppression gate: true once a prompt has actually been
    /// sent in the currently-attached session. Set by `addUserMessage`
    /// AND by `markPromptSent()` (which every send site must call at
    /// the point the prompt goes over the wire), cleared by
    /// `setSessionId` / `reset`. Until set, streamed content events
    /// (`messageChunk`, `thoughtChunk`, `toolCallStart`,
    /// `toolCallUpdate`) are dropped — Hermes' ACP adapter sometimes
    /// streams the recent session state as a sequence of agent events
    /// after `session/load`, OR auto-resumes in-flight work for
    /// sessions with persistent goals / queued prompts. Either way the
    /// user perceives bubbles materializing one-by-one when they open
    /// an old chat. The DB-fetched history is authoritative for the
    /// existing transcript; live agent work resumes once a prompt is
    /// actually sent.
    ///
    /// `promptComplete` is intentionally NOT gated (2026-07-13, S2):
    /// it never comes from the session/load replay — ACPEventParser
    /// never yields it; each send path synthesizes it from
    /// `sendPrompt`'s return — and it carries turn accounting, the
    /// `isAgentWorking` clear, and the no-output failure bubble.
    /// Gate-dropping it turned any turn whose echo/gate bookkeeping
    /// slipped into a silent, never-finishing spinner.
    private var hasUserSentPromptThisSession = false

    public struct PendingPermission {
        public let requestId: Int
        public let title: String
        public let kind: String
        public let options: [(optionId: String, name: String)]

        public init(
            requestId: Int,
            title: String,
            kind: String,
            options: [(optionId: String, name: String)]
        ) {
            self.requestId = requestId
            self.title = title
            self.kind = kind
            self.options = options
        }
    }

    // MARK: - Reset

    public func reset() {
        debounceTask?.cancel()
        hydrationTask?.cancel()
        hydrationTask = nil
        isHydratingTools = false
        stopActivePolling()
        Task { await dataService.close() }
        messages = []
        messageGroups = []
        renderWindow = RenderWindow.initial
        currentSession = nil
        lastKnownFingerprint = nil
        sessionId = nil
        originSessionId = nil
        oldestLoadedMessageID = nil
        hasMoreHistory = false
        isLoadingEarlier = false
        isAgentWorking = false
        userSendPending = false
        hasUserSentPromptThisSession = false
        resetTimestamp = Date()
        nextLocalId = -1
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
        acpInputTokens = 0
        acpOutputTokens = 0
        acpThoughtTokens = 0
        acpError = nil
        acpErrorHint = nil
        acpErrorDetails = nil
        acpCachedReadTokens = 0
        acpCompressionCount = 0
        // `acpCommands` is intentionally NOT cleared. ACP slash commands
        // are agent-level (advertised once per process via
        // `available_commands_update` typically piggy-backing on
        // `session/new`); they don't change when the user switches
        // sessions. Hermes does not re-emit on `session/load`, so if
        // we wipe here, resumed sessions land at a 4-command fallback
        // until the user starts a fresh session — observed during
        // dogfooding against a Hermes v0.13 host. The caller paths
        // (startNewSession, resumeSession, continueLastSession) all
        // spawn a fresh ACP subprocess; if that subprocess emits a
        // fresh list, our value is replaced; if it doesn't, we keep
        // the most recently-known agent-level set, which stays
        // accurate as long as the agent identity hasn't changed. The
        // host-switch case (Local → SSH) tears down the whole
        // ContextBoundRoot so this stale carry-over isn't reachable
        // there.
        projectScopedCommands = []
        currentTurnStart = nil
        turnDurations = [:]
        transientHint = nil
        pendingPermission = nil
        // v2.8 / Hermes v0.13 — drop optimistic v0.13 surfaces on
        // session reset so a fresh chat (or a resume into a different
        // session) doesn't paint stale goal / queue state from the
        // previous one. The capabilities gate stays on whatever the
        // controller most recently published; it's a host-level value
        // that doesn't change with session boundaries.
        activeGoal = nil
        queuedPrompts = []
        activeSubgoals = []
        // v0.15 — the per-session edit auto-approval mode is session-
        // scoped; a fresh chat starts back at the default "ask before
        // edits" posture rather than carrying the previous session's mode.
        activeApprovalMode = .default
        loadQuickCommands()
    }

    public func setSessionId(_ id: String?) {
        sessionId = id
        lastKnownFingerprint = nil
        // Reset the user-engagement gate on every session change so
        // the next chat we attach to also drops post-load replay
        // events until the user prompts.
        hasUserSentPromptThisSession = false
    }

    public func cleanup() async {
        stopActivePolling()
        debounceTask?.cancel()
        await dataService.close()
    }

    /// Re-fetch session metadata from DB to pick up cost/token updates.
    public func refreshSessionFromDB() async {
        await ScarfMon.measureAsync(.sessionLoad, "mac.refreshSessionFromDB") {
            guard let sessionId else { return }
            let opened = await dataService.open()
            guard opened else { return }
            if let session = await dataService.fetchSession(id: sessionId) {
                currentSession = session
            }
            await dataService.close()
        }
    }

    // MARK: - ACP Event Handling

    /// Open the replay-suppression gate: call at the point a prompt is
    /// actually handed to the agent (e.g. `ChatViewModel.sendViaACP`),
    /// independent of whether a local echo bubble was appended.
    /// `addUserMessage` also opens the gate, but send paths that echo
    /// the message BEFORE session setup completes lose that open when
    /// `setSessionId` resets the gate (autoStart), and paths that skip
    /// the echo never opened it at all — either way the turn's streamed
    /// chunks would be dropped as replay. Idempotent.
    public func markPromptSent() {
        hasUserSentPromptThisSession = true
    }

    /// Add a user message immediately (before DB write) for instant UI feedback.
    public func addUserMessage(text: String) {
        // Fresh prompt → clear any stale error banner from a prior
        // failed attempt so we don't show "old error" + "still thinking…"
        // simultaneously. Matches the Mac ChatViewModel pattern.
        clearACPErrorState()
        // Mark this session as user-engaged so subsequent ACP content
        // events (chunks, tool calls, prompt completes) get processed
        // and rendered. Until this fires, those events are dropped
        // — see `handleACPEvent` for the rationale.
        hasUserSentPromptThisSession = true
        let id = nextLocalId
        nextLocalId -= 1
        let message = HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "user",
            content: text,
            toolCallId: nil,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        )
        messages.append(message)
        // Track the local message in the pending-user-messages cache
        // so a reset/resume cycle on this session before Hermes
        // persists the row can still re-inject it on return (#63).
        if let sid = sessionId {
            pendingLocalUserMessages[sid, default: []].append(message)
        }
        // Per-turn stopwatch (v2.5): record the start time only when
        // we're entering a fresh agent turn. /steer-style mid-run sends
        // arrive while isAgentWorking is already true; preserve the
        // existing start so the captured duration reflects the FULL
        // turn (initial prompt → final reply), not just the time since
        // the user nudged.
        if !isAgentWorking {
            currentTurnStart = Date()
        }
        isAgentWorking = true
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
        buildMessageGroups()
        // User just submitted — jump to the bottom so they see their message
        // and the incoming response. `.defaultScrollAnchor(.bottom)` handles
        // slow streaming fine, but rapid responses (slash commands especially)
        // arrive faster than the anchor can track.
        requestScrollToBottom()
    }

    /// Process a streaming ACP event and update the message list.
    public func handleACPEvent(_ event: ACPEvent) {
        // Cross-session guard: drop events that arrived for a session
        // we're no longer attached to. The previous client's event task
        // is cancelled fire-and-forget in `stop()` (cancellation is a
        // signal, not a synchronous join), so a straggling buffered
        // chunk can land after `vm.reset()` + `setSessionId(new)`. Once
        // the user sends their first prompt the engagement gate opens
        // and the stale chunk would otherwise render as a bubble in
        // the new chat — surfaced in TestFlight feedback as "initial
        // chat message shows from another chat" (AFI4q5, 2026-05-10).
        // `.connectionLost` carries no session id and always passes
        // (it's a transport-level signal, not session-scoped).
        if let mine = sessionId,
           let theirs = event.sessionId,
           theirs != mine {
            return
        }
        // Drop streamed content events until a prompt has been sent in
        // the currently-attached session. Hermes' ACP adapter sometimes
        // emits a stream of agent events after `session/load`
        // (replaying the recent transcript or auto-resuming work for
        // sessions with persistent goals / queued prompts), which the
        // user perceives as bubbles materializing one-by-one when they
        // open an old chat. The DB-fetched history is authoritative for
        // what's already there; once a prompt is actually sent, live
        // agent activity flows through normally.
        //
        // Non-content events (`availableCommands`, `permissionRequest`,
        // `connectionLost`) are always processed — they carry session
        // chrome the user needs regardless of who initiated.
        //
        // `promptComplete` is ALSO never gated (S2, 2026-07-13): it is
        // not part of the replay — the parser never emits it; the send
        // path synthesizes it from `sendPrompt`'s return — and it
        // carries the turn's accounting, the `isAgentWorking` clear,
        // and the no-output failure bubble. Dropping it left a turn
        // whose gate bookkeeping slipped stuck on "Agent working…"
        // forever with no failure feedback.
        if !hasUserSentPromptThisSession {
            switch event {
            // Compaction-summary-flagged replay chunks (Hermes v0.20
            // `_meta.hermes.compactionSummary`) are NOT special-cased
            // here: the DB-hydrated history is authoritative for them
            // too — `HermesDataService.messageFromRow` classifies the
            // persisted rows by their handoff markers and sets the
            // styling flags there, so letting the replay copies through
            // would only double-render (or be clobbered by the
            // subsequent `loadSessionHistory` wholesale replace).
            case .messageChunk, .userMessageChunk, .thoughtChunk, .toolCallStart,
                 .toolCallUpdate:
                ScarfMon.event(.chatStream, "mac.handleACPEvent.preEngagementDropped", count: 1)
                return
            case .promptComplete, .permissionRequest, .connectionLost,
                 .availableCommands, .sessionInfoUpdate, .unknown:
                break
            }
        }
        switch event {
        case .messageChunk(_, let text, _, _):
            appendMessageChunk(text: text)
        case .userMessageChunk:
            // `user_message_chunk` only ever carries replayed history
            // (Scarf never sends a live one, and the pre-engagement
            // gate above drops replay). Anything that slips through
            // post-engagement is defensively ignored — the DB-hydrated
            // history owns replayed user turns.
            break
        case .thoughtChunk(_, let text):
            appendThoughtChunk(text: text)
        case .toolCallStart(_, let call):
            handleToolCallStart(call)
        case .toolCallUpdate(_, let update):
            handleToolCallComplete(update)
        case .permissionRequest(_, let requestId, let request):
            pendingPermission = PendingPermission(
                requestId: requestId,
                title: request.toolCallTitle,
                kind: request.toolCallKind,
                options: request.options
            )
        case .promptComplete(_, let response):
            handlePromptComplete(response: response)
        case .connectionLost(let reason):
            handleConnectionLost(reason: reason)
        case .availableCommands(_, let commands):
            acpCommands = parseACPCommands(commands)
        case .sessionInfoUpdate:
            // The sidebar title mutation is owned by the platform chat VM
            // (ChatViewModel on Mac / ChatView on iOS), which intercepts
            // this event in its ACP event loop and updates recentSessions /
            // sessionPreviews in place. Nothing to do at the rich-transcript
            // level — the live transcript has no title affordance.
            break
        case .unknown:
            break
        }
    }

    private func parseACPCommands(_ commands: [[String: Any]]) -> [HermesSlashCommand] {
        var result: [HermesSlashCommand] = []
        for entry in commands {
            guard let rawName = entry["name"] as? String else { continue }
            // Hermes sends names either as "compress" or "/compress"
            let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { continue }
            let description = (entry["description"] as? String) ?? ""
            var hint: String? = nil
            if let input = entry["input"] as? [String: Any],
               let h = input["hint"] as? String,
               !h.isEmpty {
                hint = h
            }
            result.append(HermesSlashCommand(
                name: name,
                description: description,
                argumentHint: hint,
                source: .acp
            ))
        }
        return result
    }

    /// Load `quick_commands` from `config.yaml` off the main actor and publish
    /// them as slash commands. Safe to call repeatedly — replaces the existing list.
    public func loadQuickCommands() {
        let ctx = context
        Task.detached { [weak self] in
            let loaded = Self.loadQuickCommands(context: ctx)
            let mapped = loaded.map { (name, command) -> HermesSlashCommand in
                let truncated = command.count > 60
                    ? String(command.prefix(60)) + "…"
                    : command
                return HermesSlashCommand(
                    name: name,
                    description: "Run: \(truncated)",
                    argumentHint: nil,
                    source: .quickCommand
                )
            }
            await MainActor.run { [weak self] in
                self?.quickCommands = mapped
            }
        }
    }

    /// Load project-scoped slash commands from
    /// `<projectPath>/.scarf/slash-commands/` off the main actor and
    /// publish them. Safe to call repeatedly — replaces the existing
    /// list (e.g., when the user adds / edits / deletes commands).
    /// Pass `nil` to clear (e.g., on session de-attribution from a
    /// project, or quick-chat sessions).
    public func loadProjectScopedCommands(at projectPath: String?) {
        guard let projectPath else {
            projectScopedCommands = []
            return
        }
        let ctx = context
        Task.detached { [weak self] in
            let svc = ProjectSlashCommandService(context: ctx)
            let loaded = svc.loadCommands(at: projectPath)
            await MainActor.run { [weak self] in
                self?.projectScopedCommands = loaded
            }
        }
    }

    /// Load the global Scarf slash commands from
    /// `~/.hermes/scarf/slash-commands/`. Populated by
    /// `SlashCommandBootstrapService` on app launch; this reads what's
    /// on disk so user edits (and version bumps from a future app
    /// release) reach the menu without a relaunch. Safe to call
    /// repeatedly. Should be called at chat-open time alongside
    /// `loadProjectScopedCommands`.
    public func loadGlobalScopedCommands() {
        let ctx = context
        Task.detached { [weak self] in
            let svc = ProjectSlashCommandService(context: ctx)
            let loaded = svc.loadGlobalCommands()
            await MainActor.run { [weak self] in
                self?.globalScopedCommands = loaded
            }
        }
    }

    /// Parse `quick_commands` from `<context>/config.yaml`. Returns
    /// `[(name, command)]` for every well-formed `type: exec` entry.
    /// Mac-side `QuickCommandsViewModel` uses a richer model + adds
    /// an `isDangerous` check; here we only need the slash-menu
    /// projection, so we keep the parser minimal and ScarfCore-local.
    nonisolated static func loadQuickCommands(context: ServerContext) -> [(name: String, command: String)] {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        var byName: [String: (type: String, command: String)] = [:]
        for (key, value) in parsed.values where key.hasPrefix("quick_commands.") {
            let parts = key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let name = String(parts[1])
            let field = String(parts[2])
            var existing = byName[name] ?? (type: "exec", command: "")
            let stripped = HermesYAML.stripYAMLQuotes(value)
            if field == "type" { existing.type = stripped }
            if field == "command" { existing.command = stripped }
            byName[name] = existing
        }
        return byName.compactMap { (name, entry) in
            guard entry.type == "exec", !entry.command.isEmpty else { return nil }
            return (name: name, command: entry.command)
        }
        .sorted { $0.name < $1.name }
    }

    private func appendMessageChunk(text: String) {
        // ScarfMon "first byte" — fires once per turn, on the first
        // visible message chunk. Splits "user tap → first byte"
        // (network + Hermes thinking) from "first byte → turn end"
        // (streaming + Scarf rendering) so we can attribute slow-feel
        // bugs to the right side. `bytes` carries the first chunk's
        // size, not the full turn.
        if streamingAssistantText.isEmpty && currentTurnStart != nil {
            ScarfMon.event(.chatStream, "firstByte", count: 1, bytes: text.utf8.count)
        }
        streamingAssistantText += text
        upsertStreamingMessage()
    }

    private func appendThoughtChunk(text: String) {
        if streamingThinkingText.isEmpty && currentTurnStart != nil {
            ScarfMon.event(.chatStream, "firstThoughtByte", count: 1, bytes: text.utf8.count)
        }
        streamingThinkingText += text
        upsertStreamingMessage()
    }

    private func handleToolCallStart(_ call: ACPToolCallEvent) {
        let toolCall = HermesToolCall(
            callId: call.toolCallId,
            functionName: call.functionName,
            arguments: call.argumentsJSON,
            startedAt: Date()
        )
        streamingToolCalls.append(toolCall)
        upsertStreamingMessage()
    }

    private func handleToolCallComplete(_ update: ACPToolCallUpdateEvent) {
        // Populate live telemetry on the matching streaming call BEFORE
        // finalizing — once finalize runs, streamingToolCalls is cleared
        // and the call is locked into the parent HermesMessage's `let
        // toolCalls`. Mutating here lets `finalizeStreamingMessage()`
        // promote a HermesToolCall that already carries duration +
        // exitCode for the inspector to render. No-op for sessions
        // loaded from `state.db` (no live event ever fires).
        if let idx = streamingToolCalls.firstIndex(where: { $0.callId == update.toolCallId }) {
            let started = streamingToolCalls[idx].startedAt
            if let started {
                streamingToolCalls[idx].duration = Date().timeIntervalSince(started)
            }
            streamingToolCalls[idx].exitCode = Self.exitCode(forStatus: update.status)
        }

        // Finalize the streaming assistant message (with its tool calls) as a permanent message
        finalizeStreamingMessage()

        // Add tool result message
        let id = nextLocalId
        nextLocalId -= 1
        messages.append(HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "tool",
            content: update.rawOutput ?? update.content,
            toolCallId: update.toolCallId,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        ))
        buildMessageGroups()
    }

    /// Derive a synthetic exit code from the ACP update event's status
    /// string. Hermes reports `completed`/`error`/`failed`/`canceled`;
    /// we collapse to 0 for success, 1 for known-failure variants, nil
    /// for anything else (so the inspector renders "—" rather than
    /// fabricating a value).
    private static func exitCode(forStatus status: String) -> Int? {
        switch status.lowercased() {
        case "completed", "success", "ok": return 0
        case "error", "failed", "canceled", "cancelled": return 1
        default: return nil
        }
    }

    private func handlePromptComplete(response: ACPPromptResult) {
        // Detect a failed prompt that produced no assistant output — e.g.
        // Hermes returning `stopReason: "refusal"` when the session was
        // silently garbage-collected, or `"error"` when the ACP call itself
        // threw. Without surfacing this, the user sees their prompt sitting
        // alone under "Agent working…" that never completes with any text.
        let hadAssistantOutput = streamingAssistantText.isEmpty == false
            || messages.last?.isAssistant == true
        finalizeStreamingMessage()

        if !hadAssistantOutput, response.stopReason != "end_turn" {
            let reason: String
            switch response.stopReason {
            case "refusal":
                reason = "The agent refused to respond (the session may have been cleared on the server). Try starting a new session from the Session menu."
            case "error":
                reason = "The prompt failed — check the ACP error banner above for details."
            case "max_tokens":
                reason = "The response was cut off before the agent could produce any output (max_tokens reached before any tokens were emitted)."
            default:
                reason = "The prompt ended without a response (stopReason: \(response.stopReason))."
            }
            let id = nextLocalId
            nextLocalId -= 1
            messages.append(HermesMessage(
                id: id,
                sessionId: sessionId ?? "",
                role: "system",
                content: reason,
                toolCallId: nil,
                toolCalls: [],
                toolName: nil,
                timestamp: Date(),
                tokenCount: nil,
                finishReason: response.stopReason,
                reasoning: nil
            ))
            // Pass-1 M7 #2: surface the same failure as a top-of-chat
            // error banner with the stderr tail, so users don't have
            // to rely solely on the system-message to understand why
            // nothing happened. The controller registers
            // `acpStderrProvider`; if absent, the banner still shows
            // with the hint fallback.
            Task { await self.recordPromptStopFailureUsingProvider(stopReason: response.stopReason) }
        }

        // Accumulate token usage from this prompt
        acpInputTokens += response.inputTokens
        acpOutputTokens += response.outputTokens
        acpThoughtTokens += response.thoughtTokens
        acpCachedReadTokens += response.cachedReadTokens
        // Compression count is a session-wide running total emitted by
        // Hermes; each prompt response carries the latest value, so we
        // replace rather than accumulate. The `max` guard tolerates
        // pre-v0.13 hosts (which emit 0) being upgraded server-side
        // mid-session — once a real number lands the count resumes from
        // there rather than snapping back to 0.
        acpCompressionCount = max(acpCompressionCount, response.compressionCount)
        isAgentWorking = false
        // v2.8 / Hermes v0.13 — Hermes runs the next `/queue`-deferred
        // prompt server-side now that this turn has settled. Drain the
        // local mirror FIFO so the header chip count matches what the
        // user staged. Best-effort: if Hermes' authoritative queue
        // diverged (deferred prompt aborted, dropped on disconnect),
        // the chip is one tick stale until the user's next interaction.
        if !queuedPrompts.isEmpty {
            popQueuedPrompt()
        }
        // TODO(v2.8.1): when this completes after an auto-resumed
        // checkpoint (Hermes v0.13's "Auto-resume interrupted sessions
        // after gateway restart"), surface a one-shot "Auto-resumed
        // from checkpoint" indicator. Wire-shape unknown until a v0.13
        // dogfooding pass confirms whether the resume lands as a
        // visible ACP event or is purely server-side. Deferred from
        // v2.8.0 per WS-2 plan Q3.
        buildMessageGroups()
        // Final position after the prompt settles. Catches fast responses
        // (slash commands, short replies) where `.defaultScrollAnchor(.bottom)`
        // didn't quite track the abrupt content growth.
        requestScrollToBottom()
    }

    private func handleConnectionLost(reason: String) {
        finalizeStreamingMessage()
        let id = nextLocalId
        nextLocalId -= 1
        messages.append(HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "system",
            content: "Connection lost: \(reason). Use the Session menu to start or resume a session.",
            toolCallId: nil,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        ))
        isAgentWorking = false
        pendingPermission = nil
        buildMessageGroups()
    }

    // MARK: - Streaming Message Management

    private static let streamingId = 0

    /// Insert or update the in-progress streaming assistant message (id=0).
    ///
    /// On update we preserve the first-seen timestamp; otherwise the
    /// per-chunk re-stamp would let a finalize race surface as the
    /// assistant landing ahead of its user prompt in the chronological
    /// sort (the prompt-jump bug).
    private func upsertStreamingMessage() {
        let existingIdx = messages.firstIndex(where: { $0.id == Self.streamingId })
        let timestamp = existingIdx.map { messages[$0].timestamp } ?? Date()
        let msg = HermesMessage(
            id: Self.streamingId,
            sessionId: sessionId ?? "",
            role: "assistant",
            content: streamingAssistantText,
            toolCallId: nil,
            toolCalls: streamingToolCalls,
            toolName: nil,
            timestamp: timestamp,
            tokenCount: nil,
            finishReason: nil,
            reasoning: streamingThinkingText.isEmpty ? nil : streamingThinkingText
        )

        if let idx = existingIdx {
            messages[idx] = msg
        } else {
            messages.append(msg)
        }
        patchTrailingGroupForStreaming(streamingMsg: msg)
    }

    /// Per-chunk fast path for `messageGroups` (issue #46). Mutates
    /// only the trailing group's assistant entry instead of rebuilding
    /// the entire `messageGroups` array via `buildMessageGroups()` on
    /// every streamed token.
    ///
    /// Falls back to a full rebuild whenever it can't safely patch:
    ///  - no trailing group exists yet (e.g. first chunk after `reset`)
    ///  - the trailing group is a user-only group (the very first chunk
    ///    of a brand-new turn — we need a full rebuild so the assistant
    ///    is grouped under the right user message)
    ///
    /// Other call sites of `buildMessageGroups()` are intentionally
    /// untouched: they handle structural events (user message, tool
    /// call complete, finalize, session resume) where group boundaries
    /// can change, and a full rebuild is the right move there.
    private func patchTrailingGroupForStreaming(streamingMsg: HermesMessage) {
        guard let lastIdx = messageGroups.indices.last else {
            buildMessageGroups()
            return
        }
        let trailing = messageGroups[lastIdx]
        var assistants = trailing.assistantMessages
        if let i = assistants.firstIndex(where: { $0.id == Self.streamingId }) {
            assistants[i] = streamingMsg
        } else {
            assistants.append(streamingMsg)
        }
        messageGroups[lastIdx] = MessageGroup(
            id: trailing.id,
            userMessage: trailing.userMessage,
            assistantMessages: assistants,
            toolResults: trailing.toolResults
        )
    }

    /// Convert the streaming message (id=0) into a permanent message and reset streaming state.
    private func finalizeStreamingMessage() {
        ScarfMon.measure(.chatStream, "finalizeStreamingMessage") {
            _finalizeStreamingMessageImpl()
        }
    }

    private func _finalizeStreamingMessageImpl() {
        guard let idx = messages.firstIndex(where: { $0.id == Self.streamingId }) else { return }

        // Only finalize if there's actual content
        let hasContent = !streamingAssistantText.isEmpty
            || !streamingThinkingText.isEmpty
            || !streamingToolCalls.isEmpty

        // ScarfMon — surface turns that finalize with NO visible
        // assistant text. Common Nous-model failure mode: model
        // emits a few thought-stream bytes then falls silent;
        // Hermes finalizes with empty content; the user sees a
        // stuck "(°□°) deliberating..." placeholder bubble. The
        // event fires for both the all-empty case (which gets
        // removed below) and the thoughts-only case (which is
        // kept as a permanent message with empty body) — both
        // are user-visible failures worth tracking.
        if streamingAssistantText.isEmpty && streamingToolCalls.isEmpty {
            ScarfMon.event(
                .chatStream,
                "emptyAssistantTurn",
                count: 1,
                bytes: streamingThinkingText.utf8.count
            )
        }

        if hasContent {
            let id = nextLocalId
            nextLocalId -= 1
            // Wrap the streaming-id rewrite in a no-animation
            // transaction. Without this SwiftUI sees an identity
            // change for the streaming ForEach element (id 0 → new
            // permanent id) and runs an animated diff against
            // adjacent elements, which costs ~5–8 RichMessageBubble
            // body re-evaluations per turn-end (visible in the
            // ScarfMon ring as a 1–2 ms burst right after every
            // `finalizeStreamingMessage` interval). The new message
            // is content-equal to the streaming one — there is no
            // animation worth running.
            // Preserve the streaming message's original timestamp.
            // Re-stamping with `Date()` here used to let a polling tick
            // that landed mid-finalize push the assistant's chronology
            // ahead of its actual position — the prompt-jump bug.
            let preservedTimestamp = messages[idx].timestamp ?? Date()
            withTransaction(Transaction(animation: nil)) {
                messages[idx] = HermesMessage(
                    id: id,
                    sessionId: sessionId ?? "",
                    role: "assistant",
                    content: streamingAssistantText,
                    toolCallId: nil,
                    toolCalls: streamingToolCalls,
                    toolName: nil,
                    timestamp: preservedTimestamp,
                    tokenCount: nil,
                    finishReason: streamingToolCalls.isEmpty ? "stop" : nil,
                    reasoning: streamingThinkingText.isEmpty ? nil : streamingThinkingText
                )
            }
            // Capture per-turn duration so the chat UI can render the
            // stopwatch pill (v2.5). Skips assistants we don't have a
            // start time for — e.g., the .promptComplete fired but the
            // turn began before this VM was constructed (shouldn't
            // happen in practice but guards an edge case).
            if let start = currentTurnStart {
                turnDurations[id] = Date().timeIntervalSince(start)
                currentTurnStart = nil
            }
        } else {
            // Remove empty streaming placeholder. Same no-animation
            // transaction pattern — empty-finalize used to ripple the
            // ForEach diff to every following bubble.
            withTransaction(Transaction(animation: nil)) {
                _ = messages.remove(at: idx)
            }
        }

        // Reset streaming state for next chunk
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
    }

    // MARK: - Disconnect Recovery

    /// Finalize streaming state on disconnect, before reconnection attempts begin.
    /// Saves partial content as a permanent message without adding a system message.
    public func finalizeOnDisconnect() {
        finalizeStreamingMessage()
        isAgentWorking = false
        pendingPermission = nil
        buildMessageGroups()
    }

    /// Reconcile in-memory messages with DB state after a successful reconnection.
    /// Merges DB-persisted messages with any local-only messages (e.g., user messages
    /// that the ACP process may not have persisted before crashing).
    public func reconcileWithDB(sessionId: String) async {
        let opened = await dataService.open()
        guard opened else { return }

        // Reconnects don't generate hundreds of unseen messages, so a
        // 200-row tail is plenty for the merge — and it keeps us from
        // re-materializing 1000+ message sessions on every reconnect.
        var dbMessages = await dataService.fetchMessages(sessionId: sessionId, limit: HistoryPageSize.reconcile)

        // If we have an origin session (CLI session continued via ACP),
        // include those messages too
        if let origin = originSessionId, origin != sessionId {
            let originMessages = await dataService.fetchMessages(sessionId: origin, limit: HistoryPageSize.reconcile)
            if !originMessages.isEmpty {
                dbMessages = originMessages + dbMessages
                dbMessages.sort(by: HermesMessage.chronologicalOrder)
            }
        }

        let session = await dataService.fetchSession(id: sessionId)
        await dataService.close()

        // Find local-only user messages not yet in DB.
        // Local messages have negative IDs; DB messages have positive IDs.
        let dbUserContents = Set(dbMessages.filter(\.isUser).map(\.content))
        let localOnlyMessages = messages.filter { msg in
            msg.id < 0 && msg.isUser && !dbUserContents.contains(msg.content)
        }

        // Build reconciled list: DB messages + unmatched local user messages
        var reconciled = dbMessages
        for localMsg in localOnlyMessages {
            if let ts = localMsg.timestamp,
               let insertIdx = reconciled.firstIndex(where: { ($0.timestamp ?? .distantPast) > ts }) {
                reconciled.insert(localMsg, at: insertIdx)
            } else {
                reconciled.append(localMsg)
            }
        }

        messages = reconciled
        currentSession = session
        let minId = reconciled.map(\.id).min() ?? 0
        nextLocalId = min(minId - 1, -1)
        buildMessageGroups()
    }

    // MARK: - Load History from DB (for resumed sessions)

    /// Load message history from the DB, optionally combining an origin session
    /// (e.g., CLI session) with the current ACP session.
    public func loadSessionHistory(sessionId: String, acpSessionId: String? = nil) async {
        await ScarfMon.measureAsync(.sessionLoad, "mac.hydrateMessages") {
        self.sessionId = sessionId
        // Capture the session-id we're loading FOR so we can verify
        // it's still the active one before assigning to `messages`.
        // Without this guard, switching to a small chat while a
        // larger one is mid-fetch can result in last-write-wins:
        // the slow fetch finishes after the small chat's, drops
        // the user back into the big chat's transcript, and the
        // user has to reselect the small one. Observed in remote
        // perf captures (parallel fetchMessages calls, one timing
        // out at 30s for a 157-message session, the other 2-message
        // chat completing in 425ms; the 30s one's assignment
        // overwrote the small chat).
        let loadingForSession = sessionId
        // Force a fresh snapshot pull on remote contexts. An earlier open()
        // would have cached a stale copy — on resume we need whatever
        // Hermes has actually persisted since then, or the resumed session
        // will show only history up to the moment the snapshot was taken.
        // `forceFresh: true` refuses the stale-snapshot fallback the data
        // service grew in M11 — falling back here would silently hide
        // messages the agent streamed during the user's offline window.
        let opened = await dataService.refresh(forceFresh: true)
        guard opened else { return }
        // Race-check #1: session id may have changed during refresh.
        guard self.sessionId == loadingForSession else {
            ScarfMon.event(.sessionLoad, "mac.hydrateMessages.dropped", count: 1)
            return
        }

        // v2.8 two-phase loader. Phase 1 — skeleton: user + assistant
        // rows only, no tool_calls JSON, no reasoning, no
        // reasoning_content. Wire payload bounded by conversational
        // text alone so chats with multi-page tool result blobs (the
        // 30s-timeout case) come up in seconds. Phase 2 (kicked off
        // below in a Task.detached) fills tool calls + tool results in
        // the background — the chat is usable while it runs.
        let pageSize = HistoryPageSize.initial
        let originOutcome = await dataService.fetchSkeletonMessages(sessionId: sessionId, limit: pageSize)
        var allMessages = originOutcome.messages
        var transportFailure: String? = originOutcome.transportError
        // Race-check #2: session id may have changed during the
        // long fetch (the most common race — a 30s timeout on a
        // big session lets the user switch to a small one and back).
        guard self.sessionId == loadingForSession else {
            ScarfMon.event(.sessionLoad, "mac.hydrateMessages.dropped", count: 1)
            return
        }
        // The DB has more on-disk history when the initial fetch
        // saturated the limit. The "Load earlier" affordance reads
        // this flag.
        var moreHistory = allMessages.count >= pageSize
        let session = await dataService.fetchSession(id: sessionId)

        // If the ACP session is different from the origin, load its messages too
        // and combine them chronologically
        if let acpId = acpSessionId, acpId != sessionId {
            originSessionId = sessionId
            self.sessionId = acpId
            let acpOutcome = await dataService.fetchSkeletonMessages(sessionId: acpId, limit: pageSize)
            // Race-check #3: same guard, after the second fetch.
            guard self.sessionId == acpId else {
                ScarfMon.event(.sessionLoad, "mac.hydrateMessages.dropped", count: 1)
                return
            }
            if let acpErr = acpOutcome.transportError, transportFailure == nil {
                transportFailure = acpErr
            }
            if !acpOutcome.messages.isEmpty {
                allMessages.append(contentsOf: acpOutcome.messages)
                allMessages.sort(by: HermesMessage.chronologicalOrder)
                moreHistory = moreHistory || acpOutcome.messages.count >= pageSize
            }
        }

        // Issue #63 — re-inject any locally-created user messages
        // we still have on file for this session that haven't yet
        // shown up in state.db. Covers two paths:
        //   1. The user just sent a prompt then resumed a different
        //      session before Hermes persisted the row. `reset()` had
        //      cleared `messages` but the per-session pending cache
        //      survived; restore the row here so the bubble doesn't
        //      come back blank.
        //   2. The DB-resume path on first load — a previously-pending
        //      message Hermes is still mid-write may not appear in
        //      this fetch. We merge it in, and drop it from the cache
        //      as soon as a matching DB row (same content, persisted
        //      id ≥ 0) shows up.
        let pendingForSession = pendingLocalUserMessages[sessionId] ?? []
        if pendingForSession.isEmpty {
            messages = allMessages
        } else {
            var merged = allMessages
            var stillPending: [HermesMessage] = []
            for local in pendingForSession {
                let persisted = merged.contains { msg in
                    msg.isUser && msg.id >= 0 && msg.content == local.content
                }
                if persisted {
                    continue // DB caught up — drop the local copy
                }
                if !merged.contains(where: { $0.id == local.id }) {
                    merged.append(local)
                }
                stillPending.append(local)
            }
            merged.sort(by: HermesMessage.chronologicalOrder)
            messages = merged
            if stillPending.isEmpty {
                pendingLocalUserMessages.removeValue(forKey: sessionId)
            } else {
                pendingLocalUserMessages[sessionId] = stillPending
            }
        }
        currentSession = session
        let minId = messages.map(\.id).min() ?? 0
        nextLocalId = min(minId - 1, -1)
        // Track the oldest loaded id from THIS session (not the merged
        // origin) so `loadEarlier()` pages back through the live ACP
        // session's history. Cross-session backfill (paging into the
        // CLI origin) isn't supported in v1 — the merged 2× pageSize
        // is enough headroom for the dashboard-resume case.
        let currentSessionId = self.sessionId ?? sessionId
        oldestLoadedMessageID = allMessages
            .filter { $0.sessionId == currentSessionId }
            .map(\.id)
            .min()
        hasMoreHistory = moreHistory
        ScarfMon.event(.sessionLoad, "mac.hydrateMessages.rows", count: messages.count)
        buildMessageGroups()
        // Session activation: `.defaultScrollAnchor(.bottom)` only fires
        // on initial ScrollView mount. When the user activates a
        // different session while the chat surface stays on screen,
        // the existing ScrollView keeps its prior offset and the new
        // transcript appears wherever the last one happened to scroll
        // to. Bump the trigger so the bottom sentinel re-anchors —
        // mirrors the `addUserMessage` / `handlePromptComplete` bumps.
        requestScrollToBottom()

        // Partial-result detection — if a fetch tripped a transport
        // failure (SSH timeout / ControlMaster drop) the user is now
        // looking at zero or near-zero messages with no idea why. The
        // pre-v2.8 behavior was a silent empty transcript. Surface a
        // banner via the existing acpError triplet so the user sees
        // "couldn't load full history — connection slow." We assume
        // more history exists (so the "Load earlier" affordance is
        // honest about the gap) — caller can retry by reopening the
        // session.
        if let reason = transportFailure {
            acpError = "Couldn't load full chat history — the connection to \(dataService.context.displayName) timed out."
            acpErrorHint = "Reopen the session to retry, or check the SSH link if this keeps happening."
            acpErrorDetails = reason
            acpErrorOAuthProvider = nil
            hasMoreHistory = true
        } else {
            // v2.8 — kick off background hydration of tool_calls JSON
            // and tool result rows for the just-loaded skeleton.
            // Non-blocking on the main load path (chat is usable).
            startToolHydration(loadingForSession: self.sessionId ?? sessionId)
        }
        } // end measureAsync(.sessionLoad, "mac.hydrateMessages")
    }

    /// Phase 2 of the two-phase chat loader. Pulls `tool_calls` JSON
    /// for the loaded assistant rows, then fetches `role='tool'` rows
    /// in the loaded id range and splices both into `messages` /
    /// `messageGroups` without disturbing what the user is already
    /// reading. Cancellable — restarting (a session switch, a
    /// `reset()`) drops any in-flight pass.
    ///
    /// Tool calls go in first because they live ON the existing
    /// assistant message and surface the most-visible UI affordance
    /// (the tool card chips). Tool result content rows go in second
    /// because they're the heaviest payload and the UI degrades
    /// gracefully without them (the cards still show "running" /
    /// "complete" state; only the result body is missing).
    private func startToolHydration(loadingForSession: String) {
        hydrationTask?.cancel()
        let sessionForLoad = loadingForSession
        let dataService = self.dataService
        hydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isHydratingTools = true
            defer { self.isHydratingTools = false }

            // Snapshot the assistant ids + id range from the messages
            // we just loaded. Doing this on MainActor keeps us in step
            // with the observable view of `messages`; the actual
            // SQL calls happen in `await` slots that release the actor.
            let assistantIds = self.messages
                .filter { $0.isAssistant && $0.id > 0 }
                .map(\.id)
            guard let minId = self.messages.map(\.id).min(),
                  let maxId = self.messages.map(\.id).max(),
                  !assistantIds.isEmpty || minId < maxId else {
                return
            }

            // Phase 2a — tool_calls JSON. Splice parsed values into
            // each assistant message that has them.
            let toolCallMap = await dataService.hydrateAssistantToolCalls(messageIds: assistantIds)
            if Task.isCancelled || self.sessionId != sessionForLoad {
                ScarfMon.event(.sessionLoad, "mac.hydrateTools.dropped", count: 1)
                return
            }
            if !toolCallMap.isEmpty {
                self.messages = self.messages.map { msg in
                    guard msg.isAssistant, let calls = toolCallMap[msg.id] else { return msg }
                    return msg.withToolCalls(calls)
                }
                self.buildMessageGroups()
            }

            // Phase 2b — tool result rows. Default OFF (v2.8). A
            // single tool result blob (file dump, stack trace) can run
            // hundreds of KB; bulk-fetching all of them during chat
            // resume on a slow remote was the cause of the 30s timeout
            // observed in 2026-05-05 dogfooding. Users can opt in via
            // Settings → Display → "Load tool results in past chats"
            // when bandwidth is plentiful. Tool call CARDS still
            // render either way (`tool_calls` JSON loads in Phase 2a);
            // only the inspector pane's "Output" section is empty
            // until the user opens a card, at which point a per-call
            // lazy fetch fills it in.
            let loadResults = UserDefaults.standard.bool(
                forKey: Self.loadHistoricalToolResultsKey
            )
            guard loadResults else {
                ScarfMon.event(.sessionLoad, "mac.hydrateTools.skippedToolResults", count: 1)
                return
            }
            let toolResults = await dataService.fetchToolResultsInRange(
                sessionId: sessionForLoad,
                minId: minId,
                maxId: maxId
            )
            if Task.isCancelled || self.sessionId != sessionForLoad {
                ScarfMon.event(.sessionLoad, "mac.hydrateTools.dropped", count: 1)
                return
            }
            if !toolResults.isEmpty {
                var merged = self.messages
                let existingIds = Set(merged.map(\.id))
                for tr in toolResults where !existingIds.contains(tr.id) {
                    merged.append(tr)
                }
                merged.sort { lhs, rhs in
                    let lt = lhs.timestamp ?? .distantPast
                    let rt = rhs.timestamp ?? .distantPast
                    if lt != rt { return lt < rt }
                    return lhs.id < rhs.id
                }
                self.messages = merged
                self.buildMessageGroups()
            }
            ScarfMon.event(.sessionLoad, "mac.hydrateTools.complete", count: 1)
        }
    }

    /// Lazy-load the rich `reasoning_content` (v0.11) for a settled
    /// message on demand. The bulk/skeleton fetch excludes it (issue #74)
    /// and carries only the lighter `reasoning` channel, so the chat bubble
    /// upgrades to the full chain-of-thought when the user opens the
    /// REASONING disclosure. Returns nil on pre-v0.11 hosts or when the
    /// message has no reasoning_content. (t-aud21)
    @MainActor
    public func reasoningContent(for messageId: Int) async -> String? {
        await dataService.fetchReasoningContent(for: messageId)
    }

    /// Lazy-load the content of a single tool result by call id and
    /// splice it into `messages` / `messageGroups` as a synthetic
    /// `role='tool'` row. Used by `ChatInspectorPane` when the user
    /// opens a tool call card whose result hasn't been hydrated yet
    /// (auto-hydrate is opt-in via `loadHistoricalToolResultsKey`).
    /// No-op when the result is already present in the transcript or
    /// the session id has changed underneath us.
    @MainActor
    public func loadToolResultIfMissing(callId: String) async {
        guard let sessionForLoad = sessionId else { return }
        // Already in the transcript? Done.
        if messages.contains(where: { $0.toolCallId == callId && $0.isToolResult }) {
            return
        }
        guard let content = await dataService.fetchToolResult(callId: callId) else {
            return
        }
        guard self.sessionId == sessionForLoad else { return }
        // Build a synthetic tool result row. We don't have the original
        // row id (would need a second SELECT) so we use a negative
        // local id that won't collide with persisted rows. The bubble
        // and inspector both key on `toolCallId`, not `id`, for tool
        // results — so this is enough to render correctly.
        let placeholderId = nextLocalId
        nextLocalId -= 1
        let synthetic = HermesMessage(
            id: placeholderId,
            sessionId: sessionForLoad,
            role: "tool",
            content: content,
            toolCallId: callId,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil,
            reasoningContent: nil
        )
        messages.append(synthetic)
        // Re-sort so the tool result lands next to its assistant
        // parent. ID-based ordering preserves the chronological order
        // of all the persisted rows; the synthetic placeholder uses a
        // negative id so it slots in last — fine for inspector display
        // since the inspector keys on toolCallId.
        messages.sort(by: HermesMessage.chronologicalOrder)
        buildMessageGroups()
        ScarfMon.event(.sessionLoad, "mac.lazyToolResult.fetched", count: 1)
    }

    // MARK: - Load Earlier (pagination)

    /// Page back through the current session's DB-persisted history
    /// before `oldestLoadedMessageID` and prepend the page to
    /// `messages`. Cheap on the SQLite side (`id` is the primary
    /// key); the cost is the data-service `open()` round-trip on
    /// remote contexts. `pageSize` defaults to the same 200-row
    /// budget as the initial load.
    public func loadEarlier(pageSize: Int = HistoryPageSize.initial) async {
        guard !isLoadingEarlier, hasMoreHistory else { return }
        guard let sessionId, let oldest = oldestLoadedMessageID else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }

        let opened = await dataService.open()
        guard opened else { return }

        let older = await dataService.fetchMessages(
            sessionId: sessionId,
            limit: pageSize,
            before: oldest
        )
        guard !older.isEmpty else {
            hasMoreHistory = false
            return
        }
        messages.insert(contentsOf: older, at: 0)
        oldestLoadedMessageID = older.first?.id
        // If this fetch returned fewer than the page size we've hit
        // the bottom of the table — no further pages worth fetching.
        hasMoreHistory = older.count >= pageSize
        buildMessageGroups()
    }

    // MARK: - DB Polling (terminal mode fallback)

    public func markAgentWorking() {
        isAgentWorking = true
        userSendPending = true
        startActivePolling()
    }

    public func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.refreshMessages()
        }
    }

    public func refreshMessages() async {
        // Polling tick (terminal mode): pull a fresh snapshot so remote
        // reflects Hermes writes since the last tick. On local this is a
        // cheap reopen of the live DB.
        let opened = await dataService.refresh()
        guard opened else { return }

        if sessionId == nil {
            if let resetTime = resetTimestamp {
                if let candidate = await dataService.fetchMostRecentlyStartedSessionId(after: resetTime) {
                    sessionId = candidate
                }
            }
            if sessionId == nil {
                sessionId = await dataService.fetchMostRecentlyActiveSessionId()
            }
        }

        guard let sessionId else { return }

        let fingerprint = await dataService.fetchMessageFingerprint(sessionId: sessionId)

        if fingerprint != lastKnownFingerprint {
            let fetched = await dataService.fetchMessages(sessionId: sessionId, limit: HistoryPageSize.polling)
            let session = await dataService.fetchSession(id: sessionId)
            lastKnownFingerprint = fingerprint

            messages = Self.mergedAfterPoll(fetched: fetched, currentLocal: messages)
            currentSession = session
            buildMessageGroups()

            let derivedWorking = deriveAgentWorking(from: fetched)
            if userSendPending {
                if fetched.last?.isUser == true {
                    userSendPending = false
                }
                isAgentWorking = true
            } else {
                let wasWorking = isAgentWorking
                isAgentWorking = derivedWorking
                if wasWorking && !derivedWorking {
                    stopActivePolling()
                }
            }
        }
    }

    /// Merge a polling-tick DB snapshot with the current in-memory
    /// state, preserving local-only rows (streaming chunk, optimistic
    /// user msg, optimistic tool-result placeholder) whose semantic
    /// twin hasn't yet appeared in `fetched`.
    ///
    /// Without this guard the bare `messages = fetched` swap at line
    /// ~1724 would briefly drop the streaming bubble or a tool result
    /// placeholder that Hermes hasn't committed to `state.db` yet —
    /// visible as the prompt-jump symptom (issue tracked alongside
    /// the v2.7-era ordering rework).
    nonisolated static func mergedAfterPoll(
        fetched: [HermesMessage],
        currentLocal: [HermesMessage]
    ) -> [HermesMessage] {
        let dbUserContents = Set(fetched.filter(\.isUser).map(\.content))
        let dbToolCallIds = Set(fetched.compactMap { $0.role == "tool" ? $0.toolCallId : nil })
        var merged = fetched
        for msg in currentLocal {
            // Persisted DB rows always have positive ids; only locals
            // (negative id) and the streaming chunk (id == 0) qualify
            // for survival.
            guard msg.id <= 0 else { continue }
            if msg.id == 0 {
                // Streaming assistant — DB never carries id == 0, so
                // this is always purely local. Keep until finalize
                // flips it to a negative permanent id.
                merged.append(msg)
                continue
            }
            if msg.isUser, !dbUserContents.contains(msg.content) {
                merged.append(msg)
                continue
            }
            if msg.role == "tool", let callId = msg.toolCallId, !dbToolCallIds.contains(callId) {
                merged.append(msg)
                continue
            }
        }
        merged.sort(by: HermesMessage.chronologicalOrder)
        return merged
    }

    private func startActivePolling() {
        stopActivePolling()
        activePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshMessages()
            }
        }
    }

    private func stopActivePolling() {
        activePollingTimer?.invalidate()
        activePollingTimer = nil
    }

    private func deriveAgentWorking(from fetched: [HermesMessage]) -> Bool {
        guard let last = fetched.last else { return false }
        if last.isUser { return true }
        if last.isToolResult { return true }
        if last.isAssistant {
            if !last.toolCalls.isEmpty {
                let allCallIds = Set(last.toolCalls.map(\.callId))
                let resultCallIds = Set(fetched.compactMap { $0.isToolResult ? $0.toolCallId : nil })
                return !allCallIds.subtracting(resultCallIds).isEmpty
            }
            return last.finishReason == nil
        }
        return false
    }

    // MARK: - Message Grouping

    private func buildMessageGroups() {
        var groups: [MessageGroup] = []
        var currentUser: HermesMessage?
        var currentAssistant: [HermesMessage] = []
        var currentToolResults: [String: HermesMessage] = [:]
        var groupIndex = 0

        func flushGroup() {
            if currentUser != nil || !currentAssistant.isEmpty {
                // Use stable sequential IDs so SwiftUI doesn't re-create views
                // when streaming messages finalize (id changes from 0 to -N)
                groups.append(MessageGroup(
                    id: groupIndex,
                    userMessage: currentUser,
                    assistantMessages: currentAssistant,
                    toolResults: currentToolResults
                ))
                groupIndex += 1
            }
            currentUser = nil
            currentAssistant = []
            currentToolResults = [:]
        }

        for message in messages {
            if message.isUser {
                flushGroup()
                currentUser = message
            } else if message.isToolResult {
                if let callId = message.toolCallId {
                    currentToolResults[callId] = message
                }
                currentAssistant.append(message)
            } else {
                if currentUser == nil && !currentAssistant.isEmpty && message.isAssistant {
                    flushGroup()
                }
                currentAssistant.append(message)
            }
        }
        flushGroup()

        messageGroups = groups
    }
}

#endif // canImport(SQLite3)
