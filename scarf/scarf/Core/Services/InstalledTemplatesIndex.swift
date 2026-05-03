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
        guard transport.fileExists(registryPath) else { return [:] }

        let data: Data
        do {
            data = try transport.readFile(registryPath)
        } catch {
            Self.logger.warning("couldn't read projects registry at \(registryPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        let data: Data
        do {
            data = try transport.readFile(path)
        } catch {
            Self.logger.warning("couldn't read template lock at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            return try JSONDecoder().decode(TemplateLock.self, from: data)
        } catch {
            Self.logger.warning("couldn't decode template lock at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Plain semver-ish comparison: split on `.`, compare numerically
    /// from major down. Pre-release suffixes (anything after `-` in a
    /// segment) make that release *older* than the same numeric prefix
    /// without a suffix — matches semver §11 ("a pre-release version has
    /// lower precedence than the associated normal version"), so
    /// `1.0.0-beta` is *not* newer than `1.0.0`. Two pre-releases on the
    /// same numeric prefix fall back to lexicographic compare on the
    /// suffix. Good enough for "is the catalog ahead?" — this isn't a
    /// package manager.
    static func isVersionNewer(_ candidate: String, than other: String) -> Bool {
        let (aCore, aPre) = splitPrerelease(candidate)
        let (bCore, bPre) = splitPrerelease(other)
        let a = aCore.split(separator: ".").map(String.init)
        let b = bCore.split(separator: ".").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let ai = i < a.count ? a[i] : "0"
            let bi = i < b.count ? b[i] : "0"
            if let an = Int(ai), let bn = Int(bi) {
                if an != bn { return an > bn }
            } else if ai != bi {
                return ai > bi
            }
        }
        // Numeric cores match. Pre-release tiebreak: an absent pre-release
        // outranks any present pre-release.
        switch (aPre, bPre) {
        case (nil, nil):           return false
        case (nil, _):             return true   // candidate has no pre-release; older has one → newer
        case (_, nil):             return false  // candidate has pre-release; other is the release → older
        case (let ap?, let bp?):   return ap > bp
        }
    }

    /// Split a version string into its numeric core and pre-release
    /// suffix on the first `-`. `"1.0.0-beta.2"` → `("1.0.0", "beta.2")`.
    /// `"1.0.0"` → `("1.0.0", nil)`.
    private static func splitPrerelease(_ version: String) -> (core: String, pre: String?) {
        if let dash = version.firstIndex(of: "-") {
            return (String(version[..<dash]), String(version[version.index(after: dash)...]))
        }
        return (version, nil)
    }
}
