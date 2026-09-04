import Foundation
import Observation
import os
import ScarfCore

/// MainActor view model for the Models sidebar entry. Holds the
/// snapshot of `ModelPreset` records and the per-preset usage count
/// (projects that bind each preset). All disk I/O dispatches off
/// MainActor through `ModelPresetService` and `ProjectDashboardService`.
@Observable
@MainActor
final class ModelPresetsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ModelPresetsViewModel")

    let context: ServerContext

    private(set) var presets: [ModelPreset] = []
    private(set) var usageCounts: [UUID: Int] = [:]
    /// Transient message string for inline banners (errors / status).
    /// Cleared after ~3 seconds by the caller via `clearStatus()`.
    private(set) var statusMessage: String?
    private(set) var statusIsError: Bool = false
    private(set) var isLoading = false

    private let service: ModelPresetService

    init(context: ServerContext) {
        self.context = context
        self.service = ModelPresetService.shared(for: context)
    }

    // MARK: - Load

    /// `hasLoaded` lets a plain section re-entry skip the preset re-read (the
    /// VM is cached in `AppCoordinator` and persists across switches); post-
    /// mutation reloads pass `force: true` (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        let svc = service
        let ctx = context
        Task { @MainActor [weak self] in
            do {
                let loaded = try await svc.list()
                let counts = await Self.countUsage(of: loaded, in: ctx)
                self?.presets = loaded
                self?.usageCounts = counts
            } catch {
                self?.logger.error("failed to load model presets: \(error.localizedDescription)")
                self?.statusMessage = "Couldn't load presets: \(error.localizedDescription)"
                self?.statusIsError = true
            }
            self?.isLoading = false
        }
    }

    // MARK: - Mutations

    func upsert(_ preset: ModelPreset) {
        let svc = service
        Task { @MainActor [weak self] in
            do {
                try await svc.upsert(preset)
                self?.statusMessage = "Saved \"\(preset.name)\""
                self?.statusIsError = false
                self?.load(force: true)
            } catch {
                self?.statusMessage = "Save failed: \(error.localizedDescription)"
                self?.statusIsError = true
            }
        }
    }

    func delete(id: UUID) {
        let svc = service
        Task { @MainActor [weak self] in
            do {
                try await svc.delete(id: id)
                self?.statusMessage = "Deleted preset"
                self?.statusIsError = false
                self?.load(force: true)
            } catch {
                self?.statusMessage = "Delete failed: \(error.localizedDescription)"
                self?.statusIsError = true
            }
        }
    }

    func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }

    // MARK: - Usage scan

    /// Count how many projects bind each preset. Reads every project's
    /// manifest once and folds into a `[UUID: Int]`. Dispatched off
    /// MainActor — `Task.detached` per ScarfCore conventions.
    private static func countUsage(
        of presets: [ModelPreset],
        in context: ServerContext
    ) async -> [UUID: Int] {
        guard !presets.isEmpty else { return [:] }
        let presetIDs = Set(presets.map { $0.id.uuidString })
        return await Task.detached(priority: .utility) {
            let registry = ProjectDashboardService(context: context).loadRegistry()
            let reader = ProjectModelPresetReader(context: context)
            var counts: [UUID: Int] = [:]
            for project in registry.projects {
                guard let idString = reader.presetID(forProjectPath: project.path),
                      presetIDs.contains(idString),
                      let uuid = UUID(uuidString: idString)
                else { continue }
                counts[uuid, default: 0] += 1
            }
            return counts
        }.value
    }
}
