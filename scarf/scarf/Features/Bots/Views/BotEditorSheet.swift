import SwiftUI
import ScarfCore
import ScarfDesign

/// What the editor sheet was opened for. `Identifiable` so `BotsView` can
/// present it with `.sheet(item:)` — which, unlike `isPresented`, can't show
/// a sheet built from a stale row.
struct BotEditorContext: Identifiable {
    enum Mode: Equatable {
        case create
        case edit
    }

    let mode: Mode
    let draft: BotDraft
    /// The stored avatar for an existing bot, so the sheet previews the real
    /// picture rather than the generated fallback.
    let avatar: HermesBotAvatar?

    var id: String { (mode == .create ? "create:" : "edit:") + draft.profileName }

    static func create() -> BotEditorContext {
        BotEditorContext(
            mode: .create,
            draft: BotDraft(identity: HermesBotIdentity(profileName: "", profileDirectory: "")),
            avatar: nil
        )
    }

    static func edit(_ row: BotRow) -> BotEditorContext {
        BotEditorContext(mode: .edit, draft: BotDraft(identity: row.identity), avatar: row.avatar)
    }
}

/// Create or edit one bot.
///
/// Create is two steps behind one button: `hermes profile create` makes the
/// profile, then the identity is written into its `profile.yaml`. Edit is
/// only the second step. The sheet doesn't know that — it hands back a
/// ``BotDraft`` and the view model owns the sequencing and its partial-failure
/// semantics.
struct BotEditorSheet: View {
    let context: BotEditorContext
    let onSave: (BotDraft, String?) -> Void
    let onCancel: () -> Void
    let onChooseAvatar: () -> Void

    @State private var draft: BotDraft
    /// Optional `--clone-from` source, create-only.
    @State private var cloneFrom: String = ""

    init(
        context: BotEditorContext,
        onSave: @escaping (BotDraft, String?) -> Void,
        onCancel: @escaping () -> Void,
        onChooseAvatar: @escaping () -> Void
    ) {
        self.context = context
        self.onSave = onSave
        self.onCancel = onCancel
        self.onChooseAvatar = onChooseAvatar
        _draft = State(initialValue: context.draft)
    }

    private var isCreate: Bool { context.mode == .create }

    /// Create needs a valid, addressable, non-`default` profile id. Edit
    /// already has one. `HermesProfileScope.isValidName` alone accepts
    /// `"default"` (it IS a valid, addressable name — just not one you can
    /// create), so `createBot` refuses it separately; mirroring that refusal
    /// here disables the button instead of letting the user hit Create and
    /// read a CLI-shaped error for a name the field could have caught
    /// (A1-L10).
    private var canSave: Bool {
        guard isCreate else { return true }
        let name = draft.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return HermesProfileScope.isValidName(name) && name != HermesProfileScope.defaultProfileName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    heading
                    if isCreate { profileIdField }
                    identityFields
                    appearanceFields
                    flagFields
                    footnote
                }
                .padding(ScarfSpace.s5)
            }
            ScarfDivider()
            actions
        }
        .frame(width: 520, height: 620)
        .background(ScarfColor.backgroundPrimary)
    }

    // MARK: - Sections

    private var heading: some View {
        HStack(alignment: .center, spacing: ScarfSpace.s3) {
            BotAvatarView(
                displayName: draft.title.isEmpty ? draft.profileName : draft.title,
                shapeString: draft.shape.isEmpty ? nil : draft.shape,
                colorHex: draft.color.isEmpty ? nil : draft.color,
                imageData: context.avatar?.data,
                size: 56
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(isCreate ? "New bot" : "Edit bot")
                    .scarfStyle(.title3)
                Text(isCreate
                     ? "Creates a Hermes profile with its own memory, skills and settings."
                     : "Changes the name, role and face this profile shows as.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer(minLength: 0)
            if !isCreate {
                Button("Choose Picture…") { onChooseAvatar() }
                    .buttonStyle(ScarfGhostButton())
                    .accessibilityLabel("Choose a picture for this bot")
            }
        }
    }

    private var profileIdField: some View {
        field(
            label: "Profile id",
            help: "Lowercase letters, digits, dashes and underscores. This becomes the directory name and the argument to hermes -p."
        ) {
            ScarfTextField("research-bot", text: $draft.profileName)
                .accessibilityLabel("Profile id")
                .accessibilityHint("Lowercase letters, digits, dashes and underscores")
        }
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            field(label: "Name", help: "What this bot is called in the roster.") {
                ScarfTextField("Research", text: $draft.title)
                    .accessibilityLabel("Bot name")
            }
            field(label: "Role", help: "One or two sentences. Hermes also routes work on this text.") {
                TextEditor(text: $draft.description)
                    .scarfStyle(.body)
                    .frame(height: 72)
                    .padding(ScarfSpace.s2)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                    )
                    .accessibilityLabel("Bot role")
            }
            if isCreate {
                field(
                    label: "Clone from",
                    help: "Optional. Copies an existing profile's config and skills into the new one. Leave empty to start fresh."
                ) {
                    ScarfTextField("profile id (optional)", text: $cloneFrom)
                        .accessibilityLabel("Clone from profile id, optional")
                }
            }
        }
    }

    private var appearanceFields: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            ScarfSectionHeader("Face", subtitle: "Used when there's no picture — generated from the name otherwise.")
            HStack(alignment: .top, spacing: ScarfSpace.s3) {
                field(label: "Color", help: "A hex color, e.g. #C1502E.") {
                    ScarfTextField("#C1502E", text: $draft.color)
                        .accessibilityLabel("Avatar color, hex")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shape")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Picker("Shape", selection: $draft.shape) {
                        Text("Automatic").tag("")
                        ForEach(BotAvatarGenerator.Shape.allCases, id: \.rawValue) { shape in
                            Text(shape.rawValue).tag(shape.rawValue)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Avatar shape")
                }
            }
        }
    }

    private var flagFields: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Toggle("Pin to the top of the roster", isOn: $draft.pinned)
                .accessibilityLabel("Pin this bot to the top of the roster")
            Toggle("Hide from the roster", isOn: $draft.hidden)
                .accessibilityLabel("Hide this bot from the roster")
        }
    }

    /// The concurrent-edit caveat, stated once and quietly.
    ///
    /// Hermes Desktop writes the same block through the gateway's
    /// compare-and-swap; Scarf writes the file directly, so a simultaneous
    /// desktop edit of the *same bot* can be overwritten either way. In
    /// practice this needs both apps open on one bot at once, which is why
    /// it's a footnote rather than a banner — the mitigation (re-read
    /// immediately before writing, only on an explicit save) is already in
    /// the write path.
    private var footnote: some View {
        Label(
            "Saving rewrites this profile's profile.yaml. If Hermes Desktop is editing the same bot at the same time, the last save wins.",
            systemImage: "info.circle"
        )
        .scarfStyle(.footnote)
        .foregroundStyle(ScarfColor.foregroundFaint)
        .accessibilityLabel("Note: saving rewrites this profile's profile.yaml. If Hermes Desktop is editing the same bot at the same time, the last save wins.")
    }

    private var actions: some View {
        HStack(spacing: ScarfSpace.s2) {
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(ScarfGhostButton())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel")
            Button(isCreate ? "Create Bot" : "Save") {
                let trimmed = cloneFrom.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(draft, isCreate && !trimmed.isEmpty ? trimmed : nil)
            }
            .buttonStyle(ScarfPrimaryButton())
            .disabled(!canSave)
            .accessibilityLabel(isCreate ? "Create bot" : "Save changes to this bot")
        }
        .padding(ScarfSpace.s4)
    }

    // MARK: - Field scaffold

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            content()
            Text(help)
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
    }
}
