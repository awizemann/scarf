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
    }

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Text("Conversation")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer()
            if case .live = viewModel.phase {
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
                detail: "\(botTitle) is answering your first message. This one turn runs through the Hermes CLI — after it, messages stream live."
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

    private var starter: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            placeholder(
                icon: "bubble.left.and.bubble.right",
                title: "No conversation yet",
                detail: "\(botTitle) doesn’t have a Bot Chat. Send the first message and Hermes creates it."
            )
            BotConversationStarter { viewModel.send($0) }
            // Stated up front rather than discovered later: Scarf can only
            // create this session through the Hermes CLI, which has no way
            // to hide it (see BotConversationViewModel.createCanonicalBotChat).
            Text("Heads up: the chat Scarf creates also shows up in Sessions. Don’t rename it there — its name is how Hermes finds it.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
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
