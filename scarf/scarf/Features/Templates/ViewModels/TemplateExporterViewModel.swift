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

    var stage: Stage = .idle

    func load() {
        let ctx = context
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

    func previewPlan() -> ProjectTemplateExporter.ExportPlan {
        exporter.previewPlan(for: currentInputs)
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
                try exporter.export(inputs: inputs, outputZipPath: outputPath)
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
