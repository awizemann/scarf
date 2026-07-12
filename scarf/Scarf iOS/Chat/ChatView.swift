import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign
import os
#if canImport(PhotosUI)
import PhotosUI
#endif

// The Chat feature on iOS is gated on `canImport(SQLite3)` because
// `RichChatViewModel` reads session history from `HermesDataService`
// (which is itself SQLite3-gated). iOS always has SQLite3 available,
// so on any real iOS build this renders normally. The guard exists
// so ScarfCore-agnostic static analysis doesn't choke.
#if canImport(SQLite3)

/// M4 iOS Chat: streams JSON-RPC over a Citadel SSH exec channel to a
/// remote `hermes acp` process. Reuses ScarfCore's `RichChatViewModel`
/// state machine (from M0d) + `ACPClient` (from M1).
///
/// Scope: one active session, rich-chat mode only (no terminal /
/// SwiftTerm mode). Permission prompts, tool-call display, markdown,
/// voice — all deferred to M5+ polish.
struct ChatView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle

    @Environment(\.scarfGoCoordinator) private var coordinator
    @Environment(\.serverContext) private var envContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var controller: ChatController
    @State private var showProjectPicker = false
    @State private var showSlashCommandsSheet = false
    /// Drives the inline slash-command autocomplete above the composer.
    /// Toggled by `RichChatViewModel.shouldShowSlashMenu(text:)` on draft
    /// changes — true only while the user is typing the command token
    /// (slash + no whitespace), hides once a space or newline appears.
    @State private var showSlashMenu = false
    /// PhotosPicker selection. Bridge between SwiftUI's selection
    /// binding and our `ChatImageAttachment` payload — `loadTransferable`
    /// produces raw `Data` we then hand to `ImageEncoder`. v0.12+ only.
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var isEncodingAttachment = false
    @State private var attachmentError: String?

    private static let maxAttachments = 5

    private var supportsImagePrompts: Bool {
        capabilitiesStore?.capabilities.hasACPImagePrompts ?? false
    }

    /// v0.13 `/goal` capability — drives the goal pill in `projectContextBar`.
    /// Read-only on iOS in v2.8.0; users send `/goal` from the Mac. The pill
    /// drops automatically when `vm.activeGoal` clears.
    private var supportsActiveGoal: Bool {
        capabilitiesStore?.capabilities.hasGoals ?? false
    }

    /// v0.13 ACP `/queue` capability — drives the queue-count chip. Tap is a
    /// no-op in v2.8.0 (no popover); previews live on the Mac app.
    private var supportsACPQueue: Bool {
        capabilitiesStore?.capabilities.hasACPQueue ?? false
    }

    /// Prefix-filtered slash command list driven by the current draft.
    /// Pulls from the shared `RichChatViewModel.availableCommands` (same
    /// merged + capability-gated list the Mac uses).
    private var filteredSlashCommands: [HermesSlashCommand] {
        let query = RichChatViewModel.slashMenuQuery(text: controller.draft)
        return RichChatViewModel.filterSlashCommands(
            controller.vm.availableCommands,
            query: query
        )
    }

    /// Names that render greyed-out + ignore taps. Matches the Mac's
    /// disabled gating exactly — `/steer` on pre-v0.13 idle sessions
    /// PLUS every agent-side command when there's no active session
    /// (P2 of the projects-feature fix).
    private var disabledSlashCommandNames: Set<String> {
        RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: controller.vm.isAgentWorking,
            hasActiveSession: controller.vm.sessionId != nil,
            capabilities: capabilitiesStore?.capabilities ?? .empty
        )
    }

    private var disabledSlashCommandReason: String? {
        RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: controller.vm.isAgentWorking,
            hasActiveSession: controller.vm.sessionId != nil,
            capabilities: capabilitiesStore?.capabilities ?? .empty
        )
    }
    /// Drives the composer's keyboard. Bound to the TextField via
    /// `.focused(...)`; cleared by the scroll-to-dismiss gesture on
    /// the message list AND by an explicit keyboard-toolbar button.
    /// (issue #51 — pre-fix the keyboard could never be dismissed,
    /// blocking access to the toolbar nav button on small phones.)
    @FocusState private var composerFocused: Bool

    init(config: IOSServerConfig, key: SSHKeyBundle) {
        self.config = config
        self.key = key
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _controller = State(initialValue: ChatController(context: ctx))
    }

    /// Same UUID DashboardView uses, so the transport's cached SSH
    /// connection (if still open) can be reused when the user hops
    /// between Chat and Dashboard.
    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        // ScarfMon body-evaluation counter. Re-render churn during
        // streaming is one of the load-bearing perf signals; rendering
        // here costs ~one signpost emit + ring-buffer append (off the
        // hot path otherwise).
        let _: Void = ScarfMon.event(.chatRender, "ios.ChatView.body")
        return VStack(spacing: 0) {
            connectionBanner
            errorBanner
            projectContextBar
            messageList
            Divider()
            if let hint = controller.vm.transientHint {
                steeringToast(hint)
            }
            composer
        }
        .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Principal: "Chat" title + small folder chip below when
            // the current session is project-attributed. iOS-native
            // equivalent of Mac's SessionInfoBar project-chip pattern.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showProjectPicker = true
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .disabled(controller.state == .connecting)
            }
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet(
                context: config.toServerContext(id: Self.sharedContextID),
                onQuickChat: {
                    Task { await controller.resetAndStartNewSession() }
                },
                onProject: { project in
                    Task { await controller.resetAndStartInProject(project) }
                }
            )
        }
        // Forward the env-injected capabilities snapshot into the
        // shared `RichChatViewModel` whenever it changes. Drives the
        // capability gate `RichChatViewModel.availableCommands` reads.
        // Mirrors the Mac `ChatView` plumbing — the iOS chat surface
        // doesn't render `/goal` / `/queue` UI yet (deferred to WS-9),
        // but the VM-side state has to stay aligned across platforms
        // so the Mac surface is correct after a cross-device session
        // resume.
        .task(id: capabilitiesStore?.capabilities.versionLine ?? "") {
            controller.vm.publishCapabilities(capabilitiesStore?.capabilities ?? .empty)
        }
        .task {
            // Dashboard row taps set `pendingResumeSessionID`, Project
            // Detail's "New Chat" sets `pendingProjectChat`. Both fire
            // a tab switch to .chat alongside the value set; we
            // consume + clear here on first appear. Resume wins over
            // project-chat if both somehow get set in a single hop —
            // but in practice the coordinator never sets both at once.
            if let sessionID = coordinator?.pendingResumeSessionID {
                coordinator?.pendingResumeSessionID = nil
                await controller.startResuming(sessionID: sessionID)
            } else if let projectPath = coordinator?.pendingProjectChat {
                coordinator?.pendingProjectChat = nil
                await consumePendingProjectChat(projectPath)
            } else {
                await controller.start()
            }
        }
        // React to coordinator changes that happen while Chat is
        // already mounted (e.g., user is in Chat, taps Projects, opens
        // a project detail, taps "New Chat" — coordinator flips the
        // tab AND sets pendingProjectChat. The `.task` above only
        // fires on first appear; these are the mid-session hooks.)
        .onChange(of: coordinator?.pendingResumeSessionID) { _, new in
            guard let sessionID = new else { return }
            coordinator?.pendingResumeSessionID = nil
            Task { await controller.startResuming(sessionID: sessionID) }
        }
        .onChange(of: coordinator?.pendingProjectChat) { _, new in
            guard let projectPath = new else { return }
            coordinator?.pendingProjectChat = nil
            Task { await consumePendingProjectChat(projectPath) }
        }
        // React to network reachability transitions. The service
        // updates its `transitionTick` on every `.satisfied <->
        // .unsatisfied` edge; the `.onChange` here funnels each
        // edge into ChatController so the reconnect machinery can
        // suspend on link-down and resume on link-up.
        .onChange(of: NetworkReachabilityService.shared.transitionTick) { _, _ in
            Task { await controller.handleReachabilityChange() }
        }
        // React to scene-phase transitions (background → active etc).
        // Source of truth is the coordinator, not `@Environment(\.scenePhase)`,
        // so the chat tab still picks up phase changes that happened
        // while it was unmounted (the user is on Dashboard when the
        // app backgrounds; sees Chat after resume).
        .onChange(of: coordinator?.scenePhaseTick) { _, _ in
            guard let phase = coordinator?.scenePhase else { return }
            Task { await controller.handleScenePhase(phase) }
        }
        // Deliberately NOT tearing down the ACP session on .onDisappear.
        // `TabView` unmounts tab content when the user switches tabs
        // (disappear fires), but `@State var controller` keeps the
        // ChatController alive across those switches, so dropping the
        // SSH exec channel + re-opening on next appear would cost the
        // user a ~1-2s reconnect every time they hop to Dashboard
        // and back. The ACPClient stays open; the controller cleans up
        // properly when:
        //   - the user Disconnects / Forgets the server (RootModel
        //     flips out of .connected, whole tab root unmounts, and
        //     ChatController.deinit + transport teardown runs),
        //   - or the app goes to background (iOS will terminate the
        //     socket eventually if memory pressure hits anyway).
        // If a future iPad / multi-window variant wants to explicitly
        // pause idle connections, add a coordinator-driven stop() on
        // app-lifecycle phase changes instead.
        .overlay {
            if case .failed(let msg) = controller.state {
                errorOverlay(msg)
            } else if controller.state == .connecting {
                connectingOverlay
            }
        }
        .sheet(isPresented: Binding(
            get: { controller.modelPreflightReason != nil },
            set: { newValue in
                if !newValue { controller.cancelModelPreflight() }
            }
        )) {
            IOSModelPreflightSheet(
                reason: controller.modelPreflightReason ?? "",
                serverDisplayName: controller.context.displayName,
                onSelect: { model, provider in
                    controller.confirmModelPreflight(model: model, provider: provider)
                },
                onCancel: { controller.cancelModelPreflight() }
            )
        }
        .sheet(item: Binding(
            get: { controller.vm.pendingPermission.map(PermissionWrapper.init) },
            set: { if $0 == nil { controller.vm.pendingPermission = nil } }
        )) { wrapper in
            PermissionSheet(permission: wrapper.value) { optionId in
                await controller.respondToPermission(
                    requestId: wrapper.value.requestId,
                    optionId: optionId
                )
            }
            // Custom detents — `.medium` is either too tall (empty
            // space above) or too short (options clipped). A 220pt
            // peek shows the prompt + first ~3 options; users can
            // drag to large for long option lists.
            .presentationDetents([.height(220), .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Resolve a project absolute path to a `ProjectEntry` via the
    /// transport-backed registry, then dispatch `resetAndStartInProject`.
    /// If the path isn't registered (race with a Mac-app removal, or
    /// SFTP read failure), fall back to a synthesized entry whose name
    /// is the path's last component — chat still starts and the user
    /// sees a usable project chip.
    private func consumePendingProjectChat(_ path: String) async {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        let entry: ProjectEntry = await Task.detached {
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            if let match = registry.projects.first(where: { $0.path == path }) {
                return match
            }
            return ProjectEntry(
                name: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent,
                path: path
            )
        }.value
        await controller.resetAndStartInProject(entry)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var messageList: some View {
        // Plain `VStack`, NOT `LazyVStack`. LazyVStack virtualizes
        // cells based on viewport, which collides with the
        // identity-churning streaming pattern: the streaming bubble
        // is appended at `id == 0`, then `finalizeStreamingMessage`
        // (RichChatViewModel.swift:1581-1596) replaces it with a
        // permanent id mid-ForEach. While the user is dragging,
        // SwiftUI's gesture handler and LazyVStack's cell
        // recycling race — observed by j@djinna.com 2026-05-12 as
        // hard crashes within 4s of session start on iPhone 17 Pro
        // Max / iOS 26.4.2. Plain VStack eagerly materializes the
        // full list; cost is bounded because `HistoryPageSize.initial`
        // caps initial load at 25 rows and `loadEarlier()` is a
        // user-driven action. Mac switched for the same reason — see
        // `RichChatMessageList.swift:26-42`.
        //
        // Follow-up: migrate iOS to `controller.vm.visibleGroups` so
        // the `RenderWindow` budget (30 rows) bounds memory on long
        // sessions. Requires an iOS-flavor `MessageGroupView`.
        ScrollView {
            VStack(spacing: 12) {
                if controller.vm.messages.isEmpty, controller.state == .ready {
                    if controller.vm.sessionId != nil {
                        // Resumed-session path: session ID is set but
                        // no messages loaded. ACP-native sessions don't
                        // persist their transcript to state.db (only
                        // CLI/terminal sessions do), so resuming one
                        // reconnects to the agent but can't surface
                        // the history client-side. Explain to the user
                        // rather than showing a blank canvas.
                        resumedEmptyState
                    } else {
                        emptyState
                    }
                }
                if controller.vm.hasMoreHistory {
                    loadEarlierButton
                }
                ForEach(controller.vm.messages) { msg in
                    MessageBubble(
                        message: msg,
                        turnDuration: controller.vm.turnDuration(forMessageId: msg.id),
                        loadFullReasoning: { await controller.vm.reasoningContent(for: msg.id) }
                    )
                    .equatable()
                    .id(msg.id)
                }
                if controller.vm.isGenerating {
                    HStack {
                        ProgressView()
                        Text("Agent is thinking…")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                } else if controller.vm.isPostProcessing {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Finishing up…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        // iOS 17+ keeps the scroll pinned to the newest content at
        // the bottom on row insertion. Replaces the old manual
        // proxy.scrollTo dance which fought with the user's own
        // scroll gestures.
        //
        // The iOS 18 `.sizeChanges` variant was dropped — combined
        // with plain VStack + per-chunk streaming mutations it
        // re-anchored on every content-size delta, which was
        // visible as a "jiggle" on long replies AND was the
        // suspected co-conspirator in the LazyVStack scroll crashes
        // (mid-drag re-anchor + identity churn). Plain `.bottom`
        // is sufficient: on row insertion the anchor lands the new
        // content at the bottom edge, and content growth on the
        // last row (the streaming bubble expanding) naturally
        // extends below the viewport — which is the right behavior
        // when the user has scrolled away from the tail.
        .defaultScrollAnchor(.bottom)
        // Drag the messages downward to interactively collapse the
        // keyboard — the standard iOS chat gesture. Without this the
        // keyboard could never be dismissed once it rose, hiding the
        // top-trailing nav button on small phones (issue #51).
        .scrollDismissesKeyboard(.interactively)
    }

    /// "Load earlier messages" affordance pinned above the oldest
    /// loaded bubble. Only rendered when `vm.hasMoreHistory == true`,
    /// so it disappears organically once the user has paged back to
    /// the start of the session.
    @ViewBuilder
    private var loadEarlierButton: some View {
        Button {
            Task { await controller.vm.loadEarlier() }
        } label: {
            HStack(spacing: 6) {
                if controller.vm.isLoadingEarlier {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(.caption)
                }
                Text(controller.vm.isLoadingEarlier ? "Loading earlier…" : "Load earlier messages")
                    .font(.caption)
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(controller.vm.isLoadingEarlier)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask Hermes something")
                .font(.headline)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Connected to \(config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Friendlier-than-blank state for a session resumed from the
    /// Dashboard that had no transcript persisted to `state.db`.
    /// Hermes doesn't write ACP-native session messages to the
    /// client DB — only CLI/terminal sessions leave a history there —
    /// so resuming a "recent session" started via Chat means the
    /// agent has the context but the client can't replay it. The
    /// user can keep chatting and the agent will have full memory.
    @ViewBuilder
    private var resumedEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Session resumed")
                .font(.headline)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Hermes has the context for this session, but the transcript isn't cached locally. Send a message to continue.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Top-of-screen banner for transient connection states. `.failed`
    /// keeps using the existing full-screen overlay (so the user has
    /// somewhere obvious to tap "Retry"); `.reconnecting` and
    /// `.offline` are non-modal so the user can keep reading the
    /// transcript while we work in the background.
    @ViewBuilder
    private var connectionBanner: some View {
        switch controller.state {
        case .reconnecting(let attempt, let total):
            // `attempt == 0` is the "paused on background" sentinel set
            // by `pauseInBackground` — we haven't started a real attempt
            // yet, just demoted out of `.ready` so the send button isn't
            // a silent no-op while client is nil. Show neutral copy until
            // `attemptReconnect` actually fires on `.active`.
            connectionBannerStrip(
                text: attempt == 0 ? "Resuming…" : "Reconnecting (\(attempt)/\(total))…",
                tint: ScarfColor.warning,
                showSpinner: true
            )
        case .offline(let reason):
            connectionBannerStrip(
                text: reason,
                tint: ScarfColor.danger,
                showSpinner: false
            )
        default:
            // v2.7: surface "Thinking…" while the agent's thought
            // stream is in flight without any visible message bytes.
            // Hermes reasoning models commonly take 3–8 s here and
            // the streaming bubble has nothing to render — the user
            // would otherwise see a stalled transcript. Disappears
            // the moment the first message chunk arrives.
            if controller.vm.isStreamingThoughtsOnly {
                connectionBannerStrip(
                    text: "Thinking…",
                    tint: ScarfColor.info,
                    showSpinner: true
                )
            } else if controller.vm.isHydratingTools {
                // v2.7 — Phase 2 tool-call hydration is in flight.
                // Bare conversation skeleton is already on screen;
                // this banner tells the user the tool cards are
                // about to fill in.
                connectionBannerStrip(
                    text: "Loading tool details…",
                    tint: ScarfColor.info,
                    showSpinner: true
                )
            } else {
                EmptyView()
            }
        }
    }

    private func connectionBannerStrip(
        text: String,
        tint: Color,
        showSpinner: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(tint)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.16))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    /// Soft pill above the composer confirming a non-interruptive
    /// command was received (e.g. `/steer`). Auto-clears via the
    /// 4-second Task in `ChatController.send()`.
    private func steeringToast(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12))
        .transition(.opacity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if showSlashMenu {
                IOSSlashCommandMenu(
                    commands: filteredSlashCommands,
                    agentHasCommands: !controller.vm.availableCommands.isEmpty,
                    disabledCommandNames: disabledSlashCommandNames,
                    disabledReason: disabledSlashCommandReason,
                    onSelect: { command in
                        controller.insertSlashCommand(command)
                        showSlashMenu = false
                        composerFocused = true
                    }
                )
                .background(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg)
                        .strokeBorder(ScarfColor.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !controller.attachments.isEmpty || isEncodingAttachment || attachmentError != nil {
                attachmentStrip
            }
            composerRow
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.top, ScarfSpace.s2)
        .padding(.bottom, ScarfSpace.s2)
        .background(.regularMaterial)
        .onChange(of: controller.draft) { _, newValue in
            let next = RichChatViewModel.shouldShowSlashMenu(text: newValue)
            if next != showSlashMenu {
                showSlashMenu = next
            }
        }
        #if canImport(PhotosUI)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerSelection,
            maxSelectionCount: max(0, Self.maxAttachments - controller.attachments.count),
            matching: .images
        )
        .onChange(of: pickerSelection) { _, items in
            ingestPickerItems(items)
        }
        #endif
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            if isEncodingAttachment {
                ProgressView().controlSize(.small)
                Text("Encoding…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.attachments) { attachment in
                attachmentChip(attachment)
            }
            if let err = attachmentError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(ScarfColor.danger)
            }
            Spacer(minLength: 0)
            if !controller.attachments.isEmpty {
                Text("\(controller.attachments.count)/\(Self.maxAttachments)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: ChatImageAttachment) -> some View {
        HStack(spacing: 4) {
            attachmentChipThumbnail(attachment)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                controller.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached image")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ScarfColor.backgroundSecondary)
        )
    }

    @ViewBuilder
    private func attachmentChipThumbnail(_ attachment: ChatImageAttachment) -> some View {
        if let thumb = attachment.thumbnailBase64,
           let data = Data(base64Encoded: thumb),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ScarfColor.backgroundSecondary)
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: ScarfSpace.s2) {
            if supportsImagePrompts {
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(
                            attachDisabled
                                ? ScarfColor.foregroundFaint
                                : ScarfColor.foregroundMuted
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attachDisabled)
                .accessibilityLabel("Attach image")
            }
            // Inline keyboard-dismiss affordance, shown only while the
            // composer is focused. It lives here — a plain button in the
            // composer row — rather than in a `.toolbar(placement:
            // .keyboard)` accessory bar. That accessory sits directly
            // above the keyboard, but so does this composer (last child
            // of the body VStack, lifted by keyboard avoidance), so the
            // two collided: iOS 26.5 drew the accessory's chevron on top
            // of the paperclip and the paperclip stole its taps (the
            // gh#107 regression). A normal sibling button can't overlap
            // and always receives its own tap. Swipe-down still works on
            // a scrollable transcript via `.scrollDismissesKeyboard`;
            // this button covers the empty / resumed-empty state where
            // there's nothing to scroll.
            if composerFocused {
                Button {
                    composerFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")
                .transition(.opacity)
            }
            TextField(
                "Message…",
                text: $controller.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                    .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
            )
            .disabled(controller.state != .ready)
            .submitLabel(.send)
            .focused($composerFocused)
            .onSubmit {
                Task { await controller.send() }
            }
            // Persist the half-typed message across app suspensions
            // and force-quits. Debounced inside `scheduleDraftSave`
            // so we coalesce per-keystroke writes.
            .onChange(of: controller.draft) { _, _ in
                controller.scheduleDraftSave()
            }

            // Big circular send button. Filled with the brand accent when
            // ready, swapped to a flat gray when disabled — opacity dims
            // alone read as "not quite tappable" (issue #69), the explicit
            // color swap makes the state unambiguous in both light and
            // dark mode.
            Button {
                Task { await controller.send() }
            } label: {
                ZStack {
                    Circle()
                        .fill(canSendComposer
                              ? ScarfColor.accent
                              : ScarfColor.backgroundTertiary)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSendComposer
                                         ? ScarfColor.onAccent
                                         : ScarfColor.foregroundFaint)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .animation(ScarfAnimation.fast, value: canSendComposer)
            }
            .buttonStyle(.plain)
            .disabled(!canSendComposer)
            .accessibilityLabel("Send message")
        }
        // Fade the dismiss button in/out as focus changes so the
        // TextField's width shift rides the keyboard slide instead of
        // popping.
        .animation(ScarfAnimation.fast, value: composerFocused)
    }

    /// Send is enabled when ready AND we have either text or at least
    /// one attachment. Image-only sends are valid for vision models.
    private var canSendComposer: Bool {
        guard controller.state == .ready else { return false }
        if !controller.attachments.isEmpty { return true }
        return !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Mirror of the `.disabled(...)` predicate on the paperclip button.
    /// Pulled out so the button's foreground branch reads cleanly.
    private var attachDisabled: Bool {
        controller.state != .ready || controller.attachments.count >= Self.maxAttachments
    }

    /// Pull JPEG/PNG bytes out of each PhotosPickerItem and feed them
    /// through ImageEncoder. Detached so the heavyweight resize +
    /// JPEG-encode work doesn't block MainActor; the resulting
    /// attachment hops back to MainActor for state mutation.
    ///
    /// PhotosPickerItem can deliver `Data` directly via the
    /// `Transferable` API. After ingestion the binding is reset so a
    /// follow-up pick triggers `onChange` again.
    #if canImport(PhotosUI)
    private func ingestPickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        // Cap up front and snapshot so the slot calculation is honest under
        // concurrent ingestion (we'd otherwise have to re-check
        // controller.attachments.count after every parallel completion).
        let remainingSlots = Self.maxAttachments - controller.attachments.count
        let snapshot = Array(items.prefix(max(remainingSlots, 0)))
        // Clear the binding immediately so a follow-up pick triggers onChange
        // even when the user re-selects the same image set (PhotosPicker
        // doesn't re-fire onChange unless the binding flips through nil).
        pickerSelection = []
        guard !snapshot.isEmpty else { return }
        isEncodingAttachment = true
        Task { @MainActor in
            // Run loadTransferable + encode for each item in parallel.
            // iCloud-backed PHAssets are network-bound, so 5 picks finish
            // closer to 1 round-trip than 5 sequential ones. Errors carry
            // a Sendable String (not the Error itself) since `any Error`
            // isn't Sendable under strict concurrency.
            let outcomes = await withTaskGroup(
                of: (index: Int, attachment: ChatImageAttachment?, errorMessage: String?).self
            ) { group in
                for (index, item) in snapshot.enumerated() {
                    group.addTask {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                return (index, nil, nil)
                            }
                            let attachment = try await Task.detached(priority: .userInitiated) {
                                try ImageEncoder().encode(rawBytes: data, sourceFilename: nil)
                            }.value
                            return (index, attachment, nil)
                        } catch {
                            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't encode image"
                            return (index, nil, message)
                        }
                    }
                }
                var rows: [(index: Int, attachment: ChatImageAttachment?, errorMessage: String?)] = []
                for await row in group { rows.append(row) }
                return rows.sorted { $0.index < $1.index }
            }
            var firstError: String?
            for outcome in outcomes {
                if let attachment = outcome.attachment {
                    controller.attachments.append(attachment)
                } else if firstError == nil, let message = outcome.errorMessage {
                    firstError = message
                }
            }
            if let firstError {
                attachmentError = firstError
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    attachmentError = nil
                }
            }
            isEncodingAttachment = false
        }
    }
    #endif

    @State private var showErrorDetails: Bool = false

    /// Inline error banner rendered above the message list when the
    /// ACP layer signals a non-retryable failure (provider HTTP 4xx,
    /// malformed model, missing credentials…). Mirrors the Mac pattern
    /// in scarf/scarf/Features/Chat/Views/ChatView.swift:errorBanner;
    /// both now pull from RichChatViewModel's shared error triplet.
    /// Pass-1 M7 #2 — previously errors vanished into stderr and the
    /// user saw a perpetual spinner.
    @ViewBuilder
    private var errorBanner: some View {
        if let err = controller.vm.acpError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let hint = controller.vm.acpErrorHint {
                            Text(hint)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .textSelection(.enabled)
                            .lineLimit(showErrorDetails ? nil : 2)
                    }
                    Spacer(minLength: 4)
                    if controller.vm.acpErrorDetails != nil {
                        Button(showErrorDetails ? "Hide" : "Details") {
                            showErrorDetails.toggle()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    Button {
                        let payload = [
                            controller.vm.acpErrorHint,
                            err,
                            controller.vm.acpErrorDetails
                        ]
                            .compactMap { $0 }
                            .joined(separator: "\n\n")
                        UIPasteboard.general.string = payload
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if showErrorDetails, let details = controller.vm.acpErrorDetails {
                    ScrollView(.vertical) {
                        Text(details)
                            .font(.caption2.monospaced())
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
        }
    }

    /// Contextual header rendered BELOW the navigation bar when the
    /// current session is scoped to a Scarf project. Sits full-width
    /// so the project name has room to breathe (the nav bar's
    /// `.principal` slot gets squeezed to icon-only by adjacent
    /// toolbar buttons on iPhone — exactly the pass-2 bug). Drawn as
    /// a subtle tinted strip so it doesn't dominate but is clearly
    /// informational.
    @ViewBuilder
    private var projectContextBar: some View {
        // v2.8.0 (WS-9): the bar is no longer project-only — a non-empty
        // active goal OR a non-empty queue mirror also light it up. Project
        // chip, goal pill, and queue chip render independently and the bar
        // shows when ANY of them is present.
        let projectName = controller.currentProjectName ?? ""
        let hasProject = !projectName.isEmpty
        let hasGoal = supportsActiveGoal && controller.vm.activeGoal != nil
        let hasQueue = supportsACPQueue && !controller.vm.queuedPrompts.isEmpty
        if hasProject || hasGoal || hasQueue {
            HStack(spacing: 8) {
                if hasProject {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Project chat")
                            .font(.caption2)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        HStack(spacing: 6) {
                            Text(projectName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let branch = controller.currentGitBranch, !branch.isEmpty {
                                Label(branch, systemImage: "arrow.triangle.branch")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                                    .labelStyle(.titleAndIcon)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: Capsule())
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if hasGoal { goalChip }
                if hasQueue { queueChip }
                Spacer()
                if hasProject && !controller.vm.projectScopedCommands.isEmpty {
                    Button {
                        showSlashCommandsSheet = true
                    } label: {
                        Label(
                            "\(controller.vm.projectScopedCommands.count) slash",
                            systemImage: "slash.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.1))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hasGoal)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hasQueue)
            .sheet(isPresented: $showSlashCommandsSheet) {
                ProjectSlashCommandsBrowser(
                    projectName: projectName,
                    commands: controller.vm.projectScopedCommands
                )
            }
        }
    }

    /// v0.13 goal pill — purely informational mirror of the agent's
    /// currently-locked `/goal`. Read-only on iOS; `/goal --clear` lives on
    /// the Mac app and the pill drops on the next VM update. Semantic
    /// `.subheadline` font so the goal text scales with Dynamic Type
    /// (it's content the user reads, not chrome). VoiceOver gets the full
    /// untruncated text via the accessibility label.
    @ViewBuilder
    private var goalChip: some View {
        if let goal = controller.vm.activeGoal {
            Label(truncatedGoalText(goal.text), systemImage: "scope")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(ScarfColor.info)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ScarfColor.info.opacity(0.16), in: Capsule())
                .lineLimit(1)
                .accessibilityLabel("Goal locked: \(goal.text)")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    /// v0.13 queue chip — read-only count of prompts queued via `/queue`.
    /// Tap is a no-op in v2.8.0 (no popover); the source of truth lives on
    /// the Mac app. Defaults to one fixed pill regardless of count.
    @ViewBuilder
    private var queueChip: some View {
        let count = controller.vm.queuedPrompts.count
        if count > 0 {
            Label("\(count) queued", systemImage: "tray.full")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.18), in: Capsule())
                .lineLimit(1)
                .accessibilityLabel("\(count) prompt\(count == 1 ? "" : "s") queued — manage on the Mac app")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    /// Trim long goal text to fit a chip beside the project name on iPhone
    /// portrait. The full text rides VoiceOver via the chip's accessibility
    /// label.
    private func truncatedGoalText(_ text: String) -> String {
        text.count <= 28 ? text : String(text.prefix(25)) + "…"
    }

    /// Shown while we're opening the SSH exec channel + spawning
    /// `hermes acp` + creating the ACP session. Typically ~0.5–1.5 s
    /// on a warm network — silent before this overlay existed, which
    /// made the app feel frozen (pass-1 M7 #3).
    @ViewBuilder
    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(config.displayName)…")
                .font(.callout)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Chat connection failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal)
            Button("Retry") {
                Task { await controller.start() }
            }
            .buttonStyle(ScarfPrimaryButton())
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}

// MARK: - ChatController

/// Owns the ACPClient + RichChatViewModel lifecycle for one iOS chat
/// screen. Kept out of `ChatView.body` so SwiftUI view re-renders don't
/// spawn or tear down SSH connections unintentionally.
@Observable
@MainActor
final class ChatController {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        /// Mid-recovery: the SSH exec channel died but the agent on
        /// the remote may still be running. We're trying to reattach
        /// via `session/resume` (or `session/load` as a fallback).
        case reconnecting(attempt: Int, of: Int)
        /// Network reachability is unsatisfied. Distinct from
        /// `.failed` so the banner can stay tinted yellow ("we'll
        /// retry") instead of red ("dead").
        case offline(reason: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var vm: RichChatViewModel
    var draft: String = ""

    /// v0.12+ image attachments queued to send with the next prompt.
    /// Capped at 5 by the composer UI; the cap matches the Mac behavior
    /// and keeps total ACP prompt payload under ~2 MB even on a slow
    /// cellular link. Cleared after each successful `send()`.
    var attachments: [ChatImageAttachment] = []

    /// Set when chat-start is blocked because the active server's
    /// `config.yaml` has no `model.default` / `model.provider`. ChatView
    /// observes this to present an inline "pick a model" sheet — the
    /// Mac picker UI doesn't ship on iOS today, so the iOS sheet
    /// captures model + provider as text fields and persists them via
    /// the same `hermes config set` path. Reset on cancel or after a
    /// successful retry.
    var modelPreflightReason: String?

    /// Stash of the original chat-start intent while we wait for the
    /// user to fill in a model. Captured by the gate inside `start`,
    /// `startInternal`, `startResuming`; replayed verbatim once
    /// `confirmModelPreflight` writes the chosen values to config.yaml
    /// so the chat the user originally tried to open lands without
    /// them having to click the project row again.
    private enum PendingStart {
        case fresh
        case project(path: String, name: String)
        case resume(sessionID: String)
    }
    private var pendingStartIntent: PendingStart?
    /// Display name of the Scarf project this session is scoped to,
    /// or nil for "quick chat" / global sessions. Surfaced as a
    /// subtitle under the "Chat" title in the nav bar so users can
    /// see at a glance which project the agent is operating inside.
    /// Set by `resetAndStartInProject` and by `startResuming` when
    /// the resumed session is attributed to a registered project.
    private(set) var currentProjectName: String?

    /// Git branch of the project's working directory at session start
    /// (v2.5). Nil for non-project sessions and projects that aren't
    /// git repos / have git missing on the host. Surfaced as a small
    /// chip on the right side of the project context bar.
    private(set) var currentGitBranch: String?

    /// Public so the surrounding `ChatView` can read `displayName`
    /// when presenting sheets (e.g., the model preflight). Still
    /// `let` — set once at init, never mutated after.
    let context: ServerContext
    private var client: ACPClient?
    private var eventTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    private var pendingDraftSave: Task<Void, Never>?

    /// Session id of the currently-active chat. Saved when state
    /// reaches `.ready` and cleared on explicit `stop()` so a
    /// user-initiated disconnect doesn't get auto-reconnected when
    /// network/scene events fire later.
    private var lastActiveSessionID: String?
    /// Optional project working directory of the currently-active
    /// session. Used as `cwd` on the recovery path so a project-
    /// scoped session reconnects with the right scope.
    private var lastProjectPath: String?

    // Reconnect tuning — verbatim from the Mac implementation at
    // scarf/Features/Chat/ViewModels/ChatViewModel.swift:563-693.
    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000   // 1s
    private static let maxReconnectDelay: UInt64 = 16_000_000_000   // 16s

    private static let logger = Logger(
        subsystem: "com.scarf.ios",
        category: "ChatController"
    )

    // MARK: - Draft persistence

    private static let draftKeyPrefix = "scarf.chat.draft.v1"
    private static let draftMaxAge: TimeInterval = 7 * 24 * 60 * 60   // 7 days

    private static func draftKey(serverID: ServerID, sessionID: String?) -> String {
        // `_no_session` covers the brief connecting window before
        // `vm.setSessionId` lands. The TextField is disabled in that
        // window today, so this slot is essentially never written —
        // but the sentinel is here so the key is always well-formed.
        "\(draftKeyPrefix).\(serverID.uuidString).\(sessionID ?? "_no_session")"
    }

    private static func draftTimestampKey(forKey key: String) -> String { key + ".ts" }

    private func saveDraft() {
        let key = Self.draftKey(serverID: context.id, sessionID: vm.sessionId)
        let tsKey = Self.draftTimestampKey(forKey: key)
        if draft.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: tsKey)
        } else {
            UserDefaults.standard.set(draft, forKey: key)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: tsKey)
        }
    }

    private func loadDraft() {
        let key = Self.draftKey(serverID: context.id, sessionID: vm.sessionId)
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            draft = saved
        }
    }

    private func clearStoredDraft() {
        let key = Self.draftKey(serverID: context.id, sessionID: vm.sessionId)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: Self.draftTimestampKey(forKey: key))
    }

    /// Debounced draft save. The view layer hooks this off
    /// `.onChange(of: controller.draft)` so per-keystroke writes are
    /// coalesced into one UserDefaults flush per ~1s of typing.
    func scheduleDraftSave() {
        pendingDraftSave?.cancel()
        pendingDraftSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// One-shot janitor invoked at app launch. Removes draft slots
    /// whose timestamp sidecar predates `draftMaxAge`. Cheap enough
    /// to call synchronously — UserDefaults is in-memory at runtime.
    static func pruneStaleDrafts(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let cutoff = now.timeIntervalSince1970 - draftMaxAge
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(draftKeyPrefix) && key.hasSuffix(".ts")
        {
            guard let ts = defaults.object(forKey: key) as? TimeInterval, ts < cutoff else { continue }
            let baseKey = String(key.dropLast(3))   // strip ".ts"
            defaults.removeObject(forKey: baseKey)
            defaults.removeObject(forKey: key)
        }
    }

    init(context: ServerContext) {
        self.context = context
        self.vm = RichChatViewModel(context: context)
    }

    /// Pre-flight: returns true when `config.yaml` has both
    /// `model.default` and `model.provider`. Returns false and stashes
    /// the start intent so the preflight sheet can replay it after the
    /// user picks a model. Reads via `context.readText` (transport-
    /// aware) and parses with the ScarfCore YAML parser — same path
    /// `IOSSettingsViewModel.load` uses.
    ///
    /// **Off MainActor.** `context.readText` synchronously calls
    /// `transport.fileExists` + `transport.readFile`; on a remote
    /// ScarfGo context that's a blocking SSH round-trip that, before
    /// this fix, ran on the controller's `@MainActor` and stalled the
    /// UI for seconds during connect — long enough for iOS's
    /// non-responsive-app watchdog to kill the process if the user
    /// kept tapping (the typing TestFlight crash report). Reading
    /// detached pushes the I/O off MainActor; the result and the
    /// `pendingStartIntent` / `modelPreflightReason` writes hop back.
    private func passModelPreflight(intent: PendingStart) async -> Bool {
        let ctx = context
        // Direct read → `cat "$(hermes config path)"` wrapper fallback →
        // `hermes config show` model-line probe. The probe is the only
        // read that works when Hermes runs inside a container (gh#112) —
        // without it, Docker users hit the "pick a model" sheet on every
        // start even though config.yaml is fully configured.
        let config: HermesConfig = await Task.detached {
            if let raw = HermesConfigReader.readRawConfig(context: ctx) {
                return HermesConfig(yaml: raw)
            }
            return HermesConfigReader.probeModelConfig(context: ctx) ?? .empty
        }.value
        let result = ModelPreflight.check(config)
        if result.isConfigured { return true }
        pendingStartIntent = intent
        modelPreflightReason = result.reason
        return false
    }

    /// User confirmed model + provider in the preflight sheet. Persist
    /// to `config.yaml` via `hermes config set` (transport-aware — runs
    /// over SSH on the active server) and replay the original start
    /// intent. iOS picker is a free-form text input today (matches the
    /// Mac overlay-provider field for `nous`), so trust the user's
    /// input — Hermes will surface a runtime error if the model isn't
    /// valid for the provider.
    func confirmModelPreflight(model: String, provider: String) {
        let intent = pendingStartIntent
        modelPreflightReason = nil
        pendingStartIntent = nil

        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespaces)
        guard !trimmedProvider.isEmpty else { return }

        let ctx = context
        Task.detached { [weak self] in
            // Same PATH-prefix trick `IOSSettingsViewModel.saveValue`
            // uses so non-interactive shells find `hermes` even when
            // it's in ~/.local/bin / /opt/homebrew/bin.
            let hermes = ctx.paths.hermesBinary
            let providerScript = """
            PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH" \
            \(hermes) config set 'model.provider' '\(Self.escapeShellArg(trimmedProvider))'
            """
            let provider = Self.runConfigSet(ctx, script: providerScript)
            let providerOK = provider.result?.exitCode == 0
            var modelResult: ProcessResult? = nil
            var modelError: String? = nil
            var modelOK = true
            if providerOK, !trimmedModel.isEmpty {
                let modelScript = """
                PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH" \
                \(hermes) config set 'model.default' '\(Self.escapeShellArg(trimmedModel))'
                """
                let model = Self.runConfigSet(ctx, script: modelScript)
                modelResult = model.result
                modelError = model.error
                modelOK = modelResult?.exitCode == 0
            }

            // Build the diagnostic message before hopping to MainActor so
            // we don't lose stderr if everything fails. gh#112: Docker
            // users with `hermes` wrapped in `docker compose exec` saw
            // only the generic "Couldn't save" message — surfacing the
            // wrapper's stderr makes the failure mode self-diagnostic
            // (missing config dir in the container, wrapper needs a TTY,
            // PATH miss, etc.) instead of a black box.
            let failureMessage = Self.preflightFailureMessage(
                hermes: hermes,
                providerOK: providerOK,
                providerResult: provider.result,
                providerError: provider.error,
                modelOK: modelOK,
                modelResult: modelResult,
                modelError: modelError
            )

            // Capture `modelOK` by value (it's a `var` finalized above) so the
            // closure holds an immutable copy — avoids "reference to captured
            // var in concurrently-executing code" (Swift-6 error-class).
            await MainActor.run { [weak self, modelOK] in
                guard let self else { return }
                if providerOK, modelOK, let intent {
                    Task { @MainActor in
                        switch intent {
                        case .fresh:
                            await self.start()
                        case .project(let path, let name):
                            await self.start(projectPath: path, projectName: name)
                        case .resume(let id):
                            await self.startResuming(sessionID: id)
                        }
                    }
                } else if !(providerOK && modelOK) {
                    self.state = .failed(failureMessage)
                }
            }
        }
    }

    /// Run one `hermes config set` over the (pooled) transport, capturing
    /// EITHER the process result — the command ran, even if it exited
    /// non-zero — OR the transport error string, which means the SSH session
    /// itself threw before the command could run (a genuine connection
    /// failure). The failure banner distinguishes the two so the user sees
    /// the real reason rather than a generic line.
    nonisolated private static func runConfigSet(
        _ ctx: ServerContext,
        script: String
    ) -> (result: ProcessResult?, error: String?) {
        do {
            let result = try ctx.makeTransport().runProcess(
                executable: "/bin/sh",
                args: ["-c", script],
                stdin: nil,
                timeout: 15
            )
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Compose a self-diagnostic error message for the preflight save
    /// failure path. Includes which command failed, the hermes binary
    /// that was invoked (so a misconfigured `hermesBinaryHint` is
    /// visible), and either the exit code + stderr (the command ran) or
    /// the transport error (the SSH session couldn't be opened). gh#112.
    nonisolated private static func preflightFailureMessage(
        hermes: String,
        providerOK: Bool,
        providerResult: ProcessResult?,
        providerError: String?,
        modelOK: Bool,
        modelResult: ProcessResult?,
        modelError: String?
    ) -> String {
        let failed: (key: String, result: ProcessResult?, error: String?) = !providerOK
            ? ("model.provider", providerResult, providerError)
            : ("model.default", modelResult, modelError)
        var lines = ["Couldn't save \(failed.key) to config.yaml via `\(hermes) config set`."]
        if let result = failed.result {
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
            lines.append("Exit code \(result.exitCode).")
            if !payload.isEmpty {
                // Truncate runaway output so the failure banner stays
                // legible; full output is in Console.app via the
                // transport's own logging.
                let trimmed = payload.count > 400 ? String(payload.prefix(400)) + "…" : payload
                lines.append(trimmed)
            }
        } else if let error = failed.error, !error.isEmpty {
            lines.append("Couldn't open an SSH session to the server: \(error)")
        } else {
            lines.append("Couldn't open an SSH session to the server — check that it's reachable and your key is still authorized.")
        }
        return lines.joined(separator: "\n")
    }

    /// Single-quote escape a shell argument. Handles embedded single
    /// quotes via the standard `'"'"'` trick. Mirrors the helper on
    /// `IOSSettingsViewModel`. `nonisolated static` so the
    /// `Task.detached` body can call it without a `self` capture and
    /// without hopping back to the MainActor.
    nonisolated private static func escapeShellArg(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    func cancelModelPreflight() {
        modelPreflightReason = nil
        pendingStartIntent = nil
    }

    /// Build an `ACPClient` for this controller's server, wired with the
    /// shared Keychain key provider. `projectCwd` (when set) is threaded to
    /// `forIOSApp` so `hermes acp` spawns IN the project dir and Hermes
    /// loads its `AGENTS.md` / `CLAUDE.md` / `.cursorrules` (it reads
    /// context files from the process cwd, not the ACP session cwd) — the
    /// iOS counterpart to Mac's project-cwd spawn. Single source of truth
    /// for the four chat-start paths (fresh / project / resume / reconnect).
    private func makeClient(projectCwd: String? = nil) -> ACPClient {
        ACPClient.forIOSApp(
            context: context,
            projectCwd: projectCwd,
            keyProvider: {
                let store = KeychainSSHKeyStore()
                guard let key = try await store.load() else {
                    throw SSHKeyStoreError.backendFailure(
                        message: "No SSH key in Keychain — re-run onboarding.",
                        osStatus: nil
                    )
                }
                return key
            }
        )
    }

    /// Open the SSH exec channel, send ACP `initialize`, then
    /// `session/new` — so that by the time `state == .ready` the user
    /// can type and hit send immediately.
    func start() async {
        if state == .connecting || state == .ready { return }
        guard await passModelPreflight(intent: .fresh) else { return }
        state = .connecting
        vm.reset()
        let client = makeClient()
        self.client = client

        // Hand the VM a closure that can fetch the ACPClient's recent
        // stderr when it needs to enrich the error banner on a non-
        // retryable `promptComplete` (pass-1 M7 #2). The VM caches
        // this; we only need to set it once per client.
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        // Start streaming ACP events into the view-model BEFORE we
        // send session/new, so the `available_commands_update`
        // notification that the server sends on session init is
        // captured. Health monitor catches socket-level death the
        // event-stream EOF wouldn't see (e.g., a hung remote read).
        startACPEventLoop(client: client)
        startHealthMonitor(client: client)

        // Create a fresh ACP session. `cwd` is the remote user's home
        // directory — Hermes defaults to that for tool scoping.
        do {
            let home = await context.resolvedUserHome()
            let sessionId = try await client.newSession(cwd: home)
            vm.setSessionId(sessionId)
            loadDraft()
            state = .ready
            lastActiveSessionID = sessionId
            lastProjectPath = nil
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Replace the current draft with `/<name>` (plus a trailing space
    /// when the command takes an argument), mirroring the Mac
    /// `RichChatInputBar.insertCommand`. Triggered by tapping a row in
    /// the iOS slash autocomplete.
    func insertSlashCommand(_ command: HermesSlashCommand) {
        if command.argumentHint != nil {
            draft = "/\(command.name) "
        } else {
            draft = "/\(command.name)"
        }
        scheduleDraftSave()
    }

    /// Send the current draft as a prompt. Fire-and-forget — the
    /// assistant reply streams back as ACP notifications handled by
    /// the event task.
    func send() async {
        await ScarfMon.measureAsync(.chatStream, "ios.send") {
            await _sendImpl()
        }
    }

    private func _sendImpl() async {
        guard state == .ready, let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // v0.12+ allows image-only sends — vision models accept "describe
        // this" with no text. Bail only when both fields are empty.
        guard !text.isEmpty || !attachments.isEmpty else { return }

        // Client-side slash intercept. Hermes ACP doesn't intercept `/new`
        // server-side — sending it as a prompt routes to the LLM, which
        // responds in-character ("/new is a TUI slash command, type it in
        // the TUI prompt"). TestFlight feedback ADyrlh, 2026-05-11. Catch
        // these BEFORE the user-message bubble + ACP wire send so the
        // transcript doesn't sprout an orphaned slash bubble right before
        // we tear it down for the new session.
        if !text.isEmpty,
           let intercept = RichChatViewModel.clientSideSlashCommand(for: text) {
            draft = ""
            clearStoredDraft()
            attachments = []
            switch intercept {
            case .newSession(let name):
                // iOS fresh-chat path doesn't accept a session name yet
                // (Hermes v0.13 `hasNewWithSessionName` lands later in
                // the iOS catch-up). Drop the name silently and start
                // a clean session.
                _ = name
                await resetAndStartNewSession()
            }
            return
        }

        let sessionId = vm.sessionId ?? ""
        guard !sessionId.isEmpty else { return }
        let images = attachments
        attachments = []
        draft = ""
        clearStoredDraft()
        if !text.isEmpty {
            vm.addUserMessage(text: text)
        } else {
            // Surface an image-only message so the user sees their bubble
            // even when they didn't type any caption.
            vm.addUserMessage(text: "[image attached]")
        }
        // Non-interruptive slash commands: keep the chat working
        // indicator off and surface a transient toast confirming the
        // command was accepted. v2.5 added `/steer`; v2.8 / Hermes
        // v0.13 adds `/goal` (lock the agent on a target across
        // turns) and `/queue` (queue a prompt for after the current
        // turn). Each gets its own optimistic side-effect on the VM
        // so the (Mac-rendered) chat header pill / queue chip update
        // synchronously. iOS doesn't surface those affordances yet
        // (WS-9), but mirroring the dispatch keeps the shared VM
        // state aligned across platforms — otherwise an iOS user who
        // ran `/goal` then opened the same session on Mac would see
        // an empty pill until they typed `/goal` again.
        let parsedSlash = RichChatViewModel.parseSlashName(text)
        switch parsedSlash.name {
        case "goal":
            // TODO(WS-2-Q7): verify on a real v0.13 host.
            let arg = RichChatViewModel.parseGoalArgument(parsedSlash.args)
            switch arg {
            case .set(let goalText):
                vm.recordActiveGoal(text: goalText)
                vm.transientHint = "Goal locked: \(RichChatViewModel.truncatedToastGoal(goalText))"
            case .clear:
                vm.recordActiveGoal(text: nil)
                vm.transientHint = "Goal cleared."
            case .empty:
                vm.transientHint = "Sent /goal — see the agent reply for current goal."
            }
            scheduleTransientHintClear(snapshot: vm.transientHint)
        case "queue":
            let queuedText = parsedSlash.args.trimmingCharacters(in: .whitespacesAndNewlines)
            if !queuedText.isEmpty {
                vm.recordQueuedPrompt(text: queuedText)
            }
            vm.transientHint = "Queued — runs after current turn."
            scheduleTransientHintClear(snapshot: vm.transientHint)
        case "subgoal":
            // v0.14 — mirror the Mac dispatch so iOS users who run
            // `/subgoal …` see the same trailing-line pill update as
            // Mac users on the same session.
            let arg = RichChatViewModel.parseSubgoalArgument(parsedSlash.args)
            switch arg {
            case .add(let subText):
                vm.recordSubgoalAdded(subText)
                vm.transientHint = "Subgoal added."
            case .remove(let idx):
                vm.recordSubgoalRemoved(idx)
                vm.transientHint = "Subgoal \(idx) removed."
            case .clear:
                vm.recordSubgoalsCleared()
                vm.transientHint = "Subgoals cleared."
            case .empty:
                vm.transientHint = "Sent /subgoal — see the agent reply for current subgoals."
            }
            scheduleTransientHintClear(snapshot: vm.transientHint)
        case "steer" where vm.isNonInterruptiveSlash(text):
            vm.transientHint = "Guidance queued — applies after the next tool call."
            scheduleTransientHintClear(snapshot: vm.transientHint)
        default:
            break
        }
        // Project-scoped slash commands expand client-side: the user
        // bubble shows the literal `/<name> args` they typed (above);
        // Hermes receives the expanded prompt template body. Other
        // command sources (ACP, quick_commands) keep going to Hermes
        // literally. v2.5.
        let wireText = expandIfProjectScoped(text)
        do {
            let result = try await client.sendPrompt(
                sessionId: sessionId,
                text: wireText,
                images: images
            )
            // `promptComplete` is a Scarf-local lifecycle event, not a
            // `session/update` notification emitted by ACP. Mirror the
            // macOS controller by synthesizing it from the resolved
            // `session/prompt` result so the shared VM finalizes the
            // streaming message and clears its working state.
            vm.handleACPEvent(
                .promptComplete(sessionId: sessionId, response: result)
            )
        } catch {
            // gh#108: a send in flight when the user switches apps
            // gets cancelled by pauseInBackground tearing down the
            // client. Detect that case (state demoted to .reconnecting
            // by pauseInBackground) and silently restore the prompt to
            // the draft so the user can tap Send again on resume —
            // the user bubble we already appended to the VM stays
            // visible as an orphan, but the agent never saw it so
            // letting the user re-send is the only correct recovery.
            if case .reconnecting = state {
                if !text.isEmpty, draft.isEmpty {
                    draft = text
                    scheduleDraftSave()
                }
                vm.transientHint = "Message not sent — tap Send again after reconnecting."
                scheduleTransientHintClear(snapshot: vm.transientHint)
                return
            }
            // The event task may already have surfaced a
            // .connectionLost; show the send-time error only if the
            // state didn't already fail. Always populate the error
            // banner so the user sees actionable detail regardless
            // of which path raised first (M7 #2).
            await vm.recordACPFailure(error, client: client)
            if case .ready = state {
                state = .failed("Prompt failed: \(error.localizedDescription)")
            }
            vm.handleACPEvent(
                .promptComplete(sessionId: sessionId, response: ACPPromptResult(
                    stopReason: "error",
                    inputTokens: 0,
                    outputTokens: 0,
                    thoughtTokens: 0,
                    cachedReadTokens: 0
                ))
            )
        }
    }

    /// Auto-clear the chat composer's transient hint after 4s. Mirror
    /// of `ChatViewModel.scheduleHintClear` — uses a value snapshot
    /// rather than identity so a later toast that reuses the same
    /// string still triggers the clear once the latest value matches.
    @MainActor
    private func scheduleTransientHintClear(snapshot: String?) {
        Task { @MainActor [weak vm] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if vm?.transientHint == snapshot {
                vm?.transientHint = nil
            }
        }
    }

    private func expandIfProjectScoped(_ text: String) -> String {
        vm.expandIfProjectScoped(text, context: context)
    }

    /// Tear down the live ACP session when the controller is deallocated —
    /// the tab root unmounts on Disconnect/Forget, or the profile switcher
    /// rebuilds the tab subtree (#120). The event/health tasks hold the
    /// `ACPClient` strongly and don't stop on handle release, so without
    /// this the remote `hermes acp` process + SSH channel would linger after
    /// the view is gone. `deinit` can't await, so cancel the tasks
    /// synchronously and fire-and-forget the actor `stop()` — the same
    /// pattern `CitadelServerTransport.deinit` uses. `isolated` so it runs
    /// on the MainActor and can touch the actor-isolated task handles.
    isolated deinit {
        eventTask?.cancel()
        healthMonitorTask?.cancel()
        reconnectTask?.cancel()
        pendingDraftSave?.cancel()
        if let client {
            Task { await client.stop() }
        }
    }

    /// Stop the current session + tear down the SSH exec channel.
    /// Idempotent.
    func stop() async {
        eventTask?.cancel(); eventTask = nil
        healthMonitorTask?.cancel(); healthMonitorTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        if let client {
            await client.stop()
        }
        client = nil
        state = .idle
        // Explicit user-initiated disconnect — clear the session
        // memory so reachability/scenePhase events don't try to
        // resurrect the dead chat.
        lastActiveSessionID = nil
        lastProjectPath = nil
        isHandlingDisconnect = false
    }

    // MARK: - Reconnect machinery (Section 1)

    /// Stream ACP events into the view-model. When the stream ends
    /// without us cancelling it, the channel died; route into the
    /// reconnect path. Direct port of Mac's `startACPEventLoop`
    /// (scarf/Features/Chat/ViewModels/ChatViewModel.swift:563).
    private func startACPEventLoop(client: ACPClient) {
        eventTask = Task { @MainActor [weak self] in
            let stream = await client.events
            for await event in stream {
                guard !Task.isCancelled else { break }
                ScarfMon.event(.chatStream, "ios.acpEvent", count: 1)
                ScarfMon.measure(.chatStream, "ios.handleACPEvent") {
                    self?.vm.handleACPEvent(event)
                }
            }
            // Stream ended — if we weren't explicitly cancelled the
            // channel died (EOF on stdin/out, write to dead pipe,
            // SSH socket gone). The Mac caller calls
            // `handleConnectionDied`; we mirror that.
            if !Task.isCancelled {
                self?.handleConnectionDied()
            }
        }
    }

    /// Threshold for read-side stall detection. When the agent is
    /// actively working (streaming a turn, running a tool) but no byte
    /// has arrived from the channel for this long, we declare the
    /// channel dead and route into the reconnect path. Set conservatively
    /// — Hermes streams thoughts/tools every <1s during normal work, but
    /// a long-running tool call (a slow bash command, a remote fetch)
    /// can legitimately hold a turn silent for tens of seconds. Tuned to
    /// avoid false positives on routine work while still catching the
    /// "Tailscale/iOS silently severed the TCP socket" symptom (TestFlight
    /// feedback AObiv7, 2026-05-07) within a window the user will tolerate.
    private static let stallDetectionSeconds: TimeInterval = 75

    /// 5-second heartbeat that catches dead channels which don't
    /// explicitly EOF the stream (e.g., a hung SSH socket waiting
    /// for the next chunk that never arrives). When `isHealthy`
    /// returns false, route into the reconnect path. Mirrors Mac's
    /// `startHealthMonitor`.
    ///
    /// Also detects a silent stall: when the VM thinks the agent is
    /// working but no byte has arrived from the channel for
    /// `stallDetectionSeconds`, treat the channel as dead. iOS over
    /// Tailscale is the symptom — the SSH socket can sit idle for
    /// minutes before the OS notices, and the user perceives this as
    /// "streaming just stopped." We don't apply the stall threshold
    /// when the agent is idle (no prompt in flight) because there's
    /// genuinely nothing for the channel to send.
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
                guard let self else { break }
                if self.vm.isAgentWorking {
                    let idle = await client.secondsSinceLastIncoming
                    if idle > Self.stallDetectionSeconds {
                        Self.logger.warning(
                            "ACP channel appears stalled — \(Int(idle))s since last byte while agent is working; routing to reconnect"
                        )
                        self.handleConnectionDied()
                        break
                    }
                }
            }
        }
    }

    /// One-stop cleanup + reconnect dispatch. Idempotent — guarded by
    /// `isHandlingDisconnect` so concurrent triggers (event-stream
    /// EOF + health monitor + write failure) don't tear down the same
    /// client twice.
    private func handleConnectionDied() {
        guard client != nil, !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        Self.logger.warning("ACP connection died")

        // Capture any in-progress streaming text into a finalized
        // message before we attempt to merge against the DB. The VM
        // doesn't add a system "Connection lost" bubble — that would
        // create a phantom message during reconnect.
        vm.finalizeOnDisconnect()

        let savedSessionId = vm.sessionId

        // Tear down the dead client. The eventTask will be cancelled
        // immediately; awaiting `stop()` on the dead client is the
        // detached fire-and-forget pattern Mac uses (its `Task` block).
        eventTask?.cancel(); eventTask = nil
        healthMonitorTask?.cancel(); healthMonitorTask = nil
        if let dead = client { Task { await dead.stop() } }
        client = nil

        guard let savedSessionId else {
            // No session id to resume — surface the failure.
            state = .failed("Connection lost")
            isHandlingDisconnect = false
            return
        }
        attemptReconnect(sessionId: savedSessionId)
    }

    /// React to an iOS scene-phase transition.
    ///
    /// `.background`: cancel the keepalive — iOS will suspend the
    /// socket within ~30s anyway, and fighting it via background
    /// tasks costs battery for marginal benefit (the agent's work is
    /// persisted to state.db on the remote, so we recover on resume).
    ///
    /// `.active`: if we had a session running before suspension and
    /// the channel is now unhealthy, route into the reconnect path
    /// so the user sees fresh state without having to tap anything.
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            // Tear down the live SSH/ACP loop so the OS doesn't kill
            // us for running network IO during the ~30s background
            // grace window. Citadel's NIO event loop + the ACP read
            // task + the keepalive timer all keep heartbeating
            // through `.background` otherwise; on weak networks
            // (cellular, low battery) iOS escalates that into a
            // jetsam / watchdog termination, which surfaces to the
            // user as a crash on next launch. Reported by an
            // Italian TestFlight tester on iPhone 16 Pro Max, mobile
            // data, 15% battery (feedback AADa60kw, 2026-05-15).
            //
            // We KEEP `lastActiveSessionID` and `lastProjectPath`
            // populated so `.active`'s `verifyAndResume` sees
            // `client == nil` and routes through
            // `handleConnectionDied` → `attemptReconnect`, which
            // resumes the same session id via `session/resume` (or
            // `session/load` as a fallback). VM state (messages,
            // streaming text, capabilities) is preserved.
            //
            // Side-benefit: the stall-detection clock (`ACPClient.
            // lastIncomingAt`) is primed fresh inside the reconnect
            // path's `client.start()`, so the first health-monitor
            // tick after resume can't false-positive on a
            // long-background timestamp gap.
            pauseInBackground()
        case .active:
            // No session worth verifying.
            guard let id = lastActiveSessionID else { return }
            // Already mid-recovery — let it finish.
            if case .reconnecting = state { return }
            await verifyAndResume(sessionId: id)
        case .inactive:
            break       // brief: control center, banners, split-screen
        @unknown default:
            break
        }
    }

    /// Background-time variant of `stop()` that tears down the live
    /// network/IO surfaces but preserves the session-id memory and
    /// VM state so `.active`'s `verifyAndResume` can transparently
    /// reconnect. Distinct from `stop()` which is a user-initiated
    /// teardown and clears `lastActiveSessionID` to disarm
    /// auto-resume.
    private func pauseInBackground() {
        healthMonitorTask?.cancel(); healthMonitorTask = nil
        eventTask?.cancel(); eventTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        // Capture any in-progress streaming text into a finalized
        // bubble so the transcript isn't orphaned mid-chunk if the
        // OS decides to terminate before we resume.
        vm.finalizeOnDisconnect()
        if let dead = client {
            Task.detached { await dead.stop() }
        }
        client = nil
        // The next `.active` cycle will route through
        // verifyAndResume → attemptReconnect (which now handles a
        // nil client directly — previously handleConnectionDied
        // early-returned on `client != nil`, silently stranding the
        // chat in `.ready` with no live client; gh#107 / gh#108).
        // Demote `.ready` → `.reconnecting(0/max)` so the composer
        // disables Send during the gap and the banner explains why
        // — without this, taps on Send between `.background` and
        // `.active`'s reconnect were silent no-ops (gh#107).
        // Preserve `.failed` so a prior unrecoverable error stays
        // visible across the background round-trip.
        if state == .ready {
            state = .reconnecting(attempt: 0, of: Self.maxReconnectAttempts)
        }
        isHandlingDisconnect = false
    }

    /// Probe the existing client's health on resume. If alive,
    /// just re-arm the heartbeat; if dead, route into the reconnect
    /// path (which preserves the session id and reconciles against
    /// the DB).
    ///
    /// `pauseInBackground` nils out `client` on `.background`, so on
    /// `.active` we may have `client == nil` even though the session
    /// is still alive on the remote. handleConnectionDied early-
    /// returns on `client != nil`, so call attemptReconnect directly
    /// in that case — without this, the chat sat in `.reconnecting(0)`
    /// (after the pauseInBackground demote) and never recovered, and
    /// pre-demote it sat in `.ready` with a nil client (gh#107 — Send
    /// became a silent no-op) or `.failed` if a prompt was mid-flight
    /// when the user switched apps (gh#108 — "Chat connection failed").
    private func verifyAndResume(sessionId: String) async {
        if let client {
            if await client.isHealthy {
                if case .reconnecting = state { state = .ready }
                startHealthMonitor(client: client)
                return
            }
            handleConnectionDied()
            return
        }
        attemptReconnect(sessionId: sessionId)
    }

    /// React to a transition in `NetworkReachabilityService`. While
    /// the device has no network, suppress reconnect attempts (they'd
    /// just burn the 5-attempt budget against guaranteed failures);
    /// when the network comes back, kick a fresh cycle if we're
    /// stuck in `.failed` / `.offline` with a saved session id.
    func handleReachabilityChange() async {
        let satisfied = NetworkReachabilityService.shared.isSatisfied
        if !satisfied {
            // Stop the in-flight reconnect cycle — every attempt
            // will fail until the link is back. We'll restart on
            // the next `.satisfied` edge.
            reconnectTask?.cancel(); reconnectTask = nil
            if case .reconnecting = state {
                state = .offline(reason: "No network")
            }
            return
        }
        // Network back. If we have a session worth restoring AND
        // we're currently in a non-recoverable state, kick a fresh
        // reconnect cycle.
        guard let id = lastActiveSessionID else { return }
        switch state {
        case .offline, .failed:
            attemptReconnect(sessionId: id)
        default:
            break
        }
    }

    /// 5-attempt exponential-backoff reconnect targeting the same
    /// session id. Tries `session/resume` first (correct semantics
    /// for live recovery), falls back to `session/load` for older
    /// remotes. NEVER `session/new` — that would lose the agent's
    /// in-context conversation. After a successful reattach, calls
    /// `vm.reconcileWithDB` so messages the agent wrote during the
    /// outage become visible.
    private func attemptReconnect(sessionId: String) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...Self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }
                state = .reconnecting(attempt: attempt, of: Self.maxReconnectAttempts)

                // Skip backoff on the first attempt so a quick
                // recovery (e.g., a momentary SSH socket flap) feels
                // instant. Subsequent attempts back off 1→2→4→8→16s.
                if attempt > 1 {
                    let delay = min(
                        Self.reconnectBaseDelay * UInt64(1 << (attempt - 1)),
                        Self.maxReconnectDelay
                    )
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let client = makeClient(projectCwd: lastProjectPath)

                do {
                    try await client.start()

                    // Project-scoped sessions reconnect with their
                    // project path as cwd; everything else uses the
                    // remote user's home directory.
                    let cwd: String
                    if let path = lastProjectPath {
                        cwd = path
                    } else {
                        cwd = await context.resolvedUserHome()
                    }

                    let resolvedSessionId: String
                    do {
                        resolvedSessionId = try await client.resumeSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        Self.logger.info(
                            "session/resume failed, trying session/load: \(error.localizedDescription, privacy: .public)"
                        )
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    }

                    // Wire up the new client BEFORE merging messages
                    // so any streaming chunks that arrive during the
                    // reconcile land in the right place.
                    self.client = client
                    vm.acpStderrProvider = { [weak client] in
                        await client?.recentStderr ?? ""
                    }
                    vm.setSessionId(resolvedSessionId)
                    // Clear any error banner left over from a send that
                    // failed because the channel was torn down by
                    // pauseInBackground (gh#108: user sends, app
                    // switches, returns to an `acpError` describing
                    // "prompt failed" even though we've successfully
                    // reconnected on resume).
                    vm.clearACPErrorState()

                    // Merge in-memory state (any local-only user
                    // messages typed before the disconnect) with
                    // whatever Hermes has persisted to state.db
                    // since we last looked. This is what makes the
                    // "agent kept working while you were locked"
                    // case visible to the user.
                    let countBefore = vm.messages.count
                    await vm.reconcileWithDB(sessionId: resolvedSessionId)
                    let added = vm.messages.count - countBefore
                    if added > 0 {
                        vm.transientHint = "Resynced \(added) new message\(added == 1 ? "" : "s")."
                        Task { @MainActor [weak vm] in
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            if vm?.transientHint?.hasPrefix("Resynced") == true {
                                vm?.transientHint = nil
                            }
                        }
                    }

                    startACPEventLoop(client: client)
                    startHealthMonitor(client: client)
                    state = .ready
                    lastActiveSessionID = resolvedSessionId

                    isHandlingDisconnect = false
                    Self.logger.info("Reconnected on attempt \(attempt)")
                    return
                } catch {
                    Self.logger.warning(
                        "Reconnect attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    await client.stop()
                    continue
                }
            }

            // Exhausted all attempts. Surface a manual-recovery prompt.
            guard !Task.isCancelled else { return }
            state = .failed("Connection lost")
            isHandlingDisconnect = false
        }
    }

    /// User tapped "New chat". Stop, reset the VM, start again.
    func resetAndStartNewSession() async {
        await stop()
        vm.reset()
        currentProjectName = nil
        currentGitBranch = nil
        // Quick-chat sessions don't have a project; clear any leftover
        // project-scoped slash commands from a prior session. Refresh
        // global Scarf commands too so `/scarf-*` still surfaces.
        vm.loadProjectScopedCommands(at: nil)
        vm.loadGlobalScopedCommands()
        await start()
    }

    /// User tapped "In project… <project>". Stop, reset, and start
    /// with the project's path as cwd. Writes the Scarf-managed
    /// AGENTS.md block via ProjectContextBlock BEFORE spawning `hermes
    /// acp`, so Hermes sees the project context at boot. Records the
    /// returned session id in the attribution sidecar.
    func resetAndStartInProject(_ project: ProjectEntry) async {
        await stop()
        vm.reset()
        currentProjectName = project.name
        currentGitBranch = nil
        // Pull any project-authored slash commands at
        // <project.path>/.scarf/slash-commands/ into the chat menu.
        // Async + non-fatal — degrades cleanly on SFTP failures (logged).
        vm.loadProjectScopedCommands(at: project.path)
        // Refresh global Scarf commands so any version bump applied
        // this launch lands in the menu without a relaunch.
        vm.loadGlobalScopedCommands()
        // v2.5 git branch indicator. Async + nil on failure — the chip
        // simply doesn't render if the project isn't a git repo.
        let ctx = context
        let projectPath = project.path
        Task { @MainActor [weak self] in
            let branch = await GitBranchService(context: ctx).branch(at: projectPath)
            if self?.currentProjectName == project.name {
                self?.currentGitBranch = branch
            }
        }
        // Render + write the full Scarf-managed AGENTS.md block (cron,
        // config fields, template, kanban, slash commands, platform
        // reference) BEFORE `hermes acp` boots — it reads context from the
        // process cwd at spawn. Non-fatal: a write failure surfaces a
        // banner and the chat proceeds without the block.
        await writeProjectContextBlock(projectPath: project.path, projectName: project.name)
        await start(projectPath: project.path, projectName: project.name)
    }

    /// Render the full Scarf-managed block for `projectPath` and write it
    /// over SFTP. Uses `ProjectStore.renderAgentContextBlock` so the block
    /// is byte-identical to what the Mac writes for the same project state
    /// (cron jobs included). MUST be called BEFORE the `hermes acp` spawn
    /// so the block is on disk when Hermes reads context files at boot.
    ///
    /// Non-fatal: on failure we surface a yellow banner (so the user knows
    /// the agent won't see project context this session) with the
    /// underlying error in "Show details", but the chat still starts.
    /// Shared by the new-project-chat and resume paths.
    private func writeProjectContextBlock(projectPath: String, projectName: String) async {
        let ctx = context
        let writeResult: Result<Void, Error> = await Task.detached {
            let store = ProjectStore(context: ctx)
            let scarfProject = store.load(projectPath: projectPath)
                ?? store.derive(from: ProjectEntry(name: projectName, path: projectPath))
            let block = store.renderAgentContextBlock(for: scarfProject)
            do {
                try ProjectContextBlock.writeBlock(block, forProjectAt: projectPath, context: ctx)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = writeResult {
            Self.logger.error(
                "ProjectContextBlock.writeBlock failed for \(projectPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            vm.acpError = "Project context not written — agent will proceed without it."
            vm.acpErrorHint = "Check that the SSH user can write to \(projectPath)/AGENTS.md."
            vm.acpErrorDetails = error.localizedDescription
        }
    }

    /// Inline variant of `start()` that accepts a cwd + attribution
    /// hooks. The default `start()` delegates to this with nil project
    /// fields, so the ACP code path stays single-sourced.
    private func startInternal(
        projectPath: String?,
        projectName: String?
    ) async {
        if state == .connecting || state == .ready { return }
        let intent: PendingStart
        if let projectPath, let projectName {
            intent = .project(path: projectPath, name: projectName)
        } else {
            intent = .fresh
        }
        guard await passModelPreflight(intent: intent) else { return }
        state = .connecting
        let client = makeClient(projectCwd: projectPath)
        self.client = client
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        startACPEventLoop(client: client)
        startHealthMonitor(client: client)

        do {
            // Use the project's path as cwd when provided; else the
            // remote user's home, matching the pre-M9 default.
            let cwd: String
            if let projectPath {
                cwd = projectPath
            } else {
                cwd = await context.resolvedUserHome()
            }
            let sessionId = try await client.newSession(cwd: cwd)
            vm.setSessionId(sessionId)
            loadDraft()
            state = .ready
            lastActiveSessionID = sessionId
            lastProjectPath = projectPath

            // If this was a project-scoped session, record the
            // attribution so Dashboard's Sessions tab can render the
            // project badge for it. Best-effort and intentionally fire-
            // and-forget — `SessionAttributionService.persist` already
            // logs SFTP failures via `os.Logger` (see the
            // `Self.logger.error` in `persist`), and a failed write
            // here is purely cosmetic: the chat works, only the badge
            // is missing until the next reconcile. We deliberately
            // don't surface this to the chat banner because it would
            // alarm users about a non-issue.
            if let projectPath {
                let ctx = context
                Task.detached {
                    SessionAttributionService(context: ctx)
                        .attribute(sessionID: sessionId, toProjectPath: projectPath)
                }
            }
            _ = projectName // reserved for future chat-header chip
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Public entry used internally by resetAndStartInProject.
    func start(projectPath: String, projectName: String) async {
        await startInternal(projectPath: projectPath, projectName: projectName)
    }

    /// Resume an existing ACP session. Called from ChatView when the
    /// coordinator carries a `pendingResumeSessionID` (Dashboard row
    /// tap). If we're currently on a different session, stop first
    /// so there's no phantom ACP process hanging around. Falls back
    /// to `session/load` if the remote doesn't support `session/resume`
    /// (Hermes < 0.9.x).
    func startResuming(sessionID: String) async {
        await ScarfMon.measureAsync(.sessionLoad, "ios.startResuming") {
            await _startResumingImpl(sessionID: sessionID)
        }
    }

    private func _startResumingImpl(sessionID: String) async {
        guard await passModelPreflight(intent: .resume(sessionID: sessionID)) else { return }
        await stop()
        vm.reset()
        // Clear eagerly so a lingering project name from a prior
        // session doesn't flash onto the new header while the
        // attribution lookup runs.
        currentProjectName = nil
        // Resolve the project name for this session (if any) via the
        // attribution sidecar + project registry. Set BEFORE the ACP
        // handshake so the nav-bar subtitle is visible the moment the
        // "Connecting…" overlay disappears. Run off-thread so we
        // don't block while the SFTP reads happen. Empty-string names
        // are treated as nil — registry entries should never have
        // empty names in practice, but guard against a surprise
        // JSON-decode edge case that would render just a folder icon
        // with no text (pass-2 bug: user saw exactly that).
        let ctx = context
        // Resolve both the path AND the name so we can (a) render the
        // header chip with the name and (b) load any project-scoped
        // slash commands at the project's `.scarf/slash-commands/` dir.
        let resolved: (path: String, name: String)? = await Task.detached {
            let attribution = SessionAttributionService(context: ctx)
            guard let path = attribution.projectPath(for: sessionID) else { return nil }
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            guard let name = registry.projects.first(where: { $0.path == path })?.name,
                  !name.isEmpty
            else { return nil }
            return (path: path, name: name)
        }.value
        currentProjectName = resolved?.name
        currentGitBranch = nil
        vm.loadProjectScopedCommands(at: resolved?.path)
        vm.loadGlobalScopedCommands()
        // v2.5 git branch indicator for the resumed-session header.
        if let resumePath = resolved?.path {
            let resolvedName = resolved?.name
            Task { @MainActor [weak self] in
                let branch = await GitBranchService(context: ctx).branch(at: resumePath)
                // Guard against a project switch landing while we
                // were resolving — only set if the chat hasn't moved.
                if self?.currentProjectName == resolvedName {
                    self?.currentGitBranch = branch
                }
            }
        }

        // Refresh the project's AGENTS.md block before the spawn so a
        // resumed project chat picks up cron/config changes made since the
        // chat was created (Hermes re-reads context at every `hermes acp`
        // boot). Project-attributed sessions only.
        if let resumePath = resolved?.path {
            await writeProjectContextBlock(projectPath: resumePath, projectName: resolved?.name ?? "")
        }

        state = .connecting
        let client = makeClient(projectCwd: resolved?.path)
        self.client = client
        vm.acpStderrProvider = { [weak client] in
            await client?.recentStderr ?? ""
        }

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            return
        }

        startACPEventLoop(client: client)
        startHealthMonitor(client: client)

        do {
            // Project-scoped sessions resume with their project path as
            // cwd (matching the reconnect path); others use the remote
            // user's home. Hermes loads project context from the process
            // cwd set at spawn (forIOSApp projectCwd), not from this.
            let cwd: String
            if let projectPath = resolved?.path {
                cwd = projectPath
            } else {
                cwd = await context.resolvedUserHome()
            }
            // Prefer `session/resume` for true resume semantics
            // (same session id preserved in state.db); fall back to
            // `session/load` if the remote doesn't know resume.
            let resolvedID: String
            do {
                resolvedID = try await client.resumeSession(cwd: cwd, sessionId: sessionID)
            } catch {
                resolvedID = try await client.loadSession(cwd: cwd, sessionId: sessionID)
            }
            vm.setSessionId(resolvedID)
            loadDraft()
            // Pull the transcript out of state.db so the user sees
            // everything said up to now. Mirrors the Mac resume flow
            // (scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:376).
            // `loadSessionHistory` refreshes the SQLite snapshot first
            // so we pick up messages Hermes wrote between the
            // Dashboard's last load and now.
            await vm.loadSessionHistory(
                sessionId: sessionID,
                acpSessionId: resolvedID == sessionID ? nil : resolvedID
            )
            state = .ready
            lastActiveSessionID = resolvedID
            lastProjectPath = resolved?.path
        } catch {
            state = .failed(error.localizedDescription)
            await vm.recordACPFailure(error, client: client)
            await stop()
        }
    }

    /// Dispatch the user's answer to a pending permission request.
    /// Called by `PermissionSheet`.
    func respondToPermission(requestId: Int, optionId: String) async {
        guard let client else { return }
        await client.respondToPermission(requestId: requestId, optionId: optionId)
        vm.pendingPermission = nil
    }
}

/// `Identifiable` wrapper so SwiftUI's `.sheet(item:)` can key off
/// the pending permission. Two permissions for the same request-id
/// are treated as identical (rare — would only happen if the remote
/// sends a duplicate).
private struct PermissionWrapper: Identifiable {
    let value: RichChatViewModel.PendingPermission
    var id: Int { value.requestId }
}

// MARK: - Message bubble

private struct MessageBubble: View, Equatable {
    let message: HermesMessage
    /// Wall-clock duration of the agent turn this assistant message
    /// belongs to (v2.5). Renders as a small `4.2s` pill below the
    /// bubble when present. Nil for user / streaming / pre-v2.5
    /// resumed messages.
    var turnDuration: TimeInterval? = nil

    /// Lazy loader for the richer `reasoning_content` (v0.11), invoked when
    /// the REASONING disclosure is first opened. nil → no lazy upgrade
    /// (live/streaming bubbles already carry it). Excluded from `==` below
    /// (closures aren't Equatable; identity follows the message). (t-aud21)
    var loadFullReasoning: (() async -> String?)? = nil

    /// SwiftUI body short-circuit (issue #46 — iOS path). On iOS the
    /// chat list is `LazyVStack` over `controller.vm.messages` directly
    /// (no message-group layer), so every visible bubble re-evaluates
    /// its body on each streamed chunk because `messages` mutates and
    /// the `@Observable` VM invalidates anyone reading it. Without
    /// equatable short-circuiting, every visible bubble re-runs
    /// `ChatContentFormatter.segments` + `AttributedString(markdown:)`
    /// per chunk — CPU-expensive on phones, especially with long
    /// content already on screen.
    ///
    /// Streaming message has `id == 0` (shared with Mac via
    /// `RichChatViewModel.streamingId`); it correctly redraws on
    /// every chunk via the content/reasoning/toolCalls.count compare.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        guard lhs.message.id == rhs.message.id else { return false }
        if lhs.message.id == 0 {
            return lhs.message.content == rhs.message.content
                && lhs.message.reasoning == rhs.message.reasoning
                && lhs.message.reasoningContent == rhs.message.reasoningContent
                && lhs.message.toolCalls.count == rhs.message.toolCalls.count
                && lhs.turnDuration == rhs.turnDuration
        }
        return lhs.turnDuration == rhs.turnDuration
            && lhs.message.tokenCount == rhs.message.tokenCount
            && lhs.message.finishReason == rhs.message.finishReason
    }

    var body: some View {
        // Per-bubble render counter. The streaming bubble
        // (`message.id == 0`) re-renders on every chunk; tracking the
        // count here is what tells us if a slow chat is bottlenecked
        // on body re-eval vs. event-loop delivery.
        let _: Void = ScarfMon.event(.chatRender, "ios.MessageBubble.body")
        if message.isToolResult {
            ToolResultRow(message: message)
        } else {
            HStack(alignment: .bottom) {
                if message.isUser { Spacer(minLength: 40) }
                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                    // v2.5: prefer reasoning_content (Hermes v0.11+);
                    // fall back to legacy reasoning when only it's set. t-aud27:
                    // gate on `hasReasoning` ALONE (not `preferredReasoning`) so
                    // the disclosure shows on resume for reasoning_content-only
                    // messages whose blob isn't loaded yet (preferredReasoning is
                    // nil there) — `ReasoningDisclosure` renders the header and
                    // lazy-loads the content on first open via `loadFull`.
                    if message.hasReasoning {
                        ReasoningDisclosure(
                            reasoning: message.preferredReasoning ?? "",
                            hasFullContent: !(message.reasoningContent ?? "").isEmpty,
                            loadFull: loadFullReasoning
                        )
                    }
                    // Only render the bubble when there's actual text
                    // to show. Assistant messages can exist in a
                    // "reasoning-only" or "tool-calls-only" state
                    // while the agent is thinking / invoking tools —
                    // rendering an empty gray bubble next to every
                    // "Thinking…" disclosure looked like a ghost
                    // message. User bubbles we always render (the
                    // user explicitly submitted content, even if
                    // it's just whitespace, they saw it land).
                    if message.isUser || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bubbleContent
                    }
                    if !message.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.toolCalls) { call in
                                ToolCallCard(call: call)
                            }
                        }
                    }
                    // Per-turn stopwatch — assistant only, when the
                    // turn duration was captured (live ACP turns).
                    if !message.isUser, let seconds = turnDuration {
                        Text(RichChatViewModel.formatTurnDuration(seconds))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !message.isUser { Spacer(minLength: 40) }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        // User bubbles are plain text — no reason to parse what the
        // user just typed. Assistant bubbles route through the
        // ChatContentFormatter so fenced code blocks get horizontal
        // scrolling instead of soft-wrapping into ugly 4-line
        // vertical columns on an iPhone.
        if message.isUser {
            Text(message.content)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(ScarfColor.onAccent)
                .background(
                    UnevenRoundedRectangle(cornerRadii:
                        .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14))
                        .fill(ScarfColor.accent)
                )
                .textSelection(.enabled)
                .contextMenu { messageContextMenu }
        } else {
            HStack(alignment: .top, spacing: 8) {
                // Assistant avatar — rust gradient sparkles tile,
                // matches the Mac side and the ScarfChatView reference.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ScarfGradient.brand)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "sparkles")
                            .foregroundStyle(.white)
                            .font(.system(size: 10, weight: .semibold))
                    )
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ChatContentFormatter.segments(for: message.content).enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let body):
                            Self.markdownText(body)
                                .font(.body)
                                .textSelection(.enabled)
                        case .code(let lang, let body):
                            CodeBlockView(language: lang, body: body)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
                .contextMenu { messageContextMenu }
            }
        }
    }

    /// Shared context-menu actions for user + assistant bubbles.
    /// Copy is the most-used action; Share hands off to the system
    /// share sheet via ShareLink. Regenerate is intentionally absent —
    /// ACP doesn't support it natively and the pattern would require
    /// non-trivial session-state surgery.
    @ViewBuilder
    private var messageContextMenu: some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// Parses message text as markdown for the assistant side. Text-
    /// only segments coming from ChatContentFormatter can contain
    /// inline backticks / bold / links; `.inlineOnlyPreservingWhitespace`
    /// preserves newlines + spacing and won't mangle the output if
    /// the input isn't valid markdown.
    private static func markdownText(_ body: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(body)
    }
}

/// Horizontally-scrollable fenced code block. ~240pt max height
/// collapsed (Expand button reveals full height). Monospaced
/// .footnote font keeps the bubble narrow enough to still show
/// adjacent text on the same screen. Language label is a tiny
/// header when present.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var expanded = false

    private let collapsedMaxHeight: CGFloat = 240

    init(language: String?, body: String) {
        self.language = language
        self.code = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
                Button(expanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ScarfColor.foregroundMuted)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: expanded ? nil : collapsedMaxHeight)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Inline, expandable "chain-of-thought" disclosure shown above the
/// assistant's primary message when the remote surfaces `reasoning`.
/// Collapsed by default so a chatty model doesn't dominate the scroll
/// position.
private struct ReasoningDisclosure: View {
    let reasoning: String
    /// True when the rich `reasoning_content` is already in `reasoning`
    /// (live/streaming or already-hydrated). When false, fetch on open. (t-aud21)
    var hasFullContent: Bool = true
    /// Fetches the richer reasoning_content on first expand. (t-aud21)
    var loadFull: (() async -> String?)? = nil

    @State private var isExpanded = false
    @State private var lazyContent: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(lazyContent ?? reasoning)
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .italic()
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("REASONING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.5)
            }
            .foregroundStyle(ScarfColor.warning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(ScarfColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1)
                )
        )
        // Upgrade to reasoning_content on first open if it wasn't bulk-loaded. (t-aud21)
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, !hasFullContent, lazyContent == nil, let loadFull else { return }
            Task { if let full = await loadFull(), !full.isEmpty { lazyContent = full } }
        }
    }
}

/// Expanding card for a single `HermesToolCall` — kind-tinted with
/// uppercase tracked label, matches the Mac ToolCallCard treatment.
private struct ToolCallCard: View {
    let call: HermesToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: call.toolKind.icon)
                            .foregroundStyle(toolColor)
                            .font(.caption2)
                        Text(toolLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .tracking(0.4)
                            .foregroundStyle(toolColor)
                    }
                    Text(call.functionName)
                        .font(.caption.monospaced())
                        .fontWeight(.semibold)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text(call.argumentsSummary.prefix(60))
                        .font(.caption.monospaced())
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(toolColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(toolColor.opacity(0.30), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(call.arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(ScarfColor.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(ScarfColor.border, lineWidth: 1)
                            )
                    )
                    .padding(.leading, 4)
            }
        }
    }

    private var toolLabel: String {
        switch call.toolKind {
        case .read: return "READ"
        case .edit: return "EDIT"
        case .execute: return "EXECUTE"
        case .fetch: return "FETCH"
        case .browser: return "BROWSER"
        case .other: return "TOOL"
        }
    }

    private var toolColor: Color {
        switch call.toolKind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }
}

/// Row showing a tool-result (role="tool"). Styled as a small
/// quoted block beneath whichever assistant message preceded it.
private struct ToolResultRow: View {
    let message: HermesMessage
    @State private var isExpanded = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text("Tool output")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text(message.content.prefix(80))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    Text(message.content)
                        .font(.caption2.monospaced())
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemBackground))
            )
            Spacer(minLength: 40)
        }
        .padding(.horizontal)
    }
}

// MARK: - Permission sheet

/// Sheet presented when the remote asks for permission (e.g.,
/// "allow write to /etc/hosts"). Renders the VM's `PendingPermission`
/// options as tappable buttons. Tapping responds via the ChatController
/// which dispatches the answer over the ACP channel.
private struct PermissionSheet: View {
    let permission: RichChatViewModel.PendingPermission
    let onRespond: (_ optionId: String) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(permission.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text("Kind: \(permission.kind)")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your response") {
                    // Visual numbering 1-9 matches the Mac sheet's
                    // keyboard shortcuts; on iPhone the numbers serve
                    // as a hierarchy hint rather than an accelerator
                    // (no hardware keyboard binding). Mirrors the new
                    // Hermes v2026.4.23 TUI pattern.
                    ForEach(Array(permission.options.enumerated()), id: \.element.optionId) { idx, opt in
                        Button {
                            Task {
                                await onRespond(opt.optionId)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                if idx < 9 {
                                    Text("\(idx + 1).")
                                        .font(.body.monospaced())
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
                                Text(opt.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Agent permission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Explicit dismissal affordance (HIG consistency with
                // ProjectPickerSheet / IOSModelPreflightSheet) — swipe-to-
                // dismiss already worked but wasn't discoverable. Dismisses
                // without responding, same as the drag indicator. (t-aud14)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// iOS preflight sheet for the model + provider on a server whose
/// `config.yaml` is missing them. The Mac picker (`ModelPickerSheet`)
/// doesn't ship in the iOS target — the catalog UI is Mac-only today —
/// so this is a pair of `TextField`s plus a hint pointing at common
/// formats. Confirms via the same `setModelAndProvider` path the Mac
/// preflight uses, so persistence + replay logic stays single-sourced
/// in `ChatController.confirmModelPreflight`.
private struct IOSModelPreflightSheet: View {
    let reason: String
    let serverDisplayName: String
    let onSelect: (_ model: String, _ provider: String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: String = ""
    @State private var provider: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(reasonLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Provider") {
                    TextField("e.g. anthropic, nous, openai", text: $provider)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Model") {
                    TextField("e.g. claude-sonnet-4.6, hermes-3", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Hermes will pass these through verbatim. Leave model blank if you're using Nous Portal — Hermes picks its default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pick a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save & Start") {
                        let p = provider.trimmingCharacters(in: .whitespaces)
                        let m = model.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty else { return }
                        onSelect(m, p)
                        dismiss()
                    }
                    .disabled(provider.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var reasonLine: String {
        let suffix = "Scarf will save these to `config.yaml` on \(serverDisplayName) and start the chat."
        guard !reason.isEmpty else { return suffix }
        return "\(reason) \(suffix)"
    }
}

#endif // canImport(SQLite3)

// Empty shim so the file compiles on platforms without SQLite3 — the
// target never runs there, but the typechecker visits the file.
#if !canImport(SQLite3)
struct ChatView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle
    var body: some View {
        Text("Chat requires SQLite3 — this platform is not supported.")
    }
}
#endif
