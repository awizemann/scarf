import SwiftUI
import ScarfCore
import ScarfDesign

/// Editor for `profile_routes` (Hermes v0.19+) — the rules that send inbound
/// gateway messages to different profiles depending on where they came from.
///
/// **The UI mirrors Hermes's real matching model, which is NOT top-down.**
/// `parse_profile_routes` ranks rules by an additive specificity score
/// (thread 8 + channel 4 + server 2) and `match_profile_route` takes the
/// first match in *that* order, so list position only breaks ties. Rows are
/// therefore rendered in effective match order with an explicit rank badge
/// and score, never in raw file order — a top-down-looking list would teach
/// the wrong mental model.
///
/// Rules Hermes would silently drop (no `platform`, no/invalid `profile`) are
/// pushed below the ranked ones and flagged, because they never participate
/// in matching. Routing as a whole is inert unless
/// `gateway.multiplex_profiles` is on, so that prerequisite lives here too.
///
/// Writes go through `SettingsViewModel.saveProfileRoutes` → direct-YAML
/// (`hermes config set` can't express a list of maps), which rewrites the
/// whole block, preserving unmodeled keys inside each rule verbatim.
struct ProfileRoutesSection: View {
    @Bindable var viewModel: SettingsViewModel
    let capabilities: HermesCapabilities

    /// Rule currently open in the editor sheet — `nil` when closed.
    @State private var editing: HermesProfileRoute?
    /// True when the sheet is editing a brand-new rule (Cancel discards it).
    @State private var editingIsNew = false

    private var block: HermesProfileRoutes { viewModel.config.profileRoutes }

    /// Rows in the order Hermes evaluates them, with unmatched-forever rules
    /// (the ones Hermes drops) appended, unranked.
    private var rankedRows: [(rank: Int?, route: HermesProfileRoute)] {
        let ordered = block.effectiveOrder
        var rows: [(Int?, HermesProfileRoute)] = ordered.enumerated().map { ($0.offset + 1, $0.element) }
        let rankedIDs = Set(ordered.map(\.id))
        rows += block.routes.filter { !rankedIDs.contains($0.id) }.map { (nil, $0) }
        return rows.map { (rank: $0.0, route: $0.1) }
    }

    var body: some View {
        SettingsSection(title: "Profile Routing", icon: "arrow.triangle.branch") {
            explainer

            if block.location == .unsupported {
                unsupportedNotice
            } else {
                editor
            }
        }
        .sheet(item: $editing) { route in
            ProfileRouteEditorSheet(
                route: route,
                isNew: editingIsNew,
                onSave: { edited in
                    if editingIsNew {
                        save(block.routes + [edited])
                    } else {
                        replace(edited)
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    /// `profile_routes` written as a populated flow list (`[{…}]`). It's live
    /// for Hermes, but Scarf won't rewrite that shape — and editing the other
    /// form would produce changes Hermes ignores, so the editor stands down.
    private var unsupportedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(ScarfColor.warning)
            Text("`profile_routes` is written as an inline list in config.yaml. Scarf only edits the block form — rewrite it as indented `- name:` entries (or edit the file directly) to manage routes here.")
                .scarfStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    @ViewBuilder
    private var editor: some View {

            if !block.multiplexProfiles {
                multiplexPrerequisite
            }

            ForEach(rankedRows, id: \.route.id) { row in
                ProfileRouteRow(
                    rank: row.rank,
                    route: row.route,
                    // v0.20.4+ — `gateway.multiplex_profile_allowlist`.
                    // `nil` allowlist (key absent) means "no warning".
                    allowlistWarning: capabilities.isV0204OrLater
                        ? viewModel.multiplexProfileAllowlistWarning(for: row.route.profile)
                        : nil,
                    onEdit: {
                        editingIsNew = false
                        editing = row.route
                    },
                    onToggleEnabled: { enabled in
                        var updated = row.route
                        updated.enabled = enabled
                        updated.enabledIsExplicit = true
                        replace(updated)
                    },
                    onRemove: { remove(row.route) }
                )
            }

            if block.routes.isEmpty {
                Text("No routes — every platform uses the active profile.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ScarfColor.backgroundTertiary.opacity(0.5))
            }

            HStack {
                if block.location == .topLevel {
                    Text("Editing the top-level `profile_routes:` block (Hermes reads it in preference to `gateway.profile_routes`).")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
                Button("Add Route") {
                    editingIsNew = true
                    editing = HermesProfileRoute(platform: "discord")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    private var explainer: some View {
        Text("Routes are ranked by how specific they are (thread + 8, channel + 4, server + 2) — not by list order. The highest-scoring rule that matches every field it declares wins; ties keep file order. Without a match, the active profile handles the message.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    /// Routing is gated on `gateway.multiplex_profiles`; without it Hermes
    /// never even runs the matcher (gateway/run.py:23923).
    @ViewBuilder
    private var multiplexPrerequisite: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(ScarfColor.warning)
            if block.multiplexIsTopLevel {
                Text("Routing is off: `multiplex_profiles: false` is set at the top level of config.yaml. Edit it there — a `gateway.multiplex_profiles` value would be ignored.")
                    .scarfStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Routing is off until profile multiplexing is enabled — routes are ignored entirely.")
                    .scarfStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Enable Multiplexing") { viewModel.setMultiplexProfiles(true) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    // MARK: - Mutations (whole-block rewrites)

    private func replace(_ route: HermesProfileRoute) {
        save(block.routes.map { $0.id == route.id ? route : $0 })
    }

    private func remove(_ route: HermesProfileRoute) {
        save(block.routes.filter { $0.id != route.id })
    }

    private func save(_ routes: [HermesProfileRoute]) {
        viewModel.saveProfileRoutes(routes, location: block.location, capabilities: capabilities)
    }
}

/// One ranked rule row. Rank reflects Hermes's evaluation order, not the
/// row's position in config.yaml.
private struct ProfileRouteRow: View {
    let rank: Int?
    let route: HermesProfileRoute
    /// v0.20.4+ — non-nil when this route's target profile isn't in
    /// `gateway.multiplex_profile_allowlist` and would never fire.
    var allowlistWarning: String? = nil
    let onEdit: () -> Void
    let onToggleEnabled: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                rankBadge
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(route.name.isEmpty ? "(unnamed)" : route.name)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text(route.profile)
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.accent)
                    }
                    Text(route.scopeSummary)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { route.enabled }, set: onToggleEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Disable without deleting (writes `enabled: false`)")
                Button(action: onEdit) {
                    Image(systemName: "pencil").foregroundStyle(ScarfColor.foregroundMuted)
                }
                .buttonStyle(.plain)
                .help("Edit this route")
                Button(action: onRemove) {
                    Image(systemName: "minus.circle").foregroundStyle(ScarfColor.foregroundMuted)
                }
                .buttonStyle(.plain)
                .help("Remove this route")
            }
            if let reason = route.rejectionReason {
                warning(reason)
            } else if !route.enabled {
                warning("Disabled — never matches.")
            } else if let allowlistWarning {
                warning(allowlistWarning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rankBadge: some View {
        if let rank {
            Text("\(rank)")
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.sm, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .help("Match rank \(rank) — specificity \(route.specificity) (thread 8 + channel 4 + server 2).")
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(ScarfColor.warning)
                .frame(width: 22, height: 18)
                .help("Not ranked — Hermes ignores this route.")
        }
    }
}

/// Add/edit sheet for a single rule. Fields left blank are omitted from the
/// YAML entirely: in Hermes a field is a constraint only when it's set, and
/// an empty string is indistinguishable from unset at match time.
private struct ProfileRouteEditorSheet: View {
    @State var route: HermesProfileRoute
    let isNew: Bool
    let onSave: (HermesProfileRoute) -> Void
    let onCancel: () -> Void

    /// `gateway/config.py` `Platform` enum values that can receive inbound
    /// chat messages. Free text is still allowed — plugin adapters register
    /// their own platform ids at runtime.
    private let knownPlatforms = [
        "discord", "telegram", "slack", "matrix", "mattermost", "signal",
        "whatsapp", "whatsapp_cloud", "dingtalk", "feishu", "wecom",
        "weixin", "qqbot", "bluebubbles", "email", "sms", "local",
    ]

    private var trimmedProfile: String {
        route.profile.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        !route.platform.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedProfile.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text(isNew ? "New Profile Route" : "Edit Profile Route")
                .scarfStyle(.bodyEmph)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                field("Name", text: $route.name, hint: "Shown in Hermes logs. Optional.")
                GridRow {
                    Text("Platform").scarfStyle(.caption).gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        TextField("discord", text: $route.platform)
                            .textFieldStyle(.roundedBorder)
                            .font(ScarfFont.monoSmall)
                        Menu {
                            ForEach(knownPlatforms, id: \.self) { platform in
                                Button(platform) { route.platform = platform }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }
                field("Server / Guild ID", text: $route.guildID, hint: "Optional. Blank = any server.")
                field("Channel / Chat ID", text: $route.chatID, hint: "Optional. Also matches threads whose parent is this channel.")
                field("Thread ID", text: $route.threadID, hint: "Optional. Blank = any thread.")
                field("Profile", text: $route.profile, hint: "Target profile directory under ~/.hermes/profiles.")
                GridRow {
                    Text("Enabled").scarfStyle(.caption).gridColumnAlignment(.trailing)
                    Toggle("", isOn: $route.enabled).labelsHidden().toggleStyle(.switch)
                }
            }

            Text("Specificity \(previewSpecificity) — every field you fill in must match for this route to win, and each one raises its rank against the other routes.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !trimmedProfile.isEmpty, !HermesProfileName.isValid(trimmedProfile) {
                Text("Hermes would ignore this route: profile names must be lowercase [a-z0-9][a-z0-9_-] (up to 64 chars) and not one of hermes/test/tmp/root/sudo.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave(normalizedRoute()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(ScarfSpace.s4)
        .frame(width: 460)
    }

    private var previewSpecificity: Int {
        normalizedRoute().specificity
    }

    /// Trim every field — trailing whitespace in an id is a match failure
    /// that's invisible in the file — and lowercase the profile the way
    /// `normalize_profile_name` does.
    private func normalizedRoute() -> HermesProfileRoute {
        var out = route
        out.name = route.name.trimmingCharacters(in: .whitespaces)
        out.platform = route.platform.trimmingCharacters(in: .whitespaces).lowercased()
        out.guildID = route.guildID.trimmingCharacters(in: .whitespaces)
        out.chatID = route.chatID.trimmingCharacters(in: .whitespaces)
        out.threadID = route.threadID.trimmingCharacters(in: .whitespaces)
        out.profile = HermesProfileName.normalized(route.profile) ?? ""
        if !out.enabled { out.enabledIsExplicit = true }
        return out
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, hint: String) -> some View {
        GridRow {
            Text(label).scarfStyle(.caption).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 1) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(ScarfFont.monoSmall)
                Text(hint)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
    }
}
