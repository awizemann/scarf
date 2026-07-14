import Foundation
import ScarfCore
import AppKit
import SwiftTerm
import os

@Observable
final class ChatViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ChatViewModel")
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        self.fileService = HermesFileService(context: context)
        self.richChatViewModel = RichChatViewModel(context: context)
        // Probe hermes binary existence once off-main, then cache. Doing
        // this synchronously inside `hermesBinaryExists`'s getter would
        // block main on every chat-body re-evaluation — for a remote
        // context that's a SSH `test -e` round-trip on every streaming
        // chunk, which manifests as the chat screen flashing or going
        // blank during prompts.
        Task.detached(priority: .userInitiated) { [context] in
            // #100 — use the PATH-aware probe, not a raw fileExists. For a
            // remote server with no binaryHint, `paths.hermesBinary` is the
            // bare name "hermes"; `fileExists` would `test -e hermes` in the
            // remote cwd and report missing even when `command -v hermes`
            // resolves it and the ACP login-shell launch works fine. The
            // helper presumes bare names resolvable and defers the real
            // check to launch (whose failure path surfaces a clear hint).
            let exists = context.hermesBinaryProbablyResolvable()
            await MainActor.run { [weak self] in
                self?.hermesBinaryExists = exists
            }
        }
    }


    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]

    /// Debounce handle for watcher-driven `loadRecentSessions` calls.
    /// During an active ACP conversation the file watcher fires many
    /// times per second (every message Hermes persists writes to
    /// `state.db-wal`); without this, every tick spawned a fresh
    /// reload task whose `recentSessions = …` reassignment re-rendered
    /// the chat sidebar and caused the list to visibly disappear /
    /// reappear during a streaming response. The debounce coalesces
    /// rapid bursts into one trailing fetch ~500 ms after the last
    /// tick. Created/resumed sessions still appear immediately because
    /// `startACPSession` and `autoStartACPAndSend` call
    /// `loadRecentSessions()` directly outside this path.
    @ObservationIgnored
    private var sessionsRefreshTask: Task<Void, Never>?

    /// L2 (v2.8) — in-flight coalescing handle for `loadRecentSessions`.
    /// On a slow remote each load is a 1.5–2.5s SSH round-trip; the
    /// 500 ms `scheduleSessionsRefresh` debounce only suppresses a
    /// pending tick, not one that's already executing. Without this
    /// guard, file-watcher deltas during a stream stack 2–3 parallel
    /// loadRecentSessions tasks (observed at t=305844 in 2026-05-05
    /// dogfooding). The in-flight pointer lets a second caller await
    /// the active task instead of spawning another SSH subprocess.
    @ObservationIgnored
    private var inFlightSessionLoad: Task<Void, Never>?

    /// Per-recent-session project attribution. Keyed by `HermesSession.id`,
    /// value is the project's display name. Populated alongside
    /// `recentSessions` via a single batched read in `loadRecentSessions()`.
    /// Sessions with no entry are unattributed (global / quick chats).
    private(set) var sessionProjectNames: [String: String] = [:]

    /// All registered projects, used to build the project filter menu in
    /// the chat session list pane. Loaded alongside `sessionProjectNames`.
    private(set) var allProjects: [ProjectEntry] = []
    var terminalView: LocalProcessTerminalView?
    var hasActiveProcess = false
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    var displayMode: ChatDisplayMode = .richChat
    let richChatViewModel: RichChatViewModel
    private var coordinator: Coordinator?

    /// Capability store the chat surface reads from. Set by `ChatView`
    /// at body-evaluation time via `attachCapabilitiesStore(_:)` —
    /// `@ObservationIgnored` so capability refreshes don't force a
    /// full chat re-render. Forwards into
    /// `RichChatViewModel.capabilitiesGate` whenever the published
    /// snapshot changes; the slash menu reads through that. v2.8 /
    /// Hermes v0.13 — gates `/goal` + `/queue` slash menu rows.
    @ObservationIgnored
    var capabilitiesStore: HermesCapabilitiesStore?

    /// Wire the Mac chat view's environment-injected capabilities store
    /// into both this VM and its child rich-chat VM. Idempotent on the
    /// pointer (re-attaching the same store is a no-op); always
    /// re-publishes the latest snapshot so a refresh that fired before
    /// the chat view became visible still lands.
    @MainActor
    func attachCapabilitiesStore(_ store: HermesCapabilitiesStore?) {
        capabilitiesStore = store
        richChatViewModel.publishCapabilities(store?.capabilities ?? .empty)
    }

    /// `callId` of the tool call currently surfaced in the chat
    /// inspector pane, or nil when nothing is focused. Set by
    /// `ToolCallCard` taps in the transcript; cleared by the inspector's
    /// xmark close. Mac-only state — the inspector is a Mac-target view,
    /// so this lives on the Mac `ChatViewModel` rather than the
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

    /// Right-side inspector pane mode. The inspector renders different
    /// content depending on what the user clicked: a tool call (the
    /// original v2.8 behavior) OR a long user message (v2.10.2 — long
    /// pasted prompts were overflowing their bubble and overlapping
    /// later messages; routing them through the inspector uses the
    /// existing scroll surface and stops the layout collision).
    /// Mutually exclusive — see `setInspectorFocus`.
    enum ChatInspectorMode: Sendable, Equatable {
        case none
        case toolCall(id: String)
        case userMessage(id: Int)
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

    /// True when the user just sent `/goal` against a host whose `cli`
    /// platform_toolsets list lacks `kanban`. The view binds a `.sheet`
    /// to this flag and surfaces the one-time onboarding explanation
    /// + the one-click enable action. Cleared once dismissed (the
    /// per-host suppression flag in `UserDefaults` prevents re-showing
    /// on the next `/goal`). Distinct from a permanent state so an
    /// internal `false → true → false` toggle re-triggers the sheet
    /// after the user dismissed without enabling and the next host
    /// is also disabled.
    var showKanbanOnboardingSheet: Bool = false

    // ACP state
    private var acpClient: ACPClient?
    private var acpEventTask: Task<Void, Never>?
    private var acpPromptTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    var isACPConnected: Bool { acpClient != nil && hasActiveProcess }
    var acpStatus: String = ""

    /// User-facing status strings that all map to "the session is in
    /// the middle of being established." Centralized so the toolbar
    /// status pill, the chat-pane loader, and `ChatSessionListPane`'s
    /// progress capsule stay in sync. v2.8 added `loadingHistory` after
    /// the user reported the chat looked engageable while the
    /// 30-second `fetchMessages` was still in flight on a slow remote.
    static let preparingPhases: Set<String> = [
        ACPPhase.spawning,
        ACPPhase.authenticating,
        ACPPhase.creatingSession,
        ACPPhase.creatingNewSession,
        ACPPhase.loadingSession,
        ACPPhase.loadingHistory
    ]

    enum ACPPhase {
        static let spawning = "Spawning hermes acp…"
        static let authenticating = "Authenticating…"
        static let creatingSession = "Creating session…"
        static let creatingNewSession = "Creating new session…"
        static let loadingSession = "Loading session…"
        static let loadingHistory = "Loading history…"
        static let ready = "Ready"
        static let agentWorking = "Agent working…"
        static let cancelled = "Cancelled"
        static let failed = "Failed"
        static let error = "Error"
        static let connectionLost = "Connection lost"
    }

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
        if Self.preparingPhases.contains(acpStatus) { return true }
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
    /// True when `hasAnyAICredential()` returned false at last preflight.
    var missingCredentials: Bool = false

    /// `model.default` / `model.provider` mismatch detected by the
    /// last `refreshConfigDiagnostics` pass. Drives the "Configuration
    /// mismatch" banner in `errorBanner`. Nil when config is coherent
    /// or unset. v2.8 — observed in dogfooding when switching OAuth
    /// providers via Credential Pools left a stale model prefix
    /// behind (e.g. `model.default: anthropic/...` with
    /// `model.provider: nous`); chats died with `-32603 Internal error`
    /// at first prompt with no diagnostic.
    var modelProviderMismatch: ModelPreflight.Mismatch?

    /// Hermes v0.14 — current `approvals.mode` from config.yaml.
    /// Default `"manual"` matches Hermes's default. Refreshed off
    /// MainActor alongside `modelProviderMismatch`. The chat header
    /// reads this to decide whether to show the YOLO warning badge
    /// (rendered when value is `"yolo"` and the host advertises
    /// `hasYOLOWarning`).
    var approvalMode: String = "manual"

    /// Set when chat-start is blocked because the active server's
    /// `config.yaml` has no `model.default` / `model.provider`. The chat
    /// view observes this and presents `ChatModelPreflightSheet`; on
    /// successful pick we persist via `LocalModelConfigPlan` and re-attempt
    /// the original `startACPSession` call from `pendingStartArgs`.
    /// Nil when no preflight is pending.
    var modelPreflightReason: String?

    /// Stash of the original `startACPSession` arguments while we wait
    /// for the user to pick a model. Replayed verbatim once
    /// `confirmModelPreflight` writes the chosen model+provider to
    /// config.yaml. Cleared on cancel or after replay.
    private var pendingStartArgs: (sessionId: String?, projectPath: String?, initialPrompt: String?)?

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
    /// start down (`stopACP`), self-supersedes the generation so the
    /// abandoned pipeline exits silently if its awaits ever resume, and
    /// paints a retryable error banner. Disarmed on ready / failure /
    /// preflight-bail / any `stopACP`.
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

    /// Session id of the interruptive prompt currently in flight on
    /// `acpClient` — owned HERE (not read from `richChatViewModel`)
    /// because the mid-turn teardown in `stopACP` must key off state
    /// that survives `richChatViewModel.reset()`: every session-switch
    /// entry point (`startNewSession` / `resumeSession` /
    /// `continueLastSession`) resets the transcript VM at click time,
    /// long before `startACPSession` reaches `stopACP()`. Keying off
    /// `richChatViewModel.isAgentWorking`/`sessionId` there made the
    /// S4 `session/cancel` unreachable on exactly the path it was
    /// built for (switching sessions mid-turn). Set by `sendViaACP`
    /// when an interruptive prompt goes over the wire; cleared when
    /// that turn's task settles and by teardown
    /// (`stopACP` / `handleConnectionDied`).
    @ObservationIgnored
    private var inFlightPromptSessionId: String?

    /// Monotonic token for interruptive turns so a stale turn's
    /// completion (resuming after a newer turn started) can't clear
    /// the newer turn's `inFlightPromptSessionId`.
    @ObservationIgnored
    private var inFlightPromptGeneration = 0

    /// Factory for the per-session `ACPClient`. Production default wires
    /// `ACPClient.forMacApp` (a `ProcessACPChannel` spawning
    /// `hermes acp`); tests inject scripted/hanging clients to exercise
    /// the watchdog, supersede, and teardown paths without a subprocess.
    @ObservationIgnored
    var acpClientFactory: (ServerContext, String?) -> ACPClient = { ctx, projectCwd in
        ACPClient.forMacApp(context: ctx, projectCwd: projectCwd)
    }

    /// Runs the `hermes sessions delete --yes <id>` CLI for
    /// `deleteSession(_:)` and returns its exit code. Production default
    /// shells out through the context's transport (same command path the
    /// Sessions feature uses); tests inject a stub so exercising the
    /// delete-active-session teardown (t-01bd55ec) doesn't spawn a real
    /// CLI process.
    @ObservationIgnored
    var sessionDeleteRunner: (ServerContext, String) -> Int32 = { ctx, sessionId in
        ctx.runHermes(["sessions", "delete", "--yes", sessionId]).exitCode
    }

    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000 // 1 second
    private static let maxReconnectDelay: UInt64 = 16_000_000_000 // 16 seconds

    /// Cached result of probing for `hermes` on the target server. Updated
    /// once at init by a detached task; defaults to `true` so the chat
    /// view doesn't briefly flash "Hermes not found" while the async
    /// probe runs. Set to `false` only after the probe confirms the
    /// binary really isn't there.
    var hermesBinaryExists: Bool = true

    /// In-flight debounce handle for `scheduleCredentialPreflightRefresh`.
    @ObservationIgnored private var credentialPreflightTask: Task<Void, Never>?

    /// Recompute the "no AI credential configured" preflight hint off the main
    /// actor — `hasAnyAICredential()` reads `.env` + `auth.json` through the
    /// transport (a synchronous scp/SSH round-trip on remote). Mirrors
    /// `refreshConfigDiagnostics`. For the file-watcher hot path use the
    /// debounced `scheduleCredentialPreflightRefresh()`, never this directly.
    func refreshCredentialPreflight() {
        let svc = fileService
        Task.detached { [weak self] in
            let missing = !svc.hasAnyAICredential()
            await MainActor.run { [weak self] in
                self?.missingCredentials = missing
            }
        }
    }

    /// Debounced credential-preflight refresh for the file-watcher `.onChange`.
    /// The original gh#102 typing-lag was this firing per persisted message —
    /// synchronously, on the main thread. Coalescing the streaming burst into
    /// one trailing off-main read ~500 ms after the last change keeps the
    /// banner live on an external `.env` edit without stalling the UI thread.
    func scheduleCredentialPreflightRefresh() {
        credentialPreflightTask?.cancel()
        credentialPreflightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            self?.refreshCredentialPreflight()
        }
    }

    /// Canonical provider IDs from the models.dev catalog + Hermes
    /// overlays, loaded lazily the first time a model/provider
    /// mismatch is detected and cached for the VM's lifetime. Feeds
    /// `ModelPreflight.detectMismatch(_:knownProviders:)` so the
    /// banner never offers to write a provider Hermes doesn't have.
    /// Nil until first load; empty set means the load failed (treated
    /// as "no roster" — the banner trusts the prefix as before).
    private var knownProviderIDs: Set<String>?

    /// Re-reads config.yaml and refreshes the
    /// `model.default` / `model.provider` mismatch state. Off-MainActor
    /// because `loadConfig()` is a synchronous file read (and an SSH
    /// round-trip on remote contexts). Safe to call from `.task` or
    /// after a write that would have changed config.
    ///
    /// The provider roster load (`ModelCatalogService.loadProviders()`)
    /// is deferred to the rare path where a mismatch was actually
    /// detected — on remote contexts it can pull a multi-megabyte
    /// catalog over SSH, which must not tax every diagnostics refresh.
    func refreshConfigDiagnostics() {
        let svc = fileService
        let ctx = context
        Task.detached { [weak self] in
            let config = svc.loadConfig()
            var mismatch = ModelPreflight.detectMismatch(config)
            if mismatch != nil {
                var known = await MainActor.run { [weak self] in self?.knownProviderIDs }
                if known == nil {
                    // Only trust the roster when the models.dev catalog
                    // actually loaded — an overlay-only result (fresh
                    // install, cache not yet written by Hermes) would
                    // mark real providers like `anthropic` unknown.
                    // Empty set = "catalog unavailable", cached so the
                    // (possibly SSH-backed) read isn't retried every
                    // refresh.
                    let infos = ModelCatalogService(context: ctx).loadProviders()
                    let loaded = infos.contains(where: { !$0.isOverlay })
                        ? Set(infos.map(\.providerID))
                        : Set()
                    await MainActor.run { [weak self] in self?.knownProviderIDs = loaded }
                    known = loaded
                }
                if let known, !known.isEmpty {
                    mismatch = ModelPreflight.detectMismatch(config, knownProviders: known)
                }
            }
            let mode = config.approvalMode
            let resolvedMismatch = mismatch
            await MainActor.run { [weak self] in
                self?.modelProviderMismatch = resolvedMismatch
                self?.approvalMode = mode
            }
        }
    }

    /// Persist a one-click mismatch fix. Aligns `model.provider` to the
    /// prefix carried in `model.default` (the user's "I just authed
    /// against this provider, that's what the prefix means" intent).
    /// Triggers a config-diagnostics refresh on completion to clear the
    /// banner if the write took. Failures fall through to the existing
    /// `acpError` banner so the user sees something happened.
    func alignProviderToModelPrefix(_ mismatch: ModelPreflight.Mismatch) {
        let svc = fileService
        Task.detached { [weak self] in
            // We pass the bare model so config.yaml ends up with a
            // clean (provider-prefix-free) model name alongside the
            // matching provider — matches what `confirmModelPreflight`
            // writes for a fresh setup.
            //
            // Routed through the write plan, NOT `setModelAndProvider`
            // (t-9657430b): aligning is a provider SWITCH, so the
            // clear-on-switch rule applies — switching away from e.g.
            // provider=ollama must scrub the stale local-managed keys
            // (model.base_url/api_key/api_mode/context_length) that
            // would otherwise redirect the new provider (GH #27132
            // class). Config is re-read so already-unset keys are
            // skipped: a never-local user keeps the classic two-op
            // write (T4 parity).
            let ops = LocalModelConfigPlan.operations(
                selectingRemoteModel: mismatch.bareModel,
                provider: mismatch.prefixProvider,
                current: svc.loadConfig()
            )
            let ok = !ops.isEmpty && svc.applyModelConfigPlan(ops)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't write the new provider to config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// Persist the inverse mismatch fix — strip the provider prefix
    /// off `model.default` and keep `model.provider` as the active
    /// authoritative value. Use case: the user genuinely intended to
    /// switch their active provider and the stale prefix is the bug.
    func stripPrefixFromModelDefault(_ mismatch: ModelPreflight.Mismatch) {
        let svc = fileService
        Task.detached { [weak self] in
            // Same plan seam as `alignProviderToModelPrefix`, but this
            // action KEEPS the active provider — the plan sees
            // provider == currentProvider and emits no clears, so a
            // hand-maintained model.base_url (or a live local setup)
            // survives, exactly the old `setModelAndProvider`
            // semantics. Pinned by
            // `bannerStripPrefixKeepsProviderAndNeverClears` in
            // LocalModelConfigPlanTests.
            let ops = LocalModelConfigPlan.operations(
                selectingRemoteModel: mismatch.bareModel,
                provider: mismatch.activeProvider,
                current: svc.loadConfig()
            )
            let ok = !ops.isEmpty && svc.applyModelConfigPlan(ops)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't rewrite model.default in config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// Forwarders to the ScarfCore implementation so the error-banner
    /// state lives in one place (M7 #2). The per-site logging label
    /// stays here — only the storage is shared.
    private func clearACPErrorState() {
        richChatViewModel.clearACPErrorState()
    }

    /// Auto-clear the chat composer's transient hint after 4 s. Shared
    /// helper for `/steer`, `/goal`, and `/queue` so the toast lifetime
    /// stays consistent across non-interruptive commands.
    @MainActor
    private func scheduleHintClear() {
        let snapshot = richChatViewModel.transientHint
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.richChatViewModel.transientHint == snapshot {
                self?.richChatViewModel.transientHint = nil
            }
        }
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
    private func recoverRemoteTransportAfterFailure() async {
        let ctx = context
        guard ctx.isRemote else { return }
        await Task.detached(priority: .utility) {
            (ctx.makeTransport() as? SSHTransport)?.recoverControlMasterIfDead()
        }.value
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
    /// already stopped it via `stopACP`) and returns false so the
    /// caller abandons silently WITHOUT touching shared state: a
    /// superseded pipeline resuming late must never clobber the newer
    /// start's `acpClient` / `acpStatus` / flags. Call immediately
    /// after every await in a start pipeline, before any state write.
    private func startStillCurrent(_ intent: Int, client: ACPClient?) -> Bool {
        if intent == sessionStartGeneration { return true }
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
            // Self-supersede so the wedged pipeline's generation checks
            // abandon silently if its awaits ever resume, instead of
            // stomping the error state painted below.
            self.beginStartIntent()
            self.stopACP()
            self.acpStatus = ACPPhase.failed
            self.clearACPErrorState()
            self.acpError = "Session start timed out after \(seconds) seconds."
            self.acpErrorHint = "The agent never finished starting — the process may be wedged. Click the chat again (or start a new one) to retry."
        }
    }

    /// Cancel the start watchdog. Call once a start pipeline settles
    /// (ready, failure, or preflight bail) and from `stopACP` teardown.
    private func disarmStartWatchdog() {
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
    }

    // MARK: - Session Lifecycle

    func startNewSession(projectPath: String? = nil) {
        startNewSession(projectPath: projectPath, initialPrompt: nil)
    }

    /// Variant that auto-sends `initialPrompt` once the ACP session
    /// has connected. Used by the "New Project from Scratch" wizard
    /// (v2.8) to kick the conversation off with a message the agent
    /// recognizes as a `scarf-template-author` invocation, so the user
    /// doesn't have to type anything to begin the interview.
    /// Terminal mode ignores the prompt — the wizard runs in rich-chat
    /// only.
    func startNewSession(projectPath: String?, initialPrompt: String?) {
        // Flip the loading flag synchronously on the user's tap so
        // SwiftUI paints the session-list overlay on the same tick
        // — `startACPSession` won't reach `acpStatus = .spawning`
        // until the Task body runs, which on remote contexts is
        // multiple seconds after the click. v2.8.
        isStartingSession = true
        beginStartIntent()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: nil, projectPath: projectPath, initialPrompt: initialPrompt)
        } else {
            // Terminal mode doesn't surface project attribution today —
            // `hermes chat` uses the shell's cwd, so starting a terminal
            // chat from a project button would require changing the
            // shell's cwd too. Out of scope for v2.3 — Rich Chat is
            // the primary surface for project-scoped sessions.
            launchTerminal(arguments: ["chat"])
        }
    }

    /// Start a new project-scoped ACP session and send `text` as the
    /// first prompt once connected. Thin wrapper named for the
    /// wizard's call site to make intent obvious; behaves identically
    /// to `startNewSession(projectPath:initialPrompt:)`.
    func startNewSessionAndSend(projectPath: String, text: String) {
        // Force rich-chat — the wizard handoff doesn't make sense in
        // terminal mode, and we'd silently swallow the initial prompt
        // if the user happened to be on the terminal segment.
        displayMode = .richChat
        startNewSession(projectPath: projectPath, initialPrompt: text)
    }

    func resumeSession(_ sessionId: String) {
        isStartingSession = true
        beginStartIntent()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
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
                let projectPath = await Task.detached {
                    SessionAttributionService(context: ctx).resolveProjectPath(known: nil, sessionID: sessionId)
                }.value
                // Bail if a newer session-start superseded us while the
                // (possibly remote) attribution read was in flight.
                guard startStillCurrent(intent, client: nil) else { return }
                startACPSession(resume: sessionId, projectPath: projectPath)
            }
        } else {
            richChatViewModel.setSessionId(sessionId)
            launchTerminal(arguments: ["chat", "--resume", sessionId])
        }
    }

    func continueLastSession() {
        isStartingSession = true
        let intent = beginStartIntent()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
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
                    let projectPath = await Task.detached {
                        SessionAttributionService(context: ctx).resolveProjectPath(known: nil, sessionID: sessionId)
                    }.value
                    // Bail if a newer session-start superseded us across the
                    // DB + attribution reads above.
                    guard startStillCurrent(intent, client: nil) else { return }
                    startACPSession(resume: sessionId, projectPath: projectPath)
                } else {
                    guard startStillCurrent(intent, client: nil) else { return }
                    startACPSession(resume: nil)
                }
            }
        } else {
            launchTerminal(arguments: ["chat", "--continue"])
        }
    }

    // MARK: - Send Message

    func sendText(_ text: String) {
        sendText(text, images: [])
    }

    /// v0.12+ overload: forward image attachments alongside the text.
    /// Empty `images` keeps the legacy v0.11 wire shape; non-empty images
    /// only flow when `HermesCapabilities.hasACPImagePrompts` is true
    /// (the input bar gates the attachment UI on the same flag, so a
    /// non-empty array reaching here means we've already verified the
    /// agent supports it).
    ///
    /// Terminal mode silently drops attachments — there's no way to
    /// pipe binary content through the TTY. Surface a one-shot warning
    /// so the user knows.
    func sendText(_ text: String, images: [ChatImageAttachment]) {
        if displayMode == .richChat {
            if let client = acpClient {
                sendViaACP(client: client, text: text, images: images)
            } else {
                // Auto-start ACP and send the queued message
                autoStartACPAndSend(text: text, images: images)
            }
        } else if let tv = terminalView {
            if !images.isEmpty {
                logger.warning("Terminal-mode chat dropped \(images.count) image attachment(s) — image input only works in ACP rich-chat mode")
                acpError = "Image attachments require ACP mode (rich chat)."
            }
            sendToTerminal(tv, text: text + "\r")
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
        isStartingSession = true
        let intent = beginStartIntent()
        // Bound the whole auto-start pipeline (pre-spawn attribution
        // read included) — S3, t-5451bd1b.
        armStartWatchdog(intent: intent)
        // Show the user message immediately
        richChatViewModel.addUserMessage(text: text)

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
            let projectPath = await Task.detached {
                SessionAttributionService(context: ctx).resolveProjectPath(known: knownProject, sessionID: sessionToResume)
            }.value
            // Bail if a newer session-start superseded us while the (possibly
            // remote) attribution read was in flight.
            guard startStillCurrent(intent, client: nil) else { return }

            let client = acpClientFactory(context, projectPath)
            self.acpClient = client

            do {
                acpStatus = ACPPhase.spawning
                try await client.start()
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.authenticating
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                let cwd: String
                if let projectPath {
                    cwd = projectPath
                } else {
                    cwd = await context.resolvedUserHome()
                    guard startStillCurrent(intent, client: client) else { return }
                }

                hasActiveProcess = true

                let resolvedSessionId: String
                if let existing = sessionToResume {
                    acpStatus = ACPPhase.loadingSession
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: existing)
                    } catch {
                        guard startStillCurrent(intent, client: client) else { return }
                        logger.info("Session \(existing) not found in ACP, creating new session")
                        acpStatus = ACPPhase.creatingNewSession
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                }
                guard startStillCurrent(intent, client: client) else { return }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = ACPPhase.ready
                isStartingSession = false
                disarmStartWatchdog()

                // Surface the freshly-created session in the chat
                // sidebar immediately. We can't lean on the file
                // watcher to do this — it fires unconditionally
                // through `scheduleSessionsRefresh` which has a
                // 500 ms debounce. An explicit call here keeps the
                // "type → see new chat in the list" feedback prompt.
                await loadRecentSessions()
                guard startStillCurrent(intent, client: client) else { return }

                // Now send the queued prompt. The optimistic echo was
                // appended above (before session setup), so suppress
                // the second one explicitly.
                sendViaACP(client: client, text: text, images: images, localEchoAlreadyAdded: true)
            } catch {
                // Superseded start (a newer click, or the watchdog):
                // the newer path owns the shared state — just make
                // sure this attempt's spawn doesn't leak.
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.failed
                isStartingSession = false
                disarmStartWatchdog()
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
        localEchoAlreadyAdded: Bool = false
    ) {
        ScarfMon.event(.chatStream, "mac.sendViaACP", count: 1, bytes: text.utf8.count)

        // Client-side slash intercept. Hermes ACP doesn't intercept
        // `/new` server-side — sending it as a prompt routes to the
        // LLM, which responds in-character ("/new is a TUI slash
        // command, type it in the TUI prompt"). TestFlight feedback
        // ADyrlh, 2026-05-11. Run BEFORE the user-message append so
        // the transcript doesn't sprout an orphaned slash bubble right
        // before we tear it down for the new session.
        if let intercept = RichChatViewModel.clientSideSlashCommand(for: text) {
            switch intercept {
            case .newSession(let name):
                // Mac startNewSession doesn't yet honor v0.13's optional
                // session-name argument (`hasNewWithSessionName`). Drop
                // it silently for v1 — the slash menu's argument hint
                // still discoverably advertises the syntax for when
                // Mac's startNewSession gains support.
                _ = name
                startNewSession()
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
        let wireText = richChatViewModel.expandIfProjectScoped(text, context: context)

        // Non-interruptive slash commands keep the "Agent working…"
        // indicator off and surface a transient toast confirming the
        // command was accepted. v2.5 added `/steer`; v2.8 / Hermes
        // v0.13 adds `/goal` (lock the agent on a target across turns)
        // and `/queue` (queue a prompt for after the current turn).
        // Each gets its own optimistic side-effect on RichChatViewModel
        // so the chat header pill / queue chip update synchronously
        // without waiting for a server round-trip.
        let isNonInterruptive = richChatViewModel.isNonInterruptiveSlash(text)
        let parsed = RichChatViewModel.parseSlashName(text)
        switch parsed.name {
        case "goal":
            // TODO(WS-2-Q7): once a v0.13 host confirms the
            // wire-shape, this branch fires only when the host
            // advertises `hasGoals`; pre-v0.13 hosts hide the menu
            // row, but a power-user typing `/goal` directly still
            // lands here. We keep the optimistic write so the pill
            // appears synchronously — the agent's "unknown command"
            // reply on a pre-v0.13 host paints the inconsistency in
            // user-visible chat content (acceptable v1 behavior;
            // see WS-2 plan "Inconsistency caveat").
            let arg = RichChatViewModel.parseGoalArgument(parsed.args)
            switch arg {
            case .set(let goalText):
                richChatViewModel.recordActiveGoal(text: goalText)
                richChatViewModel.transientHint = "Goal locked: \(RichChatViewModel.truncatedToastGoal(goalText))"
                maybeTriggerKanbanOnboarding()
            case .clear:
                richChatViewModel.recordActiveGoal(text: nil)
                richChatViewModel.transientHint = "Goal cleared."
            case .empty:
                richChatViewModel.transientHint = "Sent /goal — see the agent reply for current goal."
            }
            scheduleHintClear()
        case "queue":
            let queuedText = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            if !queuedText.isEmpty {
                richChatViewModel.recordQueuedPrompt(text: queuedText)
            }
            richChatViewModel.transientHint = "Queued — runs after current turn."
            scheduleHintClear()
        case "subgoal":
            // v0.14 — /subgoal layers extra success criteria onto the
            // active /goal loop. Same optimistic-mirror pattern as
            // /goal: parse the arg, mutate the local mirror, surface a
            // transient hint, then send the slash verbatim to Hermes.
            // Hermes is the authoritative store; the mirror just
            // drives the goal-pill trailing line in `SessionInfoBar`.
            let arg = RichChatViewModel.parseSubgoalArgument(parsed.args)
            switch arg {
            case .add(let subText):
                richChatViewModel.recordSubgoalAdded(subText)
                richChatViewModel.transientHint = "Subgoal added."
            case .remove(let idx):
                richChatViewModel.recordSubgoalRemoved(idx)
                richChatViewModel.transientHint = "Subgoal \(idx) removed."
            case .clear:
                richChatViewModel.recordSubgoalsCleared()
                richChatViewModel.transientHint = "Subgoals cleared."
            case .empty:
                richChatViewModel.transientHint = "Sent /subgoal — see the agent reply for current subgoals."
            }
            scheduleHintClear()
        case "steer" where isNonInterruptive:
            richChatViewModel.transientHint = "Guidance queued — applies after the next tool call."
            scheduleHintClear()
        default:
            // Regular interruptive prompt (or an unrecognized slash).
            // Don't flip "Agent working…" for any other
            // non-interruptive command (defensive; matches the
            // legacy contract).
            if !isNonInterruptive { acpStatus = ACPPhase.agentWorking }
        }
        // Record the in-flight interruptive turn (ChatViewModel-owned;
        // see `inFlightPromptSessionId`) so `stopACP` can cancel it
        // even after a session-switch already reset the transcript VM.
        let turnGeneration: Int?
        if isNonInterruptive {
            turnGeneration = nil
        } else {
            inFlightPromptGeneration &+= 1
            inFlightPromptSessionId = sessionId
            turnGeneration = inFlightPromptGeneration
        }
        acpPromptTask = Task { @MainActor in
            defer {
                // This turn is over (completed, failed, or cancelled) —
                // clear the in-flight marker unless a newer turn
                // already replaced it.
                if let turnGeneration, turnGeneration == inFlightPromptGeneration {
                    inFlightPromptSessionId = nil
                }
            }
            do {
                let result = try await ScarfMon.measureAsync(.chatStream, "mac.sendPrompt") {
                    try await client.sendPrompt(sessionId: sessionId, text: wireText, images: images)
                }
                // A turn resuming after its client was superseded
                // (session switch / watchdog teardown mid-turn) must
                // not touch shared state: the newer session owns
                // `acpStatus`, the transcript, and notifications.
                guard acpClient === client else { return }
                acpStatus = ACPPhase.ready
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: result)
                )
                // Re-fetch session from DB to pick up cost/token data Hermes may have written
                await richChatViewModel.refreshSessionFromDB()
                // Issue #64 — notify the user that Hermes has
                // finished if Scarf isn't the foreground app. The
                // notifier handles the foreground/disabled gating;
                // we just hand it the latest assistant text and
                // session title for the body line.
                if !isNonInterruptive {
                    let preview = richChatViewModel.messages
                        .last(where: { $0.isAssistant })?
                        .content ?? ""
                    let title = richChatViewModel.currentSession?.title
                    ChatNotificationService.shared.postPromptCompleted(
                        sessionTitle: title,
                        preview: preview
                    )
                }
            } catch is CancellationError {
                // Routine when `stopACP` tears down a superseded
                // client mid-turn (its `client.stop()` resumes the
                // held `session/prompt` with `CancellationError`).
                // Pre-guard, this stale resume stomped "Cancelled"
                // over the SUPERSEDING session's status pill.
                guard acpClient === client else { return }
                acpStatus = ACPPhase.cancelled
            } catch {
                guard acpClient === client else { return }
                acpStatus = ACPPhase.error
                await recordACPFailure(error, client: client, context: "ACP prompt failed")
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: ACPPromptResult(
                        stopReason: "error",
                        inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0
                    ))
                )
            }
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
            let config = fileService.loadConfig()
            targetModelID = config.model
            // Pair the default model with its configured provider so
            // the "Use global default" mid-chat switch lands on the
            // same provider the CLI default would. Empty / "unknown"
            // (the YAML parser's sentinel) → nil, falling back to the
            // bare-model wire shape.
            let rawProvider = config.provider.trimmingCharacters(in: .whitespaces)
            targetProviderID = (rawProvider.isEmpty || rawProvider == "unknown") ? nil : rawProvider
        }

        Task { @MainActor [weak self] in
            do {
                try await client.setSessionModel(
                    sessionId: sessionId,
                    modelID: targetModelID,
                    providerID: targetProviderID
                )
                self?.logger.info("mid-chat model switch to \(targetModelID) (provider: \(targetProviderID ?? "auto")) succeeded")
            } catch {
                self?.logger.warning("mid-chat model switch failed: \(error.localizedDescription)")
                self?.currentModelPreset = previous
                self?.acpError = "Couldn't switch model: \(error.localizedDescription)"
            }
        }
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
        let reader = ProjectModelPresetReader(context: context)
        guard let idString = reader.presetID(forProjectPath: projectPath),
              let presetID = UUID(uuidString: idString)
        else {
            currentModelPreset = nil
            return
        }

        let service = ModelPresetService(context: context)
        let preset: ModelPreset?
        do {
            preset = try await service.get(id: presetID)
        } catch {
            logger.warning("couldn't load model preset \(idString): \(error.localizedDescription)")
            currentModelPreset = nil
            return
        }

        guard let preset else {
            logger.info("project '\(projectPath)' references deleted preset \(idString) — falling back to global default")
            currentModelPreset = nil
            return
        }

        let caps = capabilitiesStore?.capabilities ?? .empty
        guard caps.hasACPSetSessionModel else {
            logger.info("host doesn't support session/set_model (pre-v0.13) — preset '\(preset.name)' bound but not applied")
            currentModelPreset = nil
            return
        }

        do {
            // Pass providerID so the RPC uses Hermes's
            // `<provider>:<model>` colon-encoded wire format. Without
            // it, less-obvious model IDs (e.g. `inclusionai/ring-2.6-1t`)
            // fall into `detect_provider_for_model` which infers wrong
            // — see issue #97. Empty `providerID` (older presets that
            // pre-date the providerID field) falls back to bare-model
            // wire shape.
            let providerHint = preset.providerID.isEmpty ? nil : preset.providerID
            try await client.setSessionModel(
                sessionId: sessionId,
                modelID: preset.modelID,
                providerID: providerHint
            )
            currentModelPreset = preset
            logger.info("applied model preset '\(preset.name)' (\(preset.modelID), provider: \(providerHint ?? "auto")) to session \(sessionId)")
        } catch {
            logger.warning("session/set_model failed for preset '\(preset.name)': \(error.localizedDescription) — session stays on config.yaml default")
            currentModelPreset = nil
        }
    }

    private func startACPSession(
        resume sessionId: String?,
        projectPath: String? = nil,
        initialPrompt: String? = nil
    ) {
        ScarfMon.event(.sessionLoad, "mac.startACPSession", count: 1)
        stopACP()
        clearACPErrorState()
        // stopACP() clears `isStartingSession` (it's a generic teardown
        // helper used by disconnect paths too). Re-arm it here so the
        // session-list overlay stays up through the entire boot.
        isStartingSession = true
        // The spawn stage is a fresh start intent: entry points bumped
        // before their pre-spawn awaits, and bumping again here makes a
        // preflight-sheet replay (confirmModelPreflight → this method,
        // no entry-point bump) supersede whatever came before it.
        let intent = beginStartIntent()

        // Pre-flight: bail before opening any ACP plumbing if the
        // active server's `config.yaml` has no primary model or
        // provider. Hermes would otherwise let `session/new` succeed
        // and only fail at first prompt with an opaque
        // "Model parameter is required" 400. Stashing the start
        // arguments here lets `confirmModelPreflight` replay them
        // unchanged after the user picks a model.
        let preflight = ModelPreflight.check(fileService.loadConfig())
        if !preflight.isConfigured {
            pendingStartArgs = (sessionId, projectPath, initialPrompt)
            modelPreflightReason = preflight.reason
            acpStatus = ""
            hasActiveProcess = false
            isStartingSession = false
            disarmStartWatchdog()
            return
        }

        acpStatus = ACPPhase.spawning
        // Re-arm for the spawn stage (replaces any entry-point arm the
        // stopACP() above disarmed).
        armStartWatchdog(intent: intent)

        // Project-scoped chats spawn `hermes acp` with the project as the
        // process cwd so Hermes loads the project's AGENTS.md context files
        // (it reads them from the process cwd, not the ACP session cwd).
        let client = acpClientFactory(context, projectPath)
        self.acpClient = client
        let attribution = SessionAttributionService(context: context)

        // If the caller passed a project path, refresh the Scarf-
        // managed block in the project's AGENTS.md BEFORE starting
        // ACP — Hermes auto-reads AGENTS.md at session boot, so the
        // block has to land on disk first. Non-blocking on failure:
        // we log and proceed without the block. Safe on bare
        // projects (creates AGENTS.md with just the block); safe on
        // template-installed projects (splices the block into
        // existing AGENTS.md without touching template content).
        let contextForPrep = context
        let prepLogger = logger
        Task { @MainActor [self] in
            if let projectPath {
                // Synchronous file I/O (ProjectDashboardService.loadRegistry +
                // ProjectAgentContextService.refresh, which itself walks the
                // slash-commands directory) must run off the MainActor — the
                // detached task runs the work on the cooperative pool and we
                // await it here so the AGENTS.md block lands before client.start().
                await Task.detached {
                    let registry = ProjectDashboardService(context: contextForPrep).loadRegistry()
                    guard let project = registry.projects.first(where: { $0.path == projectPath }) else {
                        return
                    }
                    do {
                        try ProjectAgentContextService(context: contextForPrep).refresh(for: project)
                    } catch {
                        prepLogger.warning("couldn't refresh project context block for \(project.name): \(error.localizedDescription)")
                    }
                }.value
                // Pre-spawn await — a newer start may have superseded
                // us while the registry/AGENTS.md I/O ran. Abandon
                // BEFORE spawning so the superseded attempt never
                // launches a process at all.
                guard startStillCurrent(intent, client: client) else { return }
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
                let cwd: String
                if let projectPath {
                    cwd = projectPath
                } else {
                    cwd = await context.resolvedUserHome()
                    guard startStillCurrent(intent, client: client) else { return }
                }

                // Mark active BEFORE setting session ID so .task(id:) sees isACPMode=true
                // and doesn't wipe messages with a DB refresh
                hasActiveProcess = true

                let resolvedSessionId: String
                if let sessionId {
                    acpStatus = ACPPhase.loadingSession
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        guard startStillCurrent(intent, client: client) else { return }
                        logger.info("Session \(sessionId) not found in ACP, creating new session with history")
                        acpStatus = ACPPhase.creatingNewSession
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                    guard startStillCurrent(intent, client: client) else { return }
                    // Surface "Loading history…" before the (potentially
                    // 30s) message-history fetch fires. Pre-fix the user
                    // saw "Loading session…" through start(), then jump
                    // straight to "Ready" the moment the bytes hit the
                    // pane — but the actual hydrate is the slowest step
                    // on a remote and the pane looked engageable while
                    // the SQLite query was still pending. v2.8.
                    acpStatus = ACPPhase.loadingHistory
                    await richChatViewModel.loadSessionHistory(
                        sessionId: sessionId,
                        acpSessionId: resolvedSessionId
                    )
                    guard startStillCurrent(intent, client: client) else { return }
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                    guard startStillCurrent(intent, client: client) else { return }
                }

                // Apply the project's bound model preset before unlocking
                // the prompt. Non-fatal — falls back to the config.yaml
                // default on any failure (missing preset, pre-v0.13 host,
                // RPC error). Runs after both new and resumed sessions so
                // a project's preset survives a reconnect into the same
                // chat. No-op when no projectPath was passed.
                if let projectPath {
                    await applyProjectModelPreset(
                        client: client,
                        sessionId: resolvedSessionId,
                        projectPath: projectPath
                    )
                    guard startStillCurrent(intent, client: client) else { return }
                }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = ACPPhase.ready
                isStartingSession = false
                disarmStartWatchdog()

                // Attribute this session to the project it was started
                // under, so the per-project Sessions tab can surface it
                // without a user action. No-op when projectPath is nil.
                // Idempotent: re-attribution of the same pair is free.
                if let projectPath {
                    attribution.attribute(
                        sessionID: resolvedSessionId,
                        toProjectPath: projectPath
                    )
                }

                // Resolve which project (if any) this session belongs
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
                let attributedPath = projectPath
                    ?? attribution.projectPath(for: resolvedSessionId)
                if let path = attributedPath {
                    // Look up a human-readable name from the projects
                    // registry. Missing project (path in the sidecar,
                    // project since removed) → show the path as a
                    // fallback label so the chip still renders and the
                    // user sees *something* rather than silently losing
                    // the indicator.
                    let registry = ProjectDashboardService(context: context).loadRegistry()
                    let name = registry.projects.first(where: { $0.path == path })?.name
                    self.currentProjectPath = path
                    self.currentProjectName = name ?? path
                    // Pull any project-scoped slash commands the user has
                    // authored at <path>/.scarf/slash-commands/ so the
                    // chat slash menu surfaces them. Async + non-fatal —
                    // the menu degrades to ACP + quick commands only on
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
                await loadRecentSessions()
                guard startStillCurrent(intent, client: client) else { return }

                logger.info("ACP session ready: \(resolvedSessionId)")

                // v2.8 wizard handoff: auto-send the kickoff prompt now
                // that the session is connected. Renders as a normal user
                // bubble (matches the user's intent — they triggered this
                // flow via the New Project sheet) and routes through the
                // same `sendViaACP` path that typed messages use, so the
                // event loop, attribution, and streaming are identical.
                if let prompt = initialPrompt,
                   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    richChatViewModel.addUserMessage(text: prompt)
                    sendViaACP(client: client, text: prompt, images: [], localEchoAlreadyAdded: true)
                }
            } catch {
                // Superseded start (a newer click, or the watchdog):
                // the newer path owns the shared state — just make
                // sure this attempt's spawn doesn't leak.
                guard startStillCurrent(intent, client: client) else { return }
                acpStatus = ACPPhase.failed
                isStartingSession = false
                disarmStartWatchdog()
                await recordACPFailure(error, client: client, context: "Failed to start ACP session")
                // Stop the client even though start failed — pre-fix
                // this path leaked the spawned `hermes acp` process
                // (plus its two pipe readers) on EVERY start failure,
                // a confirmed S3 pool-starvation contributor.
                await client.stop()
                if startStillCurrent(intent, client: nil) {
                    hasActiveProcess = false
                    acpClient = nil
                }
                await recoverRemoteTransportAfterFailure()
            }
        }
    }

    private func startACPEventLoop(client: ACPClient) {
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
                if case let .sessionInfoUpdate(sessionId, title, _) = event {
                    self?.applySessionTitleUpdate(sessionId: sessionId, title: title)
                }
                ScarfMon.measure(.chatStream, "mac.handleACPEvent") {
                    self?.richChatViewModel.handleACPEvent(event)
                }
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

    private func handleConnectionDied() {
        guard acpClient != nil, !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        logger.warning("ACP connection died")

        // Finalize any in-progress streaming message before reconnection
        richChatViewModel.finalizeOnDisconnect()

        // Save session ID for reconnection before cleaning up
        let savedSessionId = richChatViewModel.sessionId

        // Clean up the dead client. No `session/cancel` here — the
        // process is already gone; just drop the in-flight-turn marker
        // so a later `stopACP` doesn't cancel a turn that died with it.
        inFlightPromptSessionId = nil
        acpPromptTask?.cancel()
        acpPromptTask = nil
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
            return
        }
        attemptReconnect(sessionId: savedSessionId)
    }

    private func attemptReconnect(sessionId: String) {
        reconnectTask?.cancel()
        clearACPErrorState()

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

            let projectPath = await Task.detached {
                SessionAttributionService(context: ctx).resolveProjectPath(known: knownProject, sessionID: sessionId)
            }.value

            for attempt in 1...Self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }

                acpStatus = "Reconnecting (\(attempt)/\(Self.maxReconnectAttempts))…"
                logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) for session \(sessionId)")

                // Backoff delay (skip on first attempt for fast recovery)
                if attempt > 1 {
                    let delay = min(
                        Self.reconnectBaseDelay * UInt64(1 << (attempt - 1)),
                        Self.maxReconnectDelay
                    )
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let client = acpClientFactory(context, projectPath)
                do {
                    try await client.start()

                    let cwd: String
                    if let projectPath {
                        cwd = projectPath
                    } else {
                        cwd = await context.resolvedUserHome()
                    }
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
                    let resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)

                    // Success — wire up the new client
                    self.acpClient = client
                    self.hasActiveProcess = true
                    richChatViewModel.setSessionId(resolvedSessionId)

                    // Reconcile in-memory messages with what Hermes persisted to DB
                    await richChatViewModel.reconcileWithDB(sessionId: resolvedSessionId)

                    acpStatus = ACPPhase.ready
                    clearACPErrorState()

                    startACPEventLoop(client: client)
                    startHealthMonitor(client: client)

                    isHandlingDisconnect = false
                    logger.info("Reconnected successfully on attempt \(attempt)")
                    return
                } catch {
                    logger.warning("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    await client.stop()
                    continue
                }
            }

            // All attempts exhausted
            guard !Task.isCancelled else { return }
            showConnectionFailure()
            isHandlingDisconnect = false
        }
    }

    private func showConnectionFailure() {
        richChatViewModel.handleACPEvent(.connectionLost(reason: "The ACP process terminated unexpectedly"))
        acpStatus = ACPPhase.connectionLost
        clearACPErrorState()
        acpError = "Connection lost. Use the Session menu to reconnect."
    }

    func stopACP() {
        disarmStartWatchdog()
        reconnectTask?.cancel()
        reconnectTask = nil
        // Capture BEFORE cancelling the prompt task. Keyed off
        // ChatViewModel-owned turn state — NOT `richChatViewModel` —
        // because in the session-switch paths `reset()` already wiped
        // `isAgentWorking`/`sessionId` at click time, which made the
        // S4 cancel unreachable on exactly its flagship path (audit,
        // t-5451bd1b).
        let inFlightSessionId = inFlightPromptSessionId
        let turnWasInFlight = acpPromptTask != nil && inFlightSessionId != nil
        inFlightPromptSessionId = nil
        acpPromptTask?.cancel()
        acpPromptTask = nil
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task {
                // S4 (t-5451bd1b): killing a mid-turn process without
                // `session/cancel` left Hermes with an unfinalized turn
                // — the same prompt re-sent later then got merged into
                // one duplicated DB row by Hermes's alternation repair.
                // Best-effort and bounded to 2s: teardown must never
                // hang on a wedged process, and `client.stop()` below
                // resumes a still-pending cancel RPC either way.
                if turnWasInFlight, let sid = inFlightSessionId {
                    await Self.boundedSessionCancel(client: client, sessionId: sid, seconds: 2)
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
                // swap when the user switched sessions mid-turn (reset()
                // already wiped the old transcript by the time we run).
                richChatViewModel.transientHint = "Turn cancelled — switched sessions."
                scheduleHintClear()
            }
        }
        acpClient = nil
        hasActiveProcess = false
        isHandlingDisconnect = false
        isStartingSession = false
    }

    /// Best-effort `session/cancel` bounded to `seconds`. Returns when
    /// Hermes acknowledges the cancel OR the deadline passes, whichever
    /// comes first — a wedged process must not be able to stall
    /// teardown. The losing branch is harmless: an unanswered cancel
    /// RPC is resumed with `CancellationError` by the `client.stop()`
    /// that always follows.
    nonisolated private static func boundedSessionCancel(
        client: ACPClient,
        sessionId: String,
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
                resumeOnce()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resumeOnce()
            }
        }
    }

    // MARK: - Model preflight

    /// Called by `ChatModelPreflightSheet` once the user has picked a
    /// model in the embedded `ModelPickerSheet`. Persists the choice via
    /// `hermes config set` (transport-aware — works on remote droplets
    /// too) and replays the pending `startACPSession` call so the chat
    /// the user originally tried to open finally lands.
    @MainActor
    func confirmModelPreflight(model: String, provider: String, local: LocalModelSelection? = nil) {
        let pending = pendingStartArgs
        modelPreflightReason = nil
        pendingStartArgs = nil

        let svc = fileService
        Task.detached { [weak self] in
            // Both branches route through the shared write plan (T4
            // audit): local picks carry keys `setModelAndProvider` can't
            // write (base_url et al.), and remote picks must scrub any
            // stale local-managed keys when the provider changes — a
            // provider=ollama config reached via preflight (e.g. its
            // model.default got emptied) would otherwise keep its
            // base_url into the new cloud provider. For a config with no
            // local keys the remote ops are exactly the classic
            // [set provider, set model] pair.
            let ok: Bool
            if let local {
                let ops = LocalModelConfigPlan.operations(selecting: local)
                ok = !ops.isEmpty && svc.applyModelConfigPlan(ops)
            } else if provider.trimmingCharacters(in: .whitespaces).isEmpty {
                // Parity with setModelAndProvider's guard: the preflight
                // must persist BOTH keys, so an empty provider is a
                // failed save, not a model-only write.
                ok = false
            } else {
                let ops = LocalModelConfigPlan.operations(
                    selectingRemoteModel: model,
                    provider: provider,
                    current: svc.loadConfig()
                )
                ok = !ops.isEmpty && svc.applyModelConfigPlan(ops)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    if let pending {
                        self.startACPSession(
                            resume: pending.sessionId,
                            projectPath: pending.projectPath,
                            initialPrompt: pending.initialPrompt
                        )
                    }
                } else {
                    self.acpError = "Couldn't save model+provider to config.yaml. Open Settings to retry."
                }
            }
        }
    }

    /// User dismissed the preflight sheet without picking a model. Drop
    /// the stashed start arguments and leave the chat in its idle state
    /// — no error banner, since this isn't a failure, just a deferral.
    @MainActor
    func cancelModelPreflight() {
        modelPreflightReason = nil
        pendingStartArgs = nil
    }

    /// Respond to a permission request from the ACP agent.
    func respondToPermission(optionId: String) {
        guard let client = acpClient,
              let permission = richChatViewModel.pendingPermission else { return }
        Task {
            await client.respondToPermission(requestId: permission.requestId, optionId: optionId)
        }
        richChatViewModel.pendingPermission = nil
    }

    // MARK: - Recent Sessions

    /// Coalesce rapid `loadRecentSessions` triggers into one trailing
    /// fetch. Hooked up to the file-watcher tick in `ChatView`; during
    /// an ACP message stream the watcher fires 5–10 times per second
    /// as Hermes appends to `state.db-wal`, and an unconditional
    /// reload on each tick would visibly flicker the chat sidebar
    /// while the response streams in.
    ///
    /// The 500 ms window is short enough that idle external changes
    /// (a session created from another `hermes` invocation, a rename
    /// from another window) still appear "soon" without explicit user
    /// action, and long enough to absorb a streaming-response burst.
    /// Newly created / resumed sessions in *this* window don't depend
    /// on the debounce — `startACPSession` and `autoStartACPAndSend`
    /// call `loadRecentSessions()` synchronously after the session id
    /// resolves, so the chat sidebar updates immediately.
    func scheduleSessionsRefresh() {
        // Track every file-watcher-driven debounce entry. During an ACP
        // stream this fires many times per second; the count helps us see
        // how often the watcher fires vs. how often a real reload executes.
        ScarfMon.event(.sessionLoad, "mac.scheduleSessionsRefresh", count: 1)
        sessionsRefreshTask?.cancel()
        sessionsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await self?.loadRecentSessions()
        }
    }

    func loadRecentSessions() async {
        // L2 (v2.8) — coalesce against an in-flight load. If one's
        // already running, await its completion instead of spawning a
        // parallel one. Drops the 2-3× contention seen during file-
        // watcher streams.
        if let existing = inFlightSessionLoad {
            ScarfMon.event(.sessionLoad, "mac.loadRecentSessions.coalesced", count: 1)
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadRecentSessions()
        }
        inFlightSessionLoad = task
        await task.value
        inFlightSessionLoad = nil
    }

    private func performLoadRecentSessions() async {
        // Measure the full wall-clock cost of a sessions sidebar reload,
        // from DB open through the off-main attribution read to the final
        // observable assignment. Surfaces fetch regressions and SQLite
        // latency spikes in the ScarfMon trace.
        await ScarfMon.measureAsync(.sessionLoad, "mac.loadRecentSessions") {
            let opened = await dataService.open()
            guard opened else { return }
            // Bumped from 10 → 50 so the project filter has enough data to
            // surface attributed sessions (older attributed sessions were
            // getting truncated out of the original limit). Sessions feature
            // loads 500; the chat sidebar doesn't need that, but 50 keeps
            // the project filter useful without measurable cost.
            //
            // v2.7: folded sessions + previews into one queryBatch round
            // trip via sessionListSnapshot. Pre-fix the two awaits below
            // were serialized SSH calls, paying the 420 ms RTT twice
            // every time the file watcher fired (~2.2 s baseline reload).
            // sessionListSnapshot halves the round-trips for every
            // sidebar refresh.
            let snapshot = await dataService.sessionListSnapshot(limit: 50)
            let fetchedSessions = snapshot.sessions
            let fetchedPreviews = snapshot.previews
            await dataService.close()

            // Project attribution + registry — single batched off-main read.
            let ctx = context
            let bundle: (names: [String: String], projects: [ProjectEntry]) = await Task.detached {
                let attribution = SessionAttributionService(context: ctx)
                let registry = ProjectDashboardService(context: ctx).loadRegistry()
                let pathToName = Dictionary(
                    uniqueKeysWithValues: registry.projects.map { ($0.path, $0.name) }
                )
                let map = attribution.load().mappings
                var names: [String: String] = [:]
                for (sessionID, path) in map {
                    if let name = pathToName[path] {
                        names[sessionID] = name
                    }
                }
                return (names: names, projects: registry.projects)
            }.value

            // Single batched commit — assigning all four observables at once
            // means SwiftUI sees one update rather than four staggered ones.
            // Eliminates the brief "list flashes / project chips appear
            // late" reload artifact during session switches.
            recentSessions = fetchedSessions
            sessionPreviews = fetchedPreviews
            sessionProjectNames = bundle.names
            allProjects = bundle.projects

            // Record the sidebar size after each reload so we can correlate
            // list-length growth with reload latency in the ScarfMon trace.
            ScarfMon.event(.sessionLoad, "mac.recentSessions.count", count: recentSessions.count)
        }
    }

    /// Resolved project display name for a recent session, or nil for
    /// unattributed (global / quick) sessions.
    func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    /// Rename a session via `hermes sessions rename`. Updates local
    /// caches in-place on success so the chat sidebar reflects the new
    /// title without a full reload. Same shell command path the
    /// SessionsView feature uses.
    func renameSession(_ sessionId: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = context.runHermes(["sessions", "rename", sessionId, trimmed])
        guard result.exitCode == 0 else { return }
        if let idx = recentSessions.firstIndex(where: { $0.id == sessionId }) {
            recentSessions[idx] = recentSessions[idx].withTitle(trimmed)
        }
        sessionPreviews[sessionId] = trimmed
    }

    /// Apply a session title from an ACP `session_info_update` event
    /// (Hermes v0.16+). Mirrors `renameSession`'s in-place cache mutation
    /// so the sidebar reflects the new title immediately, but skips the
    /// `hermes sessions rename` CLI call — Hermes generated and persisted
    /// the title itself, so re-issuing the command would be redundant.
    /// Guards a nil/empty title so a "clear title" update is a no-op.
    private func applySessionTitleUpdate(sessionId: String, title: String?) {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return }
        if let idx = recentSessions.firstIndex(where: { $0.id == sessionId }) {
            recentSessions[idx] = recentSessions[idx].withTitle(trimmed)
        }
        sessionPreviews[sessionId] = trimmed
    }

    /// Delete a session via `hermes sessions delete --yes` (server-side
    /// delete — Hermes removes it from state.db). Removes the row from
    /// local caches on success. When the deleted session is the ACTIVE
    /// one, ALSO routes through the same teardown machinery a session
    /// switch uses (t-01bd55ec): pre-fix this branch only reset the
    /// transcript, so the `hermes acp` process (+ its dispatch sources)
    /// stayed alive until app quit and a mid-flight turn kept running
    /// server-side against the just-deleted session. Deleting a
    /// non-active session never disturbs the live client.
    func deleteSession(_ sessionId: String) {
        guard sessionDeleteRunner(context, sessionId) == 0 else { return }
        recentSessions.removeAll { $0.id == sessionId }
        sessionPreviews.removeValue(forKey: sessionId)
        sessionProjectNames.removeValue(forKey: sessionId)
        guard richChatViewModel.sessionId == sessionId else { return }

        // Active session deleted — mirror startACPSession's entry
        // teardown (minus the respawn):
        //
        // Capture the in-flight turn BEFORE reset/stopACP so the
        // delete-specific hint below can replace stopACP's generic
        // "switched sessions" wording.
        let turnWasInFlight = acpPromptTask != nil && inFlightPromptSessionId != nil
        // Supersede any in-flight start pipeline: a stale await
        // resuming later must abandon at its `startStillCurrent` check
        // instead of re-attaching plumbing for the deleted session.
        beginStartIntent()
        // Detach the transcript first (same order as the switch entry
        // points) — stopACP's attachment-gated "cancelled" bubble then
        // can't paint into the freshly-blanked transcript.
        richChatViewModel.reset()
        setInspectorFocus(.none)
        // Full teardown: bounded best-effort `session/cancel` if a turn
        // is in flight (lets Hermes finalize the orphaned turn before
        // the kill), then `client.stop()`. Also disarms the start
        // watchdog, cancels reconnects, and clears `isStartingSession`.
        stopACP()
        // stopACP leaves `acpStatus` at its last painted phase; the
        // pane is now an idle blank chat, so park the pill at idle the
        // same way the preflight bail does.
        acpStatus = ""
        if turnWasInFlight {
            richChatViewModel.transientHint = "Turn cancelled — session deleted."
            scheduleHintClear()
        }
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    // MARK: - Kanban toolset onboarding

    /// Per-host UserDefaults key. Includes the context id so users with
    /// multiple Hermes installations (local + SSH) get an independent
    /// teaching moment per host — the kanban toolset is per-config and
    /// won't necessarily be enabled on both.
    private var kanbanOnboardingDismissedKey: String {
        "scarf.kanbanOnboarding.dismissed.\(context.id.uuidString)"
    }

    /// Decide whether to surface the toolset-off teaching sheet after
    /// the user just sent `/goal`. Skipped when:
    /// - The host pre-dates v0.12 — kanban itself doesn't exist yet.
    /// - The user has dismissed this sheet on this host before.
    /// - The detector reports the toolset is already enabled (or the
    ///   detector couldn't classify, in which case we silently skip
    ///   rather than nag with a misleading banner).
    private func maybeTriggerKanbanOnboarding() {
        let dismissedKey = kanbanOnboardingDismissedKey
        if UserDefaults.standard.bool(forKey: dismissedKey) {
            return
        }
        let context = self.context
        Task { [weak self] in
            let detector = KanbanToolsetDetector(context: context)
            let state = await detector.detect()
            guard case .disabled = state else {
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.showKanbanOnboardingSheet = true
            }
        }
    }

    /// Called from the sheet's "Enable kanban tools" button. Runs the
    /// `hermes tools enable kanban --platform cli` shellout and sets a
    /// transient hint either way so the user gets a confirmation toast
    /// without having to re-open the sheet.
    func enableKanbanToolset() async {
        UserDefaults.standard.set(true, forKey: kanbanOnboardingDismissedKey)
        let enabler = KanbanToolsetEnabler(context: context)
        let result = await enabler.enable()
        await MainActor.run {
            switch result {
            case .enabled:
                richChatViewModel.transientHint =
                    "Kanban tools enabled. Start a new chat to pick this up."
            case .failed(let message):
                richChatViewModel.transientHint =
                    "Couldn't enable kanban tools: \(message)"
            }
            scheduleHintClear()
        }
    }

    /// Records the dismissal of the onboarding sheet (Skip /
    /// Open Tools paths). Navigation to the Tools tab from the
    /// "Open Tools…" button is the View's job (it has access to
    /// `AppCoordinator` via `@Environment`); the VM only persists the
    /// per-host suppression flag.
    func dismissKanbanToolsetOnboarding() {
        UserDefaults.standard.set(true, forKey: kanbanOnboardingDismissedKey)
    }

    // MARK: - Voice (terminal mode only)

    func toggleVoice() {
        guard let tv = terminalView else { return }
        if voiceEnabled {
            sendToTerminal(tv, text: "/voice off\r")
            voiceEnabled = false
            isRecording = false
        } else {
            sendToTerminal(tv, text: "/voice on\r")
            voiceEnabled = true
            ttsEnabled = fileService.loadConfig().autoTTS
        }
    }

    func toggleTTS() {
        guard let tv = terminalView, voiceEnabled else { return }
        sendToTerminal(tv, text: "/voice tts\r")
        ttsEnabled.toggle()
    }

    func pushToTalk() {
        guard let tv = terminalView, voiceEnabled else { return }
        let ctrlB: [UInt8] = [0x02]
        tv.send(source: tv, data: ctrlB[0..<1])
        isRecording.toggle()
    }

    // MARK: - Terminal Mode

    private func sendToTerminal(_ tv: LocalProcessTerminalView, text: String) {
        let bytes = Array(text.utf8)
        tv.send(source: tv, data: bytes[0..<bytes.count])
    }

    private func launchTerminal(arguments: [String]) {
        stopACP()

        if let existing = terminalView {
            existing.terminate()
            existing.removeFromSuperview()
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)

        let coord = Coordinator(onTerminated: { [weak self] in
            self?.hasActiveProcess = false
            self?.voiceEnabled = false
            self?.isRecording = false
            Task { await self?.richChatViewModel.refreshMessages() }
        })
        terminal.processDelegate = coord
        self.coordinator = coord

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Inherit ssh-agent socket for remote so password-less auth works.
        if context.isRemote {
            let shellEnv = HermesFileService.enrichedEnvironment()
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let v = shellEnv[key], !v.isEmpty {
                    env[key] = v
                }
            }
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // For remote: wrap the invocation in `ssh -t host -- hermes <args>`
        // so the embedded terminal opens a pty against the remote and the
        // hermes TUI gets the bytes it expects. `-t` requests a pty (the
        // SwiftTerm view is one).
        let exe: String
        let argv: [String]
        if context.isRemote, case .ssh(let cfg) = context.kind {
            let host = cfg.user.map { "\($0)@\(cfg.host)" } ?? cfg.host
            exe = "/usr/bin/ssh"
            var sshArgs: [String] = ["-t"]
            if let port = cfg.port { sshArgs += ["-p", String(port)] }
            if let id = cfg.identityFile, !id.isEmpty { sshArgs += ["-i", id] }
            sshArgs += ["-o", "StrictHostKeyChecking=accept-new"]
            sshArgs += ["-o", "BatchMode=yes"]
            sshArgs.append(host)
            sshArgs.append("--")
            sshArgs.append(context.paths.hermesBinary)
            sshArgs.append(contentsOf: arguments)
            argv = sshArgs
        } else {
            exe = context.paths.hermesBinary
            argv = arguments
        }

        terminal.startProcess(
            executable: exe,
            args: argv,
            environment: envArray,
            execName: nil
        )

        self.terminalView = terminal
        self.hasActiveProcess = true
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: () -> Void

        init(onTerminated: @escaping () -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1). Use the toolbar to start or resume a session.]\r\n")
            DispatchQueue.main.async { self.onTerminated() }
        }
    }
}
