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
/// `gateway.multiplex_profiles` is on, so that prerequisite lives here too —
/// from v0.21.4 an unset (or retired `false`) key means "on by default,
/// unless the host's startup check blocks it", so the section explains that
/// instead of offering an Enable button.
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
        let ordered = block.effectiveOrder(capabilities: capabilities)
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
                capabilities: capabilities,
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

    /// How `multiplex_profiles` reads on this host — exactly on/off below
    /// v0.21.4, where it is the pre-existing `block.multiplexProfiles` test.
    private var multiplexStatus: HermesProfileRoutes.MultiplexStatus {
        block.multiplexStatus(capabilities: capabilities)
    }

    @ViewBuilder
    private var editor: some View {

            switch multiplexStatus {
            case .off:
                multiplexPrerequisite
            case .defaultOn, .retiredOptOut:
                multiplexDefaultNotice
            case .on:
                EmptyView()
            }
            if capabilities.hasGatewayStandaloneProfiles, block.gatewayStandalone {
                standaloneNotice
            }

            ForEach(rankedRows, id: \.route.id) { row in
                ProfileRouteRow(
                    rank: row.rank,
                    route: row.route,
                    capabilities: capabilities,
                    // `gateway.multiplex_profile_allowlist` is only ever
                    // read in the v0.20.1 – v0.21.2 window
                    // (`hasMultiplexProfileAllowlist` — P7e re-floor; it is
                    // NOT a v0.20.4 floor, and migration 43 deletes the key
                    // entirely at v0.21.3). The allowlist is also inert
                    // without multiplexing actually enabled —
                    // `profiles_to_serve` returns the active profile and
                    // never looks at the allowlist when `multiplex=False`
                    // (`hermes_cli/profiles.py:712-713`, function at
                    // `:703-713`, @ `v2026.9.7`) — so only surface the
                    // warning once `multiplex_profiles` is on; otherwise a
                    // route just never runs, and that's already covered by
                    // `multiplexPrerequisite` above. `nil` allowlist (key
                    // absent) means "no warning" either way.
                    // v0.21.4+: an unset/retired key is multiplexing by
                    // default, so `multiplexStatus != .off` still gates
                    // correctly there even though the allowlist itself is
                    // dead from v0.21.3 on (the callee returns `nil` for
                    // that window via `hasMultiplexProfileAllowlist`).
                    allowlistWarning: (capabilities.isV0201OrLater && multiplexStatus != .off)
                        ? viewModel.multiplexProfileAllowlistWarning(for: row.route.profile, capabilities: capabilities)
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

    /// The v0.21.4 copy adds the `user_id` weight and the v0.21.3
    /// `bot_profile` scope; older hosts keep the original sentence.
    private var explainerText: LocalizedStringKey {
        if capabilities.hasProfileRouteUserID {
            return "Routes are ranked by how specific they are (user + 16, thread + 8, channel + 4, server + 2) — not by list order. The highest-scoring rule that matches every field it declares wins; ties keep file order. A route only sees messages received by its `bot_profile`'s bot (the default profile's bot when unset). Without a match, the active profile handles the message."
        }
        if capabilities.hasProfileRouteBotScope {
            return "Routes are ranked by how specific they are (thread + 8, channel + 4, server + 2) — not by list order. The highest-scoring rule that matches every field it declares wins; ties keep file order. A route only sees messages received by its `bot_profile`'s bot (the default profile's bot when unset). Without a match, the active profile handles the message."
        }
        return "Routes are ranked by how specific they are (thread + 8, channel + 4, server + 2) — not by list order. The highest-scoring rule that matches every field it declares wins; ties keep file order. Without a match, the active profile handles the message."
    }

    private var explainer: some View {
        Text(explainerText)
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    /// Routing is gated on `gateway.multiplex_profiles`; without it Hermes
    /// never even runs the matcher (`gateway/run.py:4211` in
    /// `_profile_name_for_source`, matcher call at `:4218-4221`, @
    /// `v2026.9.7`).
    @ViewBuilder
    private var multiplexPrerequisite: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(ScarfColor.warning)
            // The button is offered in BOTH shapes now:
            // `setMultiplexProfiles` writes to whichever spelling Hermes is
            // actually reading (top-level when a non-null one is present, else
            // `gateway.`), so the top-level case is no longer a dead end that
            // could only be fixed by hand. The copy still names the key the
            // user will find in their file.
            Text(block.multiplexIsTopLevel
                 ? "Routing is off: `multiplex_profiles` is set at the top level of config.yaml, where it overrides any `gateway.multiplex_profiles` value. Enabling updates that top-level key."
                 : "Routing is off until profile multiplexing is enabled — routes are ignored entirely.")
                .scarfStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Enable Multiplexing") { viewModel.setMultiplexProfiles(true) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    /// v0.21.4+ (``HermesCapabilities/hasMultiplexByDefault``): the key is
    /// unset or an explicit `false`, and both now mean "multiplex by
    /// default" (`hermes_cli/gateway_multiplex_mode.py:132-158` @
    /// `v2026.9.21`). Deliberately NOT "always on": the gateway grants the
    /// default only when `implicit_multiplex_blocker` (`:93-129`) finds
    /// nothing, and otherwise boots standalone and says why in `hermes
    /// gateway status`. No button: there is no off switch left to offer, and
    /// writing an explicit `true` is not a harmless "enable" — `true` skips
    /// `implicit_multiplex_blocker` entirely (`:143-145`), so it would skip
    /// that very blocker check. (It is not beyond ALL guards: from v0.21.5
    /// `standalone_launcher_decision` still keeps a `gateway.standalone: true`
    /// named profile standalone first, `:240-242` @ `v2026.9.24`.)
    @ViewBuilder
    private var multiplexDefaultNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(ScarfColor.foregroundMuted)
            multiplexDefaultText
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    /// Whole-sentence literals (not an interpolated `String`) so the inline
    /// code spans render and each variant stays one localizable key.
    private var multiplexDefaultText: Text {
        if multiplexStatus != .retiredOptOut {
            return Text("Profile multiplexing is on by default on this Hermes version: one host gateway serves every profile, so routes run — unless its startup check keeps it standalone (only one profile, a profile still running its own gateway, a duplicate bot token). `hermes gateway status` names the reason.")
        }
        // The retired `false` is ignored at v0.21.4 and rewritten to `true` by
        // the gateway from v0.21.5 (`persist_resolved_default`, `:171-197`
        // @ `v2026.9.24`) — in the DEFAULT profile's config.yaml, and never
        // on a guard refusal (`:177-178`), hence the wording.
        if capabilities.hasMultiplexOptOutRewrite {
            return Text("`multiplex_profiles: false` is retired and no longer turns multiplexing off — Hermes ignores it, and once the gateway starts multiplexed it writes `true` into the default profile's config.yaml. One host gateway serves every profile, so routes run — unless its startup check keeps it standalone (only one profile, a profile still running its own gateway, a duplicate bot token). `hermes gateway status` names the reason.")
        }
        return Text("`multiplex_profiles: false` is retired and no longer turns multiplexing off — Hermes ignores it. One host gateway serves every profile, so routes run — unless its startup check keeps it standalone (only one profile, a profile still running its own gateway, a duplicate bot token). `hermes gateway status` names the reason.")
    }

    /// v0.21.5 (``HermesCapabilities/hasGatewayStandaloneProfiles``):
    /// `gateway.standalone: true` keeps a NAMED profile's gateway out of the
    /// host multiplexer — it serves only itself (`STANDALONE_PROFILE_REASON`,
    /// `hermes_cli/gateway_multiplex_mode.py:29`, `:143-144` @ `v2026.9.24`)
    /// — and Hermes calls it a temporary shim (`:31-39`). The default profile
    /// ignores the key (`hermes_cli/profiles.py:976`), and this section cannot
    /// tell which profile it is editing, so the copy says both.
    @ViewBuilder
    private var standaloneNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(ScarfColor.warning)
            Text("This config sets `gateway.standalone: true`. On a named profile that keeps its gateway out of the host gateway — it serves only itself, so routes to other profiles don't run from it. The default profile ignores the key. Hermes treats it as a temporary compatibility shim.")
                .scarfStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
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
        Task { await viewModel.saveProfileRoutes(routes, location: block.location, capabilities: capabilities) }
    }
}

/// One ranked rule row. Rank reflects Hermes's evaluation order, not the
/// row's position in config.yaml.
private struct ProfileRouteRow: View {
    let rank: Int?
    let route: HermesProfileRoute
    let capabilities: HermesCapabilities
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
                    Text(route.scopeSummary(capabilities: capabilities))
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
            if let reason = route.rejectionReason(capabilities: capabilities) {
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

    private func rankHelp(_ rank: Int) -> LocalizedStringKey {
        let weight = route.specificity(capabilities: capabilities)
        if capabilities.hasProfileRouteUserID {
            return "Match rank \(rank) — specificity \(weight) (user 16 + thread 8 + channel 4 + server 2)."
        }
        return "Match rank \(rank) — specificity \(weight) (thread 8 + channel 4 + server 2)."
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
                .help(rankHelp(rank))
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
    let capabilities: HermesCapabilities
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
        !route.platform.trimmingCharacters(in: .whitespaces).isEmpty
            && !trimmedProfile.isEmpty
            && controlCharacterField == nil
    }

    /// The field carrying a pasted control character, or `nil`.
    ///
    /// Round-3 decision 6: a tab, line break or other C0/C1 control in a
    /// user-typed scalar is a visible validation error that blocks Save —
    /// the shape `MCPServerEditorViewModel.duplicateKey` established — not a
    /// silent reshape. Every field here is a single-line scalar, and an
    /// unquotable one costs the user their entire config.yaml layer:
    /// `load_gateway_config` wraps the load in a bare `except Exception`
    /// that logs and CONTINUES (`gateway/config.py:773-792` @ `v2026.9.7`).
    /// Checked on the NORMALIZED route, because `.whitespaces` trimming
    /// removes a leading/trailing tab but nothing removes an interior one —
    /// except for `profile`, where `HermesProfileName.normalized` turns any
    /// invalid name into `""` and would swallow the very character we want
    /// to name. That field is probed in its trimmed, un-slugged form.
    private var controlCharacterField: String? {
        var probe = normalizedRoute()
        probe.profile = route.profile.trimmingCharacters(in: .whitespaces)
        return probe.controlCharacterFieldLabel
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
                            .accessibilityLabel("Platform")
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

            if let field = controlCharacterField {
                Text("“\(field)” contains a tab or a control character. Hermes can't read a config.yaml with one in it — it falls back to your .env values and ignores the whole file. Remove it, then save.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Validation error: \(field) contains a tab or a control character. Remove it, then save.")
            }

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
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(!canSave)
            }
        }
        .padding(ScarfSpace.s4)
        .frame(width: 460)
    }

    private var previewSpecificity: Int {
        normalizedRoute().specificity(capabilities: capabilities)
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
                    .accessibilityLabel(label)
                Text(hint)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
    }
}
