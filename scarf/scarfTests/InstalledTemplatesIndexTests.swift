import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the catalog browser's install-state lookup. Five suites
/// covering the build path's empty / templated / ad-hoc / version-diff
/// branches plus the `classify` helper's semver-ish comparison.
@Suite(.serialized)
struct InstalledTemplatesIndexTests {

    private static let envKey = "SCARF_HERMES_HOME"

    @Test func emptyRegistryYieldsEmptyIndex() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let index = InstalledTemplatesIndex(context: .local).build()
        #expect(index.isEmpty)
    }

    @Test func templatedProjectAppearsInIndex() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let projectDir = fixture.homeURL.appendingPathComponent("project-1", isDirectory: true).path
        try seedTemplatedProject(
            at: projectDir,
            registryPath: ServerContext.local.paths.projectsRegistry,
            projectName: "Test Project",
            templateId: "alan/example",
            templateVersion: "1.2.3"
        )

        let index = InstalledTemplatesIndex(context: .local).build()
        #expect(index["alan/example"] == "1.2.3")
    }

    @Test func adHocProjectWithoutLockIsSkipped() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        // Project lives in registry but has no `.scarf/template.lock.json`.
        let projectDir = fixture.homeURL.appendingPathComponent("ad-hoc", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let registry = ProjectRegistry(projects: [
            ProjectEntry(name: "Ad Hoc", path: projectDir)
        ])
        try writeRegistry(registry, at: ServerContext.local.paths.projectsRegistry)

        let index = InstalledTemplatesIndex(context: .local).build()
        #expect(index.isEmpty)
    }

    @Test func corruptLockIsSkippedNotCrashing() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let projectDir = fixture.homeURL.appendingPathComponent("corrupt", isDirectory: true).path
        let scarfDir = projectDir + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        try "not-json".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: scarfDir + "/template.lock.json"))

        let registry = ProjectRegistry(projects: [
            ProjectEntry(name: "Corrupt", path: projectDir)
        ])
        try writeRegistry(registry, at: ServerContext.local.paths.projectsRegistry)

        let index = InstalledTemplatesIndex(context: .local).build()
        #expect(index.isEmpty)
    }

    // MARK: - classify(catalogVersion:installedVersion:)

    @Test func classifyBranches() {
        // Not installed.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.0.0", installedVersion: nil)
                == .notInstalled
        )
        // Equal versions.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.0.0", installedVersion: "1.0.0")
                == .installed(version: "1.0.0")
        )
        // Catalog ahead.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.1.0", installedVersion: "1.0.0")
                == .updateAvailable(installedVersion: "1.0.0", catalogVersion: "1.1.0")
        )
        // Catalog behind installed (downgrade or stale catalog) — treat
        // as installed, not "update available." User shouldn't see a
        // ghost update prompt that takes them backwards.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "0.9.0", installedVersion: "1.0.0")
                == .installed(version: "1.0.0")
        )
        // Multi-component compare.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "2.0.0", installedVersion: "1.99.99")
                == .updateAvailable(installedVersion: "1.99.99", catalogVersion: "2.0.0")
        )
    }

    /// Pre-release versions outrank by being *older*: a `1.0.0-beta`
    /// catalog entry must NOT surface as "Update available" against a
    /// stable `1.0.0` installation, otherwise the upgrade flow would
    /// silently downgrade the user. See semver §11.
    @Test func prereleaseDoesNotShadowStable() {
        // Catalog ships pre-release; user already on the matching stable.
        // Should classify as installed (not update-available).
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.0.0-beta", installedVersion: "1.0.0")
                == .installed(version: "1.0.0")
        )
        // The reverse: user on pre-release, catalog ships stable. Stable
        // is genuinely newer.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.0.0", installedVersion: "1.0.0-beta")
                == .updateAvailable(installedVersion: "1.0.0-beta", catalogVersion: "1.0.0")
        )
        // Two pre-releases on the same numeric core: lexicographic
        // tiebreak on the suffix. `beta.2` > `beta.1`.
        #expect(
            InstalledTemplatesIndex.classify(catalogVersion: "1.0.0-beta.2", installedVersion: "1.0.0-beta.1")
                == .updateAvailable(installedVersion: "1.0.0-beta.1", catalogVersion: "1.0.0-beta.2")
        )
        // Direct probe of the comparator for the historical bug case.
        #expect(InstalledTemplatesIndex.isVersionNewer("1.0.0-beta", than: "1.0.0") == false)
        #expect(InstalledTemplatesIndex.isVersionNewer("1.0.0", than: "1.0.0-beta") == true)
    }

    // MARK: - Helpers

    /// Helper bundle returned by `makeTmpHome()` so each `@Test`
    /// func can capture both the tmpdir and the registry snapshot in
    /// `let`s without needing `mutating` (which Swift Testing's
    /// `@Test` macros disallow).
    private struct HomeFixture {
        let homeURL: URL
        let registrySnapshot: Data?
    }

    private func makeTmpHome() throws -> HomeFixture {
        // Cross-suite serialization against any other test that reads
        // `ServerContext.local.paths`. See the matching block in
        // `CatalogServiceTests` for the rationale.
        let registrySnapshot = TestRegistryLock.acquireAndSnapshot()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("scarf-index-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: path.path + "/scarf",
            withIntermediateDirectories: true
        )
        // Sentinel marker — see CatalogServiceTests for rationale.
        try Data().write(to: path.appendingPathComponent(HermesProfileResolver.testHomeMarkerFilename))
        setenv(Self.envKey, path.path, 1)
        HermesProfileResolver.invalidateCache()
        return HomeFixture(homeURL: path, registrySnapshot: registrySnapshot)
    }

    private func teardown(_ fixture: HomeFixture) {
        unsetenv(Self.envKey)
        HermesProfileResolver.invalidateCache()
        try? FileManager.default.removeItem(at: fixture.homeURL)
        TestRegistryLock.restore(fixture.registrySnapshot)
    }

    private func writeRegistry(_ registry: ProjectRegistry, at path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(registry)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func seedTemplatedProject(
        at projectDir: String,
        registryPath: String,
        projectName: String,
        templateId: String,
        templateVersion: String
    ) throws {
        let scarfDir = projectDir + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)

        // Lock file matching what ProjectTemplateInstaller.writeLockFile would produce.
        let lockJSON = """
        {
          "template_id": "\(templateId)",
          "template_version": "\(templateVersion)",
          "template_name": "Test Template",
          "installed_at": "2026-05-03T00:00:00Z",
          "project_files": [],
          "skills_namespace_dir": null,
          "skills_files": [],
          "cron_job_names": [],
          "memory_block_id": null
        }
        """
        try lockJSON.data(using: .utf8)!
            .write(to: URL(fileURLWithPath: scarfDir + "/template.lock.json"))

        let registry = ProjectRegistry(projects: [
            ProjectEntry(name: projectName, path: projectDir)
        ])
        try writeRegistry(registry, at: registryPath)
    }
}
