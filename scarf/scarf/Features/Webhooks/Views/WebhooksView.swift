import SwiftUI
import AppKit

struct WebhooksView: View {
    @State private var viewModel = WebhooksViewModel()
    @State private var showAddSheet = false
    @State private var pendingRemove: HermesWebhook?

    // Add form state
    @State private var addName = ""
    @State private var addPrompt = ""
    @State private var addEvents = ""
    @State private var addDescription = ""
    @State private var addSkills = ""
    @State private var addDeliver = "log"
    @State private var addChatID = ""
    @State private var addSecret = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isLoading && viewModel.webhooks.isEmpty {
                ProgressView().padding()
            } else if viewModel.webhookPlatformNotEnabled {
                setupRequiredState
            } else if viewModel.webhooks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Webhooks")
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .confirmationDialog(
            pendingRemove.map { "Remove webhook \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let w = pendingRemove { viewModel.remove(w) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
    }

    private var header: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                resetAddForm()
                showAddSheet = true
            } label: {
                Label("Subscribe", systemImage: "plus")
            }
            .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Shown when hermes reports the webhook platform isn't enabled. Direct users
    /// to the interactive setup wizard instead of showing a misleading empty list.
    private var setupRequiredState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Webhook platform not enabled")
                .font(.title3.bold())
            Text("Hermes needs a global webhook secret and port before subscriptions can receive traffic. Run the gateway setup wizard or edit ~/.hermes/config.yaml manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            HStack(spacing: 8) {
                Button {
                    openGatewaySetupInTerminal()
                } label: {
                    Label("Run Setup in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: HermesPaths.configYAML))
                } label: {
                    Label("Edit config.yaml", systemImage: "doc.text")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func openGatewaySetupInTerminal() {
        guard let hermes = HermesFileService().hermesBinaryPath() else { return }
        let script = "tell application \"Terminal\"\n  activate\n  do script \"\(hermes) gateway setup\"\nend tell"
        let appleScript = NSAppleScript(source: script)
        var err: NSDictionary?
        appleScript?.executeAndReturnError(&err)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.right.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No webhook subscriptions")
                .foregroundStyle(.secondary)
            Text("Webhooks let external services trigger agent responses. Each subscription gets its own URL endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Create Subscription") {
                resetAddForm()
                showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.webhooks) { webhook in
                    row(webhook)
                }
            }
            .padding()
        }
    }

    private func row(_ webhook: HermesWebhook) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(webhook.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                if !webhook.description.isEmpty {
                    Text(webhook.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(webhook.routeSuffix)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.tertiary)
                    if !webhook.deliver.isEmpty {
                        Text(webhook.deliver)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    ForEach(webhook.events, id: \.self) { event in
                        Text(event)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            Button("Test") { viewModel.test(webhook) }
                .controlSize(.small)
            Button("Remove", role: .destructive) { pendingRemove = webhook }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Webhook Subscription")
                .font(.headline)
            formField("Name (URL suffix)", text: $addName, placeholder: "github_push", mono: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                Text("Use {dot.notation} to reference fields in the webhook payload.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextEditor(text: $addPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            formField("Events (comma separated)", text: $addEvents, placeholder: "push, pull_request", mono: true)
            formField("Description", text: $addDescription, placeholder: "Optional human description")
            formField("Skills (comma separated)", text: $addSkills, placeholder: "github-auth, pr-review", mono: true)
            formField("Deliver", text: $addDeliver, placeholder: "log | telegram | discord | slack")
            formField("Chat ID", text: $addChatID, placeholder: "Required for cross-platform delivery")
            formField("Secret", text: $addSecret, placeholder: "HMAC secret (auto-generated if empty)", mono: true)
            HStack {
                Spacer()
                Button("Cancel") { showAddSheet = false }
                Button("Subscribe") {
                    viewModel.subscribe(
                        name: addName,
                        prompt: addPrompt,
                        events: addEvents,
                        description: addDescription,
                        skills: addSkills,
                        deliver: addDeliver,
                        chatID: addChatID,
                        secret: addSecret
                    )
                    showAddSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 560)
    }

    @ViewBuilder
    private func formField(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
        }
    }

    private func resetAddForm() {
        addName = ""; addPrompt = ""; addEvents = ""; addDescription = ""
        addSkills = ""; addDeliver = "log"; addChatID = ""; addSecret = ""
    }
}
