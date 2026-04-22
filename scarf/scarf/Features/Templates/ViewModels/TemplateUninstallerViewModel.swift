import Foundation
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

    let context: ServerContext
    private let uninstaller: ProjectTemplateUninstaller

    init(context: ServerContext) {
        self.context = context
        self.uninstaller = ProjectTemplateUninstaller(context: context)
    }

    var stage: Stage = .idle
    var plan: TemplateUninstallPlan?

    /// Load the `template.lock.json` for the given project and build a
    /// removal plan. Moves stage to `.planned` on success.
    func begin(project: ProjectEntry) {
        stage = .loading
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
        Task.detached { [weak self] in
            do {
                try uninstaller.uninstall(plan: plan)
                await MainActor.run { [weak self] in
                    guard let self else { return }
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
        stage = .idle
    }
}
