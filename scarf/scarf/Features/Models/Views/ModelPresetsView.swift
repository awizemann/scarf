import SwiftUI
import ScarfCore
import ScarfDesign

/// Sidebar destination for the Models entry. CRUD over Scarf-owned
/// model presets at `~/.hermes/scarf/model_presets.json`.
///
/// Per-project bindings happen in the project Configuration sheet —
/// this view manages the *catalog* of presets, not their per-project
/// assignment. The usage column shows projects that bind each preset
/// so the user knows what'll fall back to the global default if they
/// delete one.
struct ModelPresetsView: View {
    // Coordinator-cached (t-aud24) so it survives section switches.
    let viewModel: ModelPresetsViewModel
    @State private var editingPreset: ModelPreset?
    @State private var isCreating = false
    @State private var pendingDelete: ModelPreset?

    init(viewModel: ModelPresetsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Models",
                subtitle: "Saved model presets you can bind to a project.",
                trailing: {
                    Button("New Preset") { isCreating = true }
                        .buttonStyle(ScarfPrimaryButton())
                        .accessibilityIdentifier("models.newPreset")
                }
            )

            statusBanner

            if viewModel.isLoading && viewModel.presets.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if viewModel.presets.isEmpty {
                emptyState
            } else {
                presetList
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Models")
        .onAppear { viewModel.load() }
        .sheet(isPresented: $isCreating) {
            ModelPresetEditSheet(
                initial: nil,
                onSave: { preset in
                    viewModel.upsert(preset)
                    isCreating = false
                },
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $editingPreset) { preset in
            ModelPresetEditSheet(
                initial: preset,
                onSave: { updated in
                    viewModel.upsert(updated)
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Delete preset '\($0.name)'?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let preset = pendingDelete { viewModel.delete(id: preset.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let preset = pendingDelete {
                let count = viewModel.usageCounts[preset.id] ?? 0
                if count > 0 {
                    Text("\(count) project\(count == 1 ? "" : "s") bind this preset. Those projects will fall back to the global default in config.yaml.")
                } else {
                    Text("This preset isn't bound to any project. Deletion is reversible — re-create with the same model.")
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = viewModel.statusMessage {
            HStack(spacing: ScarfSpace.s2) {
                Image(systemName: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(viewModel.statusIsError ? ScarfColor.danger : ScarfColor.success)
                Text(message)
                    .scarfStyle(.body)
                Spacer()
                Button {
                    viewModel.clearStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(ScarfSpace.s2)
            .background(
                (viewModel.statusIsError ? ScarfColor.danger : ScarfColor.success).opacity(0.1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: ScarfSpace.s3) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No model presets yet")
                .scarfStyle(.title2)
            Text("Create a preset to bind it to a project. Each project can run on a different model without touching config.yaml.")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Create First Preset") { isCreating = true }
                .buttonStyle(ScarfPrimaryButton())
                .padding(.top, ScarfSpace.s2)
                .accessibilityIdentifier("models.createFirstPreset")
            Spacer()
        }
        .padding(ScarfSpace.s4)
    }

    private var presetList: some View {
        ScrollView {
            VStack(spacing: ScarfSpace.s2) {
                ForEach(viewModel.presets) { preset in
                    presetRow(preset)
                }
            }
            .padding(ScarfSpace.s3)
        }
    }

    private func presetRow(_ preset: ModelPreset) -> some View {
        ScarfCard {
            HStack(spacing: ScarfSpace.s3) {
                VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                    HStack(spacing: ScarfSpace.s2) {
                        Text(preset.name)
                            // Row handle for the UI gate. Deliberately on the
                            // title, NOT the row container: a container
                            // identifier rewrites every descendant's, which
                            // erased the Edit/Delete handles below.
                            .accessibilityIdentifier("models.row.\(preset.name)")
                            .scarfStyle(.title3)
                        let count = viewModel.usageCounts[preset.id] ?? 0
                        if count > 0 {
                            ScarfBadge("\(count) project\(count == 1 ? "" : "s")", kind: .info)
                        }
                    }
                    HStack(spacing: ScarfSpace.s1) {
                        Image(systemName: "cpu")
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text("\(preset.providerID) / \(preset.modelID)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    if let notes = preset.notes, !notes.isEmpty {
                        Text(notes)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                Spacer()
                Button("Edit") { editingPreset = preset }
                    .buttonStyle(ScarfSecondaryButton())
                    .accessibilityIdentifier("models.row.\(preset.name).edit")
                Button("Delete") { pendingDelete = preset }
                    .buttonStyle(ScarfGhostButton())
                    .accessibilityIdentifier("models.row.\(preset.name).delete")
            }
        }
    }
}
