import SwiftUI
import ScarfCore
import ScarfDesign

/// The per-project settings that apply to this project's CHAT sessions:
/// which model they run on, and whether they open with edits
/// pre-approved.
///
/// **Model.** Reads the current binding from
/// `<project>/.scarf/manifest.json` and writes back via
/// `ProjectModelPresetBinding`. Two modes: "Use global default" clears
/// the binding so the project inherits `config.yaml`'s `model.default`;
/// "Use preset" picks one from the loaded list, each row showing the
/// model + provider line so users can pick by model name.
///
/// **Auto-accept edits.** Sends `session/set_mode accept_edits` at
/// session boot for this project's chats — the same thing the chat
/// header's mode picker does, decided once instead of per chat.
/// Deliberately NOT stored with the project: see
/// ``ProjectAutoAcceptEditsStore`` for why a bypass of the edit prompt
/// can't live anywhere the agent being approved can write.
///
/// Each section is capability-gated on its own RPC —
/// `hasACPSetSessionModel` (v0.13+) and `hasSessionEditAutoApproval`
/// (v0.15+) — because on an older host the setting simply wouldn't apply
/// at runtime, and a control that silently does nothing is worse than no
/// control. The entry point hides when neither is available.
struct ProjectChatSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: ServerContext
    let project: ProjectEntry
    let capabilities: HermesCapabilities

    @State private var presets: [ModelPreset] = []
    @State private var selectedID: UUID?
    @State private var useGlobalDefault: Bool = true
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var autoAcceptEdits = false

    /// The store is stateless (a defaults key + the machine HMAC key), so
    /// a fresh value per view is free and keeps this testable in
    /// isolation.
    private var autoAcceptStore: ProjectAutoAcceptEditsStore { ProjectAutoAcceptEditsStore() }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Chat settings for \(project.name)",
                subtitle: "How this project's chats start. Changes apply on the next chat session."
            )

            ScrollView {
                VStack(spacing: ScarfSpace.s3) {
                    if isLoading {
                        ProgressView()
                            .padding(ScarfSpace.s4)
                    } else {
                        if capabilities.hasSessionEditAutoApproval {
                            autoAcceptRow
                        }

                        if capabilities.hasACPSetSessionModel {
                            defaultRow

                            if presets.isEmpty {
                                emptyPresetsRow
                            } else {
                                ForEach(presets) { preset in
                                    presetRow(preset)
                                }
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

    /// The auto-accept toggle, with the caveat stated on the card rather
    /// than in a tooltip: the whole point of an approval prompt is that
    /// the user knows what turning it off does, and "sensitive paths
    /// still prompt" is the part that makes this a reasonable thing to
    /// turn on at all. Wording deliberately mirrors the chat header's
    /// own Accept Edits mode, because it IS that mode — just chosen once
    /// for the project instead of per chat.
    private var autoAcceptRow: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Toggle(isOn: $autoAcceptEdits) {
                    Text("Auto-accept edits in this project")
                        .scarfStyle(.title3)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("project.chatSettings.autoAcceptEdits")

                Text("New chats in this project open in Accept Edits, so Hermes doesn't ask before each file change. Sensitive paths still prompt, and shell commands are unaffected. Stored on this Mac only — it never travels with the project, and the agent can't turn it on for itself.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        // Local (UserDefaults + a Keychain read for the verifying key),
        // so it's read inline rather than through the transport — and it
        // is read even when the model section is hidden, so a
        // capability-degraded host still shows the truth.
        autoAcceptEdits = autoAcceptStore.isEnabled(projectId: project.path)

        guard capabilities.hasACPSetSessionModel else {
            isLoading = false
            return
        }

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

        // Auto-accept first, and locally: it can fail only one way (the
        // Keychain won't produce the machine key to tag the record), and
        // that failure has to be SAID rather than swallowed — silently
        // not saving a setting the user just switched on would leave them
        // expecting no prompts and getting them.
        if capabilities.hasSessionEditAutoApproval {
            guard autoAcceptStore.setEnabled(autoAcceptEdits, projectId: project.path) else {
                isSaving = false
                errorMessage = "Couldn't save the auto-accept setting: this Mac's Keychain wouldn't provide the key Scarf signs it with. Unlock your login keychain and try again."
                return
            }
        }

        guard capabilities.hasACPSetSessionModel else {
            isSaving = false
            dismiss()
            return
        }

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
