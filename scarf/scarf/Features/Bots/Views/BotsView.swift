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
    /// A selection change held back because the bot being left has unsaved
    /// `SOUL.md` edits. See ``PendingSelection``.
    @State private var pendingSelection: PendingSelection?
    /// Roster ordering, persisted the way `ChatSessionListPane` persists its
    /// own list preference. `@AppStorage` is app-wide rather than per-window;
    /// Scarf has no `@SceneStorage` precedent to borrow, and inventing a
    /// per-window store for one enum is not worth a new mechanism.
    @AppStorage("scarf.bots.sortOrder") private var storedSortOrder: String =
        BotsViewModel.BotRosterSort.pinnedThenName.rawValue

    /// The roster is the only way out of a bot's Agent pane, and the
    /// `SOUL.md` buffer is the only unsaved state in Bots that exists nowhere
    /// else. The per-bot view model is cached, so switching away does not by
    /// itself lose the text — but the user has no way to know that, and a
    /// buffer they believe is gone is as good as gone. So the switch is held
    /// until they say which they meant.
    private struct PendingSelection: Identifiable, Equatable {
        enum Target: Equatable {
            case bot(String)
            case peer(String)
        }
        /// The profile whose buffer is dirty — the one being left.
        let outgoing: String
        let target: Target
        var id: String {
            switch target {
            case .bot(let name):  return "bot:\(name)"
            case .peer(let name): return "peer:\(name)"
            }
        }
    }

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
                // Shared resizable-column mechanism (also used by the chat
                // 3-pane layout) instead of HSplitView: the divider drag
                // persists across relaunches, and the default is ~25%
                // wider than the old ideal (300 → 375).
                HStack(spacing: 0) {
                    roster
                        .resizableColumn(
                            key: "scarf.bots.rosterWidth",
                            defaultWidth: 375,
                            minWidth: 260,
                            maxWidth: 480
                        )
                    Divider().background(ScarfColor.border)
                    detail
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Bots")
        // Leaving the section stops the bot's `hermes acp` subprocess.
        // Nothing else would: the view model is coordinator-cached for the
        // window's lifetime, so without this the process would outlive the
        // UI that owns it and keep holding the bot profile's state.db.
        .onDisappear {
            viewModel.closeConversation()
            // A filter that survived the section switch would read, on the way
            // back in, as a roster that had lost most of its bots.
            viewModel.clearSearch()
        }
        .onAppear {
            if let capabilities = capabilitiesStore?.capabilities {
                viewModel.capabilities = capabilities
            }
            viewModel.sortOrder = BotsViewModel.BotRosterSort(rawValue: storedSortOrder) ?? .pinnedThenName
            viewModel.load()
            if viewModel.hasPeerRunCommands { viewModel.peers.load() }
            mirrorRoutinesCapability(forProfile: viewModel.selectedProfileName)
            mirrorAgentCapability(forProfile: viewModel.selectedProfileName)
        }
        .onChange(of: storedSortOrder) { _, raw in
            viewModel.sortOrder = BotsViewModel.BotRosterSort(rawValue: raw) ?? .pinnedThenName
        }
        .onChange(of: hasBotMode) { _, _ in
            if let capabilities = capabilitiesStore?.capabilities {
                viewModel.capabilities = capabilities
            }
            viewModel.load(force: true)
        }
        .onChange(of: viewModel.hasPeerRunCommands) { _, hasPeers in
            if hasPeers { viewModel.peers.load() }
        }
        // `capabilitiesStore` probes `hermes --version` asynchronously, so
        // `onAppear` above can fire before the real answer lands; re-run the
        // mirror when it changes (same reasoning as CronView's own
        // `.onChange(of: hasCronResumeRunNow)`).
        .onChange(of: hasCronResumeRunNow) { _, _ in
            mirrorRoutinesCapability(forProfile: viewModel.selectedProfileName)
            mirrorAgentCapability(forProfile: viewModel.selectedProfileName)
        }
        .onChange(of: viewModel.selectedProfileName) { _, newValue in
            mirrorRoutinesCapability(forProfile: newValue)
            mirrorAgentCapability(forProfile: newValue)
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
        .confirmationDialog(
            pendingSelection.map { "Leave \($0.outgoing) with unsaved SOUL.md changes?" } ?? "",
            isPresented: Binding(
                get: { pendingSelection != nil },
                set: { if !$0 { pendingSelection = nil } }
            )
        ) {
            Button("Discard Changes", role: .destructive) {
                if let pending = pendingSelection {
                    viewModel.agentViewModel(for: pending.outgoing).revertSoul()
                    apply(pending.target)
                }
                pendingSelection = nil
            }
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("This bot's identity prompt has edits you haven't saved. Discarding throws them away.")
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
                // The only place that re-reads activity: an explicit reload.
                // Every mutation's own `load(force: true)` leaves the per-bot
                // database opens alone, so pinning a bot doesn't re-open
                // twelve `state.db` files.
                Button("Reload") { viewModel.load(force: true, refreshActivity: true) }
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
            // LAZY: every roster group's rows were built and laid out on
            // first paint regardless of how many were on screen, and each row
            // carries an avatar (C10).
            LazyVStack(alignment: .leading, spacing: ScarfSpace.s3) {
                if let errorMessage = viewModel.errorMessage {
                    banner(errorMessage)
                }
                rosterControls
                if viewModel.isLoading && viewModel.rows.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ScarfSpace.s6)
                } else if viewModel.searchFoundNothing {
                    Text("No bots match “\(viewModel.searchText)”.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, ScarfSpace.s4)
                        .accessibilityLabel("No bots match \(viewModel.searchText)")
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

                // Remote group (B4): another host's `bot_peers` registry —
                // appears only on a host new enough for `hermes peer`
                // (v0.21+) and only once the registry has entries, matching
                // the "Hidden bots"/"Other profiles" disclosure pattern
                // above. Never merged into `viewModel.bots` — a peer named
                // the same as a local profile stays a distinct row with its
                // own selection state (`viewModel.peers.selectedPeerName`).
                // Filtered by the roster search text (name/url), for the same
                // reason every other group is: a search that silently skipped
                // this group would report "no results" for a peer that is
                // right there.
                if viewModel.hasPeerRunCommands, !filteredPeers.isEmpty {
                    VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                        Text("Remote (\(filteredPeers.count))")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ForEach(filteredPeers) { peer in
                            remoteRow(peer)
                        }
                    }
                    .accessibilityLabel("Remote peers, \(filteredPeers.count)")
                }
            }
            .padding(ScarfSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ScarfColor.backgroundPrimary)
    }

    /// Filter + ordering, above every roster group so it reads as scoping all
    /// of them (it does — hidden bots and unmanaged profiles are filtered too).
    private var rosterControls: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfTextField("Filter bots", text: $viewModel.searchText)
                .accessibilityLabel("Filter bots by name, role or profile id")
                .accessibilityIdentifier("bots.search")
            Picker("Order", selection: Binding(
                get: { storedSortOrder },
                set: { storedSortOrder = $0 }
            )) {
                ForEach(BotsViewModel.BotRosterSort.allCases, id: \.rawValue) { order in
                    Text(order.label).tag(order.rawValue)  // LocalizedStringResource
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Roster order")
            .accessibilityIdentifier("bots.sort")
        }
    }

    private func rosterRow(_ row: BotRow) -> some View {
        let isSelected = viewModel.selectedProfileName == row.identity.profileName
        let presence = viewModel.presence(forProfile: row.identity.profileName)
        return Button {
            requestSelection(.bot(row.identity.profileName))
        } label: {
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    // The photo comes from the cache, already decoded — no
                    // `NSImage(data:)` in a row body (audit A1-M4). Nil until
                    // the async fill lands, which paints the generated
                    // fallback: correct, and instant.
                    BotAvatarView(
                        identity: row.identity,
                        image: viewModel.avatarImage(for: row),
                        size: 34
                    )
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
                            if presence.isLive {
                                presenceDot(presence)
                            }
                            if row.avatarTooLarge {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(ScarfColor.warning)
                                    .help("Avatar file is too large to display; showing the generated icon instead.")
                                    .accessibilityLabel("Avatar too large to display")
                            }
                        }
                        if !row.identity.resolvedDescription.isEmpty {
                            Text(row.identity.resolvedDescription)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .lineLimit(2)
                        }
                        if let activity = row.activity, !activity.preview.isEmpty {
                            Text(activity.preview)
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                                .lineLimit(1)
                        }
                        HStack(spacing: ScarfSpace.s1) {
                            Text(row.identity.profileName)
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                            if let last = row.activity?.lastMessageAt {
                                Text(Self.relative(last))
                                    .scarfStyle(.footnote)
                                    .foregroundStyle(ScarfColor.foregroundFaint)
                            }
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

    /// Remote peers matching the roster search text — same substring,
    /// case- and diacritic-insensitive match `BotsViewModel.matches` uses for
    /// local rows, against the two things a user would type for a peer: its
    /// name and its gateway URL.
    private var filteredPeers: [HermesBotPeer] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.peers.peers }
        return viewModel.peers.peers.filter { peer in
            [peer.name, peer.url].contains { field in
                field.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: .current
                ) != nil
            }
        }
    }

    /// A row from the `bot_peers` registry — distinct visual grammar from a
    /// local bot row (a "remote" badge, no pin/hidden affordances, no
    /// generated-avatar identity backed by a real profile) so it reads
    /// immediately as "another host," not a local bot.
    private func remoteRow(_ peer: HermesBotPeer) -> some View {
        let isSelected = viewModel.peers.selectedPeerName == peer.name
        return Button {
            requestSelection(.peer(peer.name))
        } label: {
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    BotAvatarView(displayName: peer.name, shapeString: nil, colorHex: nil, imageData: nil, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: ScarfSpace.s2) {
                            Text(peer.name)
                                .scarfStyle(.bodyEmph)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .lineLimit(1)
                            ScarfBadge("remote", kind: .info)
                        }
                        if !peer.note.isEmpty {
                            Text(peer.note)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .lineLimit(2)
                        }
                        Text(peer.url)
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(peer.name), remote peer at \(peer.url)")
        .accessibilityIdentifier("bots.remote.\(peer.name)")
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                .strokeBorder(isSelected ? ScarfColor.accent : Color.clear, lineWidth: 1.5)
        )
    }

    private func rowAccessibilityLabel(_ row: BotRow) -> String {
        var parts = [row.identity.resolvedTitle,
                     String(localized: "profile \(row.identity.profileName)")]
        if !row.identity.isBotManaged { parts.append(String(localized: "not a bot yet")) }
        if row.isPinned { parts.append(String(localized: "pinned")) }
        if row.isHidden { parts.append(String(localized: "hidden")) }
        let presence = viewModel.presence(forProfile: row.identity.profileName)
        if presence.isLive, let spoken = presence.spokenDescription { parts.append(spoken) }
        if let last = row.activity?.lastMessageAt {
            parts.append(String(localized: "last active \(Self.relative(last))"))
        }
        return parts.joined(separator: ", ")
    }

    /// The live indicator. A dot plus a word — colour alone would carry the
    /// whole meaning otherwise, and "replying" vs "open" is exactly the
    /// distinction someone who can't tell the two hues apart needs.
    private func presenceDot(_ presence: BotPresence) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(presence == .streaming ? ScarfColor.accent : ScarfColor.success)
                .frame(width: 6, height: 6)
            Text(presence.badgeLabel)
                .scarfStyle(.footnote)
                .foregroundStyle(presence == .streaming ? ScarfColor.accent : ScarfColor.success)
        }
        // The row's own label already speaks the presence; a second
        // announcement between the title and the role would just be noise.
        .accessibilityHidden(true)
    }

    /// Relative timestamps: "2 minutes ago" reads as activity, an absolute
    /// clock time reads as a log. Same formatter configuration the Sessions
    /// and Kanban lists use, so the roster doesn't invent a third dialect.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Routines (B4)

    /// The named capability CronView itself gates Resume & Run Now on
    /// (`hasCronResumeRunNow`, `= isV0206OrLater`), used here in place of the
    /// raw version check so this pane can't drift from what it actually
    /// means if the floor for that affordance ever moves independently of
    /// the raw semver (A2-F7).
    private var hasCronResumeRunNow: Bool {
        capabilitiesStore?.capabilities.hasCronResumeRunNow ?? false
    }

    /// Fetch the cached per-bot routines view model. Pure — no capability
    /// mirroring here. That write used to happen inline in this accessor,
    /// which is called from the `@ViewBuilder` `detail` body: a stored
    /// property assignment during view-builder evaluation runs once per
    /// body pass (SwiftUI may re-evaluate `detail` for reasons that have
    /// nothing to do with a capability change), which is fragile action
    /// placement — the same anti-pattern `agentViewModel(for:)` below was
    /// also fixed to avoid. `mirrorRoutinesCapability(for:)` below does the
    /// write from `.onAppear`/`.onChange` instead, mirroring `CronView`'s own
    /// pattern (A1-M2).
    private func routinesViewModel(for row: BotRow) -> BotRoutinesViewModel {
        viewModel.routinesViewModel(for: row.identity.profileName)
    }

    /// Mirror the current capability answer onto the selected bot's routines
    /// view model. Only the visible one needs it live — a not-yet-visited
    /// bot's cached `BotRoutinesViewModel` picks up the current value the
    /// first time `routinesViewModel(for:)` creates it (via
    /// `BotsViewModel.capabilities`'s own propagation is unrelated; this is
    /// the CronViewModel-shaped flag `BotRoutinesView` reads directly).
    private func mirrorRoutinesCapability(forProfile profileName: String?) {
        guard let profileName else { return }
        viewModel.routinesViewModel(for: profileName).isV0206OrLater = hasCronResumeRunNow
    }

    // MARK: - Selection

    /// Route every roster selection through the unsaved-changes guard.
    ///
    /// A local bot and a remote peer are separate identity spaces: whichever
    /// is selected clears the other, so the detail pane never has two
    /// claimants (see `detail`).
    private func requestSelection(_ target: PendingSelection.Target) {
        if case .bot(let name) = target, name == viewModel.selectedProfileName { return }
        if let outgoing = viewModel.selectedProfileName,
           viewModel.unsavedAgentEdits(forProfile: outgoing) {
            pendingSelection = PendingSelection(outgoing: outgoing, target: target)
            return
        }
        apply(target)
    }

    private func apply(_ target: PendingSelection.Target) {
        switch target {
        case .bot(let name):
            viewModel.peers.selectedPeerName = nil
            viewModel.selectedProfileName = name
        case .peer(let name):
            viewModel.selectedProfileName = nil
            viewModel.peers.selectedPeerName = name
        }
    }

    // MARK: - Agent configuration (Phase B P1)

    /// Fetch the cached per-bot agent view model. Pure — no capability
    /// mirroring here, for the same reason `routinesViewModel(for:)` isn't:
    /// this is called from the `@ViewBuilder` `detail` body, and a stored
    /// property write during view-builder evaluation is fragile action
    /// placement. `mirrorAgentCapability(forProfile:)` below does the write
    /// from `.onAppear`/`.onChange` instead.
    private func agentViewModel(for row: BotRow) -> BotAgentViewModel {
        viewModel.agentViewModel(for: row.identity.profileName)
    }

    /// Mirror the current capability answer onto the selected bot's agent
    /// view model. Only the visible one needs it live — a not-yet-visited
    /// bot's cached `BotAgentViewModel` picks up the current value the first
    /// time `agentViewModel(for:)` creates it.
    private func mirrorAgentCapability(forProfile profileName: String?) {
        guard let profileName, let capabilities = capabilitiesStore?.capabilities else { return }
        viewModel.agentViewModel(for: profileName).capabilities = capabilities
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
                onDelete: { pendingDelete = row },
                conversation: {
                    // Only bot-managed profiles get a conversation: an
                    // ordinary profile under "Other profiles" has no bot
                    // identity and no canonical Bot Chat to open.
                    if let conversation = viewModel.conversation,
                       conversation.profileName == row.identity.profileName {
                        BotConversationView(
                            viewModel: conversation,
                            botTitle: row.identity.resolvedTitle
                        )
                    } else {
                        BotDetailPlaceholder(
                            title: "Chat",
                            detail: row.identity.isBotManaged
                                ? "Opening this bot’s conversation…"
                                : "Only bots have a conversation. Add this profile to Bots to message it.",
                            icon: "text.bubble"
                        )
                    }
                },
                automation: {
                    BotRoutinesView(
                        viewModel: routinesViewModel(for: row),
                        hasCronBotChatDelivery: capabilitiesStore?.capabilities.hasCronBotChatDelivery ?? false
                    )
                },
                agent: {
                    BotAgentView(viewModel: agentViewModel(for: row))
                }
            )
            .id(row.identity.profileName)
            .task(id: row.identity.profileName) {
                guard row.identity.isBotManaged else { return }
                viewModel.openConversation(for: row.identity.profileName)
            }
        } else if viewModel.hasPeerRunCommands, let peer = viewModel.peers.selectedPeer {
            RemoteBotDetailView(viewModel: viewModel.peers, peer: peer)
                .id(peer.name)
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
        panel.message = String(localized: "Choose a picture for this bot. Large images are scaled down to fit Hermes' 2 MB avatar limit.")
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


/// `BotPresence.label` / `.accessibilityDescription` are English tokens from
/// ScarfCore, which has no string catalog — binding them to `Text` made the
/// roster badge permanently English. The localized vocabulary lives here, one
/// extractable string per case.
private extension BotPresence {
    var badgeLabel: LocalizedStringKey {
        switch self {
        case .offline: return ""
        case .connecting: return "connecting"
        case .connected: return "open"
        case .streaming: return "replying"
        }
    }

    var spokenDescription: String? {
        switch self {
        case .offline: return nil
        case .connecting: return String(localized: "conversation connecting")
        case .connected: return String(localized: "conversation open")
        case .streaming: return String(localized: "replying now")
        }
    }
}
