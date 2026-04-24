import SwiftUI

/// Auxiliary tab — the 8 sub-model tasks hermes delegates to cheaper models.
/// Each follows the same provider/model/base_url/api_key/timeout pattern.
///
/// Adds a per-task **Route through Nous Portal** toggle for Hermes v0.10.0+
/// subscribers. The toggle flips `auxiliary.<task>.provider` between `nous`
/// (subscription-routed) and `auto` (inherit main provider) — Hermes derives
/// the gateway routing from that single field; there is no separate
/// `use_gateway` key to write.
struct AuxiliaryTab: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.serverContext) private var serverContext
    @State private var subscription: NousSubscriptionState = .absent
    @State private var showNousSignIn: Bool = false

    // Keyed by the config path name — matches `auxiliary.<task>.*` in config.yaml.
    private let tasks: [(key: String, title: LocalizedStringKey, icon: String)] = [
        ("vision", "Vision", "eye"),
        ("web_extract", "Web Extract", "doc.richtext"),
        ("compression", "Compression", "arrow.down.right.and.arrow.up.left.circle"),
        ("session_search", "Session Search", "magnifyingglass"),
        ("skills_hub", "Skills Hub", "books.vertical"),
        ("approval", "Approval", "checkmark.seal"),
        ("mcp", "MCP", "puzzlepiece"),
        ("flush_memories", "Flush Memories", "trash.slash")
    ]

    var body: some View {
        Text("Auxiliary tasks use separate, typically cheaper models. Leave Provider as `auto` to inherit the main provider.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

        ForEach(tasks, id: \.key) { task in
            SettingsSection(title: task.title, icon: task.icon) {
                auxRows(for: task.key)
            }
        }
        Color.clear.frame(height: 0)
            .onAppear {
                subscription = NousSubscriptionService(context: serverContext).loadState()
            }
            .sheet(isPresented: $showNousSignIn) {
                NousSignInSheet {
                    subscription = NousSubscriptionService(context: serverContext).loadState()
                }
            }
    }

    @ViewBuilder
    private func auxRows(for key: String) -> some View {
        let model = auxModel(for: key)
        nousGatewayToggle(for: key, currentProvider: model.provider)
        EditableTextField(label: "Provider", value: model.provider) { viewModel.setAuxiliary(key, field: "provider", value: $0) }
        EditableTextField(label: "Model", value: model.model) { viewModel.setAuxiliary(key, field: "model", value: $0) }
        EditableTextField(label: "Base URL", value: model.baseURL) { viewModel.setAuxiliary(key, field: "base_url", value: $0) }
        SecretTextField(label: "API Key", value: model.apiKey) { viewModel.setAuxiliary(key, field: "api_key", value: $0) }
        StepperRow(label: "Timeout (s)", value: model.timeout, range: 5...3600, step: 5) { viewModel.setAuxiliaryTimeout(key, value: $0) }
    }

    @ViewBuilder
    private func nousGatewayToggle(for key: String, currentProvider: String) -> some View {
        let isOn = (currentProvider == "nous")
        ToggleRow(label: "Nous Portal", isOn: isOn) { wantsOn in
            // "nous" enables subscription routing; "auto" reverts to the
            // inherit-main-provider default. We never touch model/base/key
            // fields here — Hermes reuses them if the user switches back.
            viewModel.setAuxiliary(key, field: "provider", value: wantsOn ? "nous" : "auto")
        }
        if !subscription.present && !isOn {
            HStack(spacing: 8) {
                Text("Requires an active Nous Portal subscription.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Sign in first") { showNousSignIn = true }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func auxModel(for key: String) -> AuxiliaryModel {
        switch key {
        case "vision": return viewModel.config.auxiliary.vision
        case "web_extract": return viewModel.config.auxiliary.webExtract
        case "compression": return viewModel.config.auxiliary.compression
        case "session_search": return viewModel.config.auxiliary.sessionSearch
        case "skills_hub": return viewModel.config.auxiliary.skillsHub
        case "approval": return viewModel.config.auxiliary.approval
        case "mcp": return viewModel.config.auxiliary.mcp
        case "flush_memories": return viewModel.config.auxiliary.flushMemories
        default: return .empty
        }
    }
}
