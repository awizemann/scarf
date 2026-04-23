import Foundation
import ScarfCore
import os

/// Drives the template-uninstall sheet. Mirrors the installer VM in
/// stage shape: open a plan (`begin`), preview it, confirm or cancel.
@Observable
@MainActor
final class TemplateUninstallerViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateUninstallerViewModel")

    enum Stage: Sendable {
        case idle
        case loading
        case planned
        case uninstalling
        case succeeded(removed: ProjectEntry)
        case failed(String)
    }

    /// Snapshot of "what survived the uninstall" — surfaced in the
    /// success screen so the user understands why the project directory
    /// is or isn't gone from disk. Computed from the plan right before
    /// executing it (`plan` itself is nil'd on success, so we can't
    /// reach back for this info after the fact).
    struct PreservedOutcome: Sendable {
        /// True when the uninstaller removed the project dir (nothing
        /// user-owned was left inside). In this case `preservedPaths`
        /// is empty and the success view skips the banner entirely.
        let projectDirRemoved: Bool
        /// Absolute paths of files the uninstaller refused to touch
        /// because they weren't installed by the template (typically
        /// `status-log.md` after the cron ran, or anything the user
        /// dropped into the project dir manually).
        let preservedPaths: [String]
        /// Project dir — echoed back so the success view can show the
        /// user where the orphan files now live.
        let projectDir: String
    }

    let context: ServerContext
    private let uninstaller: ProjectTemplateUninstaller

    init(context: ServerContext) {
        self.context = context
        self.uninstaller = ProjectTemplateUninstaller(context: context)
    }

    var stage: Stage = .idle
    var plan: TemplateUninstallPlan?
    /// Populated on transition to `.succeeded`. Nil whenever the user
    /// re-enters the flow (cancel/begin both clear it).
    var preservedOutcome: PreservedOutcome?

    /// Load the `template.lock.json` for the given project and build a
    /// removal plan. Moves stage to `.planned` on success.
    func begin(project: ProjectEntry) {
        stage = .loading
        preservedOutcome = nil
        let uninstaller = uninstaller
        Task.detached { [weak self] in
            do {
                let plan = try uninstaller.loadUninstallPlan(for: project)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.plan = plan
                    self.stage = .planned
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    func confirmUninstall() {
        guard let plan else { return }
        stage = .uninstalling
        let uninstaller = uninstaller
        // Capture the preservation shape before executing — the plan
        // itself gets nil'd on success and we want the banner to show
        // whatever was true at the moment of removal.
        let outcome = PreservedOutcome(
            projectDirRemoved: plan.projectDirBecomesEmpty,
            preservedPaths: plan.extraProjectEntries,
            projectDir: plan.project.path
        )
        Task.detached { [weak self] in
            do {
                try uninstaller.uninstall(plan: plan)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.preservedOutcome = outcome
                    self.stage = .succeeded(removed: plan.project)
                    self.plan = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        plan = nil
        preservedOutcome = nil
        stage = .idle
    }
}
