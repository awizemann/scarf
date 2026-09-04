import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet for binding a model preset to a specific project. Reads the
/// current binding from `<project>/.scarf/manifest.json` and writes
/// back via `ProjectModelPresetBinding`.
///
/// Two modes:
/// - **"Use global default"** — clears the binding so the project
///   inherits `config.yaml`'s `model.default`. Shows the default
///   model + provider in parentheses for visibility.
/// - **"Use preset"** — picks one from the loaded list. Each row
///   shows the model + provider line so users can pick by model name,
///   not just preset name.
///
/// Capability-gated entry point: shown only when
/// `HermesCapabilities.hasACPSetSessionModel` (v0.13+). On older hosts
/// the binding wouldn't actually apply at runtime.
struct ProjectModelPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: ServerContext
    let project: ProjectEntry

    @State private var presets: [ModelPreset] = []
    @State private var selectedID: UUID?
    @State private var useGlobalDefault: Bool = true
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Model for \(project.name)",
                subtitle: "Pick the model this project's chats run on. Changes apply on the next chat session."
            )

            ScrollView {
                VStack(spacing: ScarfSpace.s3) {
                    if isLoading {
                        ProgressView()
                            .padding(ScarfSpace.s4)
                    } else {
                        defaultRow

                        if presets.isEmpty {
                            emptyPresetsRow
                        } else {
                            ForEach(presets) { preset in
                                presetRow(preset)
                            }
                        }

                        if let errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(ScarfColor.danger)
                                Text(errorMessage)
                                    .scarfStyle(.body)
                            }
                            .padding(ScarfSpace.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ScarfColor.danger.opacity(0.1))
                        }
                    }
                }
                .padding(ScarfSpace.s4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ScarfSecondaryButton())
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button("Save") { save() }
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(ScarfSpace.s4)
            .background(ScarfColor.backgroundSecondary)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    private var defaultRow: some View {
        ScarfCard {
            HStack {
                Image(systemName: useGlobalDefault ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(useGlobalDefault ? ScarfColor.accent : ScarfColor.foregroundMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use global default")
                        .scarfStyle(.title3)
                    Text("Inherit `model.default` from ~/.hermes/config.yaml.")
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                useGlobalDefault = true
                selectedID = nil
            }
        }
    }

    private var emptyPresetsRow: some View {
        VStack(spacing: ScarfSpace.s2) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No saved presets yet")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Create one in the Models sidebar to bind it to this project.")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
        }
        .padding(ScarfSpace.s4)
        .frame(maxWidth: .infinity)
    }

    private func presetRow(_ preset: ModelPreset) -> some View {
        let selected = !useGlobalDefault && selectedID == preset.id
        return ScarfCard {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? ScarfColor.accent : ScarfColor.foregroundMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .scarfStyle(.title3)
                    Text("\(preset.providerID) / \(preset.modelID)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                useGlobalDefault = false
                selectedID = preset.id
            }
        }
    }

    // MARK: - Load + save

    @MainActor
    private func load() async {
        let service = ModelPresetService.shared(for: context)
        do {
            let loaded = try await service.list()
            self.presets = loaded
            // Hydrate the current binding from the manifest. The reader is
            // SYNCHRONOUS transport I/O (a manifest.json read, i.e. an SFTP
            // round-trip on a remote project) inside an @MainActor function —
            // detach it, the way `service.list()` above already is.
            let ctx = context
            let path = project.path
            let boundID = await Task.detached {
                ProjectModelPresetReader(context: ctx).presetID(forProjectPath: path)
            }.value
            if let idString = boundID,
               let uuid = UUID(uuidString: idString),
               loaded.contains(where: { $0.id == uuid })
            {
                self.useGlobalDefault = false
                self.selectedID = uuid
            } else {
                self.useGlobalDefault = true
                self.selectedID = nil
            }
        } catch {
            self.errorMessage = "Couldn't load presets: \(error.localizedDescription)"
        }
        self.isLoading = false
    }

    /// `ProjectModelPresetBinding.bind` is a read-modify-write of the
    /// project's `.scarf/manifest.json` through the transport — two round
    /// trips on a remote project — and ran inline on the MainActor, freezing
    /// the sheet until it returned or failed.
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let ctx = context
        let project = project
        let newValue: String? = useGlobalDefault ? nil : selectedID?.uuidString
        Task {
            let failure: String? = await Task.detached {
                do {
                    try ProjectModelPresetBinding(context: ctx)
                        .bind(presetID: newValue, to: project)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            isSaving = false
            if let failure {
                errorMessage = "Couldn't save: \(failure)"
            } else {
                dismiss()
            }
        }
    }
}
