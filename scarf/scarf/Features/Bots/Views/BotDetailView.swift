import SwiftUI
import ScarfCore
import ScarfDesign

/// The detail pane for one bot: identity summary, actions, and two **slots**
/// later work packages fill in — B3 hangs the bot's chat surface off
/// `conversation`, B4 hangs routines/peers off `automation`.
///
/// The slots are generic view parameters with placeholder defaults rather
/// than `if hasChat { … }` branches inside this file, so B3 and B4 add their
/// surfaces by passing a view at the one call site in ``BotsView`` and never
/// have to re-cut this layout. Everything above the slots (header card,
/// identity rows, destructive actions) is stable.
struct BotDetailView<Conversation: View, Automation: View>: View {
    let row: BotRow
    let isWorking: Bool
    let onEdit: () -> Void
    let onPromote: () -> Void
    let onDemote: () -> Void
    let onChooseAvatar: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    private let conversation: Conversation
    private let automation: Automation

    init(
        row: BotRow,
        isWorking: Bool,
        onEdit: @escaping () -> Void,
        onPromote: @escaping () -> Void,
        onDemote: @escaping () -> Void,
        onChooseAvatar: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder conversation: () -> Conversation = {
            BotDetailPlaceholder(
                title: "Chat",
                detail: "Talking to this bot from here lands in a later update. For now, switch to it with hermes profile use and open Chat.",
                icon: "text.bubble"
            )
        },
        @ViewBuilder automation: () -> Automation = {
            BotDetailPlaceholder(
                title: "Routines & peers",
                detail: "Scheduled work and bot-to-bot messaging for this profile land in a later update.",
                icon: "clock.arrow.2.circlepath"
            )
        }
    ) {
        self.row = row
        self.isWorking = isWorking
        self.onEdit = onEdit
        self.onPromote = onPromote
        self.onDemote = onDemote
        self.onChooseAvatar = onChooseAvatar
        self.onRename = onRename
        self.onDelete = onDelete
        self.conversation = conversation()
        self.automation = automation()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                identityCard
                identityDetails
                conversation
                automation
                dangerZone
            }
            .padding(ScarfSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ScarfColor.backgroundPrimary)
    }

    // MARK: - Identity

    private var identityCard: some View {
        ScarfCard {
            HStack(alignment: .top, spacing: ScarfSpace.s4) {
                Button(action: onChooseAvatar) {
                    BotAvatarView(identity: row.identity, avatar: row.avatar, size: 72)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help("Choose a picture for this bot")
                .accessibilityLabel("Bot picture for \(row.identity.resolvedTitle). Activate to choose an image file.")

                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    Text(row.identity.resolvedTitle)
                        .scarfStyle(.title3)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .accessibilityLabel("Bot name: \(row.identity.resolvedTitle)")
                    if !row.identity.resolvedDescription.isEmpty {
                        Text(row.identity.resolvedDescription)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .accessibilityLabel("Role: \(row.identity.resolvedDescription)")
                    }
                    HStack(spacing: ScarfSpace.s1) {
                        if row.identity.isBotManaged {
                            ScarfBadge("bot", kind: .brand)
                        } else {
                            ScarfBadge("profile only", kind: .neutral)
                        }
                        if row.isPinned { ScarfBadge("pinned", kind: .info) }
                        if row.isHidden { ScarfBadge("hidden", kind: .warning) }
                        ForEach(row.identity.effectiveGroups, id: \.self) { group in
                            ScarfBadge(group, kind: .neutral)
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: ScarfSpace.s2) {
                    if row.identity.isBotManaged {
                        Button("Edit") { onEdit() }
                            .buttonStyle(ScarfPrimaryButton())
                            .disabled(isWorking)
                            .accessibilityLabel("Edit this bot")
                    } else {
                        Button("Make a Bot") { onPromote() }
                            .buttonStyle(ScarfPrimaryButton())
                            .disabled(isWorking)
                            .accessibilityLabel("Turn this profile into a bot")
                    }
                    Button("Rename…") { onRename() }
                        .buttonStyle(ScarfGhostButton())
                        .disabled(isWorking)
                        .accessibilityLabel("Rename this profile")
                }
            }
        }
    }

    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader("Identity", subtitle: "Stored in this profile's profile.yaml")
            ScarfCard(padding: ScarfSpace.s3) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    detailRow("Profile id", row.identity.profileName)
                    detailRow("Directory", row.identity.profileDirectory)
                    detailRow("Color", row.identity.color ?? "generated from the name")
                    detailRow("Shape", row.identity.shape ?? "generated from the name")
                    detailRow("Picture", row.avatar == nil ? "generated" : "stored image")
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Destructive

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader("Danger zone")
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        if row.identity.isBotManaged {
                            Text("Remove from Bots")
                                .scarfStyle(.bodyEmph)
                            Text("Hides this profile from the bot roster. The profile, its sessions and its memories are untouched.")
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                        Text("Delete profile")
                            .scarfStyle(.bodyEmph)
                            .padding(.top, row.identity.isBotManaged ? ScarfSpace.s2 : 0)
                        Text("Runs hermes profile delete — removes the profile directory, including sessions, memories, state.db and .env. Can't be undone.")
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: ScarfSpace.s2) {
                        if row.identity.isBotManaged {
                            Button("Remove from Bots") { onDemote() }
                                .buttonStyle(ScarfGhostButton())
                                .disabled(isWorking)
                                .accessibilityLabel("Remove \(row.identity.resolvedTitle) from the bot roster")
                        }
                        Button("Delete Profile…") { onDelete() }
                            .buttonStyle(ScarfDestructiveButton())
                            .disabled(isWorking || row.identity.isDefaultProfile)
                            .help(row.identity.isDefaultProfile
                                  ? "The default profile can't be deleted."
                                  : "Permanently delete this profile.")
                            .accessibilityLabel("Delete the profile \(row.identity.profileName)")
                    }
                }
            }
        }
    }
}

/// The stand-in a slot renders until its work package fills it. Deliberately
/// a real, labelled section rather than nothing: it tells the user the
/// capability is coming and gives B3/B4 a shape to match.
struct BotDetailPlaceholder: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader(title)
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    Image(systemName: icon)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                    Text(detail)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
