import Foundation
import Observation
import ScarfCore

/// Answers the two yes/no questions the projects context menu asks about each
/// project, WITHOUT doing transport I/O on the MainActor.
///
/// Before F6, `ProjectsSidebar`'s `canConfigureProject` and
/// `isTemplateInstalled` closures each called `transport.fileExists(…)`
/// directly — a synchronous stat, i.e. an SSH round-trip on a remote context —
/// from inside a `@ViewBuilder` menu body. Two blocking round-trips per menu
/// evaluation, on the actor that has to draw the menu.
///
/// The answers are static for the life of a project entry between refreshes
/// (a manifest cache and a template lock file are written at install time and
/// removed at uninstall time), so they are probed off-main once per registry
/// reload and read from a dictionary thereafter.
///
/// **Unknown reads as false.** A menu item that appears a moment late is a
/// smaller lie than "Uninstall Template" offered for a project that has none.
@Observable
@MainActor
final class ProjectMenuProbeCache {
    struct Answers: Sendable, Equatable {
        var isConfigurable = false
        var hasInstalledTemplate = false
    }

    private var answers: [String: Answers] = [:]

    /// Newest-wins: a refresh started before a project was added or removed
    /// must not publish its stale map over a later one.
    @ObservationIgnored private var generation = 0

    func isConfigurable(_ project: ProjectEntry) -> Bool {
        answers[project.path]?.isConfigurable ?? false
    }

    func hasInstalledTemplate(_ project: ProjectEntry) -> Bool {
        answers[project.path]?.hasInstalledTemplate ?? false
    }

    /// Re-probe every project. Call after the registry loads or changes.
    func refresh(projects: [ProjectEntry], context: ServerContext) {
        generation &+= 1
        let generation = self.generation
        let paths = projects.map(\.path)
        let uninstaller = ProjectTemplateUninstaller(context: context)
        let manifestPaths = Dictionary(
            projects.map { ($0.path, ProjectConfigService.manifestCachePath(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectsByPath = Dictionary(
            projects.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }
        )

        Task { [weak self] in
            let probed = await Task.detached { () -> [String: Answers] in
                let transport = context.makeTransport()
                var result: [String: Answers] = [:]
                for path in paths {
                    guard let project = projectsByPath[path] else { continue }
                    result[path] = Answers(
                        isConfigurable: manifestPaths[path].map { transport.fileExists($0) } ?? false,
                        hasInstalledTemplate: uninstaller.isTemplateInstalled(project: project)
                    )
                }
                return result
            }.value
            guard let self, self.generation == generation else { return }
            self.answers = probed
        }
    }
}
