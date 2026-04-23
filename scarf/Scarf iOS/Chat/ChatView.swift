import SwiftUI
import ScarfCore
import ScarfIOS

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

    @State private var controller: ChatController

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
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await controller.resetAndStartNewSession() }
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .disabled(controller.state == .connecting)
            }
        }
        .task {
            await controller.start()
        }
        .onDisappear {
            Task { await controller.stop() }
        }
        .overlay {
            if case .failed(let msg) = controller.state {
                errorOverlay(msg)
            }
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
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if controller.vm.messages.isEmpty, controller.state == .ready {
                        emptyState
                    }
                    ForEach(controller.vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if controller.vm.isAgentWorking {
                        HStack {
                            ProgressView()
                            Text("Agent is working…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical)
            }
            .onChange(of: controller.vm.scrollTrigger) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: controller.vm.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask Hermes something")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Connected to \(config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Message…",
                text: $controller.draft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .disabled(controller.state != .ready)
            .submitLabel(.send)
            .onSubmit {
                Task { await controller.send() }
            }

            Button {
                Task { await controller.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(controller.state != .ready || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
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
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Retry") {
                Task { await controller.start() }
            }
            .buttonStyle(.borderedProminent)
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
        case failed(String)
    }

    private(set) var state: State = .idle
    var vm: RichChatViewModel
    var draft: String = ""

    private let context: ServerContext
    private var client: ACPClient?
    private var eventTask: Task<Void, Never>?

    init(context: ServerContext) {
        self.context = context
        self.vm = RichChatViewModel(context: context)
    }

    /// Open the SSH exec channel, send ACP `initialize`, then
    /// `session/new` — so that by the time `state == .ready` the user
    /// can type and hit send immediately.
    func start() async {
        if state == .connecting || state == .ready { return }
        state = .connecting
        vm.reset()
        let client = ACPClient.forIOSApp(
            context: context,
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
        self.client = client

        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // Start streaming ACP events into the view-model BEFORE we
        // send session/new, so the `available_commands_update`
        // notification that the server sends on session init is
        // captured.
        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await MainActor.run {
                    self.vm.handleACPEvent(event)
                }
            }
        }

        // Create a fresh ACP session. `cwd` is the remote user's home
        // directory — Hermes defaults to that for tool scoping.
        do {
            let home = await context.resolvedUserHome()
            let sessionId = try await client.newSession(cwd: home)
            vm.setSessionId(sessionId)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            await stop()
        }
    }

    /// Send the current draft as a prompt. Fire-and-forget — the
    /// assistant reply streams back as ACP notifications handled by
    /// the event task.
    func send() async {
        guard state == .ready, let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sessionId = vm.sessionId ?? ""
        guard !sessionId.isEmpty else { return }
        draft = ""
        vm.addUserMessage(text: text)
        do {
            _ = try await client.sendPrompt(sessionId: sessionId, text: text)
        } catch {
            // The event task may already have surfaced a
            // .connectionLost; show the send-time error only if the
            // state didn't already fail.
            if case .ready = state {
                state = .failed("Prompt failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop the current session + tear down the SSH exec channel.
    /// Idempotent.
    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.stop()
        }
        client = nil
        state = .idle
    }

    /// User tapped "New chat". Stop, reset the VM, start again.
    func resetAndStartNewSession() async {
        await stop()
        vm.reset()
        await start()
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

private struct MessageBubble: View {
    let message: HermesMessage

    var body: some View {
        if message.isToolResult {
            ToolResultRow(message: message)
        } else {
            HStack(alignment: .bottom) {
                if message.isUser { Spacer(minLength: 40) }
                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                    if message.hasReasoning, let r = message.reasoning, !r.isEmpty {
                        ReasoningDisclosure(reasoning: r)
                    }
                    bubbleContent
                    if !message.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.toolCalls) { call in
                                ToolCallCard(call: call)
                            }
                        }
                    }
                }
                if !message.isUser { Spacer(minLength: 40) }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        // Render markdown on the assistant side so bold/code/links
        // look right. User messages stay plain — no reason to parse
        // what the user just typed. AttributedString(markdown:) is
        // conservative — unknown constructs fall through as literal
        // text, so the worst case is just "no formatting".
        let text: Text = {
            if message.isUser {
                return Text(message.content)
            }
            if let attributed = try? AttributedString(
                markdown: message.content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                return Text(attributed)
            }
            return Text(message.content)
        }()

        text
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isUser ? Color.white : Color.primary)
            .background(
                message.isUser ? Color.accentColor : Color(.secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
    }
}

/// Inline, expandable "chain-of-thought" disclosure shown above the
/// assistant's primary message when the remote surfaces `reasoning`.
/// Collapsed by default so a chatty model doesn't dominate the scroll
/// position.
private struct ReasoningDisclosure: View {
    let reasoning: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Thinking…", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

/// Expanding card for a single `HermesToolCall` — shows function name
/// + summary collapsed; full JSON arguments expanded.
private struct ToolCallCard: View {
    let call: HermesToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(.tint)
                    Text(call.functionName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    Text(call.argumentsSummary.prefix(60))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(call.arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }

    private var iconName: String {
        call.toolKind.icon
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
                            .foregroundStyle(.secondary)
                        Text("Tool output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your response") {
                    ForEach(permission.options, id: \.optionId) { opt in
                        Button {
                            Task {
                                await onRespond(opt.optionId)
                                dismiss()
                            }
                        } label: {
                            HStack {
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
        }
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
