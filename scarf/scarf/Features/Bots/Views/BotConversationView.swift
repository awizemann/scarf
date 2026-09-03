import SwiftUI
import ScarfCore
import ScarfDesign

/// The bot's live conversation, rendered into B2's `conversation` slot in
/// `BotDetailView`.
///
/// The transcript is the *same* `ChatTranscriptPane` the main Chat feature
/// uses — streaming tokens, thinking disclosures, tool cards, permission
/// prompts, slash commands and history hydration all come for free — with
/// this bot's own `ChatViewModel` put into the environment so the pane's
/// children (`MessageGroupView`, `RichMessageBubble`, the composer) bind to
/// the bot's ACP session instead of the window's main chat.
struct BotConversationView: View {
    @Bindable var viewModel: BotConversationViewModel
    let botTitle: String

    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// Whether this host has every CLI flag the creation transport needs.
    /// `--query-file` is absent below v0.21 (see
    /// `HermesCapabilities.hasBotChatCreationCLI` for the per-flag
    /// verification), and argparse rejects the whole invocation on an
    /// unknown flag — so below the floor the starter is replaced with an
    /// explicit unsupported note rather than a button that always fails.
    private var canCreateBotChat: Bool {
        capabilitiesStore?.capabilities.hasBotChatCreationCLI ?? false
    }

    /// The transcript needs a bounded height: `BotDetailView` lays its
    /// slots out inside a `ScrollView`, and a self-scrolling transcript
    /// nested in one would be unusable. A fixed pane keeps B2's detail
    /// layout intact (the reason the slot is a `@ViewBuilder` at all)
    /// rather than re-cutting it.
    private let paneHeight: CGFloat = 520

    var body: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                header
                content
            }
        }
        // Exactly what ChatView.swift does for the main chat. Without it the
        // bot's `RichChatViewModel` never received a capability snapshot, so
        // every bot conversation's slash menu was permanently degraded to
        // the `.empty` set — greyed agent commands, no version-gated
        // surfaces (go/no-go blocking condition 5, A2-F1). The id is the
        // capabilities-line string, a stable identity that flips exactly
        // when the detector fires.
        .task(id: capabilitiesStore?.capabilities.versionLine ?? "") {
            viewModel.chat.attachCapabilitiesStore(capabilitiesStore)
        }
    }

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Text("Conversation")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer()
            if case .live = viewModel.phase {
                // Honest about the transport: a CLI-delivered conversation
                // (every Bot Chat created by Scarf or Hermes Desktop —
                // Hermes' ACP adapter can't load those sessions) shows the
                // reply only when the turn completes. Streaming applies
                // only to the rare ACP-born Bot Chat.
                if viewModel.delivery == .cliTransport {
                    Text("Replies arrive when each turn completes")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .help("This conversation runs through the Hermes CLI in the bot's real Bot Chat session. Hermes can't stream this session live over ACP, so the reply appears all at once when the bot finishes its turn.")
                }
                Text("@\(viewModel.handle)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .accessibilityLabel("Messaging the bot @\(viewModel.handle)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .resolving:
            placeholder(
                icon: "ellipsis.bubble",
                title: "Opening \(botTitle)’s chat…",
                detail: "Looking for this profile’s Bot Chat."
            )

        case .noConversationYet:
            starter

        case .creating:
            placeholder(
                icon: "hourglass",
                title: "Starting the conversation…",
                detail: "\(botTitle) is answering your first message. Bot conversations run through the Hermes CLI — the reply appears when the turn completes."
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Label("Couldn’t open this conversation", systemImage: "exclamationmark.triangle")
                    .scarfStyle(.headline)
                    .foregroundStyle(ScarfColor.danger)
                Text(message)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .textSelection(.enabled)
                Button("Try Again") { viewModel.open() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .live:
            transcript
        }
    }

    private var transcript: some View {
        ChatTranscriptPane(
            richChat: viewModel.chat.richChatViewModel,
            chatViewModel: viewModel.chat,
            onSend: { text, _, _ in viewModel.send(text) },
            isEnabled: true
        )
        // Both overrides matter. `ChatViewModel` re-points every child
        // (`MessageGroupView`, `RichMessageBubble`, the composer) at the
        // bot's session instead of the window's main chat, which is
        // injected at the app root. `serverContext` re-points the
        // composer's own reads — slash commands, quick commands — at the
        // BOT's profile home, so it can't offer the user's commands under
        // the bot's name.
        .environment(viewModel.chat)
        .environment(\.serverContext, viewModel.context)
        // Teammate-DM attribution is a Bot Mode concept and is parsed ONLY
        // here. Main Chat has no agent-to-agent DMs in it, so leaving the
        // default (false) there keeps its user bubbles byte-identical to
        // v2.23.0 and spends no work on a parse that can only return nil.
        .environment(\.showsBotAttribution, true)
        .frame(height: paneHeight)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private var starter: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            placeholder(
                icon: "bubble.left.and.bubble.right",
                title: "No conversation yet",
                detail: canCreateBotChat
                    ? "\(botTitle) doesn’t have a Bot Chat. Send the first message and Hermes creates it."
                    : "\(botTitle) doesn’t have a Bot Chat yet, and this host can’t create one."
            )
            if canCreateBotChat {
                BotConversationStarter { viewModel.send($0) }
                // Stated up front rather than discovered later: Scarf can only
                // create this session through the Hermes CLI, which has no way
                // to hide it (see BotConversationViewModel.createCanonicalBotChat).
                // The chat lives in the BOT's own state.db, so it appears in
                // Sessions only while this window is scoped to that profile —
                // not in the Sessions list of whatever profile you're in now.
                // (go/no-go blocking condition 3b: the old copy claimed the
                // former, which is wrong for the common case.)
                Text("Heads up: the chat Scarf creates isn’t hidden, so it shows up in Sessions whenever you’re viewing this bot’s profile. Don’t rename it there — its name is how Hermes finds it.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Starting a bot’s first conversation needs hermes chat --query-file, which arrived in Hermes v0.21. Upgrade the host, or send this bot its first message from Hermes itself — Scarf picks the chat up from there.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(ScarfColor.foregroundMuted)
            VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                Text(title)
                    .scarfStyle(.headline)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(detail)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A minimal composer for the pre-creation state. The real
/// `RichChatInputBar` needs a live `ChatViewModel` session; before the Bot
/// Chat exists there isn't one.
private struct BotConversationStarter: View {
    let onSend: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: ScarfSpace.s2) {
            TextField("Say hello…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        onSend(text)
        text = ""
    }
}
