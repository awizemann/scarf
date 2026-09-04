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

    /// The project set + context the last refresh probed, and when. Both
    /// halves of the skip below: a tick that hands over the same projects
    /// on the same host has nothing new to ask.
    @ObservationIgnored private var probedPaths: Set<String> = []
    @ObservationIgnored private var lastProbe: Date?
    /// Test seam: how many times a real probe pass has been started.
    @ObservationIgnored private(set) var probeCount = 0

    /// How long a probe stands before a refresh call is allowed to re-run
    /// it for an unchanged project set.
    ///
    /// The answers are install-time facts (a manifest cache and a template
    /// lock file), so in principle they never go stale on their own — but
    /// an AGENT can install a template into a project without going through
    /// Scarf, and then nothing here would ever invalidate. A slow
    /// revalidation is the honest middle: two stats per project per minute
    /// rather than per tick.
    static let revalidateAfter: TimeInterval = 60

    /// Force the next `refresh` to probe even if nothing looks different.
    /// Call from anything that changes an install-time fact — a template
    /// install, an uninstall, an upgrade.
    func invalidate() {
        lastProbe = nil
        probedPaths = []
    }

    /// Re-probe every project. Call after the registry loads or changes.
    ///
    /// **Skips when there is nothing to learn.** This is called from the
    /// coalesced watcher tick, which fires every 0.5-1.5s during an active
    /// stream, and each probe is two `fileExists` calls per project — ~40
    /// blocking SSH round-trips per tick on a 20-project host, all asking
    /// about facts that only change at install and uninstall time. So an
    /// unchanged project set on the same host is a no-op until either
    /// `invalidate()` (an install/uninstall happened) or `revalidateAfter`
    /// (an agent may have installed one behind our back).
    func refresh(projects: [ProjectEntry], context: ServerContext, force: Bool = false) {
        let paths = Set(projects.map(\.path))
        if !force,
           probedContext?.id == context.id,
           paths == probedPaths,
           let last = lastProbe,
           Date().timeIntervalSince(last) < Self.revalidateAfter {
            return
        }
        probedPaths = paths
        lastProbe = Date()
        probeCount += 1
        probedContext = context
        generation &+= 1
        let generation = self.generation
        let probeOrder = projects.map(\.path)
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
                for path in probeOrder {
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
