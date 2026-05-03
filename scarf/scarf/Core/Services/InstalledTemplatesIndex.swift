import Foundation
import ScarfCore
import os

/// Maps `templateId → installedVersion` for every project the user has
/// installed via a template. Used by the catalog browser to render
/// each row's "Installed" / "Update available" / "Not installed" badge.
///
/// **Read-only.** This service walks the projects registry + each
/// project's `.scarf/template.lock.json`. It never writes anything.
///
/// **Per-call rebuild.** The index is cheap to compute (a registry
/// read + N lock-file reads, each a few hundred bytes) and changes
/// infrequently from the user's perspective. We rebuild on every
/// catalog-sheet open instead of caching with invalidation rules —
/// the cost of a stale "Installed" badge would surprise users far more
/// than the cost of one extra `[String:Data]` walk on each refresh.
struct InstalledTemplatesIndex: Sendable {

    private static let logger = Logger(subsystem: "com.scarf", category: "InstalledTemplatesIndex")

    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    /// Build the index. Returns `[templateId: version]`. Projects
    /// without a lock file (ad-hoc projects added via "Add Project")
    /// are skipped silently — they aren't template-installed and don't
    /// belong in the index.
    func build() -> [String: String] {
        let transport = context.makeTransport()
        let registryPath = context.paths.projectsRegistry
        guard transport.fileExists(registryPath),
              let data = try? transport.readFile(registryPath) else {
            return [:]
        }

        let registry: ProjectRegistry
        do {
            registry = try JSONDecoder().decode(ProjectRegistry.self, from: data)
        } catch {
            Self.logger.warning("couldn't decode projects registry: \(error.localizedDescription, privacy: .public)")
            return [:]
        }

        var index: [String: String] = [:]
        for project in registry.projects {
            guard let lock = readLock(for: project) else { continue }
            // Last-write-wins on duplicates. Two installs of the same
            // template id at different versions is rare but possible
            // (user installed it in two project dirs); the catalog
            // doesn't need to render which version, just that
            // *something* is installed.
            index[lock.templateId] = lock.templateVersion
        }
        return index
    }

    /// Update-availability classification for a single catalog entry.
    /// `installedVersion == nil` → not installed. Equal versions →
    /// `.installed`. Catalog version newer than installed → `.updateAvailable`.
    /// Catalog version older or equal-but-different format → `.installed`
    /// (we trust the catalog; semver-noise comparisons aren't worth a
    /// full parse here).
    static func classify(catalogVersion: String, installedVersion: String?) -> InstallState {
        guard let installedVersion else { return .notInstalled }
        if catalogVersion == installedVersion {
            return .installed(version: installedVersion)
        }
        if isVersionNewer(catalogVersion, than: installedVersion) {
            return .updateAvailable(installedVersion: installedVersion, catalogVersion: catalogVersion)
        }
        return .installed(version: installedVersion)
    }

    enum InstallState: Sendable, Equatable {
        case notInstalled
        case installed(version: String)
        case updateAvailable(installedVersion: String, catalogVersion: String)
    }

    // MARK: - Internals

    /// Read `<project>/.scarf/template.lock.json`. Returns nil for
    /// ad-hoc (non-templated) projects, malformed JSON, or any I/O
    /// failure — the catalog shouldn't crash because one project's
    /// lock file got corrupted.
    private func readLock(for project: ProjectEntry) -> TemplateLock? {
        let path = project.path + "/.scarf/template.lock.json"
        let transport = context.makeTransport()
        guard transport.fileExists(path) else { return nil }
        guard let data = try? transport.readFile(path) else { return nil }
        return try? JSONDecoder().decode(TemplateLock.self, from: data)
    }

    /// Plain semver-ish comparison: split on `.`, compare numerically
    /// from major down. Non-numeric segments fall back to string
    /// comparison (so `1.0.0-beta` vs `1.0.0` does the sane thing).
    /// Good enough for "is the catalog ahead?" — this isn't a package
    /// manager.
    private static func isVersionNewer(_ candidate: String, than other: String) -> Bool {
        let a = candidate.split(separator: ".").map(String.init)
        let b = other.split(separator: ".").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let ai = i < a.count ? a[i] : "0"
            let bi = i < b.count ? b[i] : "0"
            if let an = Int(ai), let bn = Int(bi) {
                if an != bn { return an > bn }
            } else if ai != bi {
                return ai > bi
            }
        }
        return false
    }
}
