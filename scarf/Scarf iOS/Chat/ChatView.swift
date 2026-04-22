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
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: HermesMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .background(
                        message.isUser ? Color.accentColor : Color(.secondarySystemBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
                if message.hasReasoning, let r = message.reasoning, !r.isEmpty {
                    Text("🧠 \(r)")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
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
