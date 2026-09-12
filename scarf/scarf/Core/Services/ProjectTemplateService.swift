import Foundation
import ScarfCore
import os

/// Reads, validates, and plans the install of a `.scarftemplate` bundle. Pure
/// — owns no state across calls. The installer (see
/// `ProjectTemplateInstaller`) consumes the `TemplateInstallPlan` this
/// produces.
///
/// Responsibilities:
/// 1. Unpack a `.scarftemplate` zip into a caller-owned temp directory.
/// 2. Parse `template.json` and validate it against the schema we know about.
/// 3. Walk the unpacked contents and verify they match the manifest's
///    `contents` claim (so a malicious bundle can't hide files from the
///    preview sheet).
/// 4. Produce a `TemplateInstallPlan` describing every concrete filesystem
///    op the installer will perform, given a parent directory the user
///    picked.
struct ProjectTemplateService: Sendable {

    /// C10 budget for the `unzip` spawn. Generous: a template bundle is a
    /// handful of megabytes and this runs off the main actor, so the cap is a
    /// bound on a WEDGED child (a stuck mount, a full pipe), not a
    /// performance knob.
    nonisolated static let unzipTimeout: TimeInterval = 120
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateService")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Inspection

    /// Unpack the zip at `zipPath` into a fresh temp directory, parse and
    /// validate the manifest, and walk the contents. Throws on any
    /// inconsistency. On success, the caller owns `inspection.unpackedDir`
    /// and must remove it once they're done.
    nonisolated func inspect(zipPath: String) async throws -> TemplateInspection {
        let unpackedDir = try makeTempDir()
        try await unzip(zipPath: zipPath, intoDir: unpackedDir)

        let manifestPath = unpackedDir + "/template.json"
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            throw ProjectTemplateError.manifestMissing
        }

        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        } catch {
            throw ProjectTemplateError.manifestParseFailed(error.localizedDescription)
        }
        let manifest: ProjectTemplateManifest
        do {
            manifest = try JSONDecoder().decode(ProjectTemplateManifest.self, from: manifestData)
        } catch {
            throw ProjectTemplateError.manifestParseFailed(error.localizedDescription)
        }

        // schemaVersion 1 is the original v2.2 bundle; 2 adds the
        // optional `config` block. Both are valid. Newer versions get
        // refused so the installer never silently misinterprets a
        // future-shape bundle.
        guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2 else {
            throw ProjectTemplateError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        // Validate the optional config schema at inspect time — a
        // malformed schema (duplicate keys, secret-with-default, etc.)
        // gets rejected before the user ever sees the preview sheet.
        if let schema = manifest.config {
            do {
                try ProjectConfigService.validateSchema(schema)
            } catch {
                throw ProjectTemplateError.manifestParseFailed(
                    "invalid config schema: \(error.localizedDescription)"
                )
            }
        }

        let files = try Self.walk(unpackedDir)
        let cronJobs = try Self.readCronJobs(unpackedDir: unpackedDir)
        try Self.verifyClaims(manifest: manifest, files: files, cronJobCount: cronJobs.count)

        return TemplateInspection(
            manifest: manifest,
            unpackedDir: unpackedDir,
            files: files,
            cronJobs: cronJobs
        )
    }

    // MARK: - Planning

    /// Turn an inspection into a concrete install plan given the parent
    /// directory the user picked. The plan is deterministic — two calls with
    /// the same inputs produce the same ops.
    nonisolated func buildPlan(
        inspection: TemplateInspection,
        parentDir: String
    ) throws -> TemplateInstallPlan {
        let manifest = inspection.manifest
        let slug = manifest.slug
        let projectDir = parentDir + "/" + slug

        if FileManager.default.fileExists(atPath: projectDir) {
            throw ProjectTemplateError.projectDirExists(projectDir)
        }

        var projectFiles: [TemplateFileCopy] = [
            TemplateFileCopy(
                sourceRelativePath: "README.md",
                destinationPath: projectDir + "/README.md"
            ),
            TemplateFileCopy(
                sourceRelativePath: "AGENTS.md",
                destinationPath: projectDir + "/AGENTS.md"
            ),
            TemplateFileCopy(
                sourceRelativePath: "dashboard.json",
                destinationPath: projectDir + "/.scarf/dashboard.json"
            )
        ]

        // Optional per-agent instruction shims. Each is copied verbatim to
        // its conventional project-root path; we don't try to be clever.
        let instructionRoot = "instructions"
        for relative in (manifest.contents.instructions ?? []) {
            let source = instructionRoot + "/" + relative
            guard inspection.files.contains(source) else {
                throw ProjectTemplateError.requiredFileMissing(source)
            }
            projectFiles.append(
                TemplateFileCopy(
                    sourceRelativePath: source,
                    destinationPath: projectDir + "/" + relative
                )
            )
        }

        // Project-scoped slash commands (manifest schemaVersion 3+). Each
        // claimed name `<n>` must correspond to a `slash-commands/<n>.md`
        // file at the bundle root; copied into
        // `<projectDir>/.scarf/slash-commands/<n>.md`. The chat layer
        // picks them up automatically when the project chat starts.
        for slashName in (manifest.contents.slashCommands ?? []) {
            let source = "slash-commands/" + slashName + ".md"
            guard inspection.files.contains(source) else {
                throw ProjectTemplateError.requiredFileMissing(source)
            }
            projectFiles.append(
                TemplateFileCopy(
                    sourceRelativePath: source,
                    destinationPath: projectDir + "/.scarf/slash-commands/" + slashName + ".md"
                )
            )
        }

        // Namespaced skills: copied wholesale from skills/<name>/** into
        // ~/.hermes/skills/templates/<slug>/<name>/**.
        var skillsFiles: [TemplateFileCopy] = []
        var skillsNamespaceDir: String? = nil
        if let skillNames = manifest.contents.skills, !skillNames.isEmpty {
            let namespaceDir = context.paths.skillsDir + "/templates/" + slug
            skillsNamespaceDir = namespaceDir
            for skillName in skillNames {
                let prefix = "skills/" + skillName + "/"
                let skillFiles = inspection.files.filter { $0.hasPrefix(prefix) }
                guard !skillFiles.isEmpty else {
                    throw ProjectTemplateError.requiredFileMissing(prefix)
                }
                for relative in skillFiles {
                    let suffix = String(relative.dropFirst("skills/".count))
                    skillsFiles.append(
                        TemplateFileCopy(
                            sourceRelativePath: relative,
                            destinationPath: namespaceDir + "/" + suffix
                        )
                    )
                }
            }
        }

        // Cron jobs: always prefix name with the template tag so users can
        // find and remove them later. Jobs ship disabled — the installer
        // pauses each one immediately after `cron create`.
        let cronJobs: [TemplateCronJobSpec] = inspection.cronJobs.map { job in
            TemplateCronJobSpec(
                name: "[tmpl:\(manifest.id)] \(job.name)",
                schedule: job.schedule,
                prompt: job.prompt,
                deliver: job.deliver,
                skills: job.skills,
                repeatCount: job.repeatCount
            )
        }

        // Memory appendix: wrap whatever the template ships in
        // begin/end markers so an uninstall can find and remove exactly the
        // bytes this template added. `verifyClaims` already guaranteed the
        // file is present — so a read error here means something unusual
        // (permissions, encoding, etc.); surface it with the real
        // `error.localizedDescription` rather than hiding behind a
        // generic "file missing."
        var memoryAppendix: String? = nil
        if manifest.contents.memory?.append == true {
            let appendSource = inspection.unpackedDir + "/memory/append.md"
            let raw: String
            do {
                raw = try String(contentsOf: URL(fileURLWithPath: appendSource), encoding: .utf8)
            } catch {
                Self.logger.error("failed to read memory/append.md in unpacked bundle: \(error.localizedDescription, privacy: .public)")
                throw ProjectTemplateError.manifestParseFailed("memory/append.md: \(error.localizedDescription)")
            }
            memoryAppendix = Self.wrapMemoryBlock(
                templateId: manifest.id,
                templateVersion: manifest.version,
                body: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Configuration schema + manifest cache. The installer writes
        // `.scarf/config.json` (non-secret values) + `.scarf/manifest.json`
        // (schema cache used by the post-install editor) when the
        // template declares a non-empty schema. Both paths go into
        // projectFiles so the uninstaller picks them up via the lock.
        var configSchema: TemplateConfigSchema? = nil
        var manifestCachePath: String? = nil
        if let schema = manifest.config, !schema.isEmpty {
            configSchema = schema
            let configPath = projectDir + "/.scarf/config.json"
            projectFiles.append(
                // Source is synthesized by the installer from configValues;
                // no file in the unpacked bundle maps to this entry. We use
                // an empty `sourceRelativePath` as the "no physical source"
                // sentinel — the installer special-cases it below (see
                // ProjectTemplateInstaller.createProjectFiles).
                TemplateFileCopy(
                    sourceRelativePath: "",
                    destinationPath: configPath
                )
            )
            let cachePath = projectDir + "/.scarf/manifest.json"
            manifestCachePath = cachePath
            projectFiles.append(
                TemplateFileCopy(
                    sourceRelativePath: "template.json",
                    destinationPath: cachePath
                )
            )
        }

        return TemplateInstallPlan(
            manifest: manifest,
            unpackedDir: inspection.unpackedDir,
            projectDir: projectDir,
            projectFiles: projectFiles,
            skillsNamespaceDir: skillsNamespaceDir,
            skillsFiles: skillsFiles,
            cronJobs: cronJobs,
            memoryAppendix: memoryAppendix,
            memoryPath: context.paths.memoryMD,
            projectRegistryName: Self.uniqueProjectName(preferred: manifest.name, context: context),
            configSchema: configSchema,
            configValues: [:],   // filled in by TemplateInstallerViewModel before install()
            manifestCachePath: manifestCachePath
        )
    }

    // MARK: - Cleanup

    /// Remove a temp dir created by `inspect`. Safe to call if it already
    /// doesn't exist (install or cancel flows both end here).
    nonisolated func cleanupTempDir(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Memory block helpers (installer + future uninstaller share these)

    nonisolated static func memoryBlockBeginMarker(templateId: String) -> String {
        "<!-- scarf-template:\(templateId):begin -->"
    }

    nonisolated static func memoryBlockEndMarker(templateId: String) -> String {
        "<!-- scarf-template:\(templateId):end -->"
    }

    nonisolated static func wrapMemoryBlock(
        templateId: String,
        templateVersion: String,
        body: String
    ) -> String {
        let begin = memoryBlockBeginMarker(templateId: templateId)
        let end = memoryBlockEndMarker(templateId: templateId)
        return "\n\n\(begin) v\(templateVersion)\n\(body)\n\(end)\n"
    }

    // MARK: - Private

    private nonisolated func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory() + "scarf-template-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true
        )
        return base
    }

    /// Shell out to `/usr/bin/unzip` — matches the existing profile-export
    /// pattern (`hermes profile import` shells to `unzip`) and avoids
    /// pulling in a third-party zip library.
    /// Ceilings for a `.scarftemplate` bundle. A template is a handful of
    /// markdown files, a dashboard and a cron spec — kilobytes. These are
    /// two orders of magnitude above anything legitimate, so they can only
    /// ever stop something that is not a template.
    nonisolated static let maxTemplateArchiveBytes: Int64 = 64 * 1024 * 1024
    nonisolated static let maxTemplateUnpackedBytes: Int64 = 256 * 1024 * 1024
    nonisolated static let maxTemplateEntries = 5_000

    /// Refuse a bundle before extracting it.
    ///
    /// `.scarftemplate` files arrive from the catalog, from a `scarf://`
    /// URL, or from a file the user was sent — none of which are trusted,
    /// and `unzip` will happily expand a few hundred KB into as much disk as
    /// the machine has. The user's clue would be a Mac that stops working.
    ///
    /// `unzip -Zt` reports the archive's own entry count and uncompressed
    /// total, which is what a decompression bomb has to LIE about to be
    /// effective — a lie that makes the archive fail its `verifyClaims`
    /// pass anyway. The compressed-size cap catches the honest-header case.
    ///
    /// **A listing Scarf cannot read is a REFUSAL** (round-4 decision 16).
    /// This used to reason that "an `unzip` that can't list will fail the
    /// extraction below with its own error" — which is exactly backwards for
    /// the input this guard exists for. The listing fails for a corrupt
    /// central directory, for a `-Zt` too chatty to finish inside its budget,
    /// and for an archive crafted to make it fail; in every one of those
    /// cases the extraction that follows is the thing the caps were supposed
    /// to gate, and `try?` handed it a free pass. An unopenable template is a
    /// small loss; a Mac that fills its disk is not.
    /// Internal rather than private so `ProjectTemplateBoundsP43Tests` can
    /// drive the ceilings directly, on real archives, without going through
    /// an `inspect()` that would unpack them.
    nonisolated func enforceArchiveBounds(
        zipPath: String,
        listingTimeout: TimeInterval = ProjectTemplateService.listingTimeout,
        unpackedCeiling: Int64 = ProjectTemplateService.maxTemplateUnpackedBytes
    ) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: zipPath)
        if let size = attrs?[.size] as? Int64, size > Self.maxTemplateArchiveBytes {
            throw ProjectTemplateError.unzipFailed(
                String(
                    localized: "This template file is \(size / 1_048_576) MB. Templates are a few kilobytes; refusing to open it.",
                    comment: "Refusal shown when a .scarftemplate file is far larger than any real template. The argument is the file's size in megabytes."
                )
            )
        }
        let listing: String
        do {
            listing = try await Self.runToolCapturingOutput(
                "/usr/bin/unzip", ["-Zt", zipPath], timeout: listingTimeout
            )
        } catch {
            throw ProjectTemplateError.unzipFailed(Self.unreadableListingRefusal)
        }
        // Same refusal for a listing that came back in a shape this parser
        // does not recognise: an unparsed listing gates nothing, and "the
        // numbers were not there" is not evidence that they were small.
        guard let claims = Self.parseArchiveListing(listing) else {
            throw ProjectTemplateError.unzipFailed(Self.unreadableListingRefusal)
        }
        if claims.entries > Self.maxTemplateEntries {
            throw ProjectTemplateError.unzipFailed(
                String(
                    localized: "This template declares \(claims.entries) files. Templates hold a handful; refusing to open it.",
                    comment: "Refusal shown when a .scarftemplate archive declares far more entries than any real template. The argument is the declared entry count."
                )
            )
        }
        if claims.uncompressedBytes > unpackedCeiling {
            throw ProjectTemplateError.unzipFailed(
                String(
                    localized: "This template would expand to \(claims.uncompressedBytes / 1_048_576) MB. Templates are a few kilobytes; refusing to open it.",
                    comment: "Refusal shown when a .scarftemplate archive's declared uncompressed size is far larger than any real template. The argument is that size in megabytes."
                )
            )
        }
    }

    /// Parse `unzip -Zt`'s one-line summary into the two numbers the caps
    /// read. Returns nil when either is missing — which, now that a listing
    /// Scarf cannot read is a refusal, is the difference between opening a
    /// template and rejecting it.
    ///
    /// `unzip -Zt` prints
    /// `12 files, 40960 bytes uncompressed, 8192 bytes compressed:  80.0%` —
    /// **and `1 file, 3 bytes uncompressed, …` for a single-entry archive.**
    /// The old field walk looked only for `files,`, so a one-file archive
    /// silently matched neither cap; under the fail-open it merely skipped
    /// them, but as a refusal it would have rejected a legitimate template.
    /// Both spellings are accepted here, and `ProjectTemplateBoundsP43Tests`
    /// runs the real `unzip` on a real one-entry zip to keep it honest.
    nonisolated static func parseArchiveListing(
        _ listing: String
    ) -> (entries: Int, uncompressedBytes: Int64)? {
        let fields = listing.split(separator: " ").map(String.init)
        guard let countIdx = fields.firstIndex(where: { $0 == "files," || $0 == "file," }),
              countIdx > 0, let entries = Int(fields[countIdx - 1]),
              let bytesIdx = fields.firstIndex(of: "bytes"), bytesIdx > 0,
              let uncompressed = Int64(fields[bytesIdx - 1])
        else { return nil }
        return (entries, uncompressed)
    }

    /// The one sentence every "the ceilings could not be checked" arm shows.
    /// Named because three arms share it — the listing spawn failed, it
    /// outstayed its budget, or it came back unparseable — and because the
    /// tests assert on the refusal rather than on a message literal.
    nonisolated static var unreadableListingRefusal: String {
        String(
            localized: "Scarf couldn't read this template's table of contents, so it can't check the file for a decompression bomb. Refusing to open it.",
            comment: "Refusal shown when listing a .scarftemplate archive fails, times out, or comes back unparseable, so the size and entry-count ceilings could not be checked."
        )
    }

    /// Run a tool and return stdout, with a hard timeout. Charter C10: no
    /// subprocess Scarf spawns is allowed to hang a caller forever, and both
    /// of this file's `unzip` invocations are on a user-facing path.
    /// The listing spawn's own budget. `unzip -Zt` reads only the central
    /// directory, so a healthy run is milliseconds; this is a ceiling on a
    /// wedged one.
    nonisolated static let listingTimeout: TimeInterval = 20

    /// `async`, and a `waitDrainingAsync` inside, because every caller is
    /// `async`. The synchronous `waitDraining` is a `Thread.sleep` poll loop:
    /// from `async` code it parks a COOPERATIVE-POOL thread for the whole
    /// budget, and `Task.detached` — which is what the enclosing view model
    /// used — is that same pool, so the block was relabelled rather than
    /// moved (round-5 P48, t-12d04477).
    nonisolated static func runToolCapturingOutput(
        _ executable: String, _ args: [String], timeout: TimeInterval
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // The READ ends belong to `waitDraining` once the process has
        // launched; only the launch-failure path below closes them here.
        func closeWriteEnds() {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            closeWriteEnds()
            throw ProjectTemplateError.unzipFailed(error.localizedDescription)
        }
        // C10, and the half the old bounded poll was missing: the drain must
        // run CONCURRENTLY with the wait. This read stdout only after the
        // poll, so an archive chatty enough to fill the 64 KB buffer stalled
        // the child in `write()`, ran the budget out, and — through the
        // caller's `try?` — turned the bomb check into a no-op. Which is
        // precisely what an archive would want. See
        // ``Process.waitDraining(timeout:pipes:)``.
        let (exited, drained) = await process.waitDrainingAsync(
            timeout: timeout, pipes: [outPipe, errPipe])
        closeWriteEnds()
        guard exited else {
            throw ProjectTemplateError.unzipFailed("timed out reading the template archive")
        }
        // A non-zero exit is "could not read", not "read nothing". The old
        // code returned the empty stdout of a failed `unzip -Zt`, which parsed
        // into no fields and so skipped both caps — the same fail-open the
        // caller's `try?` had, one frame down.
        guard process.terminationStatus == 0 else {
            let err = String(data: drained.last ?? Data(), encoding: .utf8) ?? ""
            throw ProjectTemplateError.unzipFailed(
                err.isEmpty ? "exit \(process.terminationStatus)" : err)
        }
        return String(data: drained.first ?? Data(), encoding: .utf8) ?? ""
    }

    private nonisolated func unzip(zipPath: String, intoDir: String) async throws {
        try await enforceArchiveBounds(zipPath: zipPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", zipPath, "-d", intoDir]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // The READ ends are the ones that leak: a spawn whose `Pipe` outlives
        // it and whose read ends are never closed costs 2 fds (measured at 50
        // spawns, round-4 P43b). They belong to `waitDraining` once the
        // process has launched — see that method — so this closes them only on
        // the launch-failure path below, where nothing is draining them.
        //
        // The WRITE ends do not leak after a successful `run()`: Foundation
        // closes the parent's copy as part of the spawn, and the 50-spawn
        // /dev/fd count was identical with and without these closes. They are
        // kept anyway because on the launch-failure path `run()` never spawned
        // and they are then the real release; a `try?` close of an
        // already-closed handle is a harmless `EBADF`.
        func closePipes(includingReadEnds: Bool = false) {
            if includingReadEnds {
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            closePipes(includingReadEnds: true)
            throw ProjectTemplateError.unzipFailed(error.localizedDescription)
        }
        // C10: bounded, and drained CONCURRENTLY with the wait. `unzip`
        // prints a line per problem entry, so a corrupt or hostile archive
        // can fill the 64 KB pipe buffer and deadlock a parent that reads
        // only after the wait — see ``Process.waitDraining(timeout:pipes:)``.
        let (exited, drained) = await process.waitDrainingAsync(
            timeout: Self.unzipTimeout, pipes: [errPipe, outPipe])
        let errData = drained.first
        closePipes()

        guard exited else {
            throw ProjectTemplateError.unzipFailed(
                "unzip did not finish within \(Int(Self.unzipTimeout))s and was stopped")
        }
        guard process.terminationStatus == 0 else {
            let err = String(data: errData ?? Data(), encoding: .utf8) ?? ""
            throw ProjectTemplateError.unzipFailed(err.isEmpty ? "exit \(process.terminationStatus)" : err)
        }
    }

    /// Recursively walk `dir` and return every file (not directory) as a
    /// path relative to `dir`. Skips symlinks entirely — templates should
    /// never contain them, and following them could escape the unpack dir.
    ///
    /// Both the base dir and the enumerated URLs are resolved via
    /// `resolvingSymlinksInPath` before comparison. On macOS, temp dirs
    /// under `/var/folders/…` resolve to `/private/var/folders/…`, so a
    /// naive string-prefix check would produce malformed relative paths
    /// when the base is unresolved but enumerated URLs are resolved.
    nonisolated private static func walk(_ dir: String) throws -> [String] {
        var results: [String] = []
        let baseURL = URL(fileURLWithPath: dir).resolvingSymlinksInPath()
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ProjectTemplateError.unsafeZipEntry(url.path)
            }
            guard values.isRegularFile == true else { continue }
            var full = url.resolvingSymlinksInPath().path
            if full.hasPrefix(basePath) {
                full.removeFirst(basePath.count)
            }
            if full.contains("..") {
                throw ProjectTemplateError.unsafeZipEntry(full)
            }
            results.append(full)
        }
        return results
    }

    nonisolated private static func readCronJobs(unpackedDir: String) throws -> [TemplateCronJobSpec] {
        let path = unpackedDir + "/cron/jobs.json"
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ProjectTemplateError.requiredFileMissing("cron/jobs.json")
        }
        let jobs: [TemplateCronJobSpec]
        do {
            jobs = try JSONDecoder().decode([TemplateCronJobSpec].self, from: data)
        } catch {
            throw ProjectTemplateError.manifestParseFailed("cron/jobs.json: \(error.localizedDescription)")
        }
        try jobs.forEach(rejectFlagShapedCronFields)
        return jobs
    }

    /// Refuse a template cron job whose fields would be read by `hermes
    /// cron create` as OPTIONS rather than as values.
    ///
    /// `ProjectTemplateInstaller.createCronJobs` builds an argv from this
    /// spec, and two of the fields land as POSITIONALS: `schedule` and the
    /// resolved `prompt`. A schedule of `--deliver` or a prompt of
    /// `--skill`, coming from a `.scarftemplate` the user downloaded, is
    /// then parsed by Hermes's argparse as a flag — quietly reconfiguring
    /// the job the preview sheet just showed the user, with delivery
    /// targets and skills they never approved. `skills` entries have the
    /// same shape problem one flag along.
    ///
    /// The fix is a REFUSAL, not an escape. Inserting `--` before the
    /// positionals would be the general answer, but charter C5 forbids
    /// assuming an argv works because it looks right — `--` handling would
    /// have to be verified against every supported Hermes tag, and a
    /// mis-verified guess breaks cron creation for every template. Nothing
    /// legitimate starts a cron schedule, prompt, skill or job name with
    /// `-`, so refusing that shape costs real templates nothing and closes
    /// the injection completely.
    nonisolated private static func rejectFlagShapedCronFields(_ job: TemplateCronJobSpec) throws {
        func check(_ value: String?, _ label: String) throws {
            guard let value, value.hasPrefix("-") else { return }
            throw ProjectTemplateError.manifestParseFailed(
                "cron/jobs.json: job \"\(job.name)\" has a \(label) starting with “-” (\"\(value)\"), "
                    + "which the cron command would read as an option rather than a value. "
                    + "Refusing to install this template."
            )
        }
        try check(job.name, "name")
        try check(job.schedule, "schedule")
        try check(job.prompt, "prompt")
        try check(job.deliver, "delivery target")
        for skill in job.skills ?? [] { try check(skill, "skill") }
    }

    /// Verify the manifest's `contents` claim exactly matches the unpacked
    /// files. Any mismatch — claimed-but-missing or present-but-unclaimed —
    /// throws, so the preview sheet the user sees is always accurate.
    nonisolated private static func verifyClaims(
        manifest: ProjectTemplateManifest,
        files: [String],
        cronJobCount: Int
    ) throws {
        let fileSet = Set(files)

        if manifest.contents.dashboard {
            if !fileSet.contains("dashboard.json") {
                throw ProjectTemplateError.requiredFileMissing("dashboard.json")
            }
        }
        if manifest.contents.agentsMd {
            if !fileSet.contains("AGENTS.md") {
                throw ProjectTemplateError.requiredFileMissing("AGENTS.md")
            }
        }
        // README and AGENTS are always required; dashboard is always required
        // per spec. `contents.dashboard`/`contents.agentsMd` exist so a future
        // schema can relax those rules; for v1 we hard-require them regardless.
        if !fileSet.contains("README.md") {
            throw ProjectTemplateError.requiredFileMissing("README.md")
        }
        if !fileSet.contains("AGENTS.md") {
            throw ProjectTemplateError.requiredFileMissing("AGENTS.md")
        }
        if !fileSet.contains("dashboard.json") {
            throw ProjectTemplateError.requiredFileMissing("dashboard.json")
        }

        if let claimed = manifest.contents.instructions {
            for rel in claimed {
                let full = "instructions/" + rel
                if !fileSet.contains(full) {
                    throw ProjectTemplateError.contentClaimMismatch(
                        "manifest lists \(full) but the file is missing from the bundle"
                    )
                }
            }
            let present = fileSet.filter { $0.hasPrefix("instructions/") }
            let claimedFull = Set(claimed.map { "instructions/" + $0 })
            if let extra = present.first(where: { !claimedFull.contains($0) }) {
                throw ProjectTemplateError.contentClaimMismatch(
                    "bundle contains \(extra) but it's not listed in manifest.contents.instructions"
                )
            }
        } else if fileSet.contains(where: { $0.hasPrefix("instructions/") }) {
            throw ProjectTemplateError.contentClaimMismatch(
                "bundle has instructions/ files but manifest.contents.instructions is missing"
            )
        }

        if let claimed = manifest.contents.skills {
            for name in claimed {
                let prefix = "skills/" + name + "/"
                if !fileSet.contains(where: { $0.hasPrefix(prefix) }) {
                    throw ProjectTemplateError.contentClaimMismatch(
                        "manifest lists skill \(name) but skills/\(name)/ has no files"
                    )
                }
            }
            let presentSkills = Set(fileSet.compactMap { path -> String? in
                guard path.hasPrefix("skills/") else { return nil }
                let rest = path.dropFirst("skills/".count)
                return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
            })
            let claimedSet = Set(claimed)
            if let extra = presentSkills.subtracting(claimedSet).first {
                throw ProjectTemplateError.contentClaimMismatch(
                    "bundle contains skills/\(extra)/ but it's not listed in manifest.contents.skills"
                )
            }
        } else if fileSet.contains(where: { $0.hasPrefix("skills/") }) {
            throw ProjectTemplateError.contentClaimMismatch(
                "bundle contains skills/ but manifest.contents.skills is missing"
            )
        }

        // Slash commands (manifest schemaVersion 3+). Each claimed name
        // must correspond to exactly one `slash-commands/<name>.md` file
        // at the bundle root; extra files (not claimed) are rejected.
        // Also reject malformed names so the on-disk shape stays
        // round-trippable through `ProjectSlashCommandService.parse`.
        if let claimed = manifest.contents.slashCommands {
            for name in claimed {
                if let reason = ProjectSlashCommand.validateName(name) {
                    throw ProjectTemplateError.contentClaimMismatch(
                        "manifest.contents.slashCommands lists \"\(name)\": \(reason)"
                    )
                }
                let path = "slash-commands/" + name + ".md"
                if !fileSet.contains(path) {
                    throw ProjectTemplateError.contentClaimMismatch(
                        "manifest lists slash command \(name) but \(path) is missing from the bundle"
                    )
                }
            }
            let presentSlash = fileSet.filter { $0.hasPrefix("slash-commands/") }
            let claimedFull = Set(claimed.map { "slash-commands/" + $0 + ".md" })
            if let extra = presentSlash.first(where: { !claimedFull.contains($0) }) {
                throw ProjectTemplateError.contentClaimMismatch(
                    "bundle contains \(extra) but it's not listed in manifest.contents.slashCommands"
                )
            }
        } else if fileSet.contains(where: { $0.hasPrefix("slash-commands/") }) {
            throw ProjectTemplateError.contentClaimMismatch(
                "bundle contains slash-commands/ but manifest.contents.slashCommands is missing"
            )
        }

        let claimedCron = manifest.contents.cron ?? 0
        if claimedCron != cronJobCount {
            throw ProjectTemplateError.contentClaimMismatch(
                "manifest.contents.cron=\(claimedCron) but bundle contains \(cronJobCount) cron jobs"
            )
        }

        let hasMemoryFile = fileSet.contains("memory/append.md")
        let claimsMemory = manifest.contents.memory?.append == true
        if claimsMemory != hasMemoryFile {
            throw ProjectTemplateError.contentClaimMismatch(
                "manifest.contents.memory.append=\(claimsMemory) disagrees with memory/append.md presence=\(hasMemoryFile)"
            )
        }

        // Config claim must match the schema's actual field count so
        // the preview sheet is honest about the size of the configure
        // step. `nil` in contents means "no schema" just like `0`;
        // we normalise both to 0 before comparing.
        let claimedConfig = manifest.contents.config ?? 0
        let actualConfig = manifest.config?.fields.count ?? 0
        if claimedConfig != actualConfig {
            throw ProjectTemplateError.contentClaimMismatch(
                "manifest.contents.config=\(claimedConfig) but config.schema has \(actualConfig) field(s)"
            )
        }
    }

    /// Resolve a project-registry name that doesn't collide. Deterministic
    /// — given the same existing registry, always returns the same answer.
    nonisolated private static func uniqueProjectName(
        preferred: String,
        context: ServerContext
    ) -> String {
        let existing = Set(ProjectDashboardService(context: context).loadRegistry().projects.map(\.name))
        if !existing.contains(preferred) { return preferred }
        var i = 2
        while existing.contains("\(preferred) \(i)") {
            i += 1
        }
        return "\(preferred) \(i)"
    }
}
