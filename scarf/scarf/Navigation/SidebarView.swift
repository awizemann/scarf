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

        var manage: [SidebarSection] = [.tools, .mcpServers, .gateway, .cron]
        if caps?.hasKanban ?? false {
            manage.append(.kanban)
        }
        manage.append(contentsOf: [.health, .logs, .settings])

        return [
            Section(title: "Monitor",  items: [.dashboard, .insights, .sessions, .activity]),
            Section(title: "Projects", items: [.projects]),
            Section(title: "Interact", items: interact),
            Section(title: "Configure", items: [.platforms, .personalities, .quickCommands, .credentialPools, .plugins, .webhooks, .profiles]),
            Section(title: "Manage",   items: manage),
        ]
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

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(nsImage: sidebarIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("Scarf")
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            // Active-profile chip — local contexts only. Remote
            // ServerContexts don't read this Mac's active_profile
            // file, so the chip would be misleading there.
            if !serverContext.isRemote {
                Button {
                    coordinator.selectedSection = .profiles
                } label: {
                    ScarfBadge("profile: \(activeProfileName)", kind: .brand)
                }
                .buttonStyle(.plain)
                .help("Active Hermes profile — click to manage")
            }
            Spacer()
            Text(serverContext.displayName.lowercased())
                .font(ScarfFont.caption2)
                .foregroundStyle(ScarfColor.foregroundFaint)
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

    private var versionPill: String {
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
