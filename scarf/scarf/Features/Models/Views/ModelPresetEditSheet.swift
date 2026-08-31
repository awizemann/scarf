import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet for creating or editing a `ModelPreset`. Three fields: name
/// (required), model+provider (via the existing `ModelPickerRow`),
/// notes (optional). The provider is co-edited with the model — same
/// picker, same callback shape as Settings → General.
struct ModelPresetEditSheet: View {
    let initial: ModelPreset?
    let onSave: (ModelPreset) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var modelID: String
    @State private var providerID: String
    @State private var notes: String

    init(
        initial: ModelPreset?,
        onSave: @escaping (ModelPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial?.name ?? "")
        _modelID = State(initialValue: initial?.modelID ?? "")
        _providerID = State(initialValue: initial?.providerID ?? "")
        _notes = State(initialValue: initial?.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                initial == nil ? "New Preset" : "Edit Preset",
                subtitle: initial == nil
                    ? "Save a model + provider you can bind to a project."
                    : "Update this preset. Projects bound to it pick up the change on next chat boot."
            )

            ScrollView {
                VStack(spacing: ScarfSpace.s4) {
                    fieldRow("Name", required: true) {
                        ScarfTextField("e.g. Sonnet (production)", text: $name)
                            .accessibilityLabel("Name")
                    }

                    fieldRow("Model", required: true) {
                        ModelPickerRow(
                            label: "",
                            currentModel: modelID,
                            currentProvider: providerID,
                            onChange: { newModel, newProvider in
                                modelID = newModel
                                providerID = newProvider
                            }
                        )
                    }

                    fieldRow("Notes") {
                        TextEditor(text: $notes)
                            .scarfStyle(.body)
                            .frame(minHeight: 80)
                            .padding(ScarfSpace.s1)
                            .background(ScarfColor.backgroundSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                    }
                }
                .padding(ScarfSpace.s4)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(ScarfSecondaryButton())
                Button("Save") {
                    onSave(buildPreset())
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isValid)
            }
            .padding(ScarfSpace.s4)
            .background(ScarfColor.backgroundSecondary)
        }
        .frame(minWidth: 500, minHeight: 480)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func buildPreset() -> ModelPreset {
        if let existing = initial {
            return ModelPreset(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespaces),
                modelID: modelID.trimmingCharacters(in: .whitespaces),
                providerID: providerID.trimmingCharacters(in: .whitespaces),
                notes: notes.isEmpty ? nil : notes,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )
        }
        return ModelPreset(
            name: name.trimmingCharacters(in: .whitespaces),
            modelID: modelID.trimmingCharacters(in: .whitespaces),
            providerID: providerID.trimmingCharacters(in: .whitespaces),
            notes: notes.isEmpty ? nil : notes
        )
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(spacing: 4) {
                Text(label)
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                if required {
                    Text("*")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.danger)
                }
            }
            content()
        }
    }
}
