import Foundation
import ScarfCore
import os

/// What a `ChatSession` needs from the window that holds it. Kept small
/// and explicit so the chat never reaches the window through a strong
/// back-reference: the session list and its caches, the config-diagnostics
/// sheet, the Live Voice controller and the routing seams all stay on
/// `ChatViewModel`. Held weakly by the chat.
protocol ChatSessionHost: AnyObject {
    /// Test / Bot Chat override for the per-chat client factory. Nil = the
    /// chat builds its own `ACPClient.forMacApp` with its own hint slot.
    var acpClientFactoryOverride: ((ServerContext, String?) -> ACPClient)? { get }
    /// The window's capability store (`ChatViewModel.attachCapabilitiesStore`).
    var capabilitiesStore: HermesCapabilitiesStore? { get }
    /// The sidebar's rows (the resume step reads a listed row's `source`).
    var recentSessions: [HermesSession] { get }
    /// The compression chain `sessionId` belongs to (`ChatViewModel.transcriptLineage`).
    func transcriptLineage(for sessionId: String) -> [String]
    func loadRecentSessions() async
    func scheduleSessionsRefresh()
    /// A `session_info_update` title, applied to the sidebar caches.
    func applySessionTitleUpdate(sessionId: String, title: String?)
    /// `hermes sessions rename` through the window's seam (`/title`, `/new <name>`).
    func renameSession(_ sessionId: String, to newTitle: String) async -> Bool
    /// Why the last rename failed (`/title`'s failure hint).
    var renameError: String? { get }
    /// `/new` sent from `chat`: the window's full start-new-session path.
    /// `pendingTitle` is `/new <name>`'s name, handed to whichever chat the
    /// window starts (with parallel chats usually not `chat` itself). The
    /// window ignores it from a chat it isn't showing (a held `/new`
    /// released in the background).
    func startNewSessionFromChat(_ chat: ChatSession, pendingTitle: String?)
    /// A `/goal <target>` was sent: maybe raise the kanban teaching sheet.
    func offerKanbanOnboarding()
    /// The start preflight found no model configured: raise the window's
    /// sheet. `chat` is the one that bailed; its `pendingStartArgs` are what
    /// a pick replays, whichever chat is focused by then.
    func presentModelPreflight(for chat: ChatSession, reason: String?, customProviders: ModelPreflight.CustomProviders)
    /// A deliberate teardown (`ChatSession.stop`) removes the Live Voice turn
    /// host — when `chat` is the one the window shows.
    func chatWillTearDown(_ chat: ChatSession)
    /// The ACP connection died: end Live Voice for a lost connection, when
    /// `chat` is the one the window shows.
    func chatConnectionDied(_ chat: ChatSession)
    /// `chat` ended up with no connection and nothing running: its start
    /// failed or timed out, or its reconnect ladder gave up. The window
    /// drops it when it isn't the one shown (`ChatViewModel.leave`).
    func chatSettledWithoutConnection(_ chat: ChatSession)
    /// The live-chat budget (`LiveChatBudget`) for a spawn `chat` is about
    /// to make. True: go ahead. False: every slot on its host is taken by a
    /// working chat; the window asks the user to stop one or wait, runs
    /// `replay` once one is stopped, `onWait` if they wait. Bot Chat's
    /// single chat is always admitted.
    func admitSpawn(for chat: ChatSession, replay: @escaping () -> Void, onWait: (() -> Void)?) -> Bool
    /// `chat` let go of its process (`releaseProcess`): the window bounds
    /// how many such transcripts it keeps.
    func chatDidReleaseProcess(_ chat: ChatSession)
    /// A turn the user started in `chat` ended with Hermes's answer:
    /// the window marks it unread when it isn't the chat shown and decides
    /// whether to notify. `preview` is the reply's text.
    func chatDidFinishTurn(_ chat: ChatSession, preview: String)
    /// `chat` now holds a process slot: the window's concurrency analytics.
    func chatDidTakeProcess(_ chat: ChatSession)
    /// A blocked start carrying a kickoff prompt was told to wait: the
    /// window keeps the prompt (`ChatViewModel.parkedKickoffs`).
    func parkKickoff(projectPath: String?, initialPrompt: String)
    /// `chat`'s approval/question queue changed: `added` arrived, `removed`
    /// (request ids) were answered, settled by Hermes or dropped. The
    /// window posts and withdraws the "needs your answer" notifications.
    func chatPermissionsChanged(
        _ chat: ChatSession,
        added: [RichChatViewModel.PendingPermission],
        removed: [Int]
    )
}

/// One chat and the `hermes acp` connection it runs on: the transcript
/// (`RichChatViewModel`), the ACP client, its event loop, health monitor
/// and reconnect ladder, the prompt turns in flight, held sends, and the
/// session-start pipeline. Extracted from `ChatViewModel` (parallel chats
/// P0); the window-level `ChatViewModel` holds several (P1) and forwards to
/// the one it shows (`focusedChat`).
@Observable
final class ChatSession {
    /// Identity within the window. Not the session id: that is nil until
    /// the start is ready, changes on a #146 fallback and on a compression
    /// rotation (`covers(_:)` is the session lookup).
    let id = UUID()

    /// When the window last showed this chat; the newest one seeds a new
    /// chat's ACP commands. Set by `ChatViewModel.focus(_:)`.
    @ObservationIgnored
    var lastFocusedAt = Date()

    /// When the user last showed this chat or it last finished a turn: the
    /// budget releases the least recently used idle chat first.
    @ObservationIgnored
    var lastUsedAt = Date()

    /// The window shows this chat (its `focusedChat`). The budget never
    /// releases a chat someone is looking at. Set by the window.
    @ObservationIgnored
    var isShownInWindow = false

    /// Its window dropped it (`ChatViewModel.drop`): nothing can show it
    /// again.
    @ObservationIgnored
    var wasDropped = false

    /// What the user typed (and attached) here and hasn't sent. Kept per
    /// chat, so it survives moving to another chat and back, and a
    /// release; cleared when the chat is reused for another session.
    let composer = ComposerDraft()

    /// A reply finished while the window showed another chat; cleared when
    /// this chat is focused. The list row shows it (`rowState`). Scarf's
    /// own, beside Hermes's read watermark (`HermesSession.isUnread`).
    var hasUnreadCompletion = false

    /// The "needs your answer" notification posted for each queued request
    /// (request id → notification id), so answering it — or Hermes
    /// settling it — withdraws exactly that one. Kept by the window.
    @ObservationIgnored
    var postedPermissionNotificationIds: [Int: String] = [:]

    /// The "finished" notification last posted for this chat, withdrawn
    /// when the user comes to read it. Kept by the window.
    @ObservationIgnored
    var postedFinishedNotificationId: String?

    /// The "couldn't reconnect" notification posted for this chat, withdrawn
    /// when the user focuses it. Kept by the window.
    @ObservationIgnored
    var postedFailureNotificationId: String?

    /// What to call this chat before it has a title or a first message (Bot
    /// Chat creating its conversation names the bot). Nil: "New chat".
    @ObservationIgnored
    var untitledName: String?

    /// The request ids last seen in the permission queue, to tell the
    /// window what arrived and what went (`permissionQueueChanged`).
    @ObservationIgnored
    private var knownPermissionIds: [Int] = []

    /// The message an autostart is carrying (`autoStartACPAndSend`) and the
    /// id of its local echo, until it is handed to `sendViaACP`. A Stop on
    /// the budget dialog before then puts it back in the composer
    /// (`restoreUnsentAutostart`) instead of losing it.
    @ObservationIgnored
    private var autostartInput: (text: String, images: [ChatImageAttachment], echoId: Int?)?

    /// The budget took this chat's process to free a slot
    /// (`releaseProcess`): the transcript and session id stay, nothing
    /// runs, and focusing it (or typing into it) re-attaches (`reattach`).
    private(set) var isReleased = false

    /// A re-attach of a released chat is in progress. Leaving it before it
    /// is ready puts it back to released rather than dropping it — it is
    /// reachable, it has a row.
    @ObservationIgnored
    private(set) var isReattaching = false

    /// The project the latest `startACPSession` was asked to run in, kept
    /// for a chat released before that start was ready (`currentProjectPath`
    /// is only set at ready). Cleared at a session boundary.
    @ObservationIgnored
    private var lastStartProjectPath: String?

    /// The approval mode the user picked in this chat's header, once Hermes
    /// accepted it. Legacy Hermes keeps it in memory only (server.py
    /// :1057-1069 @ v2026.9.24), so a re-attach or reconnect comes back at
    /// the default; the start pipeline and the reconnect ladder re-send it
    /// (`reassertPickedApprovalMode`). Cleared at a session boundary.
    @ObservationIgnored
    private(set) var userPickedApprovalMode: ACPApprovalMode?

    /// Single-flight ControlMaster recovery shared by every chat on a host
    /// (`SSHMasterRecovery`). The window sets its own (tests inject one).
    @ObservationIgnored
    var masterRecovery: SSHMasterRecovery = .shared

    /// The session a resume was asked to open, set when the resume starts
    /// (before the transcript knows any id) and kept through a #146
    /// fallback, so a second click on the same row finds this chat
    /// instead of opening the session twice. Cleared on reset.
    @ObservationIgnored
    var targetSessionId: String?

    /// True from the start of a start that carries something the user typed
    /// or a kickoff prompt (`autoStartACPAndSend`, or an `initialPrompt`)
    /// until that text is handed to `sendViaACP`: leaving the chat in that
    /// window must not lose it, so the chat keeps running.
    @ObservationIgnored
    private var startCarriesUserInput = false {
        // Handed over or abandoned: nothing left to put back.
        didSet {
            if !startCarriesUserInput {
                autostartInput = nil
                startKickoff = nil
            }
        }
    }

    /// The kickoff prompt a start is carrying, with its project, until it is
    /// handed to `sendViaACP`.
    @ObservationIgnored
    private var startKickoff: (projectPath: String?, prompt: String)?

    /// What a start was carrying when the watchdog tore it down: `stop()`
    /// clears the live state before the window hears of the failure.
    @ObservationIgnored
    private var unsentAtTeardown: UnsentStartInput?

    /// Something the user asked to send that a failed start never handed over.
    enum UnsentStartInput {
        case kickoff(projectPath: String?, prompt: String)
        case typed(text: String, images: [ChatImageAttachment])
    }

    private var currentUnsentStartInput: UnsentStartInput? {
        guard startCarriesUserInput else { return nil }
        if let startKickoff {
            return .kickoff(projectPath: startKickoff.projectPath, prompt: startKickoff.prompt)
        }
        if let autostartInput {
            return .typed(text: autostartInput.text, images: autostartInput.images)
        }
        return nil
    }

    /// For the window, when this chat's start has failed: what it was still
    /// carrying. The chat no longer carries it after this.
    func takeUnsentStartInput() -> UnsentStartInput? {
        defer {
            unsentAtTeardown = nil
            startCarriesUserInput = false
        }
        return unsentAtTeardown ?? currentUnsentStartInput
    }

    /// A prompt went to Hermes on the attached session. Hermes stores an
    /// ACP session only after its first turn (session.py:329-331 @
    /// v2026.9.24), so until then a new chat has no row anywhere and the
    /// user can't come back to it. Cleared on reset.
    @ObservationIgnored
    private var hasSentPrompt = false

    /// What the chat list calls this chat until Hermes has stored it, and
    /// when its first prompt went out (`ChatViewModel.sessionsForList`). Kept
    /// apart from the transcript so a row doesn't re-render on streamed text.
    private(set) var unstoredRow: (title: String, since: Date)?
    /// This chat began with `session/new`, not a resume: only such a chat can
    /// be one Hermes hasn't stored. A resumed session is merely older than
    /// the list's newest 50.
    @ObservationIgnored
    private var startedFresh = false
    /// A delete stopped this chat's turn and hasn't been answered yet.
    @ObservationIgnored
    private var stoppedForDelete = false

    /// Hermes lists this session now: no temporary row, ever again.
    func noteStoredByHermes() { unstoredRow = nil }

    /// Stop for a delete Hermes hasn't answered yet: the transcript stays, and
    /// nothing claims the session is gone (`tearDownDeletedActiveSession` does
    /// once it is).
    func stopForDeletion() -> Task<Void, Never>? {
        stoppedForDelete = true
        return stop(reason: "Turn cancelled.")
    }

    /// Same category the code logged under before the extraction, so log
    /// filters keep matching.
    private let logger = Logger(subsystem: "com.scarf", category: "ChatViewModel")
    let context: ServerContext
    private let dataService: HermesDataService
    /// The window's file service, kept in step by `ChatViewModel.fileService`
    /// (tests swap the window's in for a recording one).
    @ObservationIgnored
    var fileService: HermesFileService

    @ObservationIgnored
    weak var host: (any ChatSessionHost)?

    typealias ACPPhase = ChatViewModel.ACPPhase
    typealias PromptTurnOrigin = ChatViewModel.PromptTurnOrigin
    typealias ChatInspectorMode = ChatViewModel.ChatInspectorMode

    init(context: ServerContext, dataService: HermesDataService, fileService: HermesFileService) {
        self.context = context
        self.dataService = dataService
        self.fileService = fileService
        self.richChatViewModel = RichChatViewModel(context: context)

        // Answer, rather than silently abandon, every permission request
        // dropped by `clearPendingPermissions()`. Each queued entry is an
        // open `session/request_permission` JSON-RPC call the agent is
        // blocked on; dropping it from the queue alone leaves that tool
        // call hanging. Read through `self` at call time (not captured as
        // a value) because `acpClient` is replaced on every session
        // start / resume — a captured client would cancel against a dead
        // subprocess. Fire-and-forget: the cancel is a notification, and
        // on the disconnect paths the write simply no-ops.
        richChatViewModel.permissionCanceller = { [weak self] requestId in
            guard let client = self?.acpClient else { return }
            Task { await client.cancelPermission(requestId: requestId) }
        }
        // Every way a request comes and goes (queued, answered, settled by
        // Hermes, dropped with its turn) passes through the queue.
        richChatViewModel.permissionQueueDidChange = { [weak self] in
            self?.permissionQueueChanged()
        }
    }

    /// Diff the permission queue against what was last seen and tell the
    /// window (`ChatSessionHost.chatPermissionsChanged`).
    private func permissionQueueChanged() {
        let queue = richChatViewModel.permissionQueue
        let ids = queue.map(\.requestId)
        let added = queue.filter { !knownPermissionIds.contains($0.requestId) }
        let removed = knownPermissionIds.filter { !ids.contains($0) }
        knownPermissionIds = ids
        guard !added.isEmpty || !removed.isEmpty else { return }
        host?.chatPermissionsChanged(self, added: added, removed: removed)
    }

    /// This chat's `hermes acp` process is attached. The window's terminal
    /// process is tracked apart (`ChatViewModel.terminalProcessRunning`).
    var hasActiveProcess = false
    let richChatViewModel: RichChatViewModel

    /// Recent voice turns (id, spoken prompt), newest last, so the engine's
    /// reply lookup by request id can find its prompt in the transcript.
    @ObservationIgnored private var voiceTurnPrompts: [(id: String, prompt: String)] = []
    /// Recent voice requests refused because Hermes was busy with a typed
    /// request, newest last; `voiceTurnReply` answers them with
    /// `voiceBusyReply`.
    @ObservationIgnored private var busyVoiceRequestIDs: [String] = []

    /// `callId` of the tool call currently surfaced in the chat
    /// inspector pane, or nil when nothing is focused. Set by
    /// `ToolCallCard` taps in the transcript; cleared by the inspector's
    /// xmark close. Mac-only state — the inspector is a Mac-target view,
    /// so this lives on the Mac `ChatSession` rather than the
    /// cross-platform `RichChatViewModel`.
    var focusedToolCallId: String?

    /// Resolved focus target for the inspector. Walks
    /// `richChatViewModel.messageGroups` to find the matching
    /// `HermesToolCall` and its tool-result message (when present).
    /// Returns nil when nothing is focused or the focused id no longer
    /// resolves (e.g., session reload swept it).
    var focusedToolCall: (call: HermesToolCall, result: HermesMessage?)? {
        guard let id = focusedToolCallId else { return nil }
        for group in richChatViewModel.messageGroups {
            for msg in group.assistantMessages {
                if let call = msg.toolCalls.first(where: { $0.callId == id }) {
                    return (call, group.toolResults[id])
                }
            }
        }
        return nil
    }

    /// User-message focus for the inspector (v2.10.2). Set by long
    /// user-message bubbles' "Expand in inspector" pill; cleared by
    /// the inspector's xmark close OR by setting `focusedToolCallId`
    /// to a non-nil value (mutual exclusion enforced via
    /// `setInspectorFocus(_:)`).
    var focusedUserMessageId: Int?

    /// Resolved focus target for the user-message inspector. Walks
    /// `richChatViewModel.messageGroups` to find the matching user
    /// message. Returns nil when nothing is focused or the focused id
    /// no longer resolves.
    var focusedUserMessage: HermesMessage? {
        guard let id = focusedUserMessageId else { return nil }
        for group in richChatViewModel.messageGroups {
            if let user = group.userMessage, user.id == id { return user }
        }
        return nil
    }

    /// Derived inspector mode. Prefers `.toolCall` when both ids are
    /// somehow set (`setInspectorFocus` shouldn't allow that, but
    /// defensive). The pane reads this to pick its rendering branch.
    var inspectorMode: ChatInspectorMode {
        if let id = focusedToolCallId { return .toolCall(id: id) }
        if let id = focusedUserMessageId { return .userMessage(id: id) }
        return .none
    }

    /// Set the inspector's focus, enforcing mutual exclusion between
    /// tool-call and user-message modes. Pass `.none` from the
    /// inspector close button. Bubbles use this rather than touching
    /// the two id fields directly so the exclusion invariant lives in
    /// one place.
    func setInspectorFocus(_ mode: ChatInspectorMode) {
        switch mode {
        case .none:
            focusedToolCallId = nil
            focusedUserMessageId = nil
        case .toolCall(let id):
            focusedUserMessageId = nil
            focusedToolCallId = id
        case .userMessage(let id):
            focusedToolCallId = nil
            focusedUserMessageId = id
        }
    }

    /// Absolute project path for the current session, when the chat is
    /// project-scoped (either started via a project's "New Chat" button
    /// or resumed from a session that was previously attributed via the
    /// v2.3 sidecar). Nil for plain global chats. Drives the project
    /// indicator in SessionInfoBar + the `Chat · <Name>` nav title.
    private(set) var currentProjectPath: String?

    /// Git branch the project's working directory is currently on, or
    /// nil when the dir isn't a git repo / git isn't installed / the
    /// resolution failed. Populated alongside `currentProjectPath`;
    /// surfaced as a small chip after the project name in
    /// `SessionInfoBar`. v2.5.
    private(set) var currentGitBranch: String?

    /// Human-readable name of the active project, resolved from the
    /// projects registry at session-start time. Stored alongside the
    /// path so the view renders without hitting disk on every update.
    /// Nil when `currentProjectPath` is nil OR the path isn't in the
    /// registry (project was removed after the session was attributed).
    private(set) var currentProjectName: String?

    /// Model preset applied to the live session via `session/set_model`,
    /// or nil when the chat is running on the global `config.yaml`
    /// default. Set after `applyProjectModelPreset` succeeds at session
    /// boot and updated by the chat header's mid-chat switcher. The
    /// chat header reads this to render the active-model badge.
    private(set) var currentModelPreset: ModelPreset?

    /// The name typed with `/new <name>`, waiting for the new session's
    /// first completed turn (see `sendViaACP`). Cleared on any session
    /// switch. Set by the window on the chat `/new` started
    /// (`ChatViewModel.startNewSessionFromChat`), and by `/title`.
    @ObservationIgnored
    var pendingSessionTitle: String?

    // ACP state
    private var acpClient: ACPClient?
    private var acpEventTask: Task<Void, Never>?
    /// Events the current event loop has handed to the transcript. Paired
    /// with `ACPClient.eventsEmitted` so a send path can wait until every
    /// event that preceded an RPC response has been handled
    /// (`awaitEventLoopDrain`). Reset whenever a loop starts, because the
    /// client's count starts at zero with each new client.
    private var acpEventsHandled = 0
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    var isACPConnected: Bool { acpClient != nil && hasActiveProcess }
    var acpStatus: String = ""

    /// Set true the moment the user kicks off a session-start path
    /// (resume / new / continue), cleared when the ACP session is
    /// fully ready or has failed. Decoupled from `hasActiveProcess`
    /// — that flag only flips true AFTER `client.start()` succeeds,
    /// which on remote contexts is a 5–7s window where the user sees
    /// nothing happening even though they've just clicked. v2.8 —
    /// fixes the gap between row-click and overlay-appears that
    /// the user reported in 2026-05-05 dogfooding.
    var isStartingSession: Bool = false

    /// True while a session is being established or restored — from the user
    /// kicking off "start chat" or "resume session" until the ACP session is
    /// ready for messages. The chat pane uses this to show a loader in place
    /// of the empty-state placeholder; `ChatSessionListPane` shows a
    /// progress capsule (rows stay clickable — a new click supersedes
    /// the in-flight start via `sessionStartGeneration`, t-5451bd1b).
    var isPreparingSession: Bool {
        if isStartingSession { return true }
        guard hasActiveProcess else { return false }
        if ChatViewModel.preparingPhases.contains(acpStatus) { return true }
        return acpStatus.hasPrefix("Reconnecting")
    }
    /// Error triplet moved to RichChatViewModel in M7 #2 so ScarfGo can
    /// share the same banner. These are forwarding accessors to keep
    /// the many existing call sites in this file unchanged.
    var acpError: String? {
        get { richChatViewModel.acpError }
        set { richChatViewModel.acpError = newValue }
    }
    var acpErrorHint: String? {
        get { richChatViewModel.acpErrorHint }
        set { richChatViewModel.acpErrorHint = newValue }
    }
    var acpErrorDetails: String? {
        get { richChatViewModel.acpErrorDetails }
        set { richChatViewModel.acpErrorDetails = newValue }
    }
    var acpErrorOAuthProvider: String? {
        get { richChatViewModel.acpErrorOAuthProvider }
        set { richChatViewModel.acpErrorOAuthProvider = newValue }
    }

    /// Stash of the original `startACPSession` arguments while we wait
    /// for the user to pick a model. Replayed verbatim once
    /// `confirmModelPreflight` writes the chosen model+provider to
    /// config.yaml. Cleared on cancel or after replay. Internal: the
    /// window's preflight sheet (`ChatViewModel.confirmModelPreflight` /
    /// `cancelModelPreflight`) replays and clears it.
    var pendingStartArgs: (sessionId: String?, projectPath: String?, initialPrompt: String?)?

    /// Monotonic "latest session-start intent" token. Every user-initiated
    /// session start (new / resume / continue-last / auto-start) bumps it
    /// synchronously on entry, and `startACPSession` bumps again when the
    /// spawn stage begins (so a preflight-sheet replay counts as a fresh
    /// intent). Every await in the start pipelines captures the token and
    /// bails on resume if a newer intent superseded it — see
    /// `startStillCurrent(_:client:)`, which also stops the abandoned
    /// attempt's client so a superseded spawn never leaks. Without this,
    /// two rapid resumes of DIFFERENT sessions could resolve out of order
    /// on a remote and load the wrong chat (t-24594c4a), and a wedged
    /// start would block every later click (S3, t-5451bd1b).
    private var sessionStartGeneration = 0

    /// Watchdog bounding the session-start pipeline (t-5451bd1b / S3).
    /// Armed at every start entry point (covering the pre-spawn
    /// attribution/DB awaits, which are log-proven wedge sites) and
    /// re-armed by `startACPSession` / `autoStartACPAndSend` when the
    /// spawn stage begins. On expiry — if the same intent is still the
    /// latest and the UI still reads as preparing — it tears the wedged
    /// start down (`stop()`), self-supersedes the generation so the
    /// abandoned pipeline exits silently if its awaits ever resume, and
    /// paints a retryable error banner. Disarmed on ready / failure /
    /// preflight-bail / any `stop()`.
    @ObservationIgnored
    private var startWatchdogTask: Task<Void, Never>?

    /// Session-start watchdog budget. 90s: the slowest single legitimate
    /// step is a control RPC under ACPClient's own 60s watchdog
    /// (`initialize` / `session/new` / `session/load` stalling on a
    /// state.db lock), and a remote start prepends an SSH spawn +
    /// attribution reads that need slack on a cold ControlMaster. A
    /// healthy boot is seconds; 90s of a *single* preparing phase means
    /// the pipeline is wedged, not slow. (The pre-spawn stage and the
    /// spawn stage each get their own 90s arm, so the theoretical
    /// worst-case detection latency is 2×90s; each stage is bounded.)
    /// `var` (not `let`) so tests can shrink it; internal for @testable
    /// access.
    @ObservationIgnored
    var sessionStartWatchdogNanos: UInt64 = 90_000_000_000

    /// One `session/prompt` Scarf started and hasn't seen return.
    private struct PromptTurn {
        let sessionId: String
        let origin: PromptTurnOrigin
        let isNonInterruptive: Bool
        var task: Task<Void, Never>?
    }

    /// Every prompt Scarf started on `acpClient` whose `sendPrompt` hasn't
    /// returned, keyed by the turn's token (`launchPromptTask`). Each turn
    /// removes only its OWN entry when it settles, and teardown cancels
    /// all of them.
    ///
    /// A map, not one task slot: Hermes answers a prompt that arrives while
    /// a turn runs at once ("Queued for the next turn", `end_turn`) and
    /// runs it inside the FIRST prompt's `_finish_turn`
    /// (`acp_adapter/server.py:696-715`, `:927-938`), so the older turn's
    /// `sendPrompt` returns LAST. With one slot, the newer turn overwrote
    /// the older one's task and its return cleared the in-flight marker
    /// while Hermes was still running the older turn, so `stop()` sent no
    /// `session/cancel` and a voice cancel waited on the wrong task.
    ///
    /// Owned HERE (not read from `richChatViewModel`) because the mid-turn
    /// teardown in `stop()` must key off state that survives
    /// `richChatViewModel.reset()`: every session-switch entry point
    /// (`startNewSession` / `resumeSession` / `continueLastSession`)
    /// resets the transcript VM at click time, long before
    /// `startACPSession` reaches `stop()`.
    @ObservationIgnored
    private var promptTurns: [Int: PromptTurn] = [:] {
        didSet { promptTurnsRevision &+= 1 }
    }

    /// Observed stand-in for `promptTurns` (which is not observed), so the
    /// composer's Stop button appears when a held or autostarted prompt
    /// actually starts, not only when `isAgentWorking` flips.
    private var promptTurnsRevision = 0

    /// Last token handed out by `launchPromptTask`.
    @ObservationIgnored
    private var promptTurnCounter = 0

    /// Finishes once the most recently launched prompt's `session/prompt`
    /// has been issued (`ACPClient.sendPrompt`'s `onIssued`: id assigned,
    /// write queued) or failed before that. The next prompt waits on it,
    /// so prompts reach Hermes in the order they were sent — not the order
    /// their tasks happened to reach the client actor (held sends released
    /// in one main-actor turn used to race). It waits for the ISSUE only,
    /// never the previous turn: Hermes's own queueing (`/queue`, `/steer`,
    /// a prompt sent mid-turn) is unchanged.
    @ObservationIgnored
    private var lastPromptIssued: AsyncStream<Never>?

    /// Test seam: awaited (with the prompt's wire text) by each prompt task
    /// before it waits its turn to issue — stands in for a slow executor
    /// hop on the way to the client. Nil in the app.
    @ObservationIgnored
    var beforePromptIssueForTesting: (@MainActor (String) async -> Void)?

    /// Origins of the interruptive turns started since the chat was last
    /// idle. Kept until EVERY interruptive turn has returned, because a
    /// typed prompt Hermes queued behind a voice turn returns at once but
    /// runs later inside that voice turn: until the whole run returns,
    /// Hermes is still busy with the typed request.
    @ObservationIgnored
    private var busyTurnOrigins: Set<PromptTurnOrigin> = []

    /// Session id of the interruptive prompt(s) in flight on `acpClient`,
    /// or `nil` when none is. Drives the S4 `session/cancel` in `stop()`.
    private var inFlightPromptSessionId: String? {
        promptTurns
            .filter { !$0.value.isNonInterruptive }
            .max { $0.key < $1.key }?
            .value.sessionId
    }

    /// Cancel and forget every in-flight prompt task (teardown).
    private func cancelAllPromptTurns() {
        for turn in promptTurns.values { turn.task?.cancel() }
        promptTurns = [:]
        busyTurnOrigins = []
    }

    /// The per-session `ACPClient`. Production builds `ACPClient.forMacApp`
    /// (a `ProcessACPChannel` spawning `hermes acp`) with THIS chat's
    /// `environmentHintSlot`, read at spawn, so a project chat on a v0.16+
    /// host carries its `HERMES_ENVIRONMENT_HINT` (#142). Tests and Bot Chat
    /// inject scripted/hanging/profile-pinned clients through the window's
    /// `acpClientFactory` override, which ignores the slot.
    private func makeACPClient(projectPath: String?) -> ACPClient {
        if let factory = host?.acpClientFactoryOverride {
            return factory(context, projectPath)
        }
        return ACPClient.forMacApp(context: context, projectCwd: projectPath, environmentHintSlot: environmentHintSlot)
    }

    /// The environment hint prepared for this chat's project, read by the
    /// default client `makeACPClient` builds when the `hermes acp` channel
    /// opens — the
    /// client is built before the project prep decides the hint. Keyed by
    /// project path, so the reconnect / autostart spawns for the same
    /// project reuse it and any other cwd gets none.
    @ObservationIgnored
    let environmentHintSlot = EnvironmentHintSlot()

    /// Reads the per-project "auto-accept edits in this project" setting
    /// at session boot. A seam rather than a `let` so tests can point it
    /// at a scratch defaults suite + test Keychain service instead of the
    /// user's real ones.
    @ObservationIgnored
    var autoAcceptEditsStore = ProjectAutoAcceptEditsStore()

    private static let maxReconnectAttempts = 5
    /// A `var` so tests can run the ladder out without waiting for it.
    @ObservationIgnored
    var reconnectBaseDelay: UInt64 = 1_000_000_000 // 1 second
    private static let maxReconnectDelay: UInt64 = 16_000_000_000 // 16 seconds

    /// Forwarders to the ScarfCore implementation so the error-banner
    /// state lives in one place (M7 #2). The per-site logging label
    /// stays here — only the storage is shared.
    private func clearACPErrorState() {
        richChatViewModel.clearACPErrorState()
    }

    /// Auto-clear the chat composer's transient hint after 4 s. Shared
    /// helper for `/steer`, `/goal`, and `/queue` so the toast lifetime
    /// stays consistent across non-interruptive commands.
    ///
    /// In a chat no window shows, the clock waits until one does: the hint
    /// is there to be read (`startDeferredHintClear`).
    @MainActor
    func scheduleHintClear() {
        guard isShownInWindow else {
            hintClearWaitsForFocus = true
            return
        }
        let snapshot = richChatViewModel.transientHint
        let lifetime = hintLifetimeNanos
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: lifetime)
            if self?.richChatViewModel.transientHint == snapshot {
                self?.richChatViewModel.transientHint = nil
            }
        }
    }

    @ObservationIgnored
    private var hintClearWaitsForFocus = false

    /// How long a hint stays once it can be seen (a `var` for tests).
    @ObservationIgnored
    var hintLifetimeNanos: UInt64 = 4_000_000_000

    /// The window now shows this chat: a hint set while it was in the
    /// background starts its clock.
    @MainActor
    func startDeferredHintClear() {
        guard hintClearWaitsForFocus else { return }
        hintClearWaitsForFocus = false
        scheduleHintClear()
    }

    @MainActor
    private func recordACPFailure(_ error: Error, client: ACPClient?, context: String) async {
        logger.error("\(context): \(error.localizedDescription)")
        await richChatViewModel.recordACPFailure(error, client: client)
    }

    /// gh#123: a remote start failure or dead stream usually means the
    /// shared ControlMaster TCP session died with it (sleep/wake, network
    /// change) while the master keeps holding its socket — every retry
    /// then hangs on the corpse and the chat reads as permanently stuck.
    /// Do explicitly what remove-and-re-add did as a side effect: probe
    /// the master and tell a dead one to exit so the next attempt
    /// handshakes fresh. No-op on Local and when no master exists.
    ///
    /// Through `SSHMasterRecovery`: every chat on the host shares the
    /// master, so one recovery serves them all — a second `-O exit` would
    /// tear down the channels the first one's reconnects just opened.
    private func recoverRemoteTransportAfterFailure() async {
        guard context.isRemote else { return }
        // The probe spawns `ssh -O check/exit` on a thread of its own.
        await masterRecovery.recover(context: context)
    }

    // MARK: - Start watchdog + supersede (t-5451bd1b)

    /// Bump the start-intent generation and return the new token. Call
    /// synchronously at the top of every start stage.
    @discardableResult
    private func beginStartIntent() -> Int {
        sessionStartGeneration &+= 1
        return sessionStartGeneration
    }

    /// True while `intent` is still the newest start intent. When a
    /// newer start (or the watchdog) superseded it, stops `client`
    /// fire-and-forget (idempotent — the superseding path usually
    /// already stopped it via `stop()`) and returns false so the
    /// caller abandons silently WITHOUT touching shared state: a
    /// superseded pipeline resuming late must never clobber the newer
    /// start's `acpClient` / `acpStatus` / flags. Call immediately
    /// after every await in a start pipeline, before any state write.
    private func startStillCurrent(_ intent: Int, client: ACPClient?) -> Bool {
        // A start whose window is gone (`host` released mid-await) is
        // superseded too: without the host it would spawn the default
        // client instead of the window's override (Bot Chat's pinned
        // profile) and skip the host's capability and lineage reads.
        if intent == sessionStartGeneration, host != nil { return true }
        if let client {
            Task { await client.stop() }
        }
        return false
    }

    /// Arm (or re-arm) the session-start watchdog for `intent`.
    /// Cancels any previous arm — there is at most one live watchdog.
    private func armStartWatchdog(intent: Int) {
        startWatchdogTask?.cancel()
        let budget = sessionStartWatchdogNanos
        startWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: budget)
            guard !Task.isCancelled, let self else { return }
            // Only fire when the wedged start is still the latest
            // intent AND the UI still reads as preparing — a start
            // that reached ready (or failed, or was superseded)
            // already cleaned up after itself.
            guard intent == self.sessionStartGeneration, self.isPreparingSession else { return }
            let seconds = Int(budget / 1_000_000_000)
            self.logger.error("session-start watchdog fired after \(seconds)s — tearing down the wedged start")
            let wasReattaching = self.isReattaching
            let unsent = self.currentUnsentStartInput
            // Counted before `stop()`, which drops sends held for a client
            // not spawned yet (a re-attach's) without a word.
            let dropped = self.heldSends.count
            // Self-supersede so the wedged pipeline's generation checks
            // abandon silently if its awaits ever resume, instead of
            // stomping the error state painted below.
            self.beginStartIntent()
            self.stop()
            self.unsentAtTeardown = unsent
            // A released chat that failed to come back is still the chat
            // it was: kept, transcript and all, to retry later.
            if wasReattaching { self.isReleased = true }
            self.acpStatus = ACPPhase.failed
            self.clearACPErrorState()
            self.acpError = "Session start timed out after \(seconds) seconds."
            self.acpErrorHint = "The agent never finished starting — the process may be wedged. Click the chat again (or start a new one) to retry."
            // Sends held for the wedged start's client will never go out.
            if dropped > 0 {
                self.heldSends = []
                self.heldSendsClient = nil
                self.richChatViewModel.transientHint = String(
                    localized: "^[\(dropped) message](inflect: true) couldn't be sent — the connection didn't come up."
                )
                self.scheduleHintClear()
            }
            self.host?.chatSettledWithoutConnection(self)
        }
    }

    /// Cancel the start watchdog. Call once a start pipeline settles
    /// (ready, failure, or preflight bail) and from `stop()` teardown.
    private func disarmStartWatchdog() {
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
    }

    // MARK: - Session Lifecycle

    /// The synchronous head of every user-initiated session switch (new /
    /// resume / continue-last): flip the loading flag and begin a fresh start
    /// intent. `ChatViewModel`'s entry points call this before ending voice,
    /// then `resetForSessionSwitch()`.
    @discardableResult
    func beginSessionSwitch() -> Int {
        // Flip the loading flag synchronously on the user's tap so
        // SwiftUI paints the session-list overlay on the same tick
        // — `startACPSession` won't reach `acpStatus = .spawning`
        // until the Task body runs, which on remote contexts is
        // multiple seconds after the click. v2.8.
        isStartingSession = true
        startCarriesUserInput = false
        return beginStartIntent()
    }

    /// Blank the transcript for the next session.
    ///
    /// `continuing`: the session the chat restarts on (the error banner's
    /// Reconnect). When the chat already is that conversation, the approval
    /// mode the user picked in it survives the restart — only a different
    /// session clears it.
    func resetForSessionSwitch(continuing sessionId: String? = nil) {
        let sameConversation = sessionId.map(covers) ?? false
        let keptMode = sameConversation ? userPickedApprovalMode : nil
        richChatViewModel.reset()
        targetSessionId = nil
        hasSentPrompt = false
        unstoredRow = nil
        startedFresh = false
        stoppedForDelete = false
        // A new session boundary: the badge must not carry the last
        // chat's model (S03-F2). The start sets it from the session.
        currentModelPreset = nil
        pendingSessionTitle = nil
        // The picked mode belonged to the session being left.
        userPickedApprovalMode = keptMode
        isReleased = false
        lastStartProjectPath = nil
        hasUnreadCompletion = false
        // A draft belongs to its conversation (#62): reused for another
        // session, the chat starts with an empty composer. Restarting the
        // same one in place (Reconnect) keeps it.
        if !sameConversation { composer.clear() }
    }

    // MARK: - Parallel chats (P1)

    /// Whether this chat is (or is becoming) the conversation `sessionId`
    /// names: a row its transcript spans (compression lineage, the #146
    /// continuation), or the session a resume in progress was asked for.
    /// A brand-new chat has neither until its start is ready, so the
    /// window finds it by identity only.
    func covers(_ sessionId: String) -> Bool {
        targetSessionId == sessionId || richChatViewModel.transcriptCovers(sessionId)
    }

    /// Something is running or about to: a client is attached, a start is
    /// in progress, or the reconnect ladder is bringing the client back.
    /// A chat that is none of these has nothing to focus — reopening its
    /// session is a fresh resume.
    var isLive: Bool {
        acpClient != nil || isStartingSession || holdingForPendingClient
    }

    /// Takes a slot in the live-chat budget: a `hermes acp` process is
    /// attached, being started, or being brought back by the reconnect
    /// ladder. A released chat holds none.
    var holdsProcess: Bool {
        acpClient != nil || isStartingSession || holdingForPendingClient
    }

    /// The budget must not release this chat's process: a turn is in flight,
    /// an approval or question waits, a start or reconnect is under way, or
    /// sends are held for a client.
    var isBusyForBudget: Bool {
        hasTurnInFlight
            || !richChatViewModel.permissionQueue.isEmpty
            || isPreparingSession
            || holdingForPendingClient
            || isHandlingDisconnect
            || !heldSends.isEmpty
            || startCarriesUserInput
    }

    /// A name the user recognises for this chat in a window that may not
    /// be showing it (the budget's Stop/Wait dialog): the session title,
    /// a `/new <name>` waiting to be applied, else the start of the first
    /// thing they typed.
    var displayTitle: String {
        if let title = richChatViewModel.currentSession?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let pending = pendingSessionTitle, !pending.isEmpty { return pending }
        if let first = richChatViewModel.messages.first(where: \.isUser)?.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            let line = first.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? first
            return line.count > 40 ? String(line.prefix(40)) + "…" : line
        }
        return untitledName ?? String(localized: "New chat")
    }

    /// A prompt Scarf started on this chat hasn't returned.
    var hasTurnInFlight: Bool { !promptTurns.isEmpty }

    /// What the chat list row shows for a live chat (parallel chats P1),
    /// most urgent first.
    enum RowState: Equatable {
        /// An approval or question waits for the user.
        case needsAnswer
        /// The last turn or the connection failed.
        case error
        /// A turn is running, or the session is starting or reconnecting.
        case replying
        /// A reply finished while the user was in another chat.
        case finishedUnread
        case idle
    }

    /// This chat's row state. Reads only observed scalars (never the
    /// transcript), so a row re-renders when its own chat's state moves,
    /// not on every streamed chunk.
    var rowState: RowState {
        if !richChatViewModel.permissionQueue.isEmpty { return .needsAnswer }
        if acpError != nil
            || acpStatus == ACPPhase.failed
            || acpStatus == ACPPhase.connectionLost {
            return .error
        }
        // `promptTurns` isn't observed; its revision is.
        _ = promptTurnsRevision
        if hasTurnInFlight || isPreparingSession { return .replying }
        if hasUnreadCompletion { return .finishedUnread }
        return .idle
    }

    /// The order to forget or release chats in: one with nothing to lose
    /// (`hasDraftOrUnread`) first, then the least recently used.
    static func forgetFirst(_ a: ChatSession, _ b: ChatSession) -> Bool {
        if a.hasDraftOrUnread != b.hasDraftOrUnread { return !a.hasDraftOrUnread }
        return a.lastUsedAt < b.lastUsedAt
    }

    /// The user would lose something if this chat were forgotten: an
    /// unsent draft, or a reply they haven't seen. The released-chat cap
    /// and the budget's release order spare such chats first.
    var hasDraftOrUnread: Bool {
        composer.hasContent || hasUnreadCompletion
    }

    /// Whether the window keeps this chat when the user moves to another
    /// one (parallel chats P1, design §6), rather than dropping it:
    /// - a turn in flight, a pending approval or question, or sends held
    ///   for a reconnect or a load replay — keep running in the background;
    /// - a start carrying something typed (autostart) or a kickoff prompt,
    ///   or a start parked on the model preflight sheet — keep it;
    /// - a live, idle session the user can come back to — one that was
    ///   resumed (it has a row), or that has had a turn (Hermes stored it):
    ///   keep its process until the budget needs the slot (`LiveChatBudget`);
    /// - released by the budget — keep it: no process, but reachable;
    /// - otherwise (blank, errored with no client, a start with nothing
    ///   typed, or a new session with no turn — unreachable, there is no
    ///   row to click) — no: the window supersedes it, as a switch always
    ///   did.
    var keepsRunningWhenLeft: Bool {
        // Released by the budget: no process, but a row the user can come
        // back to, and a transcript worth keeping.
        if isReleased { return true }
        // Scarf's own turn bookkeeping, not `isAgentWorking`: an autostart's
        // echo raises that flag and a failed start never lowers it.
        if hasTurnInFlight { return true }
        if !richChatViewModel.permissionQueue.isEmpty { return true }
        if !heldSends.isEmpty { return true }
        if pendingStartArgs != nil { return true }
        // Ready but the typed message or kickoff prompt not sent yet: the
        // start still awaits the sidebar reload / replay drain (autostart)
        // or the project setup (`initialPrompt`) before it sends.
        if startHoldsUserInput { return true }
        if isStartingSession { return false }
        if holdingForPendingClient { return true }
        guard acpClient != nil, richChatViewModel.sessionId != nil else { return false }
        return hasSentPrompt || targetSessionId != nil || richChatViewModel.currentSession != nil
    }

    /// A start under way carries something the user typed or a kickoff
    /// prompt, not yet handed to `sendViaACP`.
    var startHoldsUserInput: Bool {
        startCarriesUserInput && (isStartingSession || acpClient != nil)
    }

    /// The window isn't showing this chat and its connection is gone for
    /// good (a start failed or timed out, the reconnect ladder gave up).
    /// With a session to come back to it stays as a released chat: no process
    /// and no budget slot, its error on its row (`rowState`), and focusing it
    /// or typing into it re-attaches through the full start path. Returns
    /// whether it was kept; a blank chat has no row, and the window drops it.
    /// `lostTypedMessage`: a failed autostart never handed over what was
    /// typed. Its echo stays and the reconnect doesn't send it, so say so.
    func keepAfterFailedConnection(lostTypedMessage: Bool) -> Bool {
        guard richChatViewModel.sessionId != nil || targetSessionId != nil else { return false }
        if lostTypedMessage {
            let unsent = 1
            richChatViewModel.transientHint = String(
                localized: "^[\(unsent) message](inflect: true) couldn't be sent — the connection didn't come up."
            )
            scheduleHintClear()
        }
        // The echo raised it, and nothing else will lower it.
        if !hasTurnInFlight { richChatViewModel.cancelPendingSend() }
        isReattaching = false
        isReleased = true
        return true
    }

    /// Drop this chat: supersede any start in progress (its pipeline
    /// abandons at its next `startStillCurrent` check and stops its own
    /// client) and tear the connection down. The window removes it from
    /// its list afterwards; only call it for a chat that doesn't
    /// `keepsRunningWhenLeft`, or one the window is closing.
    @discardableResult
    func supersede() -> Task<Void, Never>? {
        beginStartIntent()
        return stop()
    }

    /// The rich-chat half of `ChatViewModel.resumeSession`.
    func resumeACPSession(_ sessionId: String) {
        // Bound the pre-spawn stage (the attribution read below is a
        // log-proven wedge site on remote) — startACPSession re-arms
        // for the spawn stage.
        armStartWatchdog(intent: sessionStartGeneration)
        // Recover the project this session was started under so the
        // respawned `hermes acp` runs with cwd = the project dir
        // (Hermes loads AGENTS.md from the PROCESS cwd) and tool calls
        // resolve against the project (the ACP session cwd) — the same
        // wiring new project chats get (t-565f8d45). The attribution
        // sidecar read is transport I/O, so resolve off the MainActor
        // before kicking ACP. Unattributed sessions resolve to nil →
        // home cwd (unchanged global-chat behavior).
        let ctx = context
        let intent = sessionStartGeneration
        Task { @MainActor in
            let projectPath = await OffPool.run {
                SessionAttributionService(context: ctx).resolveProjectPath(known: nil, sessionID: sessionId)
            }
            // Bail if a newer session-start superseded us while the
            // (possibly remote) attribution read was in flight.
            guard startStillCurrent(intent, client: nil) else { return }
            startACPSession(resume: sessionId, projectPath: projectPath)
        }
    }

    /// The rich-chat half of `ChatViewModel.continueLastSession`; `intent`
    /// is the one `beginSessionSwitch()` returned.
    func continueLastACPSession(intent: Int) {
        // Bound the pre-spawn stage (DB open + attribution reads
        // below) — startACPSession re-arms for the spawn stage.
        armStartWatchdog(intent: intent)
        // Find most recent session and resume via ACP
        Task { @MainActor in
            let opened = await dataService.open()
            guard startStillCurrent(intent, client: nil) else { return }
            if !opened {
                disarmStartWatchdog()
                isStartingSession = false
                acpError = context.isRemote
                    ? "Couldn't reach \(context.displayName). Check the SSH connection and try again."
                    : "Couldn't open the Hermes state database."
                acpErrorHint = nil
                acpErrorDetails = nil
                return
            }
            let sessionId = await dataService.fetchMostRecentlyActiveSessionId()
            await dataService.close()
            if let sessionId {
                // The most-recent session may be project-scoped; recover
                // its project so the resume spawns with the project cwd
                // (AGENTS.md + tool dirs), matching resumeSession. Off the
                // MainActor — the attribution lookup is transport I/O.
                let ctx = context
                let projectPath = await OffPool.run {
                    SessionAttributionService(context: ctx).resolveProjectPath(known: nil, sessionID: sessionId)
                }
                // Bail if a newer session-start superseded us across the
                // DB + attribution reads above.
                guard startStillCurrent(intent, client: nil) else { return }
                startACPSession(resume: sessionId, projectPath: projectPath)
            } else {
                guard startStillCurrent(intent, client: nil) else { return }
                startACPSession(resume: nil)
            }
        }
    }

    /// The session the error banner's Reconnect reopens. After a #146
    /// fallback the chat's `sessionId` is the fresh continuation, whose own
    /// history is empty or partial — and, with no turn yet, not restorable,
    /// so reopening it fell back a second time over a blank transcript.
    /// Reconnect reopens the session the user opened (`originSessionId`)
    /// instead, so the fallback repeats with the original transcript and
    /// its notice. Turns typed into the continuation stay in state.db under
    /// its own id (its own sidebar row); they aren't replayed here.
    var reconnectSessionId: String? {
        let current = richChatViewModel.sessionId
        if let fallback = lastResumeFallback, fallback.continuation == current {
            return fallback.origin
        }
        return richChatViewModel.originSessionId ?? current
    }

    /// The last #146 fallback: the session the user opened and the new ACP
    /// session that carries it on. Only read while the chat is still on
    /// `continuation`, so no start path has to clear it. Kept apart from
    /// `originSessionId`, which the auto-start path never sets and which
    /// is only set once state.db answered.
    private var lastResumeFallback: (origin: String, continuation: String)?

    /// Record a fallback from `resumed` to `continuation`. Resuming a
    /// continuation that itself falls back (an auto-start after the ladder
    /// gave up) keeps the ORIGINAL origin, not the intermediate session.
    private func noteResumeFallback(from resumed: String, to continuation: String) {
        let origin = (lastResumeFallback?.continuation == resumed ? lastResumeFallback?.origin : nil) ?? resumed
        lastResumeFallback = (origin, continuation)
    }

    // MARK: - Send Message

    /// The rich-chat branch of `ChatViewModel.sendText`, after its analytics
    /// and `sendRouter` checks. `autoStartInterceptor` is the window's seam.
    func sendRichText(
        _ text: String,
        images: [ChatImageAttachment],
        autoStartInterceptor: ((String, [ChatImageAttachment]) -> Bool)?
    ) {
        // gh#147: `/title`, and `/retry`/`/undo` on a host that doesn't
        // serve them, never touch the wire, so answer them here — before the no-client branch would
        // auto-start a session just to deliver them.
        if let intercept = RichChatViewModel.clientSideSlashCommand(
            for: text, capabilities: richChatViewModel.capabilitiesGate
        ), handleLocalSlashCommand(intercept) { return }
        // Released by the budget: bring this chat's own session back and
        // send once it is ready — an autostart would skip the model preset
        // and project chip.
        if isReleased {
            reattach(thenSend: (text, images))
            return
        }
        if let client = acpClient {
            if holdSendIfReplayPending(client: client, text: text, images: images) { return }
            sendViaACP(client: client, text: text, images: images)
        } else {
            // The reconnect ladder is bringing this session back: hold
            // the send for the client it installs. Auto-starting here
            // spawned a second `hermes acp` racing the ladder for the
            // same session.
            if holdSendDuringReconnect(text: text, images: images) { return }
            // A conversation that must not be auto-started blind (Bot
            // Chat) re-resolves itself first.
            if let autoStartInterceptor, autoStartInterceptor(text, images) { return }
            // Auto-start ACP and send the queued message
            autoStartACPAndSend(text: text, images: images)
        }
    }

    /// Sends typed while a start path's `session/load` replay may still be
    /// in flight, for the client in `heldSendsClient` (R10 carry-over).
    ///
    /// Hermes streams a session's whole stored history as live updates
    /// inside `session/load` (acp_adapter/server.py:579-589 @ v2026.9.24).
    /// The autostart and reconnect paths install their client before that
    /// replay has been handled; a send in that window called
    /// `markPromptSent`, which opens the replay gate, and the rest of the
    /// replay painted as new content. Such sends are echoed now, with the
    /// gate kept shut, and sent in order once the path has drained the
    /// replay (`releaseHeldSends`). Dropped if the client is replaced.
    @ObservationIgnored
    private var heldSends: [(text: String, images: [ChatImageAttachment])] = []
    @ObservationIgnored
    private weak var heldSendsClient: ACPClient?
    /// Something the user typed is held for a client and hasn't gone out
    /// yet (`heldSends`).
    var hasHeldSends: Bool { !heldSends.isEmpty }
    /// True while a path that will install a client for THIS session has
    /// none yet — the reconnect ladder, or the re-attach of a released chat
    /// (`reattach`) before its spawn: sends typed then are held for the
    /// client it installs, not auto-started into a second process.
    @ObservationIgnored
    private var holdingForPendingClient = false

    private func beginHoldingSends(for client: ACPClient) {
        // The new client inherits what was typed while it was coming.
        if !holdingForPendingClient { heldSends = [] }
        holdingForPendingClient = false
        heldSendsClient = client
    }

    /// Hold `text` while the reconnect ladder or a re-attach brings the
    /// client up. True when held.
    private func holdSendDuringReconnect(text: String, images: [ChatImageAttachment]) -> Bool {
        guard holdingForPendingClient else { return false }
        richChatViewModel.addUserMessage(text: text)
        richChatViewModel.closeReplayGate()
        heldSends.append((text, images))
        return true
    }

    /// The ladder (or re-attach) ended without a client: what
    /// was held will never go out. `announce` is false for a deliberate
    /// teardown, whose transcript is being replaced anyway.
    private func dropReconnectHeldSends(announce: Bool) {
        guard holdingForPendingClient else { return }
        holdingForPendingClient = false
        let dropped = heldSends.count
        heldSends = []
        if announce && dropped > 0 {
            richChatViewModel.transientHint = String(
                localized: "^[\(dropped) message](inflect: true) couldn't be sent — the connection didn't come up."
            )
            scheduleHintClear()
        }
    }

    /// Hold `text` if `client`'s replay has not drained yet. True when held.
    private func holdSendIfReplayPending(client: ACPClient, text: String, images: [ChatImageAttachment]) -> Bool {
        guard heldSendsClient === client else { return false }
        richChatViewModel.addUserMessage(text: text)
        richChatViewModel.closeReplayGate()
        heldSends.append((text, images))
        return true
    }

    /// Stop holding for `client` and send what was held, in order. A no-op
    /// when another client has taken over (its path owns the sends).
    /// `turnAlreadyRunning`: the path just sent a prompt of its own
    /// (autostart), so every held send lands mid-turn; otherwise the first
    /// one starts a turn and the rest land mid-turn. Passed explicitly
    /// because the held echoes already set `isAgentWorking`, which
    /// `sendViaACP` would otherwise read (`/queue`, `/steer` depend on it).
    private func releaseHeldSends(for client: ACPClient, turnAlreadyRunning: Bool) {
        guard heldSendsClient === client else { return }
        let sends = heldSends
        heldSends = []
        heldSendsClient = nil
        guard acpClient === client else { return }
        for (index, send) in sends.enumerated() {
            sendViaACP(
                client: client, text: send.text, images: send.images, localEchoAlreadyAdded: true,
                turnInFlight: turnAlreadyRunning || index > 0
            )
        }
    }

    /// The start path that held sends failed or was superseded: they will
    /// never go out. Their echoes stay in the transcript, so say so.
    private func dropHeldSends(for client: ACPClient) {
        guard heldSendsClient === client else { return }
        let dropped = heldSends.count
        heldSends = []
        heldSendsClient = nil
        if dropped > 0 {
            richChatViewModel.transientHint = String(
                localized: "^[\(dropped) message](inflect: true) couldn't be sent — the connection didn't come up."
            )
            scheduleHintClear()
        }
    }

    /// Start ACP for the current session (or create a new one), then send the
    /// queued prompt. Typing into a blank Chat screen ALWAYS creates a new
    /// session — the "Continue from Last Session" button is the explicit path
    /// for resuming. The previous behavior (falling back to the most recently
    /// active session in the DB) would pick up cron/background sessions the
    /// user never interacted with; those can be garbage-collected by Hermes
    /// between the DB read and ACP `session/load`, producing a silent prompt
    /// failure with no UI feedback.
    private func autoStartACPAndSend(text: String, images: [ChatImageAttachment] = []) {
        // A spawn: the budget first. Blocked, nothing is echoed; Stop on
        // the dialog re-sends it through the same routing.
        let admitted = host?.admitSpawn(
            for: self,
            replay: { [weak self] in
                self?.sendRichText(text, images: images, autoStartInterceptor: nil)
            },
            onWait: { [weak self] in self?.noteSendNotRun(text: text, images: images) }
        ) ?? true
        guard admitted else { return }
        isStartingSession = true
        isReleased = false
        startCarriesUserInput = true
        host?.chatDidTakeProcess(self)
        let intent = beginStartIntent()
        // Bound the whole auto-start pipeline (pre-spawn attribution
        // read included) — S3, t-5451bd1b.
        armStartWatchdog(intent: intent)
        // Show the user message immediately
        richChatViewModel.addUserMessage(text: text)
        autostartInput = (text, images, richChatViewModel.messages.last?.id)
        // …but keep the replay gate shut until the prompt is actually
        // sent. The echo opens it, and the `session/load` below streams
        // the session's whole stored history as live updates before it
        // returns — with the gate open, that history painted as new
        // content after this bubble (S02-F3). `sendViaACP` reopens it
        // with `markPromptSent` once the load's replay has drained.
        richChatViewModel.closeReplayGate()

        Task { @MainActor in
            let sessionToResume = richChatViewModel.sessionId

            // Auto-start under the chat's project scope (if any) so the
            // spawned `hermes acp` loads the project's AGENTS.md (process
            // cwd) and tool calls resolve against the project (session
            // cwd), matching startACPSession. currentProjectPath wins; else
            // recover via the attribution sidecar for the session we resume.
            // Off the MainActor — the sidecar read is transport I/O.
            //
            // We intentionally don't (re)set the project chip here: the
            // realistic autostart path (typing after a reconnect exhausted)
            // already has currentProjectPath set from the original
            // startACPSession, so the chip persists. startACPSession remains
            // the single owner of chip + model-preset + git-branch setup.
            let knownProject = currentProjectPath
            let ctx = context
            let projectPath = await OffPool.run {
                SessionAttributionService(context: ctx).resolveProjectPath(known: knownProject, sessionID: sessionToResume)
            }
            // Bail if a newer session-start superseded us while the (possibly
            // remote) attribution read was in flight.
            guard startStillCurrent(intent, client: nil) else { return }

            let client = makeACPClient(projectPath: projectPath)
            self.acpClient = client
            // A second send before this path has sent the first one waits
            // for the load's replay to drain, like the first one does.
            beginHoldingSends(for: client)

            do {
                acpStatus = ACPPhase.spawning
                try await client.start()
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.authenticating
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                // A remote project path can be `~`-rooted; Hermes takes the
                // session cwd literally, so expand it (B03 handoff).
                let cwd = await context.acpSessionCwd(projectPath: projectPath)
                guard startStillCurrent(intent, client: client) else { return }

                hasActiveProcess = true

                let resolvedSessionId: String
                var loadedHead: String?
                var fallback: SessionResume.FallbackReason?
                if let existing = sessionToResume {
                    acpStatus = ACPPhase.loadingSession
                    // #146: never `session/load` a session Hermes can't
                    // restore, and answer ONLY a not-restorable load with a
                    // new session — any other error fails this start
                    // (outer catch) instead of silently losing context.
                    let outcome = try await resolveResume(
                        client: client, cwd: cwd, projectPath: projectPath,
                        sessionId: existing, intent: intent)
                    guard startStillCurrent(intent, client: client) else { return }
                    resolvedSessionId = outcome.sessionId
                    loadedHead = outcome.loadedHead
                    fallback = outcome.fallbackReason
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                    startedFresh = true
                }
                guard startStillCurrent(intent, client: client) else { return }

                // Header mode chip and model badge follow the session the
                // load or new returned (S01-F1, S03-F2).
                await adoptSessionState(from: client, configModel: nil)
                guard startStillCurrent(intent, client: client) else { return }

                // The mode is scoped to the ACP session, and this path
                // spawns a NEW one — so a project opted into auto-accept
                // has to re-assert it here or the user starts getting
                // prompts again the moment an autostart happens. (Model
                // presets are deliberately not re-applied here; the mode
                // is cheap, one RPC, and its absence is user-visible as
                // a dialog per edit.)
                var autoAcceptApplied = false
                if let projectPath {
                    autoAcceptApplied = await applyProjectAutoAcceptEdits(
                        client: client,
                        sessionId: resolvedSessionId,
                        projectPath: projectPath
                    )
                    guard startStillCurrent(intent, client: client) else { return }
                }
                // The mode the user picked in this chat, if the session
                // came back without it (none picked: no-op).
                await reassertPickedApprovalMode(
                    client: client, sessionId: resolvedSessionId, autoAcceptApplied: autoAcceptApplied)
                guard startStillCurrent(intent, client: client) else { return }

                richChatViewModel.setSessionId(resolvedSessionId)
                noteLoadedHead(loadedHead)
                if let fallback, let existing = sessionToResume {
                    noteResumeFallback(from: existing, to: resolvedSessionId)
                    showResumeFallbackNotice(fallback)
                }
                acpStatus = ACPPhase.ready
                isStartingSession = false
                disarmStartWatchdog()

                // Surface the freshly-created session in the chat
                // sidebar immediately. We can't lean on the file
                // watcher to do this — it fires unconditionally
                // through `scheduleSessionsRefresh` which has a
                // 500 ms debounce. An explicit call here keeps the
                // "type → see new chat in the list" feedback prompt.
                await host?.loadRecentSessions()
                guard startStillCurrent(intent, client: client) else { return }

                // Hermes sends the whole replay before the load response,
                // but the event loop may not have handled all of it yet.
                // Wait until it has, so no replayed chunk lands after
                // `sendViaACP` reopens the gate below.
                await awaitEventLoopDrain(client: client)
                guard startStillCurrent(intent, client: client) else { return }

                // Now send the queued prompt. The optimistic echo was
                // appended above (before session setup), so suppress
                // the second one explicitly.
                // Handed over: from here the turn (or, for a client-side
                // command like `/new`, nothing) is what keeps the chat.
                startCarriesUserInput = false
                sendViaACP(client: client, text: text, images: images, localEchoAlreadyAdded: true)
                releaseHeldSends(for: client, turnAlreadyRunning: true)
            } catch {
                // The process died while reopening a session: that is a
                // dropped connection, and the reconnect ladder (load-only,
                // carries the held sends) is the recovery — hand over now
                // rather than racing the event loop's EOF for it. Pre-#146
                // the catch-all `session/new` attempt's extra hop happened
                // to let the EOF win.
                if sessionToResume != nil, acpClient === client,
                   startStillCurrent(intent, client: nil),
                   handOffDeadStartToReconnect(after: error) {
                    return
                }
                // The event loop's EOF got there first: the ladder owns this
                // session now, and its state isn't this failure's to touch.
                if sessionToResume != nil, acpClient !== client,
                   startStillCurrent(intent, client: nil) {
                    isStartingSession = false
                    disarmStartWatchdog()
                    return
                }
                // Superseded start (a newer click, or the watchdog):
                // the newer path owns the shared state — just make
                // sure this attempt's spawn doesn't leak.
                dropHeldSends(for: client)
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.failed
                isStartingSession = false
                disarmStartWatchdog()
                stopWatchingFailedStart(after: error)
                await recordACPFailure(error, client: client, context: "Auto-start ACP failed")
                // Stop the client even though start failed — a spawn
                // that got as far as opening the channel would
                // otherwise leak the `hermes acp` process (S3's leak
                // contributor: pre-fix, each failure stranded the
                // subprocess plus its pipe readers).
                await client.stop()
                if startStillCurrent(intent, client: nil) {
                    hasActiveProcess = false
                    acpClient = nil
                    host?.chatSettledWithoutConnection(self)
                }
                await recoverRemoteTransportAfterFailure()
            }
        }
    }

    /// Send a prompt over ACP. `localEchoAlreadyAdded` is true only on
    /// the paths that optimistically appended the user's bubble via
    /// `addUserMessage` BEFORE calling here (`autoStartACPAndSend`, the
    /// project-wizard kickoff) — it suppresses the second echo without
    /// any content matching. Internal (not private) for test access.
    func sendViaACP(
        client: ACPClient,
        text: String,
        images: [ChatImageAttachment] = [],
        localEchoAlreadyAdded: Bool = false,
        turnInFlight: Bool? = nil
    ) {
        ScarfMon.event(.chatStream, "mac.sendViaACP", count: 1, bytes: text.utf8.count)

        // Whether a turn was ALREADY in flight when this send started —
        // captured before the local echo below, because `addUserMessage`
        // sets `isAgentWorking = true` itself, so reading the flag after it
        // always answers "working" and the `/queue`-on-idle arm could never
        // fire. The `localEchoAlreadyAdded` callers echoed a moment earlier
        // for the same reason; both of them (autostart's queued prompt and
        // the project-wizard kickoff) are fresh sessions with nothing
        // running, so they read as idle rather than inheriting their own
        // echo.
        // `turnInFlight` overrides it for held sends (`releaseHeldSends`),
        // whose echoes were made before the turn they join had started.
        let wasAgentWorking = turnInFlight ?? (richChatViewModel.isAgentWorking && !localEchoAlreadyAdded)

        // Client-side slash intercept. Hermes ACP doesn't intercept
        // `/new` server-side — sending it as a prompt routes to the
        // LLM, which responds in-character ("/new is a TUI slash
        // command, type it in the TUI prompt"). TestFlight feedback
        // ADyrlh, 2026-05-11. Run BEFORE the user-message append so
        // the transcript doesn't sprout an orphaned slash bubble right
        // before we tear it down for the new session.
        if let intercept = RichChatViewModel.clientSideSlashCommand(
            for: text, capabilities: richChatViewModel.capabilitiesGate
        ) {
            switch intercept {
            case .newSession(let name):
                // Mac startNewSession doesn't yet honor v0.13's optional
                // session-name argument (`hasNewWithSessionName`). Drop
                // it silently for v1 — the slash menu's argument hint
                // still discoverably advertises the syntax for when
                // Mac's startNewSession gains support.
                // `/new <name>` (S03-F5): the name is applied with the same
                // `hermes sessions rename` the sidebar uses, once Hermes
                // has stored the session — its row only exists after the
                // first turn (session.py:329-331 @ v2026.9.24 keeps an
                // empty ACP session unsaved), so a rename now would fail.
                // The window hands it to the chat it starts, which with
                // parallel chats is a new one, not this one.
                let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                host?.startNewSessionFromChat(self, pendingTitle: title.isEmpty ? nil : title)
            case .renameSession, .cliOnly:
                _ = handleLocalSlashCommand(intercept)
            }
            return
        }

        guard let sessionId = richChatViewModel.sessionId else {
            clearACPErrorState()
            acpError = "No session ID — cannot send"
            return
        }

        // Append the user's bubble unless the caller already echoed it
        // optimistically. The old guard here string-matched
        // `messages.last` against the new text, which over-matched
        // DB-hydrated history: deliberately re-sending the same text
        // as an earlier message produced no bubble and (via the
        // engagement gate) a completely invisible turn (S2,
        // 2026-07-13). The echo/no-echo decision is now an explicit
        // caller flag, never content-based.
        if !localEchoAlreadyAdded {
            richChatViewModel.addUserMessage(text: text)
        }
        // Open the replay-suppression gate at the actual send point.
        // The pre-echoed paths opened it inside `addUserMessage`, but
        // autoStart's `setSessionId(resolvedSessionId)` resets the
        // gate AFTER that echo — without this, the turn's chunks and
        // tool events would be dropped as session/load replay.
        richChatViewModel.markPromptSent()

        // Project-scoped slash commands expand client-side: the user
        // sees the literal `/<name> args` they typed (already in the
        // transcript as their bubble), but Hermes receives the expanded
        // prompt template. The literal slash is meaningless to Hermes
        // for project-scoped commands; this is what makes them portable
        // and Hermes-version-independent. v2.5.
        let parsedForWire = RichChatViewModel.parseSlashName(text)
        // A typed `/queue <text>` with NOTHING running is not a queue: the
        // adapter appends it to `queued_prompts` and returns `end_turn`
        // before the only drain (`acp_adapter/server.py:793-799` vs
        // `:908-915` @ `v2026.9.7`), so it would run two turns from now.
        // Send the argument as an ordinary prompt instead — leaving the
        // `/queue` prefix on the wire would hand it straight back to
        // `_cmd_queue` and make the notice a lie.
        let idleQueueText = RichChatViewModel.idleQueueFallbackText(
            name: parsedForWire.name,
            args: parsedForWire.args,
            isAgentWorking: wasAgentWorking,
            capabilities: richChatViewModel.capabilitiesGate
        )
        // A typed `/steer <text>` with NOTHING running is an ordinary turn on
        // Hermes's side too — `_rewrite_prompt_for_interrupt` strips the
        // prefix before the slash dispatch ever sees it
        // (`acp_adapter/server.py:667-689` at `:789`, dispatch at `:792`).
        // Unlike `/queue` the WIRE needs no change (Hermes does the
        // stripping); what changes is the indicator, the hint, and — the part
        // that mattered — whether Stop can cancel it.
        let idleSteer = RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: parsedForWire.name,
            args: parsedForWire.args,
            isAgentWorking: wasAgentWorking,
            capabilities: richChatViewModel.capabilitiesGate
        )
        let wireText = idleQueueText
            ?? richChatViewModel.expandIfProjectScoped(text, context: context)
        // Reconcile the echo against what Hermes will store for THIS wire
        // text (S02-F1), not the typed text.
        richChatViewModel.notePromptWire(displayText: text, wireText: wireText, imageCount: images.count)

        // Non-interruptive slash commands keep the "Agent working…"
        // indicator off and surface a transient toast confirming the
        // command was accepted. v2.5 added `/steer`; v2.8 / Hermes v0.13
        // adds `/queue` (queue a prompt for after the current turn), whose
        // optimistic side-effect on RichChatViewModel lets the queue chip
        // update synchronously without waiting for a server round-trip.
        // `/goal` and `/subgoal` had arms here until P55 and no longer do:
        // the ACP adapter dispatches neither, so there is nothing to mirror
        // (round-6 decision 3, see the `default:` arm).
        //
        // CAPABILITY-AWARE (round-4 decision 12). The menu has hidden
        // `/steer` and `/queue` below their v0.13 floor since P37, but the
        // user can still TYPE either one, and below the floor the adapter
        // does not dispatch it: `_handle_slash_command` returns `None` for a
        // name outside `_COMMANDS` and the raw text goes to the LLM as an
        // ordinary prompt (`acp_adapter/commands.py:88-95` @ `v2026.9.7`;
        // both names enter the dict together at `acp_adapter/server.py:170`
        // /`:171` @ `v2026.5.7`, and `acp_adapter/` at `v2026.4.30` has
        // neither). So that turn is a REAL turn: no queue chip, no
        // "runs after current turn" hint, the normal working indicator, and
        // a one-line notice saying what Scarf actually sent.
        // An idle `/queue` is an ordinary turn now (see `idleQueueText`), so
        // it must NOT suppress the working indicator either.
        let isNonInterruptive = richChatViewModel.isDispatchedNonInterruptiveSlash(text)
            && idleQueueText == nil
            && !idleSteer
        let parsed = parsedForWire
        switch parsed.name {
        // `wasAgentWorking` is the second gate: the queue chip and the
        // "runs after current turn" hint are only true of a session with a
        // turn in flight.
        case "queue" where isNonInterruptive && wasAgentWorking:
            let queuedText = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            if !queuedText.isEmpty {
                richChatViewModel.recordQueuedPrompt(text: queuedText)
            }
            richChatViewModel.transientHint = "Queued — runs after current turn."
            scheduleHintClear()
        // `wasAgentWorking` is the second gate, exactly as `/queue` has it:
        // the "applies after the next tool call" promise is only true of a
        // turn that is running. `isNonInterruptive` already excludes the idle
        // case via `idleSteer`; naming it here keeps the two rows symmetric.
        case "steer" where isNonInterruptive && wasAgentWorking:
            richChatViewModel.transientHint = "Guidance queued — applies after the next tool call."
            scheduleHintClear()
        default:
            // Regular interruptive prompt (or an unrecognized slash).
            // Don't flip "Agent working…" for any other
            // non-interruptive command (defensive; matches the
            // legacy contract).
            //
            // A sub-floor `/steer` / `/queue` lands here too, which is the
            // point: it takes the ordinary-prompt path, indicator included,
            // and says so once.
            //
            // `/goal` and `/subgoal` land here on EVERY host (round-6
            // decision 3): both are real TUI/gateway commands, but the ACP
            // adapter's command table has never carried either at any tag
            // (`acp_adapter/commands.py:44-66` @ `v2026.9.7`), so the text
            // Scarf sends is an ordinary prompt everywhere. Until P55 they
            // had `case` arms that painted a goal pill and a "Goal locked"
            // toast for state Hermes had never been asked to hold;
            // `acpUnhandledSlashNotice` says what was actually sent instead.
            if let notice = RichChatViewModel.acpUnhandledSlashNotice(
                name: parsed.name, capabilities: richChatViewModel.capabilitiesGate
            ) {
                richChatViewModel.transientHint = notice
                scheduleHintClear()
                // The kanban teaching moment rode on the dropped `/goal`
                // arm and moves here with it: a user typing `/goal <text>`
                // is describing a target, which is what the board is for.
                // `--clear`-shaped arguments and a bare `/goal` are not.
                if parsed.name == "goal", ChatViewModel.goalArgumentDescribesATarget(parsed.args) {
                    host?.offerKanbanOnboarding()
                }
            } else if let notice = RichChatViewModel.subFloorSlashNotice(
                name: parsed.name,
                capabilities: richChatViewModel.capabilitiesGate
            ) {
                richChatViewModel.transientHint = notice
                scheduleHintClear()
            } else if idleQueueText != nil {
                richChatViewModel.transientHint = RichChatViewModel.idleQueueNotice
                scheduleHintClear()
            } else if idleSteer {
                richChatViewModel.transientHint = RichChatViewModel.idleSteerNotice
                scheduleHintClear()
            }
            if !isNonInterruptive { acpStatus = ACPPhase.agentWorking }
        }
        let queueHoldsTurn = ChatViewModel.queuedPromptHoldsTurn(
            name: parsed.name,
            isNonInterruptive: isNonInterruptive,
            wasAgentWorking: wasAgentWorking,
            capabilities: richChatViewModel.capabilitiesGate
        )
        launchPromptTask(
            client: client,
            sessionId: sessionId,
            wireText: wireText,
            images: images,
            contextNotes: [],
            isNonInterruptive: isNonInterruptive && !queueHoldsTurn
        )
    }

    /// Run one `session/prompt` and fold its return into the transcript
    /// (`promptComplete`), status and notifications. Shared by typed turns
    /// (`sendViaACP`) and Live Voice turns (`submitVoiceTurn`), which differ
    /// only in their wire payload and `origin`.
    ///
    /// Each turn carries a token and settles only its own entry in
    /// `promptTurns`. The shared "turn is over" state (status pill,
    /// `promptComplete`, the finished notification) moves only when no
    /// OTHER interruptive turn is still in flight: a prompt Hermes queued
    /// behind a running turn returns first, while Hermes is still working.
    private func launchPromptTask(
        client: ACPClient,
        sessionId: String,
        wireText: String,
        images: [ChatImageAttachment],
        contextNotes: [ACPContextNote],
        isNonInterruptive: Bool,
        origin: PromptTurnOrigin = .typed
    ) {
        // Record the turn (ChatViewModel-owned; see `promptTurns`) BEFORE
        // the task exists, so `stop()` and a voice cancel racing this
        // hand-off already see it.
        promptTurnCounter &+= 1
        let token = promptTurnCounter
        promptTurns[token] = PromptTurn(
            sessionId: sessionId, origin: origin, isNonInterruptive: isNonInterruptive, task: nil
        )
        hasSentPrompt = true
        // A slash command Hermes answers itself saves no session on v0.21.5
        // (acp_adapter/server.py:827-837 @ v2026.9.24), so it earns no row.
        if startedFresh, unstoredRow == nil,
           !wireText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            unstoredRow = (displayTitle, Date())
        }
        if !isNonInterruptive { busyTurnOrigins.insert(origin) }
        // Chain this prompt's issue behind the previous one's.
        let previousIssued = lastPromptIssued
        let issueHook = beforePromptIssueForTesting
        let (issued, issuedContinuation) = AsyncStream<Never>.makeStream()
        lastPromptIssued = issued
        let task = Task { @MainActor in
            defer { settlePromptTurn(token) }
            // Whatever happens below, the next prompt must not wait forever.
            defer { issuedContinuation.finish() }
            // Whether another interruptive turn is still in flight — then
            // this return doesn't end the chat's busy period.
            @MainActor func othersStillRunning() -> Bool {
                promptTurns.contains { $0.key != token && !$0.value.isNonInterruptive }
            }
            do {
                let result = try await ScarfMon.measureAsync(.chatStream, "mac.sendPrompt") {
                    // Ends when the previous prompt was issued (immediately
                    // if it already was, or if this task is cancelled).
                    if let issueHook { await issueHook(wireText) }
                    if let previousIssued { for await _ in previousIssued {} }
                    return try await client.sendPrompt(
                        sessionId: sessionId, text: wireText, images: images, contextNotes: contextNotes,
                        onIssued: { issuedContinuation.finish() }
                    )
                }
                // A turn resuming after its client was superseded
                // (session switch / watchdog teardown mid-turn) must
                // not touch shared state: the newer session owns
                // `acpStatus`, the transcript, and notifications.
                guard acpClient === client, !othersStillRunning() else { return }
                // The reply's last chunks can still be in the event loop: the
                // answer to `session/prompt` overtakes them here. Drain them
                // so they land before the turn closes, or the bubble keeps
                // the reply without its end ("IDLE393" for "IDLE39367", seen
                // live on both tags). gh#147's rewound transcript needs the
                // same before it is rebuilt.
                await awaitEventLoopDrain(client: client)
                guard acpClient === client, !othersStillRunning() else { return }
                let isRewind = RichChatViewModel.isGatewayRewindSlash(
                    wireText, capabilities: richChatViewModel.capabilitiesGate)
                acpStatus = ACPPhase.ready
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: result)
                )
                if ChatViewModel.isModelSwitchCommand(wireText),
                   let reply = richChatViewModel.messages.last(where: { $0.isAssistant })?.content {
                    await followTypedModelSwitch(reply: reply)
                }
                // Gateway-backed ACP announces no compression rotation
                // (`followCompressionTipFromDB`); follow it from state.db,
                // and list the chain under its new tip as the provenance
                // path in `startACPEventLoop` does.
                if await richChatViewModel.followCompressionTipFromDB() {
                    SessionLineageIndex.shared.record(
                        server: context.id,
                        lineage: richChatViewModel.transcriptSessionIds
                    )
                    host?.scheduleSessionsRefresh()
                }
                // gh#147: a served `/undo` / `/retry` rewound the session in
                // state.db; rebuild the transcript from it (no-op otherwise).
                if isRewind, let undone = await richChatViewModel.followRewindFromDB(wireText: wireText) {
                    showHint(undone)
                }
                // Re-fetch session from DB to pick up cost/token data Hermes may have written
                await richChatViewModel.refreshSessionFromDB()
                await applyPendingSessionTitle(sessionId: sessionId)
                // Issue #64 — tell the window a reply finished: it marks
                // the chat unread when another one is shown, and notifies
                // unless the user is looking at this chat (parallel chats
                // P1; the window owns the gating).
                if !isNonInterruptive {
                    let preview = richChatViewModel.messages
                        .last(where: { $0.isAssistant })?
                        .content ?? ""
                    host?.chatDidFinishTurn(self, preview: preview)
                }
            } catch is CancellationError {
                // Routine when `stop()` tears down a superseded
                // client mid-turn (its `client.stop()` resumes the
                // held `session/prompt` with `CancellationError`).
                // Pre-guard, this stale resume stomped "Cancelled"
                // over the SUPERSEDING session's status pill.
                guard acpClient === client, !othersStillRunning() else { return }
                acpStatus = ACPPhase.cancelled
            } catch {
                guard acpClient === client else { return }
                let endsBusyPeriod = !othersStillRunning()
                if endsBusyPeriod { acpStatus = ACPPhase.error }
                await recordACPFailure(error, client: client, context: "ACP prompt failed")
                guard endsBusyPeriod else { return }
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: ACPPromptResult(
                        stopReason: "error",
                        inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0
                    ))
                )
                // A `/retry` whose resent turn failed has still rewound
                // the session (gh#147); no-op for anything else. Not while
                // any other turn (a queued one included) is in flight: the
                // rebuild would drop its half-streamed reply.
                if RichChatViewModel.isGatewayRewindSlash(wireText, capabilities: richChatViewModel.capabilitiesGate),
                   !promptTurns.contains(where: { $0.key != token }) {
                    await awaitEventLoopDrain(client: client)
                    await richChatViewModel.followRewindFromDB(wireText: wireText)
                }
            }
        }
        // The task can't have run yet (same actor, no suspension since it
        // was created), so its entry is still there.
        promptTurns[token]?.task = task
    }

    /// A turn's `sendPrompt` returned (or threw): drop its entry, and end the
    /// chat's busy period when it was the last interruptive turn.
    private func settlePromptTurn(_ token: Int) {
        promptTurns[token] = nil
        lastUsedAt = Date()
        if !promptTurns.values.contains(where: { !$0.isNonInterruptive }) {
            busyTurnOrigins = []
        }
    }

    // MARK: - ACP Session Management

    /// Mid-chat model switch. Wired to the chat header badge's
    /// popover. Passing `nil` reverts the session to the config.yaml
    /// default — except Hermes has no "clear override" verb on
    /// `session/set_model`, so we resolve the global default model
    /// name from `config.yaml` and pass that, then drop the local
    /// `currentModelPreset` so the badge shows "Default".
    ///
    /// Non-fatal: any failure logs + restores the previous preset
    /// state (no UI bounce because we update optimistically and only
    /// revert on failure).
    func switchModelPreset(_ preset: ModelPreset?) {
        guard let client = acpClient,
              let sessionId = richChatViewModel.sessionId
        else { return }
        let previous = currentModelPreset
        // Optimistic update — badge flips immediately.
        currentModelPreset = preset

        let svc = fileService
        Task { @MainActor [weak self] in
            let targetModelID: String
            let targetProviderID: String?
            if let preset {
                targetModelID = preset.modelID
                // Pass the preset's provider so Hermes routes through the
                // colon-prefixed model_id wire format — without it, less-
                // obvious model IDs (e.g. `inclusionai/ring-2.6-1t`) fall
                // into Hermes's `detect_provider_for_model` heuristic which
                // picks the wrong provider. See issue #97.
                targetProviderID = preset.providerID.isEmpty ? nil : preset.providerID
            } else {
                // Resolve the config.yaml default. Empty fallback keeps
                // the RPC from blowing up — Hermes treats an empty model
                // as "leave alone", which is the safe no-op.
                //
                // C10: `loadConfig()` is a synchronous file read — an SSH
                // round-trip on a remote host — so it runs on a thread of
                // its own (`OffPool.run`, not the cooperative pool a
                // blocking read would park a core of). The badge already
                // flipped optimistically above, so the hop costs the user
                // nothing visually.
                let config = await OffPool.run { svc.loadConfig() }
                targetModelID = config.model
                // Pair the default model with its configured provider so
                // the "Use global default" mid-chat switch lands on the
                // same provider the CLI default would. Empty / "unknown"
                // (the YAML parser's sentinel) → nil, falling back to the
                // bare-model wire shape.
                let rawProvider = config.provider.trimmingCharacters(in: .whitespaces)
                targetProviderID = (rawProvider.isEmpty || rawProvider == "unknown") ? nil : rawProvider
            }

            do {
                try await client.setSessionModel(
                    sessionId: sessionId,
                    modelID: targetModelID,
                    providerID: targetProviderID
                )
                self?.logger.info("mid-chat model switch to \(targetModelID) (provider: \(targetProviderID ?? "auto")) succeeded")
            } catch {
                // Reverted either way; only a real failure gets a banner
                // (`modelSwitchFailureBanner`).
                self?.logger.warning("mid-chat model switch to \(targetModelID) not applied: \(error.localizedDescription)")
                self?.currentModelPreset = previous
                if let banner = ChatViewModel.modelSwitchFailureBanner(error) {
                    self?.acpError = banner
                }
            }
        }
    }

    /// Point the header's approval-mode chip and model badge at what the
    /// session just opened by `session/new` / `session/load` reports
    /// (`modes.currentModeId`, `models.currentModelId`). Hermes keeps a mode
    /// picked in the header in memory only, so a reconnect or autostart
    /// comes back at `default` (S01-F1); the model is the session's saved
    /// one on a resume, the config default on a new chat (S03-F2). A host
    /// without these fields: the mode chip keeps its value (as before) and
    /// the badge shows the global default.
    ///
    /// `keepModelWhenUnreported`: the reconnect ladder reloads the SAME
    /// session, so a host that sends no `models` keeps the badge it had
    /// (as before); a new start clears it. Every write is dropped when a
    /// newer start replaced `client` while this awaited.
    private func adoptSessionState(
        from client: ACPClient,
        configModel: String?,
        keepModelWhenUnreported: Bool = false
    ) async {
        let state = await client.lastSessionState
        guard acpClient === client else { return }
        if let modeId = state.currentModeId {
            richChatViewModel.activeApprovalMode = ACPApprovalMode(rawValue: modeId) ?? .default
        }
        guard let pickerId = state.currentModelId else {
            if !keepModelWhenUnreported { currentModelPreset = nil }
            return
        }
        let presets = (try? await ModelPresetService.shared(for: context).list()) ?? []
        var defaultModel = configModel
        if defaultModel == nil,
           ChatViewModel.presetMatching(pickerId: pickerId, in: presets) == nil {
            let svc = fileService
            defaultModel = await OffPool.run { svc.loadConfig().model }
        }
        guard acpClient === client else { return }
        currentModelPreset = ChatViewModel.badgePreset(pickerId: pickerId, presets: presets, configModel: defaultModel)
    }

    /// A typed `/model <name>` switched the session: Hermes answers with
    /// `Model switched to: <model>\nProvider: <provider>` and nothing else
    /// (`_cmd_model`, acp_adapter/commands.py:142-151 @ v2026.9.24), so the
    /// badge follows that reply. Any other reply (an error, `/model` with
    /// no argument) leaves the badge alone.
    private func followTypedModelSwitch(reply: String) async {
        guard let pickerId = ChatViewModel.modelSwitchPickerId(fromReply: reply) else { return }
        let presets = (try? await ModelPresetService.shared(for: context).list()) ?? []
        // Never "Default" here: the user asked for this model by name.
        currentModelPreset = ChatViewModel.badgePreset(pickerId: pickerId, presets: presets, configModel: nil)
    }

    /// Switch the per-session edit auto-approval mode on the live ACP
    /// session via `session/set_mode` (Hermes v0.15+). Mirrors
    /// `switchModelPreset` — optimistic update flips the header chip
    /// immediately and only reverts on RPC failure (no UI bounce).
    ///
    /// Non-fatal: any failure logs + restores the previous mode and
    /// surfaces an inline `acpError`. The caller (the header picker) is
    /// already capability-gated on `hasSessionEditAutoApproval`, so this
    /// is only reachable on v0.15+ hosts.
    func switchApprovalMode(_ mode: ACPApprovalMode) {
        guard let client = acpClient,
              let sessionId = richChatViewModel.sessionId
        else { return }
        let previous = richChatViewModel.activeApprovalMode
        guard previous != mode else { return }
        // Optimistic update — chip flips immediately.
        richChatViewModel.activeApprovalMode = mode

        Task { @MainActor [weak self] in
            do {
                try await client.setSessionMode(
                    sessionId: sessionId,
                    modeId: mode.rawValue
                )
                // Accepted: remembered, so a re-attach or reconnect (a
                // fresh session at the default) can put it back.
                if self?.richChatViewModel.sessionId == sessionId {
                    self?.userPickedApprovalMode = mode
                }
                self?.logger.info("session edit auto-approval mode switched to \(mode.rawValue)")
            } catch {
                self?.logger.warning("session/set_mode failed: \(error.localizedDescription)")
                self?.richChatViewModel.activeApprovalMode = previous
                self?.acpError = "Couldn't change edit approval mode: \(error.localizedDescription)"
            }
        }
    }

    /// Apply the project's bound model preset to a live ACP session.
    /// Resolves the binding from `<project>/.scarf/manifest.json` →
    /// looks up the preset by UUID in `~/.hermes/scarf/model_presets.json`
    /// → issues `session/set_model` if the host supports it.
    ///
    /// Non-fatal at every step:
    /// - No binding → silent no-op (use global default).
    /// - Bound id but preset deleted → log + currentModelPreset stays nil.
    /// - Pre-v0.13 host (no `set_session_model` RPC) → log + skip.
    /// - RPC error → log + currentModelPreset stays nil; session keeps
    ///   the config.yaml default.
    ///
    /// On success, `currentModelPreset` carries the applied preset so
    /// the chat header badge can display the active model. Read once at
    /// session boot — mid-chat switches go through a dedicated entry
    /// point.
    private func applyProjectModelPreset(
        client: ACPClient,
        sessionId: String,
        projectPath: String
    ) async {
        // Shared with ScarfGo (S11-F3). The manifest read inside runs off
        // the MainActor — it is transport I/O on a remote host (C10).
        let outcome = await ProjectModelPresetApplier.apply(
            client: client,
            sessionId: sessionId,
            projectPath: projectPath,
            context: context
        )
        // No binding (or a rejected one) leaves the badge on what the
        // session reported it runs.
        if let applied = outcome.appliedPreset { currentModelPreset = applied }
        switch outcome {
        case .noBinding:
            break
        case .presetMissing(let id):
            logger.info("project '\(projectPath)' references deleted preset \(id) — falling back to global default")
        case .storeUnreadable(let message):
            logger.warning("couldn't load the project's model preset: \(message)")
        case .applied(let preset):
            logger.info("applied model preset '\(preset.name)' (\(preset.modelID), provider: \(preset.providerID.isEmpty ? "auto" : preset.providerID)) to session \(sessionId)")
        case .rejected(let preset, let message):
            logger.warning("session/set_model failed for preset '\(preset.name)': \(message) — session stays on config.yaml default")
        }
    }

    /// Open this project's chats in `accept_edits` when the user has
    /// turned that on for the project.
    ///
    /// The setting is Scarf-owned and HMAC-tagged (see
    /// ``ProjectAutoAcceptEditsStore``) — an agent can't write itself
    /// into it. What this does is exactly what the user could do by hand
    /// from the header picker one second after the session opens: one
    /// `session/set_mode`. Enforcement stays Hermes-side, so sensitive
    /// paths still prompt.
    ///
    /// Non-fatal at every step, and silent about it:
    /// - Setting off → no RPC at all, byte-identical to today.
    /// - Pre-v0.15 host (no `session/set_mode`) → skip; C1 says a host
    ///   without the capability must behave exactly as the prior
    ///   release, and the user just keeps getting prompts.
    /// - RPC error → log, leave the mirror on `.default`. The failure is
    ///   "you get asked", which needs no alert.
    ///
    /// Runs after both `session/new` and `session/load`, because the
    /// mode is scoped to the ACP session and a resume is a fresh one.
    /// True when the session is now in `accept_edits` by this call.
    @discardableResult
    private func applyProjectAutoAcceptEdits(
        client: ACPClient,
        sessionId: String,
        projectPath: String
    ) async -> Bool {
        guard autoAcceptEditsStore.isEnabled(projectId: projectPath) else { return false }

        let caps = host?.capabilitiesStore?.capabilities ?? .empty
        guard caps.hasSessionEditAutoApproval else {
            logger.info("host doesn't support session/set_mode (pre-v0.15) — project auto-accept edits not applied")
            return false
        }

        do {
            try await client.setSessionMode(
                sessionId: sessionId,
                modeId: ACPApprovalMode.acceptEdits.rawValue
            )
            // Only mirror what the host actually accepted, so the header
            // chip never claims a posture the session isn't in.
            richChatViewModel.activeApprovalMode = .acceptEdits
            logger.info("applied project auto-accept edits (accept_edits) to session \(sessionId)")
            return true
        } catch {
            logger.warning("session/set_mode accept_edits failed for project '\(projectPath)': \(error.localizedDescription) — session stays on the default ask-first mode")
            return false
        }
    }

    /// Put back the approval mode the user picked in this chat
    /// (`userPickedApprovalMode`) when the session just reopened on another
    /// one — legacy Hermes forgets it with the process. Call after
    /// `adoptSessionState` and `applyProjectAutoAcceptEdits`, so it wins
    /// over the project default as the user's later pick did. Nothing
    /// picked, or a host without `session/set_mode`: no RPC.
    ///
    /// "Already in that mode" is what the SESSION is in, not the chip: the
    /// mode the open reported, or `accept_edits` when the project
    /// auto-accept just set it (`autoAcceptApplied`). A host that reports no
    /// mode leaves the chip on its old value, which says nothing about the
    /// fresh session — unreported is sent. The chip mirrors only what the
    /// host accepted.
    private func reassertPickedApprovalMode(client: ACPClient, sessionId: String, autoAcceptApplied: Bool) async {
        guard let picked = userPickedApprovalMode,
              host?.capabilitiesStore?.capabilities.hasSessionEditAutoApproval == true
        else { return }
        let sessionMode: ACPApprovalMode?
        if autoAcceptApplied {
            sessionMode = .acceptEdits
        } else {
            sessionMode = await client.lastSessionState.currentModeId.flatMap(ACPApprovalMode.init(rawValue:))
        }
        guard picked != sessionMode else { return }
        do {
            try await client.setSessionMode(sessionId: sessionId, modeId: picked.rawValue)
            guard acpClient === client else { return }
            richChatViewModel.activeApprovalMode = picked
            logger.info("re-applied the picked approval mode \(picked.rawValue) to session \(sessionId)")
        } catch {
            logger.warning("couldn't re-apply the picked approval mode \(picked.rawValue): \(error.localizedDescription)")
        }
    }

    /// Capabilities for the project-context decision (#142): the ones a
    /// probe confirmed this session, awaited if the probe is still running.
    /// No store, or a failed probe, is `.empty` — the managed block path.
    private func capabilitiesForProjectContext() async -> HermesCapabilities {
        await host?.capabilitiesStore?.confirmedCapabilities() ?? .empty
    }

    /// `reattaching`: bring this released chat's own session back
    /// (`reattach`) — the transcript stays, the load's replay is kept out of
    /// it, and sends are held (`heldSend` first) until the session is ready.
    func startACPSession(
        resume sessionId: String?,
        projectPath: String? = nil,
        initialPrompt: String? = nil,
        reattaching: Bool = false,
        heldSend: (text: String, images: [ChatImageAttachment])? = nil
    ) {
        ScarfMon.event(.sessionLoad, "mac.startACPSession", count: 1)
        // A spawn: the budget first. Blocked, the start settles here and
        // Stop on the dialog replays it.
        let admitted = host?.admitSpawn(
            for: self,
            replay: { [weak self] in
                guard let self else { return }
                if reattaching {
                    self.reattach(thenSend: heldSend)
                } else {
                    self.startACPSession(resume: sessionId, projectPath: projectPath, initialPrompt: initialPrompt)
                }
            },
            onWait: heldSend.map { send in
                { [weak self] in self?.noteSendNotRun(text: send.text, images: send.images) }
            } ?? initialPrompt.flatMap { prompt -> (() -> Void)? in
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return { [weak self] in self?.host?.parkKickoff(projectPath: projectPath, initialPrompt: prompt) }
            }
        ) ?? true
        guard admitted else {
            disarmStartWatchdog()
            isStartingSession = false
            startCarriesUserInput = false
            return
        }
        stop()
        clearACPErrorState()
        // stop() clears `isStartingSession` (it's a generic teardown
        // helper used by disconnect paths too). Re-arm it here so the
        // session-list overlay stays up through the entire boot.
        isStartingSession = true
        startCarriesUserInput = !(initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        startKickoff = startCarriesUserInput ? initialPrompt.map { (projectPath, $0) } : nil
        isReleased = false
        isReattaching = reattaching
        lastStartProjectPath = projectPath
        host?.chatDidTakeProcess(self)
        if reattaching {
            // The transcript is kept, so the gate an earlier turn opened
            // must be shut again: `session/load` streams the whole history
            // as live updates and would paint it as new content (S02-F3).
            // Sends wait for the session: none can go to a client that
            // isn't there, and none may auto-start a second one.
            richChatViewModel.closeReplayGate()
            holdingForPendingClient = true
            if let heldSend {
                _ = holdSendDuringReconnect(text: heldSend.text, images: heldSend.images)
            }
        }
        // The spawn stage is a fresh start intent: entry points bumped
        // before their pre-spawn awaits, and bumping again here makes a
        // preflight-sheet replay (confirmModelPreflight → this method,
        // no entry-point bump) supersede whatever came before it.
        let intent = beginStartIntent()

        // C10: the preflight's `loadConfig()` is a synchronous file read —
        // an SSH round-trip on a remote host — and it sat on the main
        // actor at the head of EVERY session start and resume. It now runs
        // on a thread of its own (`OffPool.run`; a blocking read on the
        // cooperative pool would park one of its fixed threads). Bound the
        // stage the way `resumeSession` / `continueLastSession` bound
        // theirs — the spawn stage below re-arms — and re-check the start
        // generation after the hop, since a newer start may have landed.
        armStartWatchdog(intent: intent)
        let svc = fileService
        Task { @MainActor [weak self] in
            let config = await OffPool.run { svc.loadConfig() }
            guard let self, self.startStillCurrent(intent, client: nil) else { return }
            self.continueStartACPSession(
                intent: intent,
                config: config,
                resume: sessionId,
                projectPath: projectPath,
                initialPrompt: initialPrompt
            )
        }
    }

    /// The rest of `startACPSession`, resumed on the main actor once the
    /// off-main `config.yaml` read has landed. Split out only for that
    /// hop: `intent` is the start intent begun by the caller (NOT a fresh
    /// one — a new generation here would supersede the caller's own
    /// bail-out checks), and `config` is what the preflight is checked
    /// against.
    private func continueStartACPSession(
        intent: Int,
        config: HermesConfig,
        resume sessionId: String?,
        projectPath: String?,
        initialPrompt: String?
    ) {
        // Pre-flight: bail before opening any ACP plumbing if the
        // active server's `config.yaml` has no primary model or
        // provider. Hermes would otherwise let `session/new` succeed
        // and only fail at first prompt with an opaque
        // "Model parameter is required" 400. Stashing the start
        // arguments here lets `confirmModelPreflight` replay them
        // unchanged after the user picks a model.
        let preflight = ModelPreflight.check(config)
        // `passed` is emitted here rather than inside `ModelPreflight` so it
        // fires once per session start (the user-visible gate), not once per
        // background config-diagnostics refresh. The failing branch stays
        // silent — its outcome is whatever the user then does with the sheet
        // (`confirmed` / `cancelled` / `failed`).
        if preflight.isConfigured {
            Analytics.record(.modelPreflightResult(outcome: .passed))
        } else {
            // Settle first: the host decides from this chat's state whether
            // to keep it (a background chat bailing while the focused one
            // already waits on the sheet is dropped), so it must not still
            // read as a start in progress.
            pendingStartArgs = (sessionId, projectPath, initialPrompt)
            acpStatus = ""
            hasActiveProcess = false
            isStartingSession = false
            startCarriesUserInput = false
            disarmStartWatchdog()
            if isReattaching {
                // Still released: a pick re-attaches it (the window's
                // replay checks), and nothing typed can wait on a sheet.
                dropReconnectHeldSends(announce: true)
                isReattaching = false
                isReleased = true
            }
            host?.presentModelPreflight(
                for: self,
                reason: preflight.reason,
                customProviders: ModelPreflight.CustomProviders(config)
            )
            return
        }

        acpStatus = ACPPhase.spawning
        // Re-arm for the spawn stage (replaces any entry-point arm the
        // stop() above disarmed).
        armStartWatchdog(intent: intent)

        // Project-scoped chats spawn `hermes acp` with the project as the
        // process cwd so Hermes loads the project's AGENTS.md context files
        // (it reads them from the process cwd, not the ACP session cwd).
        let client = makeACPClient(projectPath: projectPath)
        self.acpClient = client
        // A re-attach: what was typed since it began, and anything typed
        // until its load's replay has drained, waits for this client.
        let reattaching = isReattaching
        if reattaching { beginHoldingSends(for: client) }
        let attribution = SessionAttributionService(context: context)

        // If the caller passed a project path, hand Scarf's project
        // context to Hermes BEFORE starting ACP — Hermes reads it when it
        // builds a session's system prompt. How depends on the host (#142):
        //
        // - v0.16+ (`supportsEnvironmentHint`, confirmed by a probe this
        //   session): render the short hint into `environmentHintSlot`,
        //   which the spawn passes as `HERMES_ENVIRONMENT_HINT` (composed
        //   with the user's own env / config hint), and strip the old
        //   managed block from the project's context files.
        // - Older or undetected hosts: refresh the Scarf-managed block in
        //   the project's AGENTS.md, exactly as before (C1). Safe on bare
        //   projects (creates AGENTS.md with just the block); safe on
        //   template-installed projects (splices the block into existing
        //   AGENTS.md without touching template content).
        //
        // Non-blocking on failure either way: we log and proceed.
        //
        // What the refresh reaches (S11-F4): every NEW session, and a
        // resume that `session/load` can't restore (it falls back to a
        // new session). A resumed session that has history normally
        // does NOT see it: Hermes reuses the system prompt it stored
        // when the session began, and rebuilds it only when the model,
        // provider or cwd no longer match
        // (`_restore_or_build_system_prompt` /
        // `_stored_prompt_matches_runtime`,
        // `agent/conversation_loop.py:681-730,815-838` @ v2026.9.24).
        // So cron, slash-command or project-name changes show up in new
        // chats, not in old ones. The write is still worth doing on
        // resume: it keeps the file current for those cases.
        let contextForPrep = context
        let prepLogger = logger
        Task { @MainActor [self] in
            if let projectPath {
                let delivery = ProjectEnvironmentHint.delivery(
                    for: await capabilitiesForProjectContext())
                guard startStillCurrent(intent, client: client) else { return }
                // Synchronous file I/O (ProjectDashboardService.loadRegistry +
                // ProjectAgentContextService.refresh, which itself walks the
                // slash-commands directory) must run off the MainActor, and
                // off the cooperative pool too (`OffPool`, P60: on a remote
                // it is blocking SFTP) — awaited here so the AGENTS.md block
                // (or the hint) is ready before client.start().
                let hint: EnvironmentHintRequest? = await OffPool.run {
                    let registry = ProjectDashboardService(context: contextForPrep).loadRegistry()
                    guard let project = registry.projects.first(where: { $0.path == projectPath }) else {
                        return nil
                    }
                    switch delivery {
                    case .managedBlock:
                        do {
                            try ProjectAgentContextService(context: contextForPrep).refresh(for: project)
                        } catch {
                            prepLogger.warning("couldn't refresh project context block for \(project.name): \(error.localizedDescription)")
                        }
                        return nil
                    case .environmentHint:
                        let store = ProjectStore(context: contextForPrep)
                        let scarfProject = store.load(projectPath: project.path) ?? store.derive(from: project)
                        let prepared = ProjectEnvironmentHint.prepare(
                            project: scarfProject, projectPath: project.path, context: contextForPrep)
                        if let error = prepared.stripError {
                            prepLogger.warning("couldn't strip the managed block for \(project.name): \(error.localizedDescription)")
                        }
                        return prepared.request
                    }
                }
                // Pre-spawn await — a newer start may have superseded
                // us while the registry/AGENTS.md I/O ran. Abandon
                // BEFORE spawning so the superseded attempt never
                // launches a process at all — and before touching the
                // slot, which the newer start may already have filled.
                guard startStillCurrent(intent, client: client) else { return }
                environmentHintSlot.set(hint, forProjectPath: projectPath)
            }

            do {
                // Start ACP process and event loop FIRST
                try await client.start()
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.authenticating
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                // Project-scoped chats pass the project's absolute path
                // as cwd so Hermes tool calls and subsequent ACP ops
                // resolve relative paths against the project's files.
                // Falls back to the user's home (existing v2.2 behavior)
                // when the caller didn't request a project scope.
                // `??` can't wrap an async autoclosure, so we
                // materialize the fallback with an if-let.
                // A remote project path can be `~`-rooted; Hermes takes the
                // session cwd literally, so expand it (B03 handoff).
                let cwd = await context.acpSessionCwd(projectPath: projectPath)
                guard startStillCurrent(intent, client: client) else { return }

                // Mark active BEFORE setting session ID so .task(id:) sees isACPMode=true
                // and doesn't wipe messages with a DB refresh
                hasActiveProcess = true

                let resolvedSessionId: String
                if let sessionId {
                    acpStatus = ACPPhase.loadingSession
                    // Sessions Hermes never ACP-persisted (webui, cron, CLI,
                    // gateway) can't be `session/load`ed: open a fresh one
                    // in the same cwd, replay the transcript from state.db,
                    // and SAY so in the transcript (#146) — a new context
                    // must not wear a resume's clothes. Any load error other
                    // than not-restorable fails the start (outer catch).
                    let outcome = try await resolveResume(
                        client: client, cwd: cwd, projectPath: projectPath,
                        sessionId: sessionId, intent: intent)
                    guard startStillCurrent(intent, client: client) else { return }
                    resolvedSessionId = outcome.sessionId
                    let loadedHead = outcome.loadedHead
                    // Surface "Loading history…" before the (potentially
                    // 30s) message-history fetch fires. Pre-fix the user
                    // saw "Loading session…" through start(), then jump
                    // straight to "Ready" the moment the bytes hit the
                    // pane — but the actual hydrate is the slowest step
                    // on a remote and the pane looked engageable while
                    // the SQLite query was still pending. v2.8.
                    acpStatus = ACPPhase.loadingHistory
                    // A rotated compression chain is listed under its tip;
                    // load the whole lineage as one transcript (R11
                    // carry-over), as Hermes does.
                    // …extended by the head `session/load` reported when the
                    // chain rotated past what the list knew.
                    await richChatViewModel.loadSessionHistory(
                        sessionId: sessionId,
                        acpSessionId: resolvedSessionId,
                        lineage: RichChatViewModel.lineage(
                            host?.transcriptLineage(for: sessionId) ?? [], for: sessionId, addingLoadedHead: loadedHead)
                    )
                    guard startStillCurrent(intent, client: client) else { return }
                    // After the history, so the notice anchors below it.
                    if let fallback = outcome.fallbackReason {
                        noteResumeFallback(from: sessionId, to: resolvedSessionId)
                        showResumeFallbackNotice(fallback)
                    }
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                    startedFresh = true
                    guard startStillCurrent(intent, client: client) else { return }
                }

                // Header mode chip and model badge follow what the session
                // reports it runs (S01-F1, S03-F2); a project preset below
                // then overrides the badge.
                await adoptSessionState(from: client, configModel: config.model)
                guard startStillCurrent(intent, client: client) else { return }

                // Apply the project's bound model preset before unlocking
                // the prompt. Non-fatal — falls back to the config.yaml
                // default on any failure (missing preset, pre-v0.13 host,
                // RPC error). Runs after both new and resumed sessions so
                // a project's preset survives a reconnect into the same
                // chat. No-op when no projectPath was passed.
                var autoAcceptApplied = false
                if let projectPath {
                    await applyProjectModelPreset(
                        client: client,
                        sessionId: resolvedSessionId,
                        projectPath: projectPath
                    )
                    guard startStillCurrent(intent, client: client) else { return }

                    // Then the project's edit-approval posture, if the
                    // user has opted this project into auto-accept.
                    autoAcceptApplied = await applyProjectAutoAcceptEdits(
                        client: client,
                        sessionId: resolvedSessionId,
                        projectPath: projectPath
                    )
                    guard startStillCurrent(intent, client: client) else { return }
                }

                // A re-attach (or an in-place restart of this chat's own
                // session): the approval mode the user picked here, which
                // legacy Hermes didn't keep. A new session has none.
                await reassertPickedApprovalMode(
                    client: client, sessionId: resolvedSessionId, autoAcceptApplied: autoAcceptApplied)
                guard startStillCurrent(intent, client: client) else { return }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = ACPPhase.ready
                isStartingSession = false
                disarmStartWatchdog()

                // Attribute this session to the project it was started
                // under, so the per-project Sessions tab can surface it
                // without a user action. No-op when projectPath is nil.
                // Idempotent: re-attribution of the same pair is free.
                //
                // Then resolve which project (if any) this session belongs
                // to, so SessionInfoBar + nav title can surface it.
                // Two inputs — use whichever is non-nil:
                //   * `projectPath` — the caller asked for a project
                //     scope (fresh project chat). Just-attributed;
                //     definitely in the sidecar.
                //   * `attribution.projectPath(for: resolvedSessionId)`
                //     — the resumed session was previously attributed.
                //     Covers "click an old project-attributed session
                //     from the global Sessions sidebar / Resume menu"
                //     where projectPath isn't known at the call site.
                // The name comes from the projects registry; a path in
                // the sidecar whose project has since been removed shows
                // the path as a fallback label.
                //
                // The sidecar write, the sidecar read and the registry
                // read are all transport I/O (SFTP / SSH on a remote), so
                // they run in one `OffPool` batch, never on the main actor
                // (charter C10).
                let attributionContext = context
                let resolvedProject: (path: String?, name: String?) = await OffPool.run {
                    if let projectPath {
                        attribution.attribute(sessionID: resolvedSessionId, toProjectPath: projectPath)
                    }
                    guard let path = projectPath ?? attribution.projectPath(for: resolvedSessionId) else {
                        return (nil, nil)
                    }
                    let registry = ProjectDashboardService(context: attributionContext).loadRegistry()
                    return (path, registry.projects.first(where: { $0.path == path })?.name)
                }
                guard startStillCurrent(intent, client: client) else { return }
                let attributedPath = resolvedProject.path
                if let path = attributedPath {
                    let name = resolvedProject.name
                    self.currentProjectPath = path
                    self.currentProjectName = name ?? path
                    // Pull any project-scoped slash commands the user has
                    // authored at <path>/.scarf/slash-commands/ so the
                    // chat slash menu surfaces them. Async + non-fatal —
                    // the menu degrades to the ACP commands only on
                    // any failure (logged inside the service).
                    self.richChatViewModel.loadProjectScopedCommands(at: path)
                    // Also refresh global Scarf slash commands so the
                    // `/scarf-*` family stays in sync with any version
                    // bumps the bootstrap service applied this launch
                    // (or any hand-edits the user has made since).
                    self.richChatViewModel.loadGlobalScopedCommands()
                    // Resolve the project's current git branch (v2.5)
                    // for the chat header chip. Async + nil on failure
                    // (not a git repo / git missing / SSH error) — the
                    // chip just doesn't render.
                    let svc = GitBranchService(context: context)
                    Task { @MainActor [weak self] in
                        let branch = await svc.branch(at: path)
                        self?.currentGitBranch = branch
                    }
                } else {
                    // Explicit clear on non-project sessions so the
                    // indicator doesn't leak from a previous chat.
                    self.currentProjectPath = nil
                    self.currentProjectName = nil
                    self.currentGitBranch = nil
                    self.richChatViewModel.loadProjectScopedCommands(at: nil)
                    // Global Scarf commands stay loaded — they're not
                    // project-scoped, so this is the path that lets a
                    // user fire `/scarf-help` or `/scarf-new` from a
                    // global (non-project) chat too.
                    self.richChatViewModel.loadGlobalScopedCommands()
                }

                // Refresh session list so the new ACP session appears in the Resume menu
                await host?.loadRecentSessions()
                guard startStillCurrent(intent, client: client) else { return }

                logger.info("ACP session ready: \(resolvedSessionId)")

                if reattaching {
                    // Every replayed update is handled (and dropped by the
                    // shut gate) before a held send reopens it.
                    await awaitEventLoopDrain(client: client)
                    guard startStillCurrent(intent, client: client) else { return }
                    isReattaching = false
                    releaseHeldSends(for: client, turnAlreadyRunning: false)
                }

                // v2.8 wizard handoff: auto-send the kickoff prompt now
                // that the session is connected. Renders as a normal user
                // bubble (matches the user's intent — they triggered this
                // flow via the New Project sheet) and routes through the
                // same `sendViaACP` path that typed messages use, so the
                // event loop, attribution, and streaming are identical.
                if let prompt = initialPrompt,
                   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    richChatViewModel.addUserMessage(text: prompt)
                    startCarriesUserInput = false
                    sendViaACP(client: client, text: prompt, images: [], localEchoAlreadyAdded: true)
                }
            } catch {
                dropHeldSends(for: client)
                // Superseded start (a newer click, or the watchdog):
                // the newer path owns the shared state — just make
                // sure this attempt's spawn doesn't leak.
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.failed
                isStartingSession = false
                disarmStartWatchdog()
                stopWatchingFailedStart(after: error)
                // A released chat that failed to come back stays released:
                // kept, transcript and all, to retry when next focused.
                if reattaching {
                    isReattaching = false
                    isReleased = true
                }
                await recordACPFailure(error, client: client, context: "Failed to start ACP session")
                // Stop the client even though start failed — pre-fix
                // this path leaked the spawned `hermes acp` process
                // (plus its two pipe readers) on EVERY start failure,
                // a confirmed S3 pool-starvation contributor.
                await client.stop()
                if startStillCurrent(intent, client: nil) {
                    hasActiveProcess = false
                    acpClient = nil
                    host?.chatSettledWithoutConnection(self)
                }
                await recoverRemoteTransportAfterFailure()
            }
        }
    }

    private func startACPEventLoop(client: ACPClient) {
        acpEventsHandled = 0
        acpEventTask = Task { @MainActor [weak self] in
            let eventStream = await client.events
            for await event in eventStream {
                guard !Task.isCancelled else { break }
                ScarfMon.event(.chatStream, "mac.acpEvent", count: 1)
                // Intercept session title updates: Hermes v0.16+ emits a
                // `session_info_update` whenever it (re)generates a session
                // title. The rich transcript VM has no title affordance, so
                // apply the new title to the sidebar caches here — the same
                // in-place mutation `renameSession` performs, minus the CLI
                // call (Hermes already persisted the change).
                //
                // The same update carries Hermes's session provenance: a
                // compression rotation moved the conversation's turns to a
                // new continuation row (acp_adapter/server.py:952-962 @
                // v2026.9.24). The transcript follows it (RichChatViewModel);
                // here the sidebar reloads so the chain is listed under its
                // new tip, which `isAttached(to:)` matches by lineage.
                var rotated = false
                if case let .sessionInfoUpdate(sessionId, title, _, provenance) = event {
                    self?.host?.applySessionTitleUpdate(sessionId: sessionId, title: title)
                    if let current = provenance?.currentHermesSessionId,
                       let rich = self?.richChatViewModel,
                       rich.sessionId == sessionId, !rich.transcriptCovers(current) {
                        rotated = true
                    }
                }
                ScarfMon.measure(.chatStream, "mac.handleACPEvent") {
                    self?.richChatViewModel.handleACPEvent(event)
                }
                if rotated, let self {
                    // Attribution is keyed by the root; let id lookups on
                    // the new tip find it before the next list load does.
                    SessionLineageIndex.shared.record(
                        server: self.context.id,
                        lineage: self.richChatViewModel.transcriptSessionIds
                    )
                    self.host?.scheduleSessionsRefresh()
                }
                self?.acpEventsHandled += 1
                // Don't overwrite a phase-typed acpStatus with the
                // ACP-side "Connected" string mid-stream; we promote
                // to ready/agentWorking from the call sites that own
                // the lifecycle. The event-loop side-effect is
                // the heartbeat — leave acpStatus alone here.
                _ = await client.statusMessage
            }
            // Stream ended — if we weren't cancelled, the connection died
            if !Task.isCancelled {
                self?.handleConnectionDied()
            }
        }
    }

    /// Wait until the event loop has handled every event `client` had
    /// emitted when this was called. `ACPClient` handles incoming lines
    /// one at a time, so a count read right after an RPC returns covers
    /// every notification sent before that response (see
    /// `ACPClient.eventsEmitted`). Bounded: a wedged loop must not hold
    /// the send forever, and a client that is no longer the live one
    /// ends the wait.
    private func awaitEventLoopDrain(client: ACPClient, timeoutSeconds: TimeInterval = 5) async {
        let target = await client.eventsEmitted
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while acpEventsHandled < target,
              acpClient === client,
              Date() < deadline,
              !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func startHealthMonitor(client: ACPClient) {
        healthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                let healthy = await client.isHealthy
                if !healthy {
                    self?.handleConnectionDied()
                    break
                }
            }
        }
    }

    /// A start that failed AFTER arming its event loop / health monitor
    /// (a `session/load` error, a failed `session/new`) is about to stop its
    /// own client. Disarm them first: the stream's EOF would otherwise read
    /// as a dropped connection, and `handleConnectionDied` would overwrite
    /// the failure with a reconnect ladder that re-sends the same failing
    /// load (#146 — the error must surface, with its retry).
    ///
    /// Not when the process itself died: that EOF IS a dropped connection,
    /// and the reconnect ladder is the recovery that carries held sends
    /// over (ChatReconnectHoldR17Tests).
    /// A resume whose `hermes acp` died mid-start (`processTerminated`):
    /// end the start and run the connection-died path, whose reconnect
    /// ladder reloads the same session and carries held sends. True when
    /// handed over.
    private func handOffDeadStartToReconnect(after error: Error) -> Bool {
        guard case ACPClientError.processTerminated = error else { return false }
        isStartingSession = false
        disarmStartWatchdog()
        handleConnectionDied()
        return true
    }

    private func stopWatchingFailedStart(after error: Error) {
        if case ACPClientError.processTerminated = error { return }
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func handleConnectionDied() {
        guard acpClient != nil, !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        logger.warning("ACP connection died")

        // Finalize any in-progress streaming message before reconnection
        richChatViewModel.finalizeOnDisconnect()

        // Save session ID for reconnection before cleaning up
        let savedSessionId = richChatViewModel.sessionId

        // A Live Voice session can't reach Hermes any more: its running
        // turn died with the process, and every spoken request until a
        // reconnect (which may never come) would fail. End it now rather
        // than bill through the reconnect ladder; the panel says why.
        // (`stop()`, the other teardown, isn't on this path.)
        host?.chatConnectionDied(self)

        // Clean up the dead client. No `session/cancel` here — the
        // process is already gone; just drop the in-flight turns so a
        // later `stop()` doesn't cancel a turn that died with them.
        cancelAllPromptTurns()
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task { await client.stop() }
        }
        acpClient = nil
        hasActiveProcess = false

        // Attempt auto-reconnect if we have a session to restore
        guard let savedSessionId else {
            showConnectionFailure()
            isHandlingDisconnect = false
            host?.chatSettledWithoutConnection(self)
            return
        }
        // An autostart that died mid-start: the ladder reloads the same
        // session and sends what is held, so the message it was carrying goes
        // first (its echo is there). Whichever saw the death first, the
        // event loop's EOF or the start's own catch, comes through here.
        if startCarriesUserInput, let autostartInput {
            heldSends.insert((autostartInput.text, autostartInput.images), at: 0)
            startCarriesUserInput = false
        }
        attemptReconnect(sessionId: savedSessionId)
    }

    private func attemptReconnect(sessionId: String) {
        reconnectTask?.cancel()
        clearACPErrorState()
        // Sends from here until the ladder installs a client are held for
        // it. Sends already held for the client that just died (its load
        // replay never drained) are carried: the ladder reloads the same
        // session, so they go out on its client instead of vanishing.
        heldSendsClient = nil
        holdingForPendingClient = true

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Reconnect into the SAME project scope the chat was started
            // under so the respawned `hermes acp` reloads the project's
            // AGENTS.md (process cwd) and tool calls keep resolving against
            // the project (session cwd). currentProjectPath was set when the
            // session went ready; fall back to the attribution sidecar.
            // Resolve once (off the MainActor — transport I/O) and reuse it
            // across retry attempts.
            let knownProject = self.currentProjectPath
            let ctx = self.context

            // gh#123: the stream just died — on a remote that usually
            // means the ControlMaster's TCP died with it. Reset a dead
            // master BEFORE the attribution read below and the reconnect
            // attempts, or every one of them (and the read itself) hangs
            // on the corpse and the retry loop burns out against a
            // connection that can never succeed. Surface a status first —
            // the probe can take up to ~15s when the master is wedged.
            acpStatus = "Reconnecting…"
            await recoverRemoteTransportAfterFailure()

            let projectPath = await OffPool.run {
                SessionAttributionService(context: ctx).resolveProjectPath(known: knownProject, sessionID: sessionId)
            }

            // After a recovery that left the host without a master, one
            // chat's spawn brings a new one up and the others wait for it
            // (`SSHMasterRecovery.reconnectTurn`): N chats handshaking at
            // once each authenticate on their own (gh#138). A local host,
            // or no recent recovery: `.free`, no wait.
            let masterKey = ControlMasterKey.of(ctx)
            let recovery = self.masterRecovery
            var ledWave: UUID?
            if case .leader(let waveId) = await recovery.reconnectTurn(for: masterKey) { ledWave = waveId }
            // However the ladder ends, a leader never strands its followers
            // (they also give up waiting on their own after a few seconds).
            @MainActor func endLead() {
                if let waveId = ledWave { recovery.leaderStarted(for: masterKey, waveId: waveId) }
                ledWave = nil
            }
            defer { endLead() }

            for attempt in 1...Self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }

                acpStatus = "Reconnecting (\(attempt)/\(Self.maxReconnectAttempts))…"
                logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) for session \(sessionId)")

                // Backoff delay (skip on first attempt for fast recovery)
                if attempt > 1 {
                    let delay = min(
                        reconnectBaseDelay * UInt64(1 << (attempt - 1)),
                        Self.maxReconnectDelay
                    )
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let client = makeACPClient(projectPath: projectPath)
                do {
                    do {
                        try await client.start()
                    } catch {
                        // Spawned or not, the followers' wait is over.
                        endLead()
                        throw error
                    }
                    endLead()

                    let cwd = await context.acpSessionCwd(projectPath: projectPath)
                    // session/load ONLY (t-217da62b). NEVER session/resume:
                    // Hermes's resume_session restores through the exact same
                    // path as load_session but silently CREATES a fresh
                    // server-side session when the id isn't restorable —
                    // the old resume-then-load ladder orphaned one session
                    // per attempt (and always fell through to load anyway,
                    // because it required a top-level sessionId the resume
                    // response never carries). And NEVER session/new — that
                    // loses all conversation context. Keep in sync with the
                    // iOS ladder (Scarf iOS/Chat/ChatView.swift,
                    // attemptReconnect).
                    // Gateway-backed hosts: reload a non-project chat in
                    // its own folder, so the reconnect doesn't move it.
                    let gatewayBacked = await capabilitiesForProjectContext().hasGatewayBackedACP
                    let loaded = try await SessionResume.loadInSessionFolder(
                        defaultCwd: cwd, projectPath: projectPath, gatewayBacked: gatewayBacked,
                        sessionCwd: { await SessionResume.fetchCwd(context: ctx, sessionId: sessionId) },
                        load: { try await client.loadSessionWithProvenance(cwd: $0, sessionId: sessionId) })
                    let resolvedSessionId = loaded.sessionId

                    // The awaits above can outlive this ladder: a sidebar
                    // click / delete / leaving the chat runs `stop()`,
                    // which cancels this task (and a fresh start installs
                    // its own client) — but none of that can interrupt
                    // `start()` or `loadSession`. Installing now would put
                    // the dead session's client and transcript over the
                    // one the user moved to, so stop ours and bow out.
                    guard !Task.isCancelled, self.acpClient == nil else {
                        // Another path installed a client without tearing
                        // this ladder down: the held sends were typed for
                        // this session's client, which will not come.
                        if !Task.isCancelled { dropReconnectHeldSends(announce: true) }
                        await client.stop()
                        return
                    }

                    // Success — wire up the new client. Its load replay is
                    // still buffered in the client's event stream (the loop
                    // starts below), so sends wait until it has drained.
                    self.acpClient = client
                    beginHoldingSends(for: client)
                    self.hasActiveProcess = true
                    richChatViewModel.setSessionId(resolvedSessionId)
                    // A load naming an uncovered head (defensive; see
                    // `noteLoadedHead`): reconcile that head too.
                    noteLoadedHead(loaded.provenance?.currentHermesSessionId)

                    // Reconcile in-memory messages with what Hermes persisted to DB
                    await richChatViewModel.reconcileWithDB(sessionId: resolvedSessionId)

                    // The header shows what the reloaded session runs: a
                    // fresh `hermes acp` restores it at the `default` mode
                    // (S01-F1) and on its saved model (S03-F2).
                    await adoptSessionState(from: client, configModel: nil, keepModelWhenUnreported: true)

                    // A reconnect is a fresh ACP session, so the
                    // session-scoped edit-approval mode is back at the
                    // default — re-assert the project's opted-in posture.
                    var autoAcceptApplied = false
                    if let projectPath {
                        autoAcceptApplied = await applyProjectAutoAcceptEdits(
                            client: client,
                            sessionId: resolvedSessionId,
                            projectPath: projectPath
                        )
                    }
                    // …and then the mode the user picked in this chat, which
                    // the reload lost on legacy Hermes (P1: new behaviour —
                    // before, a reconnect came back at the default).
                    await reassertPickedApprovalMode(
                        client: client, sessionId: resolvedSessionId, autoAcceptApplied: autoAcceptApplied)

                    // Same check after the reconcile awaits: a teardown in
                    // that window already stopped this client (it was
                    // installed) — arming its event loop and health
                    // monitor now would turn that stop into a phantom
                    // "connection died" and a second ladder.
                    guard !Task.isCancelled, self.acpClient === client else { return }

                    acpStatus = ACPPhase.ready
                    clearACPErrorState()

                    startACPEventLoop(client: client)
                    startHealthMonitor(client: client)

                    isHandlingDisconnect = false
                    logger.info("Reconnected successfully on attempt \(attempt)")
                    // The replay Hermes streamed inside `session/load` is
                    // handled (and dropped by the gate `setSessionId`
                    // closed) before any held send opens the gate.
                    await awaitEventLoopDrain(client: client)
                    releaseHeldSends(for: client, turnAlreadyRunning: false)
                    return
                } catch {
                    logger.warning("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    await client.stop()
                    continue
                }
            }

            // All attempts exhausted. No Live Voice session to end here:
            // `handleConnectionDied` ended it, and none can start while
            // `acpClient` is nil (`canHostVoiceTurns`).
            guard !Task.isCancelled else { return }
            showConnectionFailure()
            dropReconnectHeldSends(announce: true)
            isHandlingDisconnect = false
            host?.chatSettledWithoutConnection(self)
        }
    }

    private func showConnectionFailure() {
        richChatViewModel.handleACPEvent(.connectionLost(reason: "The ACP process terminated unexpectedly"))
        acpStatus = ACPPhase.connectionLost
        clearACPErrorState()
        acpError = "Connection lost. Use the Session menu to reconnect."
    }

    /// Tear this chat's ACP connection down. `reason` is the composer hint
    /// painted when a turn was in flight (and cancelled): plain "Turn
    /// cancelled." unless the caller knows better (a delete). Switching
    /// chats no longer comes through here for a working chat — it keeps
    /// running in the background (parallel chats P1).
    ///
    /// Returns the task that cancels a turn in flight (bounded) and stops
    /// the client, for a caller that must wait for the process to go.
    @discardableResult
    func stop(reason: String = "Turn cancelled.") -> Task<Void, Never>? {
        // Every deliberate ACP teardown (session switch, delete, terminal
        // mode, the start watchdog) removes the voice session's turn host
        // — the window ends it only when this is the chat it shows.
        // A connection that DIES doesn't come through here:
        // `handleConnectionDied` ends the voice session itself.
        host?.chatWillTearDown(self)
        return tearDownConnection(cancelledHint: reason)
    }

    /// `stop` without the voice teardown: the connection, its watchdog,
    /// reconnect ladder and turns. `cancelledHint` is the composer hint for
    /// a turn cancelled here; nil paints none.
    private func tearDownConnection(cancelledHint: String?) -> Task<Void, Never>? {
        disarmStartWatchdog()
        isReattaching = false
        reconnectTask?.cancel()
        reconnectTask = nil
        dropReconnectHeldSends(announce: false)
        // Capture BEFORE cancelling the prompt task. Keyed off
        // ChatViewModel-owned turn state — NOT `richChatViewModel` —
        // because in the session-switch paths `reset()` already wiped
        // `isAgentWorking`/`sessionId` at click time, which made the
        // S4 cancel unreachable on exactly its flagship path (audit,
        // t-5451bd1b).
        let inFlightSessionId = inFlightPromptSessionId
        let turnWasInFlight = inFlightSessionId != nil
        // The in-flight turns' tasks, so the teardown below can wait for
        // their `session/prompt` answers. `cancelAllPromptTurns` cancels
        // the Swift tasks, but that doesn't abandon the pending RPC — the
        // task still ends when Hermes answers (its result is then ignored:
        // `acpClient` is no longer this client).
        let inFlightTurnTasks = promptTurns.values
            .filter { !$0.isNonInterruptive }
            .compactMap(\.task)
        cancelAllPromptTurns()
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        var teardown: Task<Void, Never>?
        if let client = acpClient {
            teardown = Task {
                // S4 (t-5451bd1b): killing a mid-turn process without
                // `session/cancel` left Hermes with an unfinalized turn
                // — the same prompt re-sent later then got merged into
                // one duplicated DB row by Hermes's alternation repair.
                // Best-effort and bounded to 2s: teardown must never
                // hang on a wedged process.
                if turnWasInFlight, let sid = inFlightSessionId {
                    await Self.boundedSessionCancel(
                        client: client, sessionId: sid, awaiting: inFlightTurnTasks, seconds: 2
                    )
                }
                await client.stop()
            }
            if turnWasInFlight {
                if let sid = inFlightSessionId, richChatViewModel.sessionId == sid {
                    // Transcript still attached to the killed session
                    // (e.g. switching to terminal mode mid-turn) —
                    // finalize the partial stream and surface the
                    // cancellation through the existing synthesized
                    // promptComplete mechanism (same one the send
                    // path's error branch uses). Attachment-gated: in
                    // the session-switch paths `reset()` already
                    // detached (sessionId nil), and emitting there
                    // would paint the dead turn's "cancelled" bubble
                    // into the NEXT session's fresh transcript via the
                    // nil-sessionId hole in the cross-session guard.
                    richChatViewModel.handleACPEvent(
                        .promptComplete(sessionId: sid, response: ACPPromptResult(
                            stopReason: "cancelled",
                            inputTokens: 0, outputTokens: 0,
                            thoughtTokens: 0, cachedReadTokens: 0
                        ))
                    )
                }
                // Composer-level feedback that survives the transcript
                // swap when the chat was restarted mid-turn (reset()
                // already wiped the old transcript by the time we run).
                if let cancelledHint {
                    richChatViewModel.transientHint = cancelledHint
                    scheduleHintClear()
                }
            }
        }
        acpClient = nil
        hasActiveProcess = false
        isHandlingDisconnect = false
        isStartingSession = false
        startCarriesUserInput = false
        return teardown
    }

    // MARK: - Release / re-attach (live-chat budget)

    /// Give this chat's process back to the budget (`LiveChatBudget`): stop
    /// the client — no voice teardown, no "Turn cancelled." hint — and keep
    /// the transcript, session id, project and model badge. The chat stays
    /// in its window (`keepsRunningWhenLeft`) but no longer counts; focusing
    /// it, or typing into it, re-attaches (`reattach`).
    ///
    /// `stoppingTurn`: the user chose Stop on the budget dialog for this
    /// working chat — its turn ends as Stop ends one (bounded
    /// `session/cancel`, "You stopped this turn", open approvals answered
    /// `cancelled`), and a Live Voice session on it ends. Otherwise the
    /// budget only releases idle chats, never a shown one. A
    /// re-attach in progress is abandoned and the chat is released again.
    ///
    /// Returns the teardown task (cancel, then client stop).
    @discardableResult
    func releaseProcess(stoppingTurn: Bool = false) -> Task<Void, Never>? {
        guard holdsProcess || isReattaching else { return nil }
        // A typed message an autostart hadn't sent yet: the user stopped
        // it, so it goes back in the composer rather than vanishing. (If
        // the window then drops this chat, the budget dialog hands the text
        // on: `ChatViewModel.stopChatForBudget`.)
        let unsent = stoppingTurn && startCarriesUserInput ? autostartInput : nil
        // Nothing to come back to — a new chat stopped before its session
        // existed: a released chat could never re-attach (a dead row that
        // swallows sends). Supersede it like any start left with nothing,
        // and let the window's leave rule drop it. (A background chat is
        // then dropped with its restored draft: it has no row to reach it
        // by. The one a window shows keeps it.)
        guard richChatViewModel.sessionId != nil || targetSessionId != nil else {
            let teardown = supersede()
            if let unsent { restoreUnsentAutostart(unsent) }
            host?.chatSettledWithoutConnection(self)
            return teardown
        }
        // A start in flight (a re-attach) abandons at its next check.
        beginStartIntent()
        if stoppingTurn {
            // The user stopped this chat's work: a Live Voice session on
            // it (only possible when it is shown) has nothing to talk to.
            host?.chatWillTearDown(self)
        }
        if stoppingTurn && hasTurnInFlight {
            richChatViewModel.noteTurnStopRequestedByUser()
        } else {
            richChatViewModel.clearPendingPermissions()
        }
        // Nothing held can go out now; say so where it was typed.
        let held = heldSends.count
        heldSends = []
        heldSendsClient = nil
        holdingForPendingClient = false
        if held > 0 {
            richChatViewModel.transientHint = String(
                localized: "^[\(held) message](inflect: true) couldn't be sent — the connection didn't come up."
            )
            scheduleHintClear()
        }
        let teardown = tearDownConnection(cancelledHint: nil)
        if let unsent { restoreUnsentAutostart(unsent) }
        isReleased = true
        acpStatus = ""
        logger.info("released this chat's hermes acp process to the live-chat budget")
        host?.chatDidReleaseProcess(self)
        return teardown
    }

    /// Bring a released chat back on its own session through the full start
    /// path (`startACPSession`: model preset, project chip, environment
    /// hint), not autostart. The transcript stays and the load's replay is
    /// kept out of it; `thenSend` (typed into the released chat) and every
    /// send typed until the session is ready are held, then sent once. The
    /// budget applies — a re-attach takes a slot like any open.
    ///
    /// A chat released while its resume was still loading has no transcript
    /// session yet: it re-attaches the session the resume was for
    /// (`targetSessionId`), in the project that resume resolved.
    func reattach(thenSend send: (text: String, images: [ChatImageAttachment])? = nil) {
        guard isReleased else { return }
        guard let sessionId = richChatViewModel.sessionId ?? targetSessionId else {
            // Unreachable by construction (`releaseProcess` drops such a
            // chat), but a send must never vanish without a word.
            isReleased = false
            if send != nil {
                showHint(String(localized: "Not sent — this chat has no session to reconnect to. Start a new chat and send it there."))
            }
            host?.chatSettledWithoutConnection(self)
            return
        }
        startACPSession(
            resume: sessionId, projectPath: currentProjectPath ?? lastStartProjectPath,
            reattaching: true, heldSend: send)
    }

    /// The typed message an autostart is still carrying (not yet handed to
    /// `sendViaACP`), for the budget dialog's Stop to hand to another chat.
    var unsentAutostartInput: (text: String, images: [ChatImageAttachment])? {
        guard startCarriesUserInput, let input = autostartInput else { return nil }
        return (input.text, input.images)
    }

    /// Put an autostart's message that was stopped before it went out back
    /// in the composer, and say so — when the chat has no session yet, so
    /// its echo can go too. With a session the echo is in the session's
    /// pending-echo cache and stays (as a dropped held send's does); putting
    /// the text back as well would invite sending it twice, so the hint
    /// alone says it wasn't sent.
    private func restoreUnsentAutostart(_ unsent: (text: String, images: [ChatImageAttachment], echoId: Int?)) {
        // The echo marked the chat working; no turn ever ran.
        richChatViewModel.cancelPendingSend()
        guard richChatViewModel.sessionId == nil else {
            showHint(String(localized: "Not sent — you stopped this chat before it started. The last message above didn't go out."))
            return
        }
        if let echoId = unsent.echoId {
            richChatViewModel.messages.removeAll { $0.id == echoId }
        }
        composer.restoreUnsent(text: unsent.text, images: unsent.images)
        showHint(String(localized: "Not sent — you stopped this chat before it started. Your message is back in the composer."))
    }

    /// A message typed into ANOTHER chat (no window showed it) that the
    /// budget dialog's Stop ended before it went out — that chat is dropped
    /// — lands here, in the chat the user is in. Into an empty composer;
    /// never over a draft: then the hint quotes it, so it isn't lost
    /// without a word.
    func takeUnsentFromStoppedChat(text: String, images: [ChatImageAttachment]) {
        if !composer.hasContent {
            composer.restoreUnsent(text: text, images: images)
            showHint(String(localized: "Not sent — you stopped that chat before it started. Your message is back in the composer."))
        } else {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = line.count > 40 ? String(line.prefix(40)) + "…" : line
            showHint(String(localized: "Not sent — you stopped that chat before it started: “\(quoted)”"))
        }
    }

    /// A message typed into ANOTHER chat with no session, whose start failed
    /// in the background: that chat is dropped, so the text lands here, as
    /// `takeUnsentFromStoppedChat` does for a Stop.
    func takeUnsentFromFailedChat(text: String, images: [ChatImageAttachment]) {
        if !composer.hasContent {
            composer.restoreUnsent(text: text, images: images)
            showHint(String(localized: "Not sent — that chat couldn't start. Your message is back in the composer."))
        } else {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = line.count > 40 ? String(line.prefix(40)) + "…" : line
            showHint(String(localized: "Not sent — that chat couldn't start: “\(quoted)”"))
        }
    }

    /// A send the budget dialog's Wait dropped: it was never echoed, so put
    /// it back in the composer and say it wasn't sent.
    private func noteSendNotRun(text: String, images: [ChatImageAttachment]) {
        composer.restoreUnsent(text: text, images: images)
        showHint(String(localized: "Not sent — every live chat on \(context.displayName) is in use. Your message is back in the composer: stop a chat, or send it again later."))
    }

    /// Best-effort `session/cancel`, then wait for the cancelled turn to
    /// END — its `session/prompt` answer (`stopReason: "cancelled"`) —
    /// before the caller's `client.stop()`. The cancel is a notification
    /// that returns as soon as it is written (P7a); stopping right after
    /// it closes Hermes's stdin, and the acp lib's `Connection.close()`
    /// then cancels its in-flight handlers, which can cut the cancel
    /// short and leave the turn unfinalized (S4). Returns when `turns`
    /// have all returned OR `seconds` pass, whichever comes first — a
    /// wedged process that never answers must not stall teardown.
    nonisolated private static func boundedSessionCancel(
        client: ACPClient,
        sessionId: String,
        awaiting turns: [Task<Void, Never>],
        seconds: Double
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce() {
                let isFirst = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { cont.resume() }
            }
            Task {
                try? await client.cancel(sessionId: sessionId)
                for turn in turns { await turn.value }
                resumeOnce()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resumeOnce()
            }
        }
    }

    /// The error banner's offer after a gateway refused a prompt with
    /// `unknown_execution:`: send `/discard <id>` for each lost turn the
    /// refusal named. Hermes acknowledges the turn without replaying it, and
    /// the session takes prompts again (`_discard_unknown`,
    /// acp_adapter/gateway_commands.py:72-87 @ v0.22.5).
    ///
    /// One at a time, each after the last has returned: every `/discard`
    /// refreshes and replaces the same cached pending snapshot and shares the
    /// session's `_submitting` flag (gateway_server.py:856-890), nothing in
    /// Hermes makes overlapping ones safe, and one that fails must not be
    /// followed by the next.
    func discardLostTurn() {
        let ids = richChatViewModel.acpErrorDiscardIDs
        guard let client = acpClient, !ids.isEmpty else { return }
        clearACPErrorState()
        Task { @MainActor [weak self] in
            for id in ids {
                guard let self, self.acpClient === client, self.acpError == nil else { return }
                let before = self.promptTurnCounter
                self.sendRichText("/discard \(id)", images: [], autoStartInterceptor: nil)
                if self.promptTurnCounter != before {
                    await self.promptTurns[self.promptTurnCounter]?.task?.value
                }
            }
        }
    }

    /// Respond to a permission request from the ACP agent.
    /// `requestId` is the one the sheet was PRESENTING, not whatever
    /// happens to sit at the head of the queue now — with a queue
    /// those can differ (a second request can land while the sheet is
    /// open), and answering the head would misroute the decision.
    func respondToPermission(requestId: Int, optionId: String) {
        guard let client = acpClient else { return }
        let kind = richChatViewModel.permissionQueue
            .first { $0.requestId == requestId }?.optionKinds[optionId]
        Analytics.record(.permissionPromptResponded(
            decision: ChatViewModel.analyticsPermissionDecision(optionId: optionId, kind: kind)
        ))
        Task {
            await client.respondToPermission(requestId: requestId, optionId: optionId)
        }
        richChatViewModel.resolvePermission(requestId: requestId, answeredWith: optionId)
    }

    /// `/title` and the CLI-only `/retry`/`/undo` (gh#147): handled
    /// entirely here, never sent. Returns false for `/new`, which keeps its
    /// `sendViaACP` path.
    private func handleLocalSlashCommand(_ intercept: RichChatViewModel.ClientSideSlashCommand) -> Bool {
        switch intercept {
        case .newSession:
            return false
        case .cliOnly(let name):
            showHint(RichChatViewModel.cliOnlySlashNotice(name: name))
        case .renameSession(let title):
            guard let title else {
                showHint(RichChatViewModel.titleUsageNotice)
                return true
            }
            guard let sessionId = richChatViewModel.sessionId, !sessionId.isEmpty else {
                showHint(RichChatViewModel.titleNeedsSessionNotice)
                return true
            }
            // Hermes stores an ACP session only after its first turn; until
            // `currentSession` is that row a rename would fail, so the name
            // waits like `/new <name>`'s (`applyPendingSessionTitle`).
            guard richChatViewModel.currentSession?.id == sessionId else {
                pendingSessionTitle = title
                showHint(RichChatViewModel.titlePendingNotice(title))
                return true
            }
            Task { [weak self] in
                guard let self else { return }
                let renamed = await self.host?.renameSession(sessionId, to: title) ?? false
                // The user may have moved to another chat while the rename
                // ran: its outcome is not that chat's news (iOS twin:
                // `applyTitleSlash`'s `vm.sessionId == sessionId` guard).
                guard self.richChatViewModel.sessionId == sessionId else { return }
                if renamed {
                    self.showHint(RichChatViewModel.titleAppliedNotice(title))
                } else {
                    self.showHint(self.host?.renameError
                        ?? String(localized: "Couldn't name this chat “\(title)”. Rename it from the chat list."))
                }
            }
        }
        return true
    }

    private func showHint(_ text: String?) {
        guard let text else { return }
        richChatViewModel.transientHint = text
        scheduleHintClear()
    }

    /// Name the session typed with `/new <name>` once Hermes has stored
    /// it (the row read after the turn found it). A failure says so in the
    /// chat; the name is not retried.
    private func applyPendingSessionTitle(sessionId: String) async {
        guard let title = pendingSessionTitle,
              richChatViewModel.sessionId == sessionId,
              richChatViewModel.currentSession?.id == sessionId else { return }
        pendingSessionTitle = nil
        if !(await host?.renameSession(sessionId, to: title) ?? false) {
            richChatViewModel.transientHint = String(localized: "Couldn't name this chat “\(title)”. Rename it from the chat list.")
            scheduleHintClear()
        }
    }

    /// Push a confirmed rename into the live transcript header: the
    /// `SessionInfoBar` title reads `richChatViewModel.currentSession`,
    /// which nothing refreshed on rename — the header stayed stale until
    /// the next full reload (Alan, 2026-09-02).
    func applyRenameToAttachedSession(sessionId: String, title: String) {
        if let current = richChatViewModel.currentSession, current.id == sessionId {
            richChatViewModel.currentSession = current.withTitle(title)
        }
    }

    /// Shared teardown for "the ACTIVE (attached) session was just
    /// deleted server-side" — mirrors startACPSession's entry teardown
    /// (minus the respawn). Called by `deleteSession(_:)` (the chat
    /// sidebar's own delete, t-01bd55ec) and by
    /// `handleSessionDeletedElsewhere` (the Sessions tab's independent
    /// delete surface, t-5f1d9008). Callers must have verified the
    /// deleted id is the attached one.
    @discardableResult
    func tearDownDeletedActiveSession() -> Task<Void, Never>? {
        // Supersede any in-flight start pipeline: a stale await
        // resuming later must abandon at its `startStillCurrent` check
        // instead of re-attaching plumbing for the deleted session.
        beginStartIntent()
        // Detach the transcript first (same order as the switch entry
        // points) — stop()'s attachment-gated "cancelled" bubble then
        // can't paint into the freshly-blanked transcript.
        richChatViewModel.reset()
        targetSessionId = nil
        hasSentPrompt = false
        unstoredRow = nil
        startedFresh = false
        let announceDeleted = stoppedForDelete
        stoppedForDelete = false
        userPickedApprovalMode = nil
        isReleased = false
        hasUnreadCompletion = false
        setInspectorFocus(.none)
        // Full teardown: bounded best-effort `session/cancel` if a turn
        // is in flight (lets Hermes finalize the orphaned turn before
        // the kill), then `client.stop()`. Also disarms the start
        // watchdog, cancels reconnects, and clears `isStartingSession`.
        // A cancelled turn's hint names the delete.
        let teardown = stop(reason: "Turn cancelled — session deleted.")
        // stop() leaves `acpStatus` at its last painted phase; the
        // pane is now an idle blank chat, so park the pill at idle the
        // same way the preflight bail does.
        acpStatus = ""
        if announceDeleted {
            richChatViewModel.transientHint = String(localized: "Turn cancelled — session deleted.")
            scheduleHintClear()
        }
        return teardown
    }

    /// A `session/load` answered with an internal head this transcript does
    /// not cover (`ACPSessionProvenance`): follow it like a live rotation —
    /// the transcript spans it, id lookups on the new tip find the chain,
    /// and the sidebar relists it under that tip. Nil or covered: no-op.
    ///
    /// Defensive on v2026.9.24: a fresh `hermes acp` restores the agent
    /// under the id it was asked for (`_restore`,
    /// acp_adapter/session.py:444-446), so the load reports that same id and
    /// this never fires. It is here so a Hermes that restores a chain's live
    /// head is followed rather than silently dropped.
    func noteLoadedHead(_ head: String?) {
        guard let head, richChatViewModel.sessionId != nil,
              !richChatViewModel.transcriptCovers(head) else { return }
        richChatViewModel.noteSessionRotation(to: head)
        SessionLineageIndex.shared.record(server: context.id, lineage: richChatViewModel.transcriptSessionIds)
        host?.scheduleSessionsRefresh()
    }

    /// The resume step both session-start paths share (#146): read the
    /// session's `source` (read-only, off-main), skip `session/load` for a
    /// source Hermes can't restore, and fall back to `session/new` only on
    /// the not-restorable answer (`SessionResume.resolve`). Other load
    /// errors propagate to the caller's failure path.
    ///
    /// `projectPath` nil on a gateway-backed host: the load runs in the
    /// session's own `sessions.cwd`, so Hermes doesn't move the chat to
    /// `cwd` (`SessionResume.loadInSessionFolder`).
    private func resolveResume(
        client: ACPClient, cwd: String, projectPath: String?, sessionId: String, intent: Int
    ) async throws -> SessionResume.Outcome {
        // The sidebar row already carries `sessions.source` for a listed
        // session — skip the state.db round trip (an SSH hop on a remote).
        let listed = host?.recentSessions.first { $0.id == sessionId }?.source
        let source: String?
        if let listed { source = listed } else {
            source = await SessionResume.fetchSource(context: context, sessionId: sessionId)
        }
        // Gateway-backed ACP loads `local` (and legacy CLI/TUI/GUI) rows
        // too, and refuses an unknown one with a JSON-RPC error. The probed
        // capabilities, awaited: a guess here would skip a loadable session.
        let gatewayBacked = await capabilitiesForProjectContext().hasGatewayBackedACP
        return try await SessionResume.resolve(
            sessionId: sessionId,
            source: source,
            gatewayBacked: gatewayBacked,
            load: { [context] id in
                let loaded = try await SessionResume.loadInSessionFolder(
                    defaultCwd: cwd, projectPath: projectPath, gatewayBacked: gatewayBacked,
                    sessionCwd: { await SessionResume.fetchCwd(context: context, sessionId: id) },
                    load: { try await client.loadSessionWithProvenance(cwd: $0, sessionId: id) })
                return (loaded.sessionId, loaded.provenance?.currentHermesSessionId)
            },
            newSession: { [weak self] in
                if let self, self.startStillCurrent(intent, client: client) {
                    self.acpStatus = ACPPhase.creatingNewSession
                }
                return try await client.newSession(cwd: cwd)
            }
        )
    }

    /// Raise the persistent transcript notice for a resume that continued
    /// as a new session. The Kanban sentence rides along only where the
    /// chat shows the session-scoped badge that loses the old id's tasks.
    private func showResumeFallbackNotice(_ reason: SessionResume.FallbackReason) {
        let showsKanbanBadge = host?.capabilitiesStore?.capabilities.hasKanbanSessionFilter ?? false
        richChatViewModel.showResumeContinuityNotice(
            SessionResume.notice(for: reason, mentionsKanban: showsKanbanBadge))
    }

    // MARK: - Live Voice (VoiceTurnHost)
    //
    // The turn bookkeeping behind `ChatViewModel`'s `VoiceTurnHost`
    // conformance, in this file because it drives the private ACP turn state
    // (`acpClient`, `promptTurns`, `busyTurnOrigins`) that typed turns use;
    // widening that state for an extension elsewhere would let any file write
    // it. ScarfGo's twin is `ChatController+VoiceTurnHost.swift` (P5b); both
    // follow the same rules: the bubble before any await, the turn marked in
    // flight before hand-off, one prompt path for typed and voice turns, and a
    // bounded wait (10 s) for a cancelled turn Scarf itself started.
    //
    // Voice cancels only VOICE turns (Alan, t-dd450d3a). While a typed request
    // runs — or is queued inside a running voice turn — a spoken request is not
    // sent: `isVoiceTurnBusy` doesn't count the typed turn, `cancelActiveVoiceTurn`
    // leaves it alone, and `submitVoiceTurn` answers with `voiceBusyReply`, which
    // the voice speaks. A voice request never silently kills something typed.

    /// The ACP half of `ChatViewModel.canHostVoiceTurns`: a live ACP client
    /// and an attached session.
    var hasLiveACPSession: Bool {
        acpClient != nil
            && hasActiveProcess
            && richChatViewModel.sessionId != nil
    }

    /// A voice turn Scarf started is still running and nothing typed is
    /// mixed into its run. The engine cancels whatever reads busy, and
    /// voice cancels only its own turns, so a typed request (running, or
    /// queued inside the voice turn's run) makes this false; the next
    /// spoken request is then answered "busy" in full by `submitVoiceTurn`.
    var isVoiceTurnBusy: Bool {
        inFlightPromptSessionId != nil
            && busyTurnOrigins.contains(.voice)
            && !busyTurnOrigins.contains(.typed)
    }

    /// Hermes is busy with something that isn't a voice turn: a typed
    /// prompt Scarf sent (running, or queued behind a voice turn), or a
    /// turn the transcript shows running that Scarf didn't start here
    /// (`isAgentWorking` also covers a typed send still auto-starting ACP).
    var isBusyWithNonVoiceTurn: Bool {
        if inFlightPromptSessionId != nil { return busyTurnOrigins.contains(.typed) }
        return richChatViewModel.isAgentWorking
    }

    /// Show the spoken words as the user's bubble, then send them with the
    /// voice turn note as an embedded resource (model input only, never
    /// the stored row). Everything before the prompt task is synchronous,
    /// so the bubble exists before this returns — the reply lookup matches
    /// by the bubble's text.
    ///
    /// While Hermes works on a typed request, nothing is sent: the request
    /// is answered with `voiceBusyReply` (through `voiceTurnReply`) and the
    /// composer hint says why. Returning normally (not throwing) is right
    /// for a superseding request too: a typed prompt sent after a voice
    /// cancel already consumed the prompt Hermes stored for it.
    ///
    /// `ChatViewModel.submitVoiceTurn` checks `canHostVoiceTurns` first.
    func submitVoiceTurn(_ request: VoiceTurnRequest) throws {
        guard let client = acpClient,
              let sessionId = richChatViewModel.sessionId else {
            throw ChatViewModel.VoiceTurnSubmitError.noSession
        }
        // The session's `session/load` replay has not drained yet (an
        // autostart or reconnect just installed this client), or typed
        // sends are held behind it. Sending now would open the replay gate
        // (`markPromptSent`) mid-replay and jump the held sends, so answer
        // busy like a typed turn in flight does.
        let replayPending = heldSendsClient === client
        if isBusyWithNonVoiceTurn || replayPending {
            busyVoiceRequestIDs.append(request.id)
            if busyVoiceRequestIDs.count > 8 { busyVoiceRequestIDs.removeFirst(busyVoiceRequestIDs.count - 8) }
            richChatViewModel.transientHint = replayPending
                ? String(localized: "Live Voice didn't send that — the chat is still loading its session. Ask again in a moment.")
                : String(localized: "Live Voice didn't interrupt your typed request. Ask again when it's finished.")
            scheduleHintClear()
            return
        }
        Analytics.record(.messageSent(hasAttachment: false, inputMode: .voice))
        richChatViewModel.addUserMessage(text: request.prompt)
        voiceTurnPrompts.append((id: request.id, prompt: request.prompt))
        if voiceTurnPrompts.count > 8 { voiceTurnPrompts.removeFirst(voiceTurnPrompts.count - 8) }
        richChatViewModel.markPromptSent()
        acpStatus = ACPPhase.agentWorking
        // The spoken prompt goes on the wire verbatim: no client-side slash
        // handling or project-command expansion for words said aloud.
        // `launchPromptTask` marks the turn in flight before it returns, so
        // a cancel racing this hand-off still waits for it.
        launchPromptTask(
            client: client,
            sessionId: sessionId,
            wireText: request.prompt,
            images: [],
            contextNotes: request.contextNotes,
            isNonInterruptive: false,
            origin: .voice
        )
    }

    /// `session/cancel`, then wait for the running turn's `sendPrompt` to
    /// return — Hermes drops the voice note of a prompt queued behind a
    /// running turn. Only voice turns Scarf started are cancelled, and ALL
    /// of their in-flight prompts are waited for (the older one returns
    /// last). With a typed request running or queued this does nothing:
    /// the submit that follows answers "busy" instead. The wait is bounded
    /// (charter C10): a wedged host must not freeze the voice session; the
    /// engine then submits anyway.
    func cancelActiveVoiceTurn() async {
        guard !isBusyWithNonVoiceTurn, let client = acpClient,
              let sessionId = inFlightPromptSessionId else { return }
        let tasks = promptTurns.values.filter { !$0.isNonInterruptive }.compactMap(\.task)
        // A superseded request, not a failed one: its `cancelled` return
        // ends the turn without a failure bubble.
        richChatViewModel.noteTurnCancelRequested()
        // The turn is over when its `sendPrompt` returns (Hermes answers
        // it with `stopReason: "cancelled"`), not when the cancel is sent;
        // the cancel is a notification with no reply, so it isn't awaited.
        Task { try? await client.cancel(sessionId: sessionId) }
        let all = Task { for task in tasks { await task.value } }
        await ChatViewModel.boundedWait(for: all, seconds: ChatViewModel.voiceCancelWaitSeconds)
    }

    // MARK: - Stop

    /// Whether the composer offers Stop: a turn Scarf started is running on
    /// the live ACP client. (`ChatViewModel.canStopCurrentTurn` asks the
    /// owner's transport first, via `stopRouter`.)
    var canStopCurrentTurn: Bool {
        _ = promptTurnsRevision
        return acpClient != nil && inFlightPromptSessionId != nil
    }

    /// Stop the running turn and keep the session (S01-F2). Sends
    /// `session/cancel` — a notification — for the session of the turn in
    /// flight; Hermes interrupts the agent and answers the pending
    /// `session/prompt` with `stopReason: "cancelled"`
    /// (acp_adapter/server.py:636-657, :999 @ v2026.9.24), which is what
    /// ends the turn here. `noteTurnStopRequestedByUser` makes that end
    /// quiet but visible ("You stopped this turn") and answers any
    /// permission request still on screen. The `hermes acp` process stays
    /// up: this is not `stop()`. (`ChatViewModel.stopCurrentTurn` asks
    /// `stopRouter` first.)
    func stopCurrentTurn() {
        guard let client = acpClient, let sessionId = inFlightPromptSessionId else { return }
        richChatViewModel.noteTurnStopRequestedByUser()
        Task { [logger] in
            do {
                try await client.cancel(sessionId: sessionId)
            } catch {
                logger.warning("session/cancel for Stop failed: \(error.localizedDescription)")
            }
        }
    }

    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? {
        if busyVoiceRequestIDs.contains(requestID) {
            return VoiceTurnReply(text: ChatViewModel.voiceBusyReply, isStreaming: false)
        }
        guard let prompt = voiceTurnPrompts.last(where: { $0.id == requestID })?.prompt else { return nil }
        return VoiceTurnReply.latest(in: richChatViewModel.messages, forPrompt: prompt, isStreaming: isVoiceTurnBusy)
    }
}
