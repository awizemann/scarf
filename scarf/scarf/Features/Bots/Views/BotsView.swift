import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScarfCore
import ScarfDesign

/// Bots — the roster of Hermes profiles seen as agents you talk to, above
/// Chat in the sidebar because a bot is the thing you pick *before* you pick
/// a conversation.
///
/// A bot is a profile: everything here reads and writes
/// `<profile_dir>/profile.yaml` (B0's `BotsService`) and shells out to
/// `hermes profile` for the lifecycle verbs. Non-bot profiles are listed too,
/// behind "Other profiles", because "make this profile a bot" is a real
/// action and a roster that hides the candidates couldn't offer it.
///
/// Visual grammar follows the other single-pane routes (Peers, Webhooks):
/// `ScarfPageHeader`, `ScarfCard` rows, `ScarfSectionHeader` labels,
/// plain-literal strings.
struct BotsView: View {
    // Coordinator-cached (t-aud24) so the roster + avatar bytes survive
    // section switches instead of re-reading every profile over SSH.
    @Bindable var viewModel: BotsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    @State private var editor: BotEditorContext?
    @State private var pendingDelete: BotRow?
    @State private var renaming: BotRow?
    @State private var renameText = ""

    init(viewModel: BotsViewModel) {
        self.viewModel = viewModel
    }

    /// Live capability answer. The store probes `hermes --version`
    /// asynchronously, so this can flip after the first render — the
    /// `.onChange` below is what keeps the surface honest when it does
    /// (same async-probe race `CronView` handles).
    private var hasBotMode: Bool {
        capabilitiesStore?.capabilities.hasBotMode ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !hasBotMode {
                unsupportedState
            } else {
                HSplitView {
                    roster
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                    detail
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Bots")
        .onAppear {
            if let capabilities = capabilitiesStore?.capabilities {
                viewModel.capabilities = capabilities
            }
            viewModel.load()
        }
        .onChange(of: hasBotMode) { _, _ in
            if let capabilities = capabilitiesStore?.capabilities {
                viewModel.capabilities = capabilities
            }
            viewModel.load(force: true)
        }
        .sheet(item: $editor) { context in
            BotEditorSheet(
                context: context,
                onSave: { draft, cloneFrom in
                    switch context.mode {
                    case .create:
                        viewModel.createBot(profileName: draft.profileName, draft: draft, cloneFrom: cloneFrom)
                    case .edit:
                        viewModel.save(draft)
                    }
                    editor = nil
                },
                onCancel: { editor = nil },
                onChooseAvatar: { chooseAvatar(forProfile: context.draft.profileName) }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Delete profile \($0.identity.profileName)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Profile", role: .destructive) {
                if let row = pendingDelete { viewModel.delete(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This runs hermes profile delete. It removes the whole profile directory — sessions, memories, state.db and .env — and can't be undone.")
        }
        .sheet(item: $renaming) { row in
            renameSheet(row)
        }
    }

    // MARK: - Header

    private var header: some View {
        ScarfPageHeader(
            "Bots",
            subtitle: "Each bot is a Hermes profile — its own memory, skills and settings."
        ) {
            HStack(spacing: ScarfSpace.s2) {
                if viewModel.isWorking { ProgressView().controlSize(.small) }
                if let message = viewModel.message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.success)
                }
                Button("Reload") { viewModel.load(force: true) }
                    .buttonStyle(ScarfGhostButton())
                    .accessibilityLabel("Reload the bot roster")
                Button {
                    editor = .create()
                } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(!hasBotMode || viewModel.isWorking)
                .accessibilityLabel("Create a new bot")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - States

    private var unsupportedState: some View {
        VStack(spacing: ScarfSpace.s3) {
            Image(systemName: "person.crop.square.badge.clock")
                .font(.largeTitle)
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("Bot Mode needs Hermes v0.20.3 or newer")
                .scarfStyle(.bodyEmph)
            Text("Bot identities live in each profile's ui_meta, which older agents don't read. Update Hermes on this host and reload.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bot Mode requires Hermes version 0.20.3 or newer")
    }

    private var emptyState: some View {
        VStack(spacing: ScarfSpace.s3) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.largeTitle)
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No bots yet")
                .scarfStyle(.bodyEmph)
            Text("""
                 A bot is a Hermes profile with a name, a face and a role. Each one gets \
                 its own memory, skills, credentials and settings, so a research bot and \
                 a deploy bot never share context.
                 """)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                editor = .create()
            } label: {
                Label("Create Bot", systemImage: "plus")
            }
            .buttonStyle(ScarfPrimaryButton())
            .disabled(viewModel.isWorking)
            .accessibilityLabel("Create your first bot")
            if !viewModel.otherProfiles.isEmpty {
                Text("Already have profiles? Open Other profiles below to turn one into a bot.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ScarfSpace.s6)
    }

    // MARK: - Roster

    private var roster: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                if let errorMessage = viewModel.errorMessage {
                    banner(errorMessage)
                }
                if viewModel.isLoading && viewModel.rows.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ScarfSpace.s6)
                } else if viewModel.isEmptyRoster {
                    emptyState
                } else {
                    ForEach(viewModel.bots) { row in
                        rosterRow(row)
                    }
                }

                if !viewModel.hiddenBots.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.showHiddenBots) {
                        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                            ForEach(viewModel.hiddenBots) { row in
                                rosterRow(row)
                            }
                        }
                        .padding(.top, ScarfSpace.s2)
                    } label: {
                        Text("Hidden bots (\(viewModel.hiddenBots.count))")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .accessibilityLabel("Hidden bots, \(viewModel.hiddenBots.count)")
                }

                if !viewModel.otherProfiles.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.showOtherProfiles) {
                        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                            Text("Hermes profiles that aren't set up as bots. Making one a bot only adds a name, face and role — nothing in the profile changes.")
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                            ForEach(viewModel.otherProfiles) { row in
                                rosterRow(row)
                            }
                        }
                        .padding(.top, ScarfSpace.s2)
                    } label: {
                        Text("Other profiles (\(viewModel.otherProfiles.count))")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .accessibilityLabel("Other profiles, \(viewModel.otherProfiles.count)")
                }
            }
            .padding(ScarfSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ScarfColor.backgroundPrimary)
    }

    private func rosterRow(_ row: BotRow) -> some View {
        let isSelected = viewModel.selectedProfileName == row.identity.profileName
        return Button {
            viewModel.selectedProfileName = row.identity.profileName
        } label: {
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    BotAvatarView(identity: row.identity, avatar: row.avatar, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: ScarfSpace.s2) {
                            Text(row.identity.resolvedTitle)
                                .scarfStyle(.bodyEmph)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .lineLimit(1)
                            if row.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ScarfColor.accent)
                                    .accessibilityLabel("Pinned")
                            }
                        }
                        if !row.identity.resolvedDescription.isEmpty {
                            Text(row.identity.resolvedDescription)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .lineLimit(2)
                        }
                        HStack(spacing: ScarfSpace.s1) {
                            Text(row.identity.profileName)
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                            if !row.identity.isBotManaged {
                                ScarfBadge("profile", kind: .neutral)
                            }
                            if row.isHidden {
                                ScarfBadge("hidden", kind: .warning)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityIdentifier("bots.row.\(row.identity.profileName)")
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                .strokeBorder(isSelected ? ScarfColor.accent : Color.clear, lineWidth: 1.5)
        )
        .contextMenu {
            if row.identity.isBotManaged {
                Button(row.isPinned ? "Unpin" : "Pin") { viewModel.togglePinned(row) }
                Button(row.isHidden ? "Unhide" : "Hide") { viewModel.toggleHidden(row) }
                Button("Edit…") { editor = .edit(row) }
            } else {
                Button("Make a Bot") { viewModel.promote(row) }
            }
        }
    }

    private func rowAccessibilityLabel(_ row: BotRow) -> String {
        var parts = [row.identity.resolvedTitle, "profile \(row.identity.profileName)"]
        if !row.identity.isBotManaged { parts.append("not a bot yet") }
        if row.isPinned { parts.append("pinned") }
        if row.isHidden { parts.append("hidden") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let row = viewModel.selectedRow {
            BotDetailView(
                row: row,
                isWorking: viewModel.isWorking,
                onEdit: { editor = .edit(row) },
                onPromote: { viewModel.promote(row) },
                onDemote: { viewModel.demote(row) },
                onChooseAvatar: { chooseAvatar(forProfile: row.identity.profileName) },
                onRename: {
                    renameText = row.identity.profileName
                    renaming = row
                },
                onDelete: { pendingDelete = row }
            )
        } else {
            VStack(spacing: ScarfSpace.s2) {
                Text("Select a bot")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScarfColor.backgroundPrimary)
        }
    }

    // MARK: - Rename

    private func renameSheet(_ row: BotRow) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Rename profile")
                .scarfStyle(.title3)
            Text(row.identity.isDefaultProfile
                 ? "The default profile's id can't change — hermes profile rename sets its display name instead."
                 : "This runs hermes profile rename, which moves the profile directory and updates its alias.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            ScarfTextField("new profile id", text: $renameText)
                .accessibilityLabel("New profile id")
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .buttonStyle(ScarfGhostButton())
                Button("Rename") {
                    viewModel.rename(row, to: renameText)
                    renaming = nil
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
    }

    // MARK: - Avatar picking

    /// Pick an image file, downscale it to fit Hermes' 2MB asset cap, and
    /// write it as the profile's `avatar.png`.
    private func chooseAvatar(forProfile name: String) {
        // The create sheet has no profile yet (and hides its picture
        // button for that reason) — belt and braces so a future call site
        // can't aim an asset write at an unresolvable profile id, which
        // `HermesProfileScope.resolveHome` would fail *safe* into the
        // DEFAULT profile's directory.
        guard BotsService.isAddressableProfile(name) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff, .image]
        panel.message = "Choose a picture for this bot. Large images are scaled down to fit Hermes' 2 MB avatar limit."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BotAvatarImport.pngData(fromFileAt: url)
            viewModel.setAvatar(data, forProfile: name)
        } catch BotAvatarImport.Failure.unreadable {
            viewModel.errorMessage = "That file isn't an image macOS can read."
        } catch {
            viewModel.errorMessage = "That image couldn't be scaled under Hermes' 2 MB avatar limit. Try a smaller picture."
        }
    }

    // MARK: - Banner

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.danger)
            // Verbatim: `hermes profile`'s refusals ("profile 'x' already
            // exists", "cannot delete the active profile") carry the remedy.
            Text(text)
                .scarfStyle(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.danger.opacity(0.12))
        )
        .accessibilityLabel("Error: \(text)")
    }
}
