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
    /// Internal (not private) so tests can swap in a service built on a
    /// recording transport — the only honest way to prove WHERE a config
    /// read ran (charter C10). Never reassigned in app code.
    var fileService: HermesFileService {
        // The chat reads config through the same service (tests swap it).
        didSet { focusedChat.fileService = fileService }
    }

    init(
        context: ServerContext = .local,
        voiceLive: VoiceLiveController? = nil
    ) {
        self.context = context
        self.voiceLive = voiceLive ?? VoiceLiveController()
        let dataService = HermesDataService(context: context)
        let fileService = HermesFileService(context: context)
        self.dataService = dataService
        self.fileService = fileService
        self.focusedChat = ChatSession(context: context, dataService: dataService, fileService: fileService)
        focusedChat.host = self

        // Probe hermes binary existence once off-main, then cache. Doing
        // this synchronously inside `hermesBinaryExists`'s getter would
        // block main on every chat-body re-evaluation — for a remote
        // context that's a SSH `test -e` round-trip on every streaming
        // chunk, which manifests as the chat screen flashing or going
        // blank during prompts.
        // The probe is a transport call (an SSH `test -e` on a remote), so
        // it gets a thread of its own, not a cooperative-pool one (C10).
        Task { [weak self, context] in
            // #100 — use the PATH-aware probe, not a raw fileExists. For a
            // remote server with no binaryHint, `paths.hermesBinary` is the
            // bare name "hermes"; `fileExists` would `test -e hermes` in the
            // remote cwd and report missing even when `command -v hermes`
            // resolves it and the ACP login-shell launch works fine. The
            // helper presumes bare names resolvable and defers the real
            // check to launch (whose failure path surfaces a clear hint).
            let exists = await OffPool.run { context.hermesBinaryProbablyResolvable() }
            self?.hermesBinaryExists = exists
        }
        // Cross-feature seam (t-5f1d9008): react when the Sessions tab
        // deletes the session this window's chat is attached to. Same
        // block-observer idiom as ServerLiveStatusRegistry (t-aud05):
        // queue .main → the block runs on the main thread, so
        // MainActor.assumeIsolated is safe and avoids a Task hop. The
        // payload is extracted OUTSIDE assumeIsolated (both values are
        // Sendable) so the non-Sendable Notification never crosses in.
        sessionDeletedObserver = NotificationCenter.default.addObserver(
            forName: SessionDeletedSignal.name, object: nil, queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?[SessionDeletedSignal.sessionIdKey] as? String,
                  let deletedContext = note.userInfo?[SessionDeletedSignal.contextKey] as? ServerContext
            else { return }
            MainActor.assumeIsolated {
                self?.handleSessionDeletedElsewhere(sessionId: sessionId, context: deletedContext)
            }
        }
        // Same seam for renames: keep this window's chat header title
        // live when the session is renamed from any surface.
        sessionRenamedObserver = NotificationCenter.default.addObserver(
            forName: SessionRenamedSignal.name, object: nil, queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?[SessionRenamedSignal.sessionIdKey] as? String,
                  let title = note.userInfo?[SessionRenamedSignal.titleKey] as? String,
                  let renamedContext = note.userInfo?[SessionRenamedSignal.contextKey] as? ServerContext
            else { return }
            MainActor.assumeIsolated {
                self?.handleSessionRenamedElsewhere(sessionId: sessionId, title: title, context: renamedContext)
            }
        }
    }

    /// Token for the `SessionDeletedSignal` observer. Block observers
    /// are retained by NotificationCenter for the process lifetime
    /// unless removed, and ChatViewModel is per-window (unlike the
    /// app-lifetime ServerLiveStatusRegistry), so unregister when the
    /// window's VM goes away.
    @ObservationIgnored
    private var sessionDeletedObserver: (any NSObjectProtocol)?
    @ObservationIgnored
    private var sessionRenamedObserver: (any NSObjectProtocol)?

    deinit {
        if let sessionDeletedObserver {
            NotificationCenter.default.removeObserver(sessionDeletedObserver)
        }
        if let sessionRenamedObserver {
            NotificationCenter.default.removeObserver(sessionRenamedObserver)
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
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    var displayMode: ChatDisplayMode = .richChat

    /// The chat this window shows: its transcript, its `hermes acp`
    /// connection and everything that runs on it. P0 of parallel chats: one
    /// per window for the VM's whole lifetime, never reassigned; a session
    /// switch reuses it (and its `RichChatViewModel`, via `reset()`).
    let focusedChat: ChatSession
    var richChatViewModel: RichChatViewModel { focusedChat.richChatViewModel }

    /// This window's Live Voice session (GPT-Live). This VM is its
    /// `VoiceTurnHost`: spoken requests become ordinary ACP turns in the
    /// attached chat. Ended on every session change and ACP teardown.
    let voiceLive: VoiceLiveController

    /// Raw `voice.voice_chat_mode` from config.yaml, read with the other
    /// config diagnostics (off-main). `nil` until the first read, which
    /// the readiness gate treats as chained (which now has an engine).
    var voiceChatModeRaw: String?

    /// Raw `tts.provider` from config.yaml, read alongside the mode. The
    /// chained voice panel names it in its privacy line, so the user can
    /// see who speaks the replies. `nil` until the first read.
    var voiceTTSProviderRaw: String?

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

    /// `model.provider: llamacpp` with a `model.base_url` a v0.21.1+ host
    /// ignores (`ModelPreflight.llamaCppBaseURLIgnored`, S06-F2). Drives a
    /// banner with a one-click switch to `custom`. Never migrated silently.
    var llamaCppBaseURLIgnored: Bool = false

    /// `model.provider` from config.yaml when this Hermes can't route it
    /// (`ModelPreflight.unroutableProvider`, S06-F1) — e.g. `mistral` saved
    /// by an older Scarf picker that listed every models.dev provider.
    /// Drives a warning banner with a "Choose model…" button. Nil when the
    /// provider routes, is unset, or Scarf has no table for the host
    /// (older than v0.6, or undetected).
    var unroutableProvider: String?

    /// The `approvals.mode` stored in config.yaml, read the way Hermes
    /// reads it (`HermesConfig.storedApprovalMode`: bare `false`/`no`/`off`
    /// are the `off` mode, unknown strings are `manual`), or nil when the
    /// key is absent (the host default, never `off`). Refreshed off
    /// MainActor alongside `modelProviderMismatch`. The chat header shows
    /// its YOLO warning badge when this is `.off` (S03-F3 — it used to
    /// check for a `"yolo"` value Hermes has never accepted).
    var approvalMode: HermesApprovalMode?

    /// Set when chat-start is blocked because the active server's
    /// `config.yaml` has no `model.default` / `model.provider`. The chat
    /// view observes this and presents `ChatModelPreflightSheet`; on
    /// successful pick we persist via `LocalModelConfigPlan` and re-attempt
    /// the original `startACPSession` call from `pendingStartArgs`.
    /// Nil when no preflight is pending.
    var modelPreflightReason: String?
    /// config.yaml's custom providers, from the last off-main config read —
    /// handed to the preflight sheet's picker so it doesn't treat a custom
    /// endpoint as unroutable.
    private(set) var customProviders: ModelPreflight.CustomProviders = .none

    /// Where a Scarf-started prompt came from. Live Voice cancels only
    /// turns it started itself (`cancelActiveVoiceTurn`).
    enum PromptTurnOrigin: Equatable {
        case typed
        case voice
    }

    /// Factory for the per-session `ACPClient`, as an override. Unset, the
    /// chat builds `ACPClient.forMacApp` (a `ProcessACPChannel` spawning
    /// `hermes acp`) with its own `environmentHintSlot`, so a project chat on
    /// a v0.16+ host carries its `HERMES_ENVIRONMENT_HINT` (#142); reading it
    /// returns that default. Tests inject scripted/hanging clients to
    /// exercise the watchdog, supersede, and teardown paths without a
    /// subprocess, and Bot Chat pins the agent to the bot's profile. An
    /// injected factory ignores the slot.
    var acpClientFactory: (ServerContext, String?) -> ACPClient {
        get {
            if let acpClientFactoryOverride { return acpClientFactoryOverride }
            let hintSlot = focusedChat.environmentHintSlot
            return { ctx, projectCwd in
                ACPClient.forMacApp(context: ctx, projectCwd: projectCwd, environmentHintSlot: hintSlot)
            }
        }
        set { acpClientFactoryOverride = newValue }
    }

    @ObservationIgnored
    private(set) var acpClientFactoryOverride: ((ServerContext, String?) -> ACPClient)?

    /// Optional interception point for `sendText`: when set and it returns
    /// `true`, the prompt was handled by an alternate transport and NONE of
    /// the ACP machinery runs — no `sendViaACP`, and crucially no
    /// `autoStartACPAndSend`. Installed by `BotConversationViewModel` while
    /// a bot's Bot Chat is being conversed with over the CLI transport
    /// (a CLI/gateway-born session Hermes' ACP adapter refuses to load —
    /// `acp_adapter/session.py:527`); for such a conversation an ACP
    /// auto-start would `session/new` a stray untitled session in the bot's
    /// profile and the prompt would never reach the bot. Routing at the
    /// `sendText` choke point (rather than only the bot composer's `onSend`)
    /// also covers every other UI path that funnels into `sendText` — the
    /// goal pill's clear button, the compress sheet.
    /// Nil (production main-Chat default) = unchanged behavior. Returning
    /// `false` lets the ordinary pipeline proceed.
    @ObservationIgnored
    var sendRouter: ((String, [ChatImageAttachment]) -> Bool)?

    /// Consulted in place of `autoStartACPAndSend` — the send made with no
    /// ACP client, typically after the reconnect ladder gave up. Returning
    /// true means the owner took the send. Bot Chat sets it: an autostart
    /// `session/load`s the bot's live id and, when that fails, falls back
    /// to `session/new` — a stray session outside the canonical Bot Chat
    /// that nothing re-verifies. Unlike `sendRouter` it leaves connected
    /// sends (and voice turns) alone.
    var autoStartInterceptor: ((String, [ChatImageAttachment]) -> Bool)?

    /// Consulted first by `stopCurrentTurn`. Bot Chat sets it while it
    /// converses over the CLI transport, where the running turn is a
    /// `hermes chat -Q` process, not an ACP prompt; returning true means
    /// the owner stopped it. `canStop` says whether a turn is running there.
    @ObservationIgnored
    var stopRouter: (canStop: () -> Bool, stop: () -> Bool)?

    /// Test seam for the model-config write shared by the preflight
    /// sheet and the mismatch banner's "Choose model…" flow
    /// (t-79569a15). Nil in production — `confirmModelPreflight`
    /// executes the plan via `fileService.applyModelConfigPlan` (real
    /// `hermes config set` subprocesses against the context's home).
    /// Tests inject a recorder so a simulated pick exercises the
    /// plan-routed path without shelling out to a hermes binary (which
    /// would ignore the temp-home override and write the developer's
    /// real ~/.hermes).
    @ObservationIgnored
    var modelConfigPlanApplier: (@Sendable ([LocalModelConfigPlan.Operation]) -> Bool)?

    /// Runs the `hermes sessions delete --yes <id>` CLI for
    /// `deleteSession(_:)` and returns its exit code. Production default
    /// shells out through the context's transport (same command path the
    /// Sessions feature uses); tests inject a stub so exercising the
    /// delete-active-session teardown (t-01bd55ec) doesn't spawn a real
    /// CLI process.
    ///
    /// Always called off the main actor (`deleteSession` hops to
    /// `OffPool`): on a remote host it is an SSH exec (charter C10).
    @ObservationIgnored
    var sessionDeleteRunner: @Sendable (ServerContext, String) -> Int32 = { ctx, sessionId in
        ctx.runHermes(SessionsViewModel.deleteArgv(sessionId: sessionId)).exitCode
    }

    /// Runs `hermes sessions rename -- <id> <title>` for `renameSession`
    /// and returns the CLI's output and exit code. Same seam shape as
    /// `sessionDeleteRunner`, and likewise always called off the main
    /// actor; tests stub it so no real CLI runs.
    @ObservationIgnored
    var sessionRenameRunner: @Sendable (ServerContext, String, String) -> (output: String, exitCode: Int32) = { ctx, sessionId, title in
        ctx.runHermes(SessionsViewModel.renameArgv(sessionId: sessionId, title: title))
    }

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
        Task { [weak self] in
            // `hasAnyAICredential` reads over the transport and, under a named
            // profile, may probe the host version — a thread of its own (C10).
            let missing = await OffPool.run { !svc.hasAnyAICredential() }
            self?.missingCredentials = missing
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
    /// Internal (not private) so tests can seed a roster without a
    /// models.dev catalog fixture on disk.
    var knownProviderIDs: Set<String>?

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
        let capabilities = capabilitiesStore?.capabilities ?? .empty
        // Each read (config, then the provider roster) on a thread of its
        // own; the decisions and the publish on the main actor (C10).
        Task { [weak self] in
            let config = await OffPool.run { svc.loadConfig() }
            var mismatch = ModelPreflight.detectMismatch(config, capabilities: capabilities)
            if mismatch != nil {
                var known = self?.knownProviderIDs
                if known == nil {
                    // Only trust the roster when the models.dev catalog
                    // actually loaded — an overlay-only result (fresh
                    // install, cache not yet written by Hermes) would
                    // mark real providers like `anthropic` unknown.
                    // Empty set = "catalog unavailable", cached so the
                    // (possibly SSH-backed) read isn't retried every
                    // refresh.
                    let loaded = await OffPool.run { () -> Set<String> in
                        let infos = ModelCatalogService(context: ctx).loadProviders(capabilities: capabilities)
                        return infos.contains(where: { !$0.isOverlay })
                            ? Set(infos.map(\.providerID))
                            : Set()
                    }
                    self?.knownProviderIDs = loaded
                    known = loaded
                }
                if let known, !known.isEmpty {
                    mismatch = ModelPreflight.detectMismatch(
                        config, knownProviders: known, capabilities: capabilities)
                }
            }
            let mode = config.storedApprovalMode
            let voiceChatMode = config.voice.voiceChatMode
            // The chained panel names the host's resolved TTS provider in
            // its privacy line; `nil` until the config has been read.
            let ttsProvider = config.voice.ttsProvider
            let resolvedMismatch = mismatch
            let llamaIgnored = ModelPreflight.llamaCppBaseURLIgnored(config, capabilities: capabilities)
            let unroutable = ModelPreflight.unroutableProvider(config, capabilities: capabilities)
            self?.customProviders = ModelPreflight.CustomProviders(config)
            self?.modelProviderMismatch = resolvedMismatch
            self?.llamaCppBaseURLIgnored = llamaIgnored
            self?.unroutableProvider = unroutable
            self?.approvalMode = mode
            self?.voiceChatModeRaw = voiceChatMode
            self?.voiceTTSProviderRaw = ttsProvider
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
        let capabilities = capabilitiesStore?.capabilities ?? .empty
        Task { [weak self] in
            let ok = await OffPool.run { () -> Bool in
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
                    current: svc.loadConfig(),
                    capabilities: capabilities
                )
                return !ops.isEmpty && svc.applyModelConfigPlan(ops)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A one-click banner fix is a `repaired` preflight outcome —
                // the config was wrong and the app corrected it in place,
                // without the user picking a model.
                Analytics.record(.modelPreflightResult(outcome: .repairedOrFailed(ok)))
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't write the new provider to config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// The llama.cpp banner's one-click fix: keep every local key and
    /// switch `model.provider` to `custom`, which honours `model.base_url`
    /// (S06-F2). Routed through the local write plan so the provider still
    /// commits last and any api_key / api_mode already present is kept.
    /// The plan's clear of `model.context_length` is dropped: this is the
    /// same server and model, so a user's context override still applies.
    func switchLlamaCppToCustom() {
        let svc = fileService
        let injected = modelConfigPlanApplier
        Task { [weak self] in
            // Config read + up to six `hermes config set` spawns: a thread of
            // their own, not the cooperative pool (C10).
            let ok = await OffPool.run {
                let config = svc.loadConfig()
                let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
                    providerID: "custom",
                    modelID: config.model == "unknown" ? "" : config.model,
                    baseURL: config.modelBaseURL,
                    apiKey: config.modelAPIKey,
                    apiMode: config.modelAPIMode
                )).filter { $0 != .clear(key: "model.context_length") }
                guard !ops.isEmpty else { return false }
                if let injected { return injected(ops) }
                return svc.applyModelConfigPlan(ops)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.llamaCppBaseURLIgnored = false
                    self.refreshConfigDiagnostics()
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
        let capabilities = capabilitiesStore?.capabilities ?? .empty
        Task { [weak self] in
            let ok = await OffPool.run { () -> Bool in
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
                    current: svc.loadConfig(),
                    capabilities: capabilities
                )
                return !ops.isEmpty && svc.applyModelConfigPlan(ops)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                Analytics.record(.modelPreflightResult(outcome: .repairedOrFailed(ok)))
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't rewrite model.default in config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// Banner-initiated "Choose model…" (t-79569a15) — the mismatch
    /// banner's honest escape hatch when neither one-click fix is right
    /// (and, for an unknown prefix, the only constructive path: the
    /// align button is hidden and stripping the prefix may still leave
    /// a model the active provider doesn't serve). Opens the same
    /// `ChatModelPreflightSheet` (full `ModelPickerSheet`, Local tab
    /// included) the missing-config preflight uses — `ChatView`'s
    /// sheet presents whenever `modelPreflightReason` is non-nil. The
    /// pick then applies through `confirmModelPreflight`'s plan-routed
    /// write path, whose success branch refreshes the config
    /// diagnostics so this banner re-evaluates (and clears). No start
    /// args are stashed: unlike the preflight bail there's no
    /// interrupted chat-start to replay.
    @MainActor
    func chooseModelForUnroutableProvider(_ provider: String) {
        focusedChat.pendingStartArgs = nil
        modelPreflightReason = String(localized: "This version of Hermes can't route the configured provider (\(provider)).")
    }

    /// Same escape hatch as `chooseModelForUnroutableProvider`, for the
    /// model/provider mismatch banner.
    @MainActor
    func chooseModelForMismatch(_ mismatch: ModelPreflight.Mismatch) {
        focusedChat.pendingStartArgs = nil
        modelPreflightReason = "The configured model (\(mismatch.modelDefault)) and provider (\(mismatch.activeProvider)) don't match."
    }

    /// Auto-clear the chat composer's transient hint (`ChatSession`).
    private func scheduleHintClear() {
        focusedChat.scheduleHintClear()
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
        // One event per user-initiated start. `origin` records the only
        // entry distinction the Mac can make honestly today: a chat opened
        // under a project scope vs. the global chat surface. The Kanban and
        // cron origins in the taxonomy have no macOS entry point into this
        // method — Kanban opens the chat window, which lands here as
        // `project` or `chat`, and cron sessions are created by Hermes
        // itself, never by this app.
        Analytics.record(.chatSessionStarted(
            mode: .new,
            origin: projectPath == nil ? .chat : .project
        ))
        focusedChat.beginSessionSwitch()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        // A voice session belongs to the chat it was started in.
        voiceLive.endImmediately()
        focusedChat.resetForSessionSwitch()

        if displayMode == .richChat {
            focusedChat.startACPSession(resume: nil, projectPath: projectPath, initialPrompt: initialPrompt)
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

    /// Resume an existing session.
    ///
    /// `origin` is the analytics attribution for the resulting
    /// `chat_session_started{mode: resume}`. It defaults to `"chat"` — a
    /// resume normally comes from the session list in the chat surface —
    /// and the error banner's Reconnect button passes `"error_retry"`
    /// instead: mechanically it's the same resume, but it's the user
    /// retrying a session that just broke, not opening one, and folding the
    /// two together inflates resume counts with failure recovery. The
    /// session's own project scope is only recovered later (asynchronously,
    /// from the attribution sidecar), and would describe the session rather
    /// than where the user was.
    func resumeSession(_ sessionId: String, origin: UsageEvent.ChatSessionOrigin = .chat) {
        Analytics.record(.chatSessionStarted(mode: .resume, origin: origin))
        // Explicit user action: clear any open SSH circuit breaker for
        // this host (gh#138) so the resume gets a real attempt instead of
        // an instant fail-fast from background-poller history.
        if case .ssh(let cfg) = context.kind {
            SSHConnectionGate.shared.reset(SSHConnectionGate.key(host: cfg.host, port: cfg.port))
        }
        focusedChat.beginSessionSwitch()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        // A voice session belongs to the chat it was started in.
        voiceLive.endImmediately()
        focusedChat.resetForSessionSwitch()

        if displayMode == .richChat {
            focusedChat.resumeACPSession(sessionId)
        } else {
            richChatViewModel.setSessionId(sessionId)
            launchTerminal(arguments: ["chat", "--resume", sessionId])
        }
    }

    func continueLastSession() {
        Analytics.record(.chatSessionStarted(mode: .continueLast, origin: .chat))
        let intent = focusedChat.beginSessionSwitch()
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        // A voice session belongs to the chat it was started in.
        voiceLive.endImmediately()
        focusedChat.resetForSessionSwitch()

        if displayMode == .richChat {
            focusedChat.continueLastACPSession(intent: intent)
        } else {
            launchTerminal(arguments: ["chat", "--continue"])
        }
    }

    // MARK: - Send Message

    /// How the user produced the prompt that's being sent. Analytics-only —
    /// nothing about the send behaves differently per case. `voice` is
    /// emitted by Live Voice turns (`submitVoiceTurn`); the Mac's older
    /// terminal voice mode (`sendToTerminal`) never reaches `sendText`.
    enum ChatInputMode: String {
        case typed
        case voice
        case quickCommand = "quick_command"
    }

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
    func sendText(
        _ text: String,
        images: [ChatImageAttachment],
        inputMode: ChatInputMode = .typed,
        recordAnalytics: Bool = true
    ) {
        // The `message_sent` emission site for typed and composer sends, and
        // deliberately the outermost one: `sendText` is reachable only from
        // user actions (the composer, the compress sheet, the goal pill's
        // clear button). The only other site is `submitVoiceTurn`, for a
        // spoken Live Voice request (`inputMode: .voice`), which never goes
        // through `sendText`.
        // Everything downstream — `sendViaACP`, `addUserMessage`, the wizard
        // kickoff replay, auto-resumed cron turns — can fire without a user
        // having sent anything, and must never count.
        //
        // Nothing derived from `text` is recorded: not its length, not its
        // first character, not whether it looked like a slash command.
        // `recordAnalytics: false` only for a send the user already made
        // once and an owner is re-delivering (Bot Chat's re-resolve).
        if recordAnalytics {
            Analytics.record(.messageSent(hasAttachment: !images.isEmpty, inputMode: inputMode))
        }
        // Alternate-transport hook (Bot Chat CLI delivery). Checked after
        // the analytics emission — it is still a user-sent message — and
        // before any ACP path, because for a routed conversation the ACP
        // fallback (`autoStartACPAndSend`) is precisely the bug being
        // prevented: a stray untitled `session/new` in the bot's profile.
        if let sendRouter, sendRouter(text, images) { return }
        if displayMode == .richChat {
            focusedChat.sendRichText(text, images: images, autoStartInterceptor: autoStartInterceptor)
        } else if let tv = terminalView {
            if !images.isEmpty {
                logger.warning("Terminal-mode chat dropped \(images.count) image attachment(s) — image input only works in ACP rich-chat mode")
                acpError = "Image attachments require ACP mode (rich chat)."
            }
            sendToTerminal(tv, text: text + "\r")
        }
    }

    /// Whether a mid-turn `/queue <text>` counts as an interruptive turn.
    ///
    /// Gateway-backed ACP from v0.22.3 runs it as its own admission and
    /// answers its `session/prompt` only when that queued prompt has run
    /// (acp_adapter/gateway_commands.py:286 → gateway_server.py:621-704 @
    /// v0.22.5), while the running turn's own call returns first. Counted
    /// as a turn, the queue keeps the chat working (and its chip up) until
    /// the queued prompt is done; counted as non-interruptive, the running
    /// turn's return ended the busy period with the queued prompt still to
    /// run. At v0.22.1 (the flag is on there too) the `/queue` prompt fails
    /// at once with `unsupported_command` (gateway_server.py:434-440 @
    /// v0.22.1): it then settles as a failed turn behind the running one,
    /// and the running turn's return ends the busy period as before.
    nonisolated static func queuedPromptHoldsTurn(
        name: String?,
        isNonInterruptive: Bool,
        wasAgentWorking: Bool,
        capabilities: HermesCapabilities
    ) -> Bool {
        name == "queue" && isNonInterruptive && wasAgentWorking && capabilities.hasGatewayBackedACP
    }

    /// The banner for a failed `session/set_model`, or nil when the user
    /// declined gateway-backed ACP's guarded-model confirmation
    /// (`model_switch_cancelled`, `set_session_model`,
    /// acp_adapter/gateway_server.py:483-485 @ v0.22.5): nothing changed,
    /// which is not an error.
    nonisolated static func modelSwitchFailureBanner(_ error: Error) -> String? {
        if ACPClientError.isGatewayRefusal(error, reason: "model_switch_cancelled") { return nil }
        return "Couldn't switch model: \(error.localizedDescription)"
    }

    /// The saved preset for Hermes's picker id (`provider:model`): same
    /// model, and the same provider unless the preset leaves it blank.
    nonisolated static func presetMatching(pickerId: String, in presets: [ModelPreset]) -> ModelPreset? {
        let model = ACPSessionState.modelName(fromPickerId: pickerId)
        let provider = ACPSessionState.providerID(fromPickerId: pickerId)
        return presets.first { preset in
            guard preset.modelID == model || preset.modelID == pickerId else { return false }
            let presetProvider = preset.providerID.trimmingCharacters(in: .whitespaces).lowercased()
            return presetProvider.isEmpty || provider == nil || presetProvider == provider
        }
    }

    /// What the badge shows for a session running `pickerId`: the matching
    /// preset; `nil` ("Default") when it is the config.yaml model; else
    /// the running model itself, as an unsaved entry no preset row checks.
    nonisolated static func badgePreset(pickerId: String, presets: [ModelPreset], configModel: String?) -> ModelPreset? {
        if let match = presetMatching(pickerId: pickerId, in: presets) { return match }
        let model = ACPSessionState.modelName(fromPickerId: pickerId)
        if let configModel, !configModel.isEmpty, configModel == model || configModel == pickerId { return nil }
        return ModelPreset(name: model, modelID: model, providerID: ACPSessionState.providerID(fromPickerId: pickerId) ?? "")
    }

    /// `provider:model` from Hermes's `/model` success reply, or nil.
    nonisolated static func modelSwitchPickerId(fromReply reply: String) -> String? {
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("Model switched to: ") else { return nil }
        let model = first.dropFirst("Model switched to: ".count).trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        if let providerLine = lines.dropFirst().first(where: { $0.hasPrefix("Provider: ") }) {
            let provider = providerLine.dropFirst("Provider: ".count).trimmingCharacters(in: .whitespaces).lowercased()
            if !provider.isEmpty { return "\(provider):\(model)" }
        }
        return model
    }

    /// Whether a prompt's wire text is `/model` with a model to switch to.
    nonisolated static func isModelSwitchCommand(_ wireText: String) -> Bool {
        let trimmed = wireText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/model") else { return false }
        let rest = trimmed.dropFirst("/model".count)
        guard let first = rest.first, first.isWhitespace else { return false }
        return !rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Model preflight

    /// Called by `ChatModelPreflightSheet` once the user has picked a
    /// model in the embedded `ModelPickerSheet`. Persists the choice via
    /// `hermes config set` (transport-aware — works on remote droplets
    /// too) and replays the pending `startACPSession` call so the chat
    /// the user originally tried to open finally lands.
    @MainActor
    func confirmModelPreflight(model: String, provider: String, local: LocalModelSelection? = nil) {
        let pending = focusedChat.pendingStartArgs
        modelPreflightReason = nil
        focusedChat.pendingStartArgs = nil

        let svc = fileService
        let apply: @Sendable ([LocalModelConfigPlan.Operation]) -> Bool =
            modelConfigPlanApplier ?? { svc.applyModelConfigPlan($0) }
        // Picks the `model.provider` a local row writes (llama.cpp →
        // `custom` on v0.21.1+, S06-F2).
        let capabilities = capabilitiesStore?.capabilities ?? .empty
        Task { [weak self] in
            let ok = await OffPool.run { () -> Bool in
                // Both branches route through the shared write plan (T4
                // audit): local picks carry keys `setModelAndProvider` can't
                // write (base_url et al.), and remote picks must scrub any
                // stale local-managed keys when the provider changes — a
                // provider=ollama config reached via preflight (e.g. its
                // model.default got emptied) would otherwise keep its
                // base_url into the new cloud provider. For a config with no
                // local keys the remote ops are exactly the classic
                // [set provider, set model] pair.
                //
                // Either overload may REFUSE with an empty plan (a switch
                // to a local provider with no sourceable base_url —
                // shouldn't be reachable through the picker, which
                // requires the base URL, but belt-and-braces): that's a
                // failed save, surfaced below.
                if let local {
                    let ops = LocalModelConfigPlan.operations(selecting: local, capabilities: capabilities)
                    return !ops.isEmpty && apply(ops)
                } else if provider.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Parity with setModelAndProvider's guard: the preflight
                    // must persist BOTH keys, so an empty provider is a
                    // failed save, not a model-only write.
                    return false
                } else {
                    let ops = LocalModelConfigPlan.operations(
                        selectingRemoteModel: model,
                        provider: provider,
                        current: svc.loadConfig(),
                        capabilities: capabilities
                    )
                    return !ops.isEmpty && apply(ops)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                Analytics.record(.modelPreflightResult(outcome: .confirmedOrFailed(ok)))
                if ok {
                    // The plan wrote a coherent model+provider pair —
                    // when the pick came from the mismatch banner's
                    // "Choose model…" the banner must re-evaluate.
                    // Clear eagerly, then re-read config.yaml for
                    // truth (t-79569a15).
                    self.modelProviderMismatch = nil
                    self.unroutableProvider = nil
                    self.refreshConfigDiagnostics()
                    if let pending {
                        self.focusedChat.startACPSession(
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
        Analytics.record(.modelPreflightResult(outcome: .cancelled))
        modelPreflightReason = nil
        focusedChat.pendingStartArgs = nil
    }

    /// Collapse an agent-supplied permission option id onto the taxonomy's
    /// two-value `decision`. The id itself is never recorded: Hermes picks
    /// those strings and a future one could carry anything.
    static func analyticsPermissionDecision(optionId: String, kind: String? = nil) -> UsageEvent.PermissionDecision {
        // The option's ACP kind decides when the request carried one
        // (`RichChatViewModel.permissionOptionAllows`): a clarify card's
        // `skip` is `reject_once` with no deny marker in its id.
        if let kind = kind?.lowercased(), !kind.isEmpty {
            return kind.hasPrefix("reject") ? .deny : .approve
        }
        let id = optionId.lowercased()
        // Substring match, not equality: Hermes ships `reject_once` /
        // `reject_always` alongside a bare `deny`. Deliberately no `"no"`
        // marker — it would swallow `allow_now`.
        for marker in ["deny", "reject", "decline", "cancel"] where id.contains(marker) {
            return .deny
        }
        return .approve
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
            if snapshot.queryError != nil {
                // A failed read (an SSH drop on a watcher tick) must not
                // blank a sidebar that loaded a moment ago; keep it and let
                // the next tick try again.
                await dataService.close()
                return
            }
            let fetchedSessions = snapshot.sessions
            let fetchedPreviews = snapshot.previews
            await dataService.close()

            // Project attribution + registry — single batched off-main read.
            let ctx = context
            let bundle: (names: [String: String], projects: [ProjectEntry]) = await OffPool.run {
                let attribution = SessionAttributionService(context: ctx)
                let registry = ProjectDashboardService(context: ctx).loadRegistry()
                // First row wins at a shared path; see `projectNames`.
                let names = SessionAttributionService.projectNames(
                    mappings: attribution.load().mappings,
                    projects: registry.projects
                )
                return (names: names, projects: registry.projects)
            }

            // Single batched commit — assigning all four observables at once
            // means SwiftUI sees one update rather than four staggered ones.
            // Eliminates the brief "list flashes / project chips appear
            // late" reload artifact during session switches.
            recentSessions = fetchedSessions
            sessionPreviews = fetchedPreviews
            sessionProjectNames = HermesSession.carryingLineageLabels(bundle.names, onto: fetchedSessions)
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
    ///
    /// The CLI runs off the main actor (S03-F4): it is a process spawn,
    /// and an SSH exec on a remote host, and used to freeze the whole
    /// window for the round trip. `isRenamingSession` is up while it runs
    /// so the sheet can't submit twice.
    @discardableResult
    func renameSession(_ sessionId: String, to newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear first — an empty title is a no-op, and a stale message
        // would read as a fresh failure.
        renameError = nil
        guard !trimmed.isEmpty, !isRenamingSession else { return false }
        isRenamingSession = true
        defer { isRenamingSession = false }
        // P47: `--` before the positionals, through the ONE argv builder the
        // Sessions pane already uses. `sessions rename` takes `session_id`
        // then `title` with `nargs="+"`
        // (`hermes_cli/subcommands/sessions.py:210-213` @ `v2026.9.7`), so a
        // title beginning with a dash exited 2 here while the identical
        // rename from the Sessions pane worked.
        let runner = sessionRenameRunner
        let ctx = context
        let result = await OffPool.run { runner(ctx, sessionId, trimmed) }
        guard result.exitCode == 0 else {
            // Hermes refuses some renames server-side — most notably the
            // canonical Bot Chat, whose title IS its identity. Surface the
            // reason instead of silently swallowing the failure, which is
            // what this path used to do (`SessionRenameFailure`).
            renameError = SessionRenameFailure.message(for: result.output)
            renameErrorSessionId = sessionId
            return false
        }
        renameError = nil
        if let idx = recentSessions.firstIndex(where: { $0.id == sessionId }) {
            recentSessions[idx] = recentSessions[idx].withTitle(trimmed)
        }
        sessionPreviews[sessionId] = trimmed
        focusedChat.applyRenameToAttachedSession(sessionId: sessionId, title: trimmed)
        // Broadcast so every OTHER surface showing this session — the
        // Sessions tab, another window's chat header — updates without
        // waiting for its next reload. Mirrors `SessionDeletedSignal`.
        NotificationCenter.default.post(
            name: SessionRenamedSignal.name,
            object: nil,
            userInfo: [
                SessionRenamedSignal.sessionIdKey: sessionId,
                SessionRenamedSignal.titleKey: trimmed,
                SessionRenamedSignal.contextKey: context,
            ]
        )
        return true
    }

    /// A rename landed on another surface (Sessions tab, another window).
    /// Update this window's caches and, when it's the attached session,
    /// the live header.
    private func handleSessionRenamedElsewhere(sessionId: String, title: String, context renamedContext: ServerContext) {
        guard renamedContext == context else { return }
        if let idx = recentSessions.firstIndex(where: { $0.id == sessionId }) {
            recentSessions[idx] = recentSessions[idx].withTitle(title)
        }
        sessionPreviews[sessionId] = title
        focusedChat.applyRenameToAttachedSession(sessionId: sessionId, title: title)
    }

    /// Why the last sidebar rename failed; `nil` once one succeeds or a
    /// new rename sheet opens. Rendered inside the rename sheet — read it
    /// through `renameError(for:)`.
    var renameError: String?

    /// The session the last rename failure belongs to. A rename that fails
    /// after the user cancelled its sheet and opened another one must not
    /// show its message in the new sheet (R10 carry-over).
    private(set) var renameErrorSessionId: String?

    /// `renameError`, only when it belongs to `sessionId`'s sheet.
    func renameError(for sessionId: String) -> String? {
        renameErrorSessionId == sessionId ? renameError : nil
    }

    /// True while a sidebar rename's CLI call is in flight.
    private(set) var isRenamingSession = false

    /// Apply a session title from an ACP `session_info_update` event
    /// (Hermes v0.16+). Mirrors `renameSession`'s in-place cache mutation
    /// so the sidebar reflects the new title immediately, but skips the
    /// `hermes sessions rename` CLI call — Hermes generated and persisted
    /// the title itself, so re-issuing the command would be redundant.
    /// Guards a nil/empty title so a "clear title" update is a no-op.
    func applySessionTitleUpdate(sessionId: String, title: String?) {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return }
        // `covers`: the update is keyed by the ACP id, an older segment of
        // a chain the sidebar lists under its tip after a rotation (R14-2).
        if let idx = recentSessions.firstIndex(where: { $0.covers(sessionId) }) {
            recentSessions[idx] = recentSessions[idx].withTitle(trimmed)
            sessionPreviews[recentSessions[idx].id] = trimmed
        } else {
            sessionPreviews[sessionId] = trimmed
        }
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
    ///
    /// The CLI runs off the main actor (t-fa0043f6; C10) — it is an SSH
    /// exec on a remote host. Whether the deleted session is the attached
    /// one is decided AFTER it returns, so a switch made while it ran is
    /// respected.
    func deleteSession(_ sessionId: String) async {
        await deleteSessionIds([sessionId])
    }

    /// Delete a sidebar row's whole conversation: every segment of a
    /// rotated compression chain, tip first (R14-3, `SessionChainDelete`).
    /// Deleting only the tip let Hermes orphan the earlier segments and
    /// the conversation reappeared under the previous one.
    func deleteConversation(_ session: HermesSession) async {
        await deleteSessionIds(SessionChainDelete.deletionOrder(lineage: session.lineageIds, rowId: session.id))
    }

    private func deleteSessionIds(_ ids: [String]) async {
        let runner = sessionDeleteRunner
        let ctx = context
        let outcome = await OffPool.run { SessionChainDelete.run(ids) { runner(ctx, $0) } }
        guard !outcome.deleted.isEmpty else {
            // Nothing was deleted. The row staying put is right; saying
            // nothing about it read as a UI glitch. Same wording as the
            // Sessions tab's delete error.
            if let failed = outcome.failed {
                richChatViewModel.transientHint = String(
                    localized: "Couldn't delete that session on \(ctx.displayName) (hermes sessions delete exited \(failed.exitCode))."
                )
                scheduleHintClear()
            }
            return
        }
        let deleted = Set(outcome.deleted)
        recentSessions.removeAll { deleted.contains($0.id) }
        for id in deleted {
            sessionPreviews.removeValue(forKey: id)
            sessionProjectNames.removeValue(forKey: id)
        }
        if richChatViewModel.transcriptSessionIds.contains(where: deleted.contains) {
            focusedChat.tearDownDeletedActiveSession()
        }
        if outcome.failed != nil {
            // Some segments went, the rest are still there (and chained):
            // reload so the list shows the shorter conversation, and say so.
            scheduleSessionsRefresh()
            richChatViewModel.transientHint = String(
                localized: "Deleted \(outcome.deleted.count) of \(ids.count) linked segments — the rest couldn't be deleted."
            )
            scheduleHintClear()
        }
        // Audit fix (t-5f1d9008 wave 1): this sidebar is ALSO an
        // independent delete surface for every OTHER window on the same
        // server/profile — two windows can be attached to the same
        // session, and pre-fix a sidebar delete here orphaned the other
        // window's `hermes acp` client exactly the way the Sessions tab
        // did. Broadcast the same signal `SessionsViewModel.confirmDelete`
        // posts, once per deleted id (success only). Posted AFTER the
        // local teardown so this window's own observer no-ops on its
        // `transcriptCovers` guard regardless of whether
        // NotificationCenter delivers the block synchronously or via a
        // queue hop.
        for id in outcome.deleted {
            NotificationCenter.default.post(
                name: SessionDeletedSignal.name,
                object: nil,
                userInfo: [
                    SessionDeletedSignal.sessionIdKey: id,
                    SessionDeletedSignal.contextKey: context,
                ]
            )
        }
    }

    /// Cross-feature seam (t-5f1d9008): the Sessions tab
    /// (`SessionsViewModel.confirmDelete`) is an independent delete
    /// surface that runs the same `hermes sessions delete` CLI but has
    /// no reference to this window's chat — pre-fix, deleting the
    /// chat-ATTACHED session there left the `hermes acp` client running
    /// against the deleted session (the exact leak/orphan shape
    /// t-01bd55ec fixed for the sidebar path). It posts
    /// `SessionDeletedSignal` after a successful CLI delete (as does
    /// `deleteSession(_:)` for other windows); every window's
    /// ChatViewModel observes, and only the ones whose chat is attached
    /// to that session react. Identity is the SESSION STORE the id
    /// lives in — `ServerContext.id` plus `paths.home` — not just the
    /// session id (different servers, or different profile homes on one
    /// server (#126), can each hold a session with the same id), and
    /// deliberately NOT full-struct `ServerContext` equality: the
    /// context also carries fields that don't move the session store
    /// (`displayName`, `SSHConfig.hermesBinaryHint`, `identityFile`,
    /// `projectsRoot`), and if any of those ever drifts between the
    /// poster's captured context and this VM's (registry edit /
    /// probe write-back while the window is open), full equality would
    /// silently SKIP the teardown — reintroducing the leaked-client
    /// orphan this seam exists to fix. (id, home) matches exactly when
    /// the two contexts read the same state.db. A non-matching
    /// session/store is a strict no-op for chat: the sidebar list
    /// refreshes through the state.db file watcher as usual.
    private func handleSessionDeletedElsewhere(
        sessionId: String, context deletedContext: ServerContext
    ) {
        guard deletedContext.id == context.id,
              deletedContext.paths.home == context.paths.home,
              richChatViewModel.sessionId != nil,
              richChatViewModel.transcriptCovers(sessionId) else { return }
        // Same cache purge deleteSession does for the row it removed.
        recentSessions.removeAll { $0.id == sessionId }
        sessionPreviews.removeValue(forKey: sessionId)
        sessionProjectNames.removeValue(forKey: sessionId)
        focusedChat.tearDownDeletedActiveSession()
    }

    /// The compression chain `sessionId` belongs to (root first), from the
    /// sidebar row that lists it or from any list Scarf has loaded this
    /// launch (`SessionLineageIndex`); empty for an ordinary session.
    func transcriptLineage(for sessionId: String) -> [String] {
        if let row = recentSessions.first(where: { $0.covers(sessionId) }), row.lineageIds.count > 1 {
            return row.lineageIds
        }
        return SessionLineageIndex.shared.lineage(server: context.id, sessionID: sessionId)
    }

    /// Whether this window's chat is attached to `session`'s conversation.
    /// Matches on the whole lineage (R14-2): a chain is listed under its
    /// TIP while the live chat keeps the ACP id it started with, which is
    /// an older segment once Hermes rotated mid-chat.
    func isAttached(to session: HermesSession) -> Bool {
        guard let attached = richChatViewModel.sessionId else { return false }
        return session.covers(attached)
            || richChatViewModel.transcriptSessionIds.contains(where: session.covers)
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

    /// The dismissal key for what the sheet showed. The Enable offer keeps
    /// the original key; the pre-0.21.5 explanation has its own.
    private func kanbanOnboardingDismissedKey(for prompt: KanbanChatToolsetPrompt?) -> String {
        prompt == .unavailableInChat
            ? kanbanOnboardingDismissedKey + ".pre0215"
            : kanbanOnboardingDismissedKey
    }

    /// Whether a `/goal` argument tail reads as "here is my target" rather
    /// than a clear. The only surviving reader of a `/goal` argument: it
    /// decides whether the kanban teaching sheet is worth raising, never
    /// what Scarf sends (the whole line goes to Hermes verbatim).
    static func goalArgumentDescribesATarget(_ raw: String) -> Bool {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lowered.isEmpty && lowered != "clear" && lowered != "--clear"
    }

    /// The version + dismissal half of the decision, pure so it can be tested
    /// without a host (the detector half needs a live config.yaml).
    ///
    /// **`hasKanban`, not "has a version".** Below the flag's floor there is
    /// no kanban at all, so the sheet has nothing to teach. (Its Enable
    /// button writes `platform_toolsets.acp` via `KanbanToolsetEnabler`, and
    /// only on 0.21.5+; below that the sheet explains instead — see
    /// `KanbanChatToolsetPrompt`.)
    ///
    /// `.empty` capabilities (not yet detected, or detection failed) are
    /// `false` on every flag, so an unwired window stays quiet rather than
    /// teaching a feature it cannot confirm exists.
    static func shouldOfferKanbanOnboarding(
        capabilities: HermesCapabilities, dismissed: Bool
    ) -> Bool {
        capabilities.hasKanban && !dismissed
    }

    /// Decide whether to surface the toolset-off teaching sheet after
    /// the user just sent `/goal`. Skipped when:
    /// - The host pre-dates **v0.13** — `hermes_cli/kanban.py` does not
    ///   exist at `v2026.4.30` (0.12.0) and the string `kanban` appears zero
    ///   times in its `commands.py` / `main.py`. At `v2026.5.7` (0.13.0)
    ///   `hermes_cli/kanban.py` exists AND the slash roster gains
    ///   `CommandDef("kanban", …)` — which lives in `hermes_cli/commands.py`
    ///   at `:163`, not in `kanban.py` (P59 cited the wrong file; P60
    ///   re-opened both tags). The release notes said 0.12, which is why the
    ///   flag's floor moved in P55 (charter C2) and why this comment said
    ///   0.12 until P59.
    /// - The user has dismissed this sheet on this host before.
    /// - The detector reports the toolset is already enabled (or the
    ///   detector couldn't classify, in which case we silently skip
    ///   rather than nag with a misleading banner).
    private func maybeTriggerKanbanOnboarding() {
        let capabilities = capabilitiesStore?.capabilities ?? .empty
        // Dismissal is recorded per prompt: acknowledging "needs 0.21.5" on
        // an older host must not suppress the Enable offer after an upgrade.
        guard Self.shouldOfferKanbanOnboarding(capabilities: capabilities, dismissed: false) else { return }
        let context = self.context
        let enableKey = kanbanOnboardingDismissedKey
        let unavailableKey = kanbanOnboardingDismissedKey(for: .unavailableInChat)
        Task { [weak self] in
            // Rich chat runs over ACP: on 0.21.5+ it reads
            // `platform_toolsets.acp`; below that no config gives it kanban
            // tools, and the sheet says so instead of offering Enable.
            let state = await KanbanToolsetDetector(context: context)
                .detectForChat(capabilities: capabilities)
            guard let prompt = KanbanChatToolsetPrompt.forState(state) else { return }
            let key = prompt == .unavailableInChat ? unavailableKey : enableKey
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            await MainActor.run {
                guard let self else { return }
                self.kanbanOnboardingPrompt = prompt
                self.showKanbanOnboardingSheet = true
            }
        }
    }

    /// What the onboarding sheet shows; set with `showKanbanOnboardingSheet`.
    var kanbanOnboardingPrompt: KanbanChatToolsetPrompt?

    /// Called from the sheet's "Enable kanban tools" button. Adds `kanban`
    /// to the chat platform's list in config.yaml (`KanbanToolsetEnabler`
    /// writes the YAML; `hermes tools enable` refuses kanban) and sets a
    /// transient hint either way so the user gets a confirmation toast
    /// without having to re-open the sheet.
    func enableKanbanToolset() async {
        UserDefaults.standard.set(true, forKey: kanbanOnboardingDismissedKey)
        // Only the offer-to-enable prompt carries a platform; below 0.21.5
        // there is nothing to write.
        guard case .offerEnable(let platform) = kanbanOnboardingPrompt else { return }
        let enabler = KanbanToolsetEnabler(context: context)
        let result = await enabler.enable(platform: platform)
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
        UserDefaults.standard.set(
            true, forKey: kanbanOnboardingDismissedKey(for: kanbanOnboardingPrompt))
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
            // C10: `loadConfig()` is a synchronous file read (an SSH
            // round-trip on a remote host) and blocked the click. Read it
            // off-main and settle the TTS chip when it lands — re-checking
            // `voiceEnabled`, since the user may have toggled voice back
            // off while the read was in flight.
            let svc = fileService
            Task { @MainActor [weak self] in
                let autoTTS = await OffPool.run { svc.loadConfig().autoTTS }
                guard let self, self.voiceEnabled else { return }
                self.ttsEnabled = autoTTS
            }
        }
    }

    func toggleTTS() {
        guard let tv = terminalView, voiceEnabled else { return }
        sendToTerminal(tv, text: "/voice tts\r")
        // Record only the on transition — `!ttsEnabled` here is "about to
        // become true" since the toggle happens on the next line.
        if !ttsEnabled {
            Analytics.record(.voiceUsed(kind: .tts))
        }
        ttsEnabled.toggle()
    }

    func pushToTalk() {
        guard let tv = terminalView, voiceEnabled else { return }
        let ctrlB: [UInt8] = [0x02]
        tv.send(source: tv, data: ctrlB[0..<1])
        // Record only when this press starts recording, not when it stops.
        if !isRecording {
            Analytics.record(.voiceUsed(kind: .pushToTalk))
        }
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
            // Pin the window's profile the same way `SSHTransport` does
            // (S13-F1) and put the install dirs on PATH (S15-F1). This path
            // builds its own ssh argv, so it gets neither from the transport;
            // ssh hands the words to the user's own shell (csh/tcsh too)
            // unwrapped — see `remoteLoginShellHermesWords`.
            sshArgs += context.remoteLoginShellHermesWords(args: arguments) ?? []
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

// MARK: - The focused chat (forwarding)
//
// Everything here belongs to the one chat this window shows and forwards to
// `focusedChat`, so views, Bot Chat, Live Voice and the tests keep talking to
// the window's VM unchanged.

extension ChatViewModel {
    var hasActiveProcess: Bool {
        get { focusedChat.hasActiveProcess }
        set { focusedChat.hasActiveProcess = newValue }
    }
    var isACPConnected: Bool { focusedChat.isACPConnected }
    var acpStatus: String {
        get { focusedChat.acpStatus }
        set { focusedChat.acpStatus = newValue }
    }
    var isStartingSession: Bool {
        get { focusedChat.isStartingSession }
        set { focusedChat.isStartingSession = newValue }
    }
    var isPreparingSession: Bool { focusedChat.isPreparingSession }
    var sessionStartWatchdogNanos: UInt64 {
        get { focusedChat.sessionStartWatchdogNanos }
        set { focusedChat.sessionStartWatchdogNanos = newValue }
    }
    var environmentHintSlot: EnvironmentHintSlot { focusedChat.environmentHintSlot }
    var autoAcceptEditsStore: ProjectAutoAcceptEditsStore {
        get { focusedChat.autoAcceptEditsStore }
        set { focusedChat.autoAcceptEditsStore = newValue }
    }

    var focusedToolCallId: String? {
        get { focusedChat.focusedToolCallId }
        set { focusedChat.focusedToolCallId = newValue }
    }
    var focusedToolCall: (call: HermesToolCall, result: HermesMessage?)? { focusedChat.focusedToolCall }
    var focusedUserMessageId: Int? {
        get { focusedChat.focusedUserMessageId }
        set { focusedChat.focusedUserMessageId = newValue }
    }
    var focusedUserMessage: HermesMessage? { focusedChat.focusedUserMessage }
    var inspectorMode: ChatInspectorMode { focusedChat.inspectorMode }
    func setInspectorFocus(_ mode: ChatInspectorMode) { focusedChat.setInspectorFocus(mode) }

    var currentProjectPath: String? { focusedChat.currentProjectPath }
    var currentGitBranch: String? { focusedChat.currentGitBranch }
    var currentProjectName: String? { focusedChat.currentProjectName }
    var currentModelPreset: ModelPreset? { focusedChat.currentModelPreset }
    var pendingSessionTitle: String? { focusedChat.pendingSessionTitle }
    var reconnectSessionId: String? { focusedChat.reconnectSessionId }

    func sendViaACP(
        client: ACPClient,
        text: String,
        images: [ChatImageAttachment] = [],
        localEchoAlreadyAdded: Bool = false,
        turnInFlight: Bool? = nil
    ) {
        focusedChat.sendViaACP(
            client: client, text: text, images: images,
            localEchoAlreadyAdded: localEchoAlreadyAdded, turnInFlight: turnInFlight
        )
    }
    func switchModelPreset(_ preset: ModelPreset?) { focusedChat.switchModelPreset(preset) }
    func switchApprovalMode(_ mode: ACPApprovalMode) { focusedChat.switchApprovalMode(mode) }
    func respondToPermission(requestId: Int, optionId: String) {
        focusedChat.respondToPermission(requestId: requestId, optionId: optionId)
    }
    func noteLoadedHead(_ head: String?) { focusedChat.noteLoadedHead(head) }

    /// Tear down the focused chat's ACP connection (`ChatSession.stop`):
    /// the bounded `session/cancel` of a turn in flight, `client.stop()`,
    /// and the "Turn cancelled — switched sessions." hint. P1 splits this
    /// from `stopAllChats()`, which in P0 is the same single chat.
    func stopACP() {
        focusedChat.stop()
    }

    /// Tear down every chat this window holds (window close, server
    /// switch). In P0 the window holds one chat, so this is `stopACP()`.
    func stopAllChats() {
        focusedChat.stop()
    }
}

// MARK: - ChatSessionHost

extension ChatViewModel: ChatSessionHost {
    func startNewSessionFromChat() {
        startNewSession()
    }

    func offerKanbanOnboarding() {
        maybeTriggerKanbanOnboarding()
    }

    func presentModelPreflight(reason: String?, customProviders: ModelPreflight.CustomProviders) {
        self.customProviders = customProviders
        modelPreflightReason = reason
    }

    func chatWillTearDown() {
        voiceLive.endImmediately()
    }

    func chatConnectionDied() {
        voiceLive.endForLostConnection()
    }
}

// MARK: - Live Voice (VoiceTurnHost)
//
// The conformance stays on the window's VM: the Live Voice controller is
// window-level and holds this as its host, and whether the chat may take
// voice turns depends on window state (`displayMode`, `sendRouter`). The turn
// bookkeeping it drives lives on `ChatSession` (its "Live Voice" section),
// beside the private ACP turn state typed turns use.

extension ChatViewModel: VoiceTurnHost {

    /// Why a voice turn couldn't be handed to Hermes. The engine speaks its
    /// "could not reach Hermes" line for any of them.
    enum VoiceTurnSubmitError: Error, Equatable {
        /// No rich-chat ACP session is attached (or this chat routes its
        /// sends elsewhere, like Bot Chat).
        case noSession
    }

    /// Whether this chat can take voice turns right now: rich chat, a live
    /// ACP client, an attached session, and no alternate send route.
    var canHostVoiceTurns: Bool {
        displayMode == .richChat
            && sendRouter == nil
            && focusedChat.hasLiveACPSession
    }

    /// The voice gate for this chat (P7b): Hermes ≥ 0.21.3 AND
    /// `voice.voice_chat_mode: gpt-live` mounts GPT-Live; any host that can
    /// speak (≥ 0.20.1) mounts the free chained engine; below that the
    /// composer entry is hidden entirely (C1).
    func voiceLiveAvailability(capabilities: HermesCapabilities) -> VoiceLiveAvailability {
        VoiceLiveReadiness.availability(capabilities: capabilities, voiceChatMode: voiceChatModeRaw)
    }

    /// Start a voice session in this chat, mounting whichever engine the
    /// readiness verdict names. No-op unless the chat can host voice turns,
    /// the host passes the gate, and no session is running.
    func startVoiceLive(capabilities: HermesCapabilities) {
        guard canHostVoiceTurns else { return }
        guard let engineKind = voiceLiveAvailability(capabilities: capabilities).engineKind else { return }
        voiceLive.start(context: context, host: self, engineKind: engineKind)
        // A start refused because another window holds the app's one
        // session has no panel to say so on (none was built): the
        // composer's transient hint carries the same sentence the button's
        // tooltip does.
        if voiceLive.consumeStartRefusal() == .blockedByAnotherWindow {
            richChatViewModel.transientHint = String(
                localized: "Live Voice is running in another Scarf window. End it there first."
            )
            scheduleHintClear()
        }
    }

    /// Leaving the chat pane — a sidebar section, terminal mode, the
    /// window closing. `endImmediately` alone kept the engine and its
    /// bridge (and the now-detached WKWebView) alive, so coming back into
    /// Chat re-rendered a stale "session ended" strip for a session the
    /// user had already walked away from. `dismiss` ends it AND drops
    /// both; the in-chat graceful End still keeps its panel up to show
    /// the outcome.
    func leaveChatVoiceLive() {
        voiceLive.dismiss()
    }

    /// The chat's root went away: the window closed, or a server/profile
    /// switch is rebuilding it. The `hermes acp` process belongs to this
    /// root — nothing can reach it once the root is gone — so it has to be
    /// torn down here or it survives as an orphan holding an SSH channel
    /// (and, on a wedged host, a reconnect ladder that retries into
    /// nothing). `stopAllChats` is the deliberate-teardown path
    /// (`ChatSession.stop` for each chat): it disarms the start watchdog,
    /// cancels the reconnect ladder, sends the bounded mid-turn
    /// `session/cancel`, and ends the Live Voice session
    /// (`endImmediately`). `leaveChatVoiceLive` then DROPS the voice
    /// engine and its web view, which `endImmediately` alone leaves
    /// attached. Idempotent: a second call finds no ACP client and does
    /// nothing.
    func leaveChat() {
        stopAllChats()
        leaveChatVoiceLive()
    }

    /// Continue on the Live Voice consent sheet: remember the consent, then
    /// start the session the user asked for.
    func acceptVoiceLiveConsent(capabilities: HermesCapabilities) {
        guard voiceLive.pendingConsent != nil else { return }
        voiceLive.acceptConsent()
        startVoiceLive(capabilities: capabilities)
    }

    /// A voice turn Scarf started is still running and nothing typed is
    /// mixed into its run (`ChatSession.isVoiceTurnBusy`).
    var isVoiceTurnBusy: Bool { focusedChat.isVoiceTurnBusy }

    /// Hermes is busy with something that isn't a voice turn
    /// (`ChatSession.isBusyWithNonVoiceTurn`).
    var isBusyWithNonVoiceTurn: Bool { focusedChat.isBusyWithNonVoiceTurn }

    /// What the voice says when a spoken request arrives while Hermes works
    /// on a typed one. Model input, not UI copy (the voice speaks it in the
    /// conversation's language), so English like the engine's own lines.
    static let voiceBusyReply = "Hermes is busy with another request in this chat, so I didn't send that. Ask me again when it's finished."

    var activeVoiceToolName: String? {
        if case .runningTool(let name) = richChatViewModel.liveActivityStatus { return name }
        return nil
    }

    /// The ACP session: Hermes keeps a cancelled turn's text per session,
    /// so the engine's "next voice turn goes text-only" debt is keyed by it
    /// and survives into the next voice session (`VoiceTextOnlyTurnLedger`).
    var voiceChatID: String? { richChatViewModel.sessionId }

    /// Hand a spoken request to the chat as an ordinary ACP turn
    /// (`ChatSession.submitVoiceTurn`), when it can host voice turns.
    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
        guard canHostVoiceTurns else {
            throw VoiceTurnSubmitError.noSession
        }
        try focusedChat.submitVoiceTurn(request)
    }

    /// Cancel the running voice turn and wait (bounded) for it to return
    /// (`ChatSession.cancelActiveVoiceTurn`).
    func cancelActiveVoiceTurn() async {
        await focusedChat.cancelActiveVoiceTurn()
    }

    // MARK: - Stop

    /// Whether the composer offers Stop: a turn Scarf started is running on
    /// the live ACP client (or on the owner's transport, via `stopRouter`).
    var canStopCurrentTurn: Bool {
        if let stopRouter { return stopRouter.canStop() }
        return focusedChat.canStopCurrentTurn
    }

    /// Stop the running turn and keep the session (S01-F2) —
    /// `ChatSession.stopCurrentTurn`, unless the owner's transport takes it
    /// (`stopRouter`). The `hermes acp` process stays up: this is not
    /// `stopACP`.
    func stopCurrentTurn() {
        if let stopRouter {
            _ = stopRouter.stop()
            return
        }
        focusedChat.stopCurrentTurn()
    }

    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? {
        focusedChat.voiceTurnReply(for: requestID)
    }

    /// The chat's user and assistant text turns, oldest first; tool rows,
    /// system notices and empty tool-call carriers are left out.
    func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] {
        richChatViewModel.messages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if message.isUser { return VoiceLiveText.SeedTurn(role: .user, text: text) }
            if message.isAssistant { return VoiceLiveText.SeedTurn(role: .assistant, text: text) }
            return nil
        }
    }

    /// How long a superseding voice turn waits for the cancelled turn to
    /// return. Hermes answers a cancel within a tool step; a turn stuck in a
    /// long tool call shouldn't hold the conversation longer than this.
    static let voiceCancelWaitSeconds: Double = 10

    /// Wait for `task` to finish, or `seconds`, whichever comes first. The
    /// task itself is never cancelled.
    nonisolated static func boundedWait(for task: Task<Void, Never>, seconds: Double) async {
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
                await task.value
                resumeOnce()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resumeOnce()
            }
        }
    }
}
