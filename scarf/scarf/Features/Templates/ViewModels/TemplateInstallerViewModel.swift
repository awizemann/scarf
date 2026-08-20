import Foundation
import ScarfCore
import os

/// Drives the template install sheet. Handles three entry points:
/// 1. `openLocalFile(_:)` — user picked a `.scarftemplate` from disk.
/// 2. `openRemoteURL(_:)` — user pasted/deeplinked a https URL.
/// 3. `confirmInstall()` — user clicked "Install" in the preview sheet.
///
/// The view model owns one ephemeral temp dir at a time (the unpacked
/// bundle). `cancel()` or `confirmInstall()` removes it.
@Observable
@MainActor
final class TemplateInstallerViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateInstallerViewModel")

    enum Stage: Sendable {
        case idle
        case fetching(sourceDescription: String)
        case inspecting
        case awaitingParentDirectory
        /// Template declared a non-empty config schema; the sheet
        /// presents `TemplateConfigSheet` before continuing to the
        /// preview. Schema-less templates skip this stage entirely.
        case awaitingConfig
        case planned
        case installing
        case succeeded(installed: ProjectEntry)
        case failed(String)
    }

    let context: ServerContext
    private let templateService: ProjectTemplateService
    private let installer: ProjectTemplateInstaller

    init(context: ServerContext) {
        self.context = context
        self.templateService = ProjectTemplateService(context: context)
        self.installer = ProjectTemplateInstaller(context: context)
    }

    var stage: Stage = .idle

    /// The inspected bundle awaiting confirmation. Derived from
    /// ``pendingInstall`` rather than stored alongside it, so the bundle and
    /// the analytics source token describing it cannot drift apart.
    var inspection: TemplateInspection? { pendingInstall?.inspection }
    var plan: TemplateInstallPlan?
    var chosenParentDirectory: String?
    /// README body preloaded off MainActor when inspection completes, so the
    /// preview sheet can render it without hitting `String(contentsOf:)` from
    /// inside a View body.
    var readmeBody: String?

    /// The install awaiting confirmation: the inspected bundle plus the
    /// analytics source token that entry point supplied.
    ///
    /// The source is carried *with* the pending install rather than in a
    /// standalone VM property because two entries can overlap — a hub
    /// download still in flight when the user opens a local file — and a
    /// shared property would let the second entry's source be read back
    /// for the first install. Each entry point captures its own token and
    /// publishes it in the same MainActor step that publishes its
    /// inspection, so the token and the bundle it describes can never come
    /// apart.
    ///
    /// Tokens — the taxonomy's full vocabulary for `template_installed` /
    /// `skill_installed`: `"hub"` (Browse Catalog) or `"url"` (Install
    /// from URL, a `scarf://install` deep link, and the local-file entry
    /// points — Install from File, Finder double-click, drag-onto-icon).
    /// Local-file installs fall into `"url"` because, like a pasted URL,
    /// they're an external file the user supplied rather than something
    /// Scarf shipped or curated. Recorded on `confirmInstall()`, not at
    /// entry, so a cancelled or failed install never counts.
    struct PendingInstall {
        var inspection: TemplateInspection
        var source: String
    }

    private var pendingInstall: PendingInstall?

    /// Test seam: the source token currently paired with the pending
    /// install, or `nil` when nothing is awaiting confirmation.
    var pendingInstallSourceForTesting: String? { pendingInstall?.source }

    // MARK: - Entry points

    /// Inspect a local `.scarftemplate` file. Moves stage to `.inspecting`
    /// then either `.awaitingParentDirectory` or `.failed`. The unpacked
    /// README body is read off MainActor here and stored on the VM so the
    /// preview sheet doesn't do sync I/O during View body evaluation.
    ///
    /// - Parameter source: analytics source token; defaults to `"url"` (the
    ///   local-file case). `openRemoteURL` passes its own token through
    ///   when it delegates here for a catalog pick.
    func openLocalFile(_ zipPath: String, source: String = "url") {
        resetTempState()
        stage = .inspecting
        let service = templateService
        Task.detached { [weak self] in
            do {
                let inspection = try service.inspect(zipPath: zipPath)
                let readme = Self.readReadme(unpackedDir: inspection.unpackedDir)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // The bundle and its source token land in one step —
                    // see `PendingInstall`.
                    self.pendingInstall = PendingInstall(inspection: inspection, source: source)
                    self.readmeBody = readme
                    self.stage = .awaitingParentDirectory
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Read README.md from an unpacked template dir. Nonisolated so the
    /// inspect task can call it off MainActor. Returns `nil` on any I/O
    /// failure — the preview sheet treats a nil README as "no section."
    nonisolated private static func readReadme(unpackedDir: String) -> String? {
        let path = unpackedDir + "/README.md"
        do {
            return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        } catch {
            Logger(subsystem: "com.scarf", category: "TemplateInstallerViewModel")
                .warning("couldn't read README at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Download a https `.scarftemplate` to a temp file, then hand off to
    /// `openLocalFile`. The 50 MB cap matches the plan — templates shouldn't
    /// be anywhere near that, and rejecting huge downloads is cheap defense.
    ///
    /// Content-Length is checked first as an early-out, but chunked
    /// transfer responses omit that header. The authoritative check is the
    /// actual on-disk file size after the download completes — it runs
    /// unconditionally and covers the chunked-transfer case.
    func openRemoteURL(_ url: URL, source: String = "url") {
        resetTempState()
        stage = .fetching(sourceDescription: url.host ?? url.absoluteString)
        Task.detached { [weak self] in
            let maxBytes: Int64 = 50 * 1024 * 1024
            do {
                let tempZip = NSTemporaryDirectory() + "scarf-template-download-" + UUID().uuidString + ".scarftemplate"
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                if let httpResponse = response as? HTTPURLResponse {
                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw ProjectTemplateError.unzipFailed("HTTP \(httpResponse.statusCode)")
                    }
                    if let length = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                       let bytes = Int64(length), bytes > maxBytes {
                        throw ProjectTemplateError.unzipFailed("template exceeds 50 MB size cap (\(bytes) bytes)")
                    }
                }
                // Unconditional post-download size check — catches chunked
                // responses that ship no Content-Length. The download already
                // hit disk, but refusing to *process* it bounds the blast
                // radius to one temp file that gets removed in the defer.
                let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard actualSize <= maxBytes else {
                    throw ProjectTemplateError.unzipFailed("template exceeds 50 MB size cap (\(actualSize) bytes)")
                }
                try FileManager.default.moveItem(atPath: tempURL.path, toPath: tempZip)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // `source` is the one this call captured, not a VM
                    // property another entry point may have overwritten
                    // while the download was in flight.
                    self.openLocalFile(tempZip, source: source)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed("Couldn't fetch template: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Planning + confirmation

    /// Finalize the plan now that the user has picked a parent directory.
    func pickParentDirectory(_ parentDir: String) {
        guard let inspection else { return }
        chosenParentDirectory = parentDir
        let service = templateService
        Task.detached { [weak self] in
            do {
                let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.plan = plan
                    // If the template declares a non-empty config
                    // schema, insert the configure step before the
                    // preview sheet. Otherwise go straight to .planned.
                    if let schema = plan.configSchema, !schema.isEmpty {
                        self.stage = .awaitingConfig
                    } else {
                        self.stage = .planned
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Called by `TemplateInstallSheet` once the user has filled in
    /// the configure form and `TemplateConfigViewModel.commit()`
    /// succeeded. Stashes the values in the plan and advances to the
    /// preview stage (`.planned`). Secrets in `values` are already
    /// `.keychainRef(...)` — the VM's commit step wrote them to the
    /// Keychain.
    func submitConfig(values: [String: TemplateConfigValue]) {
        guard var plan else { return }
        plan.configValues = values
        self.plan = plan
        stage = .planned
    }

    /// Called when the user cancels out of the configure step without
    /// committing. Returns to `.awaitingParentDirectory` so they can
    /// try again (or dismiss the whole sheet).
    func cancelConfig() {
        stage = .awaitingParentDirectory
    }

    func confirmInstall() {
        guard let plan else { return }
        // Read once, here, so the whole emission below describes the same
        // install even if a new entry point lands mid-flight.
        let source = pendingInstall?.source ?? "url"
        stage = .installing
        let installer = installer
        let service = templateService
        Task.detached { [weak self] in
            do {
                let entry = try installer.install(plan: plan)
                service.cleanupTempDir(plan.unpackedDir)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.stage = .succeeded(installed: entry)
                    self.pendingInstall = nil
                    self.plan = nil
                    self.chosenParentDirectory = nil
                    self.readmeBody = nil
                    Analytics.record("template_installed", props: ["source": source])
                    // `manifest.id` is arbitrary author-controlled text
                    // (`TemplateExporterViewModel` seeds it from the
                    // project's own free-typed name), so it can never ride
                    // along as `template` — every template install, hub or
                    // otherwise, is user- or third-party-authored content,
                    // not something Scarf ships or curates, so "custom" is
                    // the honest coarse value rather than inventing a
                    // "builtin" bucket nothing here would ever produce.
                    Analytics.record("project_created", props: [
                        "template": "custom",
                        "method": "import",
                    ])
                    // A template can bundle skills (namespaced under
                    // `templates/<slug>/`); each one installed here arrived
                    // through the same channel as the template itself.
                    //
                    // Counted from the file copies the installer actually
                    // performed, NOT from `manifest.contents.skills` (which is
                    // what the author *declared*): the plan is what
                    // `createSkillsFiles` writes, and a declared skill with no
                    // files in the bundle aborts the whole install before we
                    // get here. `install()` has no per-item result to consult,
                    // but it is all-or-nothing — reaching this branch means
                    // every planned copy landed — so the planned set is the
                    // written set.
                    for _ in 0..<Self.installedSkillCount(plan: plan) {
                        Analytics.record("skill_installed", props: ["source": source])
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Analytics helpers

    /// How many skills a successful install of `plan` actually wrote.
    ///
    /// Skills are directories: the plan carries one `TemplateFileCopy` per
    /// *file*, all under `<skillsNamespaceDir>/<skillName>/…`, so the skill
    /// count is the number of distinct first path components below the
    /// namespace dir. Pure and `static` so the `skill_installed` cardinality
    /// can be tested without an install.
    nonisolated static func installedSkillCount(plan: TemplateInstallPlan) -> Int {
        guard let namespaceDir = plan.skillsNamespaceDir else { return 0 }
        let prefix = namespaceDir.hasSuffix("/") ? namespaceDir : namespaceDir + "/"
        var names = Set<String>()
        for copy in plan.skillsFiles {
            guard copy.destinationPath.hasPrefix(prefix) else { continue }
            let relative = String(copy.destinationPath.dropFirst(prefix.count))
            guard let name = relative.split(separator: "/").first, !name.isEmpty else { continue }
            names.insert(String(name))
        }
        return names.count
    }

    // MARK: - Cleanup

    func cancel() {
        resetTempState()
        stage = .idle
    }

    private func resetTempState() {
        if let inspection {
            templateService.cleanupTempDir(inspection.unpackedDir)
        }
        pendingInstall = nil
        plan = nil
        chosenParentDirectory = nil
        readmeBody = nil
    }
}
