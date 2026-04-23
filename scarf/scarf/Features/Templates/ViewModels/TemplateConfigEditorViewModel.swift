import Foundation
import Observation
import os

/// Drives the post-install "Configuration" button on the project
/// dashboard. Loads `<project>/.scarf/manifest.json` + `config.json`,
/// hands a `TemplateConfigViewModel` seeded with current values to the
/// sheet, then writes the edited values back on commit.
///
/// Smaller surface than `TemplateInstallerViewModel` — no unzipping,
/// no parent-dir picking, no cron CLI. Just: read → edit → save.
@Observable
@MainActor
final class TemplateConfigEditorViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateConfigEditorViewModel")

    enum Stage: Sendable {
        case idle
        case loading
        /// Manifest + config loaded; the sheet is displaying the form.
        case editing
        case saving
        case succeeded
        case failed(String)
        /// Project wasn't installed from a schemaful template — no
        /// manifest cache on disk. The dashboard button is hidden in
        /// this case so we shouldn't hit this stage normally.
        case notConfigurable
    }

    let context: ServerContext
    let project: ProjectEntry
    private let configService: ProjectConfigService

    init(context: ServerContext, project: ProjectEntry) {
        self.context = context
        self.project = project
        self.configService = ProjectConfigService(context: context)
    }

    var stage: Stage = .idle
    var manifest: ProjectTemplateManifest?
    var currentValues: [String: TemplateConfigValue] = [:]

    /// Non-nil while `.editing`; used to construct the sheet's VM.
    var formViewModel: TemplateConfigViewModel?

    /// Load the cached manifest + current config values, then move to
    /// `.editing` so the sheet can render the form.
    func begin() {
        stage = .loading
        let service = configService
        let project = project
        Task.detached { [weak self] in
            do {
                guard let cachedManifest = try service.loadCachedManifest(project: project),
                      let schema = cachedManifest.config,
                      !schema.isEmpty else {
                    await MainActor.run { [weak self] in
                        self?.stage = .notConfigurable
                    }
                    return
                }
                let configFile = try service.load(project: project)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.manifest = cachedManifest
                    self.currentValues = configFile?.values ?? [:]
                    self.formViewModel = TemplateConfigViewModel(
                        schema: schema,
                        templateId: cachedManifest.id,
                        templateSlug: cachedManifest.slug,
                        initialValues: self.currentValues,
                        mode: .edit(project: project)
                    )
                    self.stage = .editing
                }
            } catch {
                Self.logger.error("couldn't load config for \(project.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Called when the sheet's commit succeeded. Persists the edited
    /// values to `<project>/.scarf/config.json`. Secrets are already
    /// in the Keychain — the VM's commit step wrote them.
    func save(values: [String: TemplateConfigValue]) {
        guard let manifest else { return }
        stage = .saving
        let service = configService
        let project = project
        Task.detached { [weak self] in
            do {
                try service.save(
                    project: project,
                    templateId: manifest.id,
                    values: values
                )
                await MainActor.run { [weak self] in
                    self?.stage = .succeeded
                }
            } catch {
                Self.logger.error("couldn't save config for \(project.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        stage = .idle
        formViewModel = nil
    }
}
