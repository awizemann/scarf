import Foundation
import ScarfCore
import os

/// Drives the template export sheet. Holds form state for the author-facing
/// fields (id, name, version, description, …) and the selection of skills
/// and cron jobs to include, then builds and writes the `.scarftemplate` on
/// confirm.
@Observable
@MainActor
final class TemplateExporterViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateExporterViewModel")

    enum Stage: Sendable {
        case idle
        case exporting
        case succeeded(path: String)
        case failed(String)
    }

    let context: ServerContext
    let project: ProjectEntry
    private let exporter: ProjectTemplateExporter

    init(context: ServerContext, project: ProjectEntry) {
        self.context = context
        self.project = project
        self.exporter = ProjectTemplateExporter(context: context)

        self.templateName = project.name
        self.templateId = "you/\(ProjectTemplateExporter.slugify(project.name))"
    }

    // Form fields
    var templateId: String
    var templateName: String
    var templateVersion: String = "1.0.0"
    var templateDescription: String = ""
    var authorName: String = ""
    var authorURL: String = ""
    var category: String = ""
    var tags: String = ""
    var includeSkillIds: Set<String> = []
    var includeCronJobIds: Set<String> = []
    var memoryAppendix: String = ""

    // Derived: what the author can pick from
    var availableSkills: [HermesSkill] = []
    var availableCronJobs: [HermesCronJob] = []
    /// The project-folder half of the preview, scanned by `rescanFiles()` off
    /// the main actor. `nil` while the scan is running. The sheet reads this
    /// instead of recomputing a plan in `body` — which ran seven transport
    /// `fileExists`, a `jobs.json` read and a directory listing, three times
    /// per keystroke, on the main actor (SSH round trips on a remote host).
    var fileScan: ProjectTemplateExporter.ProjectFileScan?
    /// True while a re-check of the project folder is in flight. The last
    /// scan stays on screen meanwhile, so the list doesn't flicker.
    private(set) var isRescanning = false

    var stage: Stage = .idle

    func load() {
        let ctx = context
        let exporter = exporter
        let projectDir = project.path
        rescanFiles()
        Task.detached { [weak self] in
            let service = HermesFileService(context: ctx)
            let skills = service.loadSkills().flatMap(\.skills)
            let jobs = service.loadCronJobs()
            await MainActor.run { [weak self] in
                self?.availableSkills = skills
                self?.availableCronJobs = jobs
            }
        }
    }

    /// Re-check the project folder off the main actor (C10) — the author may
    /// add README.md / AGENTS.md while the sheet is open. The sheet calls
    /// this when the app regains focus and from its "Check Again" button.
    /// A call while one is already running queues one more pass, so a file
    /// that lands after the running scan read the folder isn't missed.
    @discardableResult
    func rescanFiles() -> Task<Void, Never>? {
        guard !isRescanning else {
            rescanQueued = true
            return nil
        }
        isRescanning = true
        let exporter = exporter
        let projectDir = project.path
        return Task { [weak self] in
            repeat {
                self?.rescanQueued = false
                let scan = await Task.detached {
                    exporter.scanProjectFiles(projectDir: projectDir)
                }.value
                self?.fileScan = scan
            } while self?.rescanQueued == true
            self?.isRescanning = false
        }
    }
    @ObservationIgnored private var rescanQueued = false

    /// Whether the required files are present, as of the last scan. `false`
    /// until the scan lands — Export stays disabled rather than guessing.
    var requiredFilesPresent: Bool {
        guard let fileScan else { return false }
        return fileScan.dashboardPresent && fileScan.readmePresent && fileScan.agentsMdPresent
    }

    /// Kick off the export, writing to `outputPath`. The caller is
    /// responsible for bouncing the user through an `NSSavePanel` to get
    /// that path.
    func export(to outputPath: String) {
        stage = .exporting
        let exporter = exporter
        let inputs = currentInputs
        Task.detached { [weak self] in
            do {
                try await exporter.export(inputs: inputs, outputZipPath: outputPath)
                await MainActor.run { [weak self] in
                    self?.stage = .succeeded(path: outputPath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private

    private var currentInputs: ProjectTemplateExporter.ExportInputs {
        let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmedAppendix = memoryAppendix.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectTemplateExporter.ExportInputs(
            project: project,
            templateId: templateId.trimmingCharacters(in: .whitespaces),
            templateName: templateName.trimmingCharacters(in: .whitespaces),
            templateVersion: templateVersion.trimmingCharacters(in: .whitespaces),
            description: templateDescription.trimmingCharacters(in: .whitespaces),
            authorName: authorName.isEmpty ? nil : authorName,
            authorUrl: authorURL.isEmpty ? nil : authorURL,
            category: category.isEmpty ? nil : category,
            tags: parsedTags,
            includeSkillIds: Array(includeSkillIds),
            includeCronJobIds: Array(includeCronJobIds),
            memoryAppendix: trimmedAppendix.isEmpty ? nil : trimmedAppendix
        )
    }
}

extension ProjectTemplateExporter {
    /// Lowercase-and-hyphenate a human name into something safe for a
    /// template id suffix. Only used to seed the default id in the export
    /// form — the author can overwrite it.
    nonisolated static func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber { return c }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "template" : collapsed
    }
}
