import SwiftUI
import ScarfCore
import ScarfDesign

struct PersonalitiesView: View {
    @State private var viewModel: PersonalitiesViewModel
    @State private var soulDraft = ""
    @State private var editingSOUL = false
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(context: ServerContext) {
        _viewModel = State(initialValue: PersonalitiesViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Personalities",
                subtitle: "Hermes' built-in personalities plus any you define under `agent.personalities` in config.yaml."
            ) {
                HStack(spacing: ScarfSpace.s2) {
                    if let msg = viewModel.message {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.success)
                    }
                    Button("Edit config.yaml") { viewModel.openConfigInEditor() }
                        .buttonStyle(ScarfGhostButton())
                    Button("Reload") {
                        viewModel.hasBuiltinPersonalitiesInCode =
                            capabilitiesStore?.capabilities.hasBuiltinPersonalitiesInCode ?? false
                        viewModel.load()
                        soulDraft = viewModel.soulMarkdown
                    }
                        .buttonStyle(ScarfSecondaryButton())
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    activeSection
                    listSection
                    soulSection
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Personalities")
        .onAppear {
            // Push the host capability in before the load: it decides whether
            // Hermes' in-code built-ins are unioned into the list at all.
            viewModel.hasBuiltinPersonalitiesInCode =
                capabilitiesStore?.capabilities.hasBuiltinPersonalitiesInCode ?? false
            viewModel.load()
            soulDraft = viewModel.soulMarkdown
        }
    }

    private var activeSection: some View {
        SettingsSection(title: "Active Personality", icon: "theatermasks.fill") {
            if viewModel.personalities.isEmpty {
                ReadOnlyRow(label: "Current", value: viewModel.activeName.isEmpty ? "default" : viewModel.activeName)
                ReadOnlyRow(label: "Defined", value: "None in config.yaml — add under `personalities:` to customize.")
            } else {
                PickerRow(label: "Active", selection: viewModel.activeName, options: viewModel.activeOptions) { viewModel.setActive($0) }
                    .disabled(viewModel.isSaving)
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if !viewModel.personalities.isEmpty {
            SettingsSection(title: "Available Personalities", icon: "list.bullet") {
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
                            if personality.isBuiltin {
                                Text("built-in")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.5))
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
                    .disabled(viewModel.isSaving)
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
