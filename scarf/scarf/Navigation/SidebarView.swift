import AppKit
import SwiftUI
import ScarfCore
import ScarfDesign

/// Mirrors the visual structure in `design/static-site/ui-kit/Sidebar.jsx`:
/// glassy translucent background, header with app-icon + title + scope pill,
/// uppercase section labels, custom row treatment with rust accent tint when
/// active, footer with running indicator + version pill.
///
/// We don't use `List(.sidebar)` because the default sidebar style locks down
/// row chrome we want to customize (background, padding, accent treatment).
struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ServerLiveStatusRegistry.self) private var liveRegistry
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// This window's client-side "viewing profile" (#126) — populated on
    /// remote windows so the header chip can show which profile the window is
    /// scoped to (the remote analogue of `activeProfileName` below).
    @Environment(WindowProfileScope.self) private var profileScope: WindowProfileScope?

    /// Currently-active Hermes profile name, surfaced as a header
    /// chip on local contexts so users always see which profile
    /// Scarf is reading from (issue #70 follow-up). Refreshed on
    /// every section change as a cheap proxy for "user is
    /// interacting with the app" — covers the rare case where the
    /// user runs `hermes profile use` from a terminal mid-session.
    @State private var activeProfileName: String = HermesProfileResolver.activeProfileName()

    /// Capability-gated sections. Curator is v0.12+ only; older Hermes
    /// hosts get the same Interact section minus the Curator row.
    /// Building the list lazily off the env keeps the sidebar honest
    /// when the user reconnects to a different-version host.
    private var sections: [Section] {
        let caps = capabilitiesStore?.capabilities

        var interact: [SidebarSection] = [.chat, .memory]
        if caps?.hasCurator ?? false {
            interact.append(.curator)
        }
        interact.append(.skills)

        // Kanban moved from Manage → Monitor in v2.7.5: it's runtime
        // work-in-progress, not configuration. Sits between Activity
        // and the remaining Manage entries so users see "what's
        // happening right now" at a glance.
        var monitor: [SidebarSection] = [.dashboard, .insights, .sessions, .activity]
        if caps?.hasKanban ?? false {
            monitor.append(.kanban)
        }

        // v0.21 — `hermes peer` bot-to-bot messaging across gateways.
        // Sits right after Gateway (this machine's inbound messaging)
        // since Peers is its outbound, machine-to-machine counterpart.
        // Hidden entirely pre-v0.21: every verb the surface offers
        // (`peer run/status/stop`) fails at argparse on an older host.
        var manage: [SidebarSection] = [.tools, .mcpServers, .gateway]
        if caps?.hasPeerRunCommands ?? false {
            manage.append(.peers)
        }
        manage += [.cron, .health, .logs, .settings]

        // Models entry sits in Configure when the host supports the
        // session/set_model RPC (v0.13+). Pre-v0.13 the binding can be
        // stored but never applied at runtime, so the surface stays
        // hidden — same posture every other capability-gated entry
        // takes.
        var configure: [SidebarSection] = [.platforms, .personalities, .quickCommands, .credentialPools, .plugins, .webhooks, .profiles]
        if caps?.hasACPSetSessionModel ?? false {
            configure.append(.models)
        }
        // v0.14 — Hermes Proxy is the user-facing surface for the
        // `hermes proxy` CLI. Gated on hasHermesProxy so pre-v0.14
        // hosts don't see an entry that wouldn't launch.
        if caps?.hasHermesProxy ?? false {
            configure.append(.proxy)
        }

        var sections: [Section] = [
            // Projects sits first now — promoting it to a first-class
            // entry point reflects how users actually open Scarf
            // (start with a project, not the dashboard).
            Section(title: "Projects", items: [.projects]),
            Section(title: "Monitor",  items: monitor),
        ]

        // Bots — its own top-level section immediately above Interact, so
        // it reads directly above Chat (Interact's first row). A bot is a
        // whole Hermes profile, so it's a level up from the conversation
        // you have with one, not another Interact tool.
        //
        // Gated on hasBotMode (v0.20.3+, where ui_meta['hermes-bots'] is
        // read) and NOT on "does any bot exist": a data gate would make
        // the section — and therefore the first bot — unreachable.
        if caps?.hasBotMode ?? false {
            sections.append(Section(title: "Bots", items: [.bots]))
        }

        sections += [
            Section(title: "Interact", items: interact),
            Section(title: "Configure", items: configure),
            Section(title: "Manage",   items: manage),
        ]
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, ScarfSpace.s2)
                .padding(.top, ScarfSpace.s1)
                .padding(.bottom, ScarfSpace.s4)
            }
            footer
        }
        .background(.regularMaterial)
        .background(ScarfColor.backgroundTertiary.opacity(0.4))
        .splitViewAutosaveName("ScarfMainSidebar.\(serverContext.id)")
        .onAppear {
            HermesProfileResolver.invalidateCache()
            activeProfileName = HermesProfileResolver.activeProfileName()
        }
        .onChange(of: coordinator.selectedSection) { _, _ in
            HermesProfileResolver.invalidateCache()
            activeProfileName = HermesProfileResolver.activeProfileName()
        }
    }

    // MARK: - Header

    /// Chip label prefix: remote windows show the per-window *viewing*
    /// profile (#126); local windows show the machine's *active* profile.
    private var profileChipPrefix: String {
        serverContext.isRemote ? "viewing" : "profile"
    }

    /// Chip profile name — the remote window's selected profile (default when
    /// none) or the local active profile.
    private var profileChipName: String {
        serverContext.isRemote
            ? (profileScope?.selectedProfile ?? HermesProfileScope.defaultProfileName)
            : activeProfileName
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(spacing: ScarfSpace.s2) {
                Image(nsImage: sidebarIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Scarf")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                Text(serverContext.displayName.lowercased())
                    .font(ScarfFont.caption2)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            // Profile chip. Local: the Mac's active Hermes profile
            // (`active_profile`). Remote: this window's client-side "viewing
            // profile" (#126) — remote ServerContexts don't read this Mac's
            // active_profile, so we surface the per-window scope instead.
            // Anchored to the trailing edge so it sits visually under the
            // server name in the row above; saves horizontal space in the top
            // row when the server name + chip would otherwise compete.
            HStack(spacing: 0) {
                Spacer()
                Button {
                    coordinator.selectedSection = .profiles
                } label: {
                    ScarfBadge("\(profileChipPrefix): \(profileChipName)", kind: .brand)
                }
                .buttonStyle(.plain)
                .help(serverContext.isRemote
                      ? "Profile this window is viewing — click to switch"
                      : "Active Hermes profile — click to manage")
            }
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.top, 19) // Half the original 38 px traffic-light clearance.
        .padding(.bottom, ScarfSpace.s3)
    }

    /// Prefer the asset catalog's `AppIcon` set directly so the rust art
    /// renders even before launch services has refreshed its icon cache.
    /// Falls back to `NSApp.applicationIconImage` if for some reason the
    /// named lookup fails (shouldn't, but keeps us safe across Xcode
    /// dev-build oddities).
    private var sidebarIconImage: NSImage {
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        return NSApplication.shared.applicationIconImage
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(section.title)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, ScarfSpace.s2 + 2)
                .padding(.top, ScarfSpace.s2)
                .padding(.bottom, ScarfSpace.s1)
            ForEach(section.items) { item in
                row(item)
            }
        }
    }

    private func row(_ item: SidebarSection) -> some View {
        let isActive = coordinator.selectedSection == item
        return Button {
            coordinator.selectedSection = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 15, height: 15)
                Text(item.displayName)
                    .scarfStyle(isActive ? .bodyEmph : .body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ScarfSpace.s2 + 2)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(isActive ? ScarfColor.accentTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.section.\(item.rawValue)")
    }

    // MARK: - Footer

    private var footer: some View {
        let running = liveRegistry.statuses.first(where: { $0.id == serverContext.id })?.hermesRunning ?? false
        return HStack(spacing: ScarfSpace.s2) {
            Circle()
                .fill(running ? ScarfColor.success : ScarfColor.foregroundFaint)
                .frame(width: 7, height: 7)
            Text(running ? "Hermes running" : "Hermes stopped")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
            Text(versionPill)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .padding(.horizontal, ScarfSpace.s4 - 2)
        .padding(.vertical, ScarfSpace.s2 + 2)
        .overlay(
            Rectangle()
                .fill(ScarfColor.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    /// The connected host's Hermes version (cached probe — no live call
    /// from a view body). Falls back to Scarf's own version while no
    /// probe has landed yet, so the footer never shows a bare dash.
    /// Scarf's version remains available in About / Settings.
    private var versionPill: String {
        if let semver = HermesVersionCache.shared.cached(for: serverContext)?.semver {
            return "Hermes v\(semver)"
        }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(v)"
    }

    // MARK: - Models

    private struct Section: Identifiable {
        let title: String
        let items: [SidebarSection]
        var id: String { title }
    }
}
