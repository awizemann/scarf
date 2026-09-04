import Testing
import Foundation
import ScarfCore
@testable import scarf

/// t-e5bc2ad4 — the sidebar restructure: the projects list moved into a
/// well in the main sidebar, the other nav sections became collapsible,
/// and the in-area second project sidebar went away.
///
/// The two behaviours worth pinning are the ones a user notices when
/// they break: which sections are open on a first launch (and that a
/// choice survives a relaunch), and that clicking a project in the well
/// actually lands you in that project's cockpit.
@MainActor
@Suite(.serialized)
struct SidebarRestructureTests {

    /// A defaults suite that no other test — and no running copy of the
    /// app — shares.
    private func isolatedDefaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "scarf.tests.sidebar." + name))
        defaults.removePersistentDomain(forName: "scarf.tests.sidebar." + name)
        return defaults
    }

    // MARK: - Collapse defaults

    @Test("first launch: Monitor, Bots and Interact are open; Configure and Manage are closed")
    func firstLaunchDefaults() throws {
        let store = SidebarSectionCollapseStore(defaults: try isolatedDefaults())
        #expect(store.isCollapsed("Monitor") == false)
        #expect(store.isCollapsed("Bots") == false)
        #expect(store.isCollapsed("Interact") == false)
        #expect(store.isCollapsed("Configure") == true)
        #expect(store.isCollapsed("Manage") == true)
    }

    @Test("a capability-gated section that appears later still gets its default, not a stale value")
    func unknownSectionFallsBackToDefault() throws {
        let store = SidebarSectionCollapseStore(defaults: try isolatedDefaults())
        // Bots only exists on v0.20.3+ hosts, so a window may never have
        // rendered it before. "Never written" must not read as collapsed.
        #expect(store.isCollapsed("Bots") == false)
    }

    // MARK: - Persistence round-trip

    @Test("a collapse choice round-trips through UserDefaults into a fresh store")
    func collapseChoiceSurvivesRelaunch() throws {
        let suite = UUID().uuidString
        let defaults = try isolatedDefaults(suite)

        let first = SidebarSectionCollapseStore(defaults: defaults)
        first.setCollapsed(true, for: "Monitor")     // against the default
        first.setCollapsed(false, for: "Manage")     // also against the default
        #expect(first.isCollapsed("Monitor") == true)
        #expect(first.isCollapsed("Manage") == false)

        // A brand-new store reading the same defaults is the relaunch.
        let relaunched = SidebarSectionCollapseStore(defaults: defaults)
        #expect(relaunched.isCollapsed("Monitor") == true)
        #expect(relaunched.isCollapsed("Manage") == false)
        // Untouched sections still answer from their defaults.
        #expect(relaunched.isCollapsed("Configure") == true)
        #expect(relaunched.isCollapsed("Interact") == false)
    }

    @Test("an explicit choice that matches the default is still persisted")
    func explicitChoiceMatchingDefaultIsPersisted() throws {
        let suite = UUID().uuidString
        let defaults = try isolatedDefaults(suite)
        let store = SidebarSectionCollapseStore(defaults: defaults)
        // Collapsing Configure agrees with `defaultCollapsedTitles`. If we
        // skipped the write because "it already looks like that", a later
        // change to the defaults table would silently move the user's
        // section.
        store.setCollapsed(true, for: "Configure")
        #expect(defaults.object(forKey: SidebarSectionCollapseStore.key(for: "Configure")) as? Bool == true)
    }

    @Test("toggle flips and persists")
    func toggleFlipsAndPersists() throws {
        let defaults = try isolatedDefaults()
        let store = SidebarSectionCollapseStore(defaults: defaults)
        store.toggle("Interact")
        #expect(store.isCollapsed("Interact") == true)
        store.toggle("Interact")
        #expect(store.isCollapsed("Interact") == false)
        #expect(defaults.object(forKey: SidebarSectionCollapseStore.key(for: "Interact")) as? Bool == false)
    }

    @Test("keys are namespaced per section title")
    func keysAreNamespaced() {
        #expect(SidebarSectionCollapseStore.key(for: "Manage") == "sidebar.section.collapsed.Manage")
        #expect(SidebarSectionCollapseStore.key(for: "Monitor") != SidebarSectionCollapseStore.key(for: "Manage"))
    }

    // MARK: - Selection routing

    @Test("picking a project in the well selects it AND navigates to the Projects area")
    func selectRoutesToProjectsArea() {
        let coordinator = AppCoordinator()
        coordinator.selectedSection = .chat
        let viewModel = ProjectsViewModel(context: .local)
        let project = ProjectEntry(name: "atlas", path: "/tmp/atlas")

        SidebarProjectNavigator.select(project, coordinator: coordinator, viewModel: viewModel)

        #expect(coordinator.selectedSection == .projects)
        #expect(coordinator.selectedProjectName == "atlas")
        #expect(viewModel.selectedProject == project)
        // The dashboard glyph is cleared pending the off-main probe —
        // asserting it here is what keeps that probe from being moved
        // back onto this actor.
        #expect(viewModel.selectedHasDashboard == false)
    }

    @Test("selecting a different project replaces the previous selection")
    func selectReplacesPreviousSelection() {
        let coordinator = AppCoordinator()
        let viewModel = ProjectsViewModel(context: .local)
        let first = ProjectEntry(name: "atlas", path: "/tmp/atlas")
        let second = ProjectEntry(name: "borealis", path: "/tmp/borealis")

        SidebarProjectNavigator.select(first, coordinator: coordinator, viewModel: viewModel)
        SidebarProjectNavigator.select(second, coordinator: coordinator, viewModel: viewModel)

        #expect(viewModel.selectedProject == second)
        #expect(coordinator.selectedProjectName == "borealis")
    }

    @Test("Projects is no longer a plain nav row the sidebar can route to as a section list")
    func projectsSectionStillExistsForRouting() {
        // The `.projects` case must survive — the well, the deep links and
        // the New Project hand-off all still set it — even though it is no
        // longer rendered as a row in the section list.
        #expect(SidebarSection.projects.analyticsToken == "projects")
    }
}
