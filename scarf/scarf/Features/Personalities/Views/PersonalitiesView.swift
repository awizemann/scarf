import SwiftUI
import ScarfCore

struct PersonalitiesView: View {
    @State private var viewModel: PersonalitiesViewModel
    @State private var soulDraft = ""
    @State private var editingSOUL = false

    init(context: ServerContext) {
        _viewModel = State(initialValue: PersonalitiesViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                activeSection
                listSection
                soulSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Personalities")
        .onAppear {
            viewModel.load()
            soulDraft = viewModel.soulMarkdown
        }
    }

    private var header: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Edit config.yaml") { viewModel.openConfigInEditor() }
                .controlSize(.small)
            Button("Reload") { viewModel.load(); soulDraft = viewModel.soulMarkdown }
                .controlSize(.small)
        }
    }

    private var activeSection: some View {
        SettingsSection(title: "Active Personality", icon: "theatermasks.fill") {
            if viewModel.personalities.isEmpty {
                ReadOnlyRow(label: "Current", value: viewModel.activeName.isEmpty ? "default" : viewModel.activeName)
                ReadOnlyRow(label: "Defined", value: "None in config.yaml — add under `personalities:` to customize.")
            } else {
                PickerRow(label: "Active", selection: viewModel.activeName, options: viewModel.personalities.map(\.name)) { viewModel.setActive($0) }
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if !viewModel.personalities.isEmpty {
            SettingsSection(title: "Defined Personalities", icon: "list.bullet") {
                ForEach(viewModel.personalities) { personality in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(personality.name)
                                .font(.system(.body, design: .monospaced, weight: .medium))
                            if personality.name == viewModel.activeName {
                                Text("active")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        if !personality.prompt.isEmpty {
                            Text(personality.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.3))
                }
            }
        }
    }

    private var soulSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("SOUL.md", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if editingSOUL {
                    Button("Cancel") {
                        editingSOUL = false
                        soulDraft = viewModel.soulMarkdown
                    }
                    .controlSize(.small)
                    Button("Save") {
                        viewModel.saveSOUL(soulDraft)
                        editingSOUL = false
                    }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("Edit") { editingSOUL = true }
                        .controlSize(.small)
                }
            }
            Text("SOUL.md describes the agent's voice, values, and personality at ~/.hermes/SOUL.md. It is injected into every session's context.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if editingSOUL {
                TextEditor(text: $soulDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(viewModel.soulMarkdown.isEmpty ? "(empty)" : viewModel.soulMarkdown)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(viewModel.soulMarkdown.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
