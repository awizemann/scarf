import SwiftUI

/// Auxiliary tab — the 8 sub-model tasks hermes delegates to cheaper models.
/// Each follows the same provider/model/base_url/api_key/timeout pattern.
struct AuxiliaryTab: View {
    @Bindable var viewModel: SettingsViewModel

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
    }

    @ViewBuilder
    private func auxRows(for key: String) -> some View {
        let model = auxModel(for: key)
        EditableTextField(label: "Provider", value: model.provider) { viewModel.setAuxiliary(key, field: "provider", value: $0) }
        EditableTextField(label: "Model", value: model.model) { viewModel.setAuxiliary(key, field: "model", value: $0) }
        EditableTextField(label: "Base URL", value: model.baseURL) { viewModel.setAuxiliary(key, field: "base_url", value: $0) }
        SecretTextField(label: "API Key", value: model.apiKey) { viewModel.setAuxiliary(key, field: "api_key", value: $0) }
        StepperRow(label: "Timeout (s)", value: model.timeout, range: 5...3600, step: 5) { viewModel.setAuxiliaryTimeout(key, value: $0) }
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
