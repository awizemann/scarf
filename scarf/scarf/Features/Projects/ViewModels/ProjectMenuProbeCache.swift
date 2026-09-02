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
/// **A cache miss falls back to a live probe on LOCAL contexts only.** The
/// asynchronous refresh leaves a window right after an install in which the
/// menu would still answer "no template here" — and on a local context the
/// stat that closes that window is a plain filesystem `stat`, which was never
/// the cost this class exists to remove. Remote contexts — where a miss would
/// mean a blocking SSH round-trip on the actor drawing the menu — answer
/// `false` and correct themselves on the next refresh.
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

    /// The context these answers describe. Set by `refresh`; nil until the
    /// first one, which is also when there is nothing cached to fall back on.
    @ObservationIgnored private var probedContext: ServerContext?

    func isConfigurable(_ project: ProjectEntry) -> Bool {
        if let cached = answers[project.path] { return cached.isConfigurable }
        guard let context = probedContext, !context.isRemote else { return false }
        return context.makeTransport()
            .fileExists(ProjectConfigService.manifestCachePath(for: project))
    }

    func hasInstalledTemplate(_ project: ProjectEntry) -> Bool {
        if let cached = answers[project.path] { return cached.hasInstalledTemplate }
        guard let context = probedContext, !context.isRemote else { return false }
        return ProjectTemplateUninstaller(context: context).isTemplateInstalled(project: project)
    }

    /// Re-probe every project. Call after the registry loads or changes.
    func refresh(projects: [ProjectEntry], context: ServerContext) {
        probedContext = context
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
