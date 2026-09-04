import Foundation
#if canImport(os)
import os
#endif

/// One reconciliation pass over everything that claims to know what a
/// project is, and the repairs for what it finds.
///
/// **Three sources of truth, none authoritative on its own.**
/// - the registry index `~/.hermes/scarf/projects.json` (agent-writable),
/// - the canonical record `<root>/.scarf/project.json` (agent-writable),
/// - the directories actually on disk.
///
/// They drift because agents hand-write two of the three. `diagnose()`
/// compares them and reports; `repair(_:)` fixes only what an EXISTING
/// idempotent writer can fix — `ProjectStore.save` / `derive` /
/// `indexInRegistry`, `ProjectDashboardService.saveRegistry`. The doctor
/// owns no write path of its own, so a repair can never do something the
/// rest of the app cannot already do, and re-running it is always a no-op.
///
/// **Never rewrites an agent-owned file.** A malformed `dashboard.json`,
/// `manifest.json`, `config.json` — or a `project.json` that exists but
/// doesn't parse — is reported and left exactly as it is. Overwriting one
/// would destroy the only copy of whatever the agent was trying to say.
///
/// All I/O is synchronous transport I/O (an SSH round-trip per read on a
/// remote context), so callers MUST run `diagnose()` and `repair(_:)`
/// off-main — charter C10. `ProjectDoctorViewModel` does.
///
/// **Cost.** One `diagnose()` is roughly `2 + rows × 5 + scanRoots +
/// candidates` transport calls: two registry reads (decoded, then raw, to
/// tell an invalid id from an absent one), five per row (root, record, three
/// sidecars — each classified from a single read), one `listDirectory` per
/// scan root, and one or two per orphan candidate. That is seconds over SSH
/// on a large home, which is why it is user-initiated or once-per-project,
/// never per file-watcher tick.
public struct ProjectDoctorService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectDoctor")
    #endif

    /// Directory-scan bounds. The orphan scan walks candidate roots one
    /// level deep; these keep a pathological home (or a `~/projects` with
    /// thousands of entries) from turning a health check into a minutes-long
    /// SSH crawl.
    static let maxScanRoots = 16
    static let maxScanEntriesPerRoot = 300
    /// Total candidates probed across every root. The per-root cap alone
    /// bounds nothing useful: 16 roots × 300 entries is 4,800 candidates and
    /// up to two `fileExists` each, which on SSH is thousands of round-trips
    /// for one health check.
    static let maxScanCandidates = 400

    public let context: ServerContext
    public let transport: any ServerTransport

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Diagnose

    /// Walk all three sources and report. Pure read — writes nothing, not
    /// even a migration.
    public nonisolated func diagnose() -> ProjectDoctorReport {
        let dashboardService = ProjectDashboardService(context: context)
        let store = ProjectStore(context: context)
        let loaded = dashboardService.loadRegistryDetailed()
        let rows = loaded.registry.projects

        var findings: [ProjectDoctorFinding] = []

        // Raw pass: the salvaging decode DROPS an invalid `uuid`, so a row
        // that hand-carries `"uuid": "SHABUBOX-…"` is indistinguishable from
        // one that never had a uuid once decoded. Re-read the bytes to tell
        // those two apart — the difference matters, because one is a mistake
        // being repaired and the other is a migration that never ran.
        let rawInvalidUUIDPaths = rawInvalidUUIDPaths()

        let cronJobs = loadCronJobs()

        // Paths more than one row claims. Identity repairs are withheld for
        // these: every writer underneath addresses a row BY PATH and stops at
        // the first match, so repairing one of two rows at a path leaves the
        // other unrepaired and the finding un-clearable — a button that
        // silently does nothing. The `duplicatePath` finding is the one that
        // actually resolves the situation.
        var rowsByPath: [String: [ProjectEntry]] = [:]
        for row in rows { rowsByPath[ProjectIdentity.normalizedPath(row.path), default: []].append(row) }

        for row in rows {
            let group = rowsByPath[ProjectIdentity.normalizedPath(row.path)] ?? [row]
            findings += diagnoseRow(
                row,
                store: store,
                rawInvalidUUIDPaths: rawInvalidUUIDPaths,
                cronJobs: cronJobs,
                rowsAtSamePath: group
            )
        }

        findings += duplicateFindings(rows: rows)
        findings += orphanFindings(rows: rows, cronJobs: cronJobs)
        findings += salvagedFieldFindings(loaded: loaded, alreadyReported: findings)
        findings += historyFindings(loaded: loaded)

        // One definition of lossy, asked once: `RegistryLoss` decides, the
        // block is its presentation. The doctor no longer re-derives the
        // rule, so it can't drift from the one `saveRegistry` enforces.
        let block = ProjectDoctorRepairBlock(loaded.loss)

        // Finding ids key on the SUBJECT (a path, a name), and two registry
        // rows can share a subject — duplicate rows at one path each produce
        // their own "no uuid" finding with the same id. Collapse them: the
        // duplicate itself is already its own finding, and a `List` handed
        // two rows with one id misrenders.
        var seenIDs: Set<String> = []
        findings = findings.filter { seenIDs.insert($0.id).inserted }

        findings.sort {
            $0.severity == $1.severity ? $0.id < $1.id : $0.severity > $1.severity
        }
        return ProjectDoctorReport(
            findings: findings,
            repairBlock: block,
            projectCount: rows.count
        )
    }

    // MARK: - Per-row checks

    private nonisolated func diagnoseRow(
        _ row: ProjectEntry,
        store: ProjectStore,
        rawInvalidUUIDPaths: Set<String>,
        cronJobs: [HermesCronJob],
        rowsAtSamePath: [ProjectEntry]
    ) -> [ProjectDoctorFinding] {
        var out: [ProjectDoctorFinding] = []
        let pathIsDuplicated = rowsAtSamePath.count > 1

        // Dead vs unreachable, told apart exactly the way `ProjectStore.save`
        // tells them apart: `fileExists` is false both for "gone" and for
        // "transport down", so a reachable PARENT is what makes "gone" a
        // fact rather than a guess. Getting this wrong would offer to delete
        // every project row the moment an SSH host went offline.
        if !transport.fileExists(row.path) {
            if transport.fileExists(parentPath(row.path)) {
                // One finding per FOLDER, not per row. The removal matches
                // rows by normalized path, so `/a/b` and `/a/b/` are one
                // dead folder claimed twice — two findings would mean a
                // second button that can only ever throw `rowVanished`
                // after the first one removed both. Keyed on the normalized
                // path so the two spellings collapse here, and carrying the
                // row count so the confirm copy says what will happen.
                let normalized = ProjectIdentity.normalizedPath(row.path)
                let group = rowsAtSamePath
                let names = group.map { "“\($0.name)”" }.joined(separator: ", ")
                out.append(ProjectDoctorFinding(
                    id: "deadRootPath:\(normalized)",
                    kind: .deadRootPath,
                    severity: .high,
                    title: group.count == 1
                        ? "“\(row.name)” no longer exists on disk"
                        : "\(group.count) entries point at a folder that no longer exists",
                    detail: group.count == 1
                        ? "The folder at \(row.path) is gone, but the project is still listed. Removing the row won't delete anything else."
                        : "The folder at \(normalized) is gone, but \(names) are all still listed. Removing them takes out all \(group.count) entries and deletes nothing else.",
                    projectName: group.count == 1 ? row.name : nil,
                    path: row.path,
                    repair: .removeRegistryRow(path: row.path),
                    affectedRowCount: group.count
                ))
            } else {
                out.append(ProjectDoctorFinding(
                    id: "unreachableRoot:\(row.path)",
                    kind: .unreachableRoot,
                    severity: .medium,
                    title: "Can't reach “\(row.name)”",
                    detail: "Neither \(row.path) nor the folder containing it could be read. That usually means this server is offline rather than that the project is gone, so nothing is offered to remove.",
                    projectName: row.name,
                    path: row.path
                ))
            }
            // Everything below reads inside the root; there is nothing to read.
            return out
        }

        // Canonical record. Distinguish "absent" (a migration that never ran
        // — repairable) from "present but unreadable" (agent-owned damage —
        // report only). The old `derive()` path could not tell them apart and
        // would happily overwrite the second.
        let recordPath = ProjectStore.recordPath(forProjectPath: row.path)
        let record = store.load(projectPath: row.path)
        // Only ask whether the file is there when we failed to read it — on a
        // remote context every `fileExists` is its own round-trip, and a
        // successful load already answered the question.
        let recordExists = record != nil || transport.fileExists(recordPath)

        if record == nil && recordExists {
            out.append(malformedSidecarFinding(path: recordPath, projectName: row.name, label: "project record"))
        } else if record == nil && !pathIsDuplicated {
            out.append(ProjectDoctorFinding(
                id: "missingRecord:\(row.path)",
                kind: .missingRecord,
                severity: .medium,
                title: "“\(row.name)” has no project record",
                detail: "This project predates Scarf's project file, or it was removed. Creating it restores the project's identity, board and template links.",
                projectName: row.name,
                path: row.path,
                repair: .writeMissingRecord(path: row.path)
            ))
        }

        // Identity. An invalid raw uuid and a missing one decode identically,
        // so the raw set decides which of the two is reported — never both.
        if let record, !pathIsDuplicated {
            if rawInvalidUUIDPaths.contains(row.path) {
                out.append(ProjectDoctorFinding(
                    id: "invalidRegistryUUID:\(row.path)",
                    kind: .invalidRegistryUUID,
                    severity: .high,
                    title: "“\(row.name)” has an invalid ID in the projects list",
                    detail: "Its entry carries something that isn't an ID, so Scarf ignores it. The project's own record still knows the right one, and repairing copies it back.",
                    projectName: row.name,
                    path: row.path,
                    repair: .reindexRegistryFromRecord(path: row.path)
                ))
            } else if row.uuid == nil {
                out.append(ProjectDoctorFinding(
                    id: "missingRegistryUUID:\(row.path)",
                    kind: .missingRegistryUUID,
                    severity: .medium,
                    title: "“\(row.name)” isn't linked to its project record",
                    detail: "The projects list has no ID for it, so scheduled jobs and fleet links can't find it. Repairing copies the ID from the project's own record.",
                    projectName: row.name,
                    path: row.path,
                    repair: .reindexRegistryFromRecord(path: row.path)
                ))
            } else if row.uuid != record.id {
                // "The record wins" holds only while the record's id is an
                // asserted one. When the record carries the PATH-DERIVED id
                // and the row carries something else, the row's is the minted
                // one, and copying the record over it would demote an
                // asserted identity to a derived one — the opposite of the
                // rule identity derivation is built on. Report, don't repair.
                let derived = ProjectIdentity.deterministicID(
                    forProjectPath: row.path,
                    hostKey: ProjectIdentity.hostKey(for: context)
                )
                let recordIDIsDerived = record.id == derived
                out.append(ProjectDoctorFinding(
                    id: "recordIdMismatch:\(row.path)",
                    kind: .recordIdMismatch,
                    severity: .high,
                    title: "“\(row.name)” has two different IDs",
                    detail: recordIDIsDerived
                        ? "The projects list and the project's own record disagree, and the list's ID looks like the deliberate one. Scarf won't choose for you here — picking wrong detaches the project from its scheduled jobs and fleet links."
                        : "The projects list and the project's own record disagree. The record is the one that travels with the project, so repairing makes the list match it.",
                    projectName: row.name,
                    path: row.path,
                    repair: recordIDIsDerived ? nil : .reindexRegistryFromRecord(path: row.path)
                ))
            }
        } else if let record, pathIsDuplicated, row.uuid != record.id {
            // Same disagreement, but two rows claim this path: see above.
            out.append(ProjectDoctorFinding(
                id: "recordIdMismatch:\(row.path)",
                kind: .recordIdMismatch,
                severity: .high,
                title: "“\(row.name)” has two different IDs",
                detail: "The projects list and the project's own record disagree, and more than one entry points at this folder. Resolve the duplicate entries first.",
                projectName: row.name,
                path: row.path
            ))
        } else if record == nil, !pathIsDuplicated, rawInvalidUUIDPaths.contains(row.path) {
            // No readable record to copy an id from; creating the record
            // (deterministic id from host+path) settles both at once.
            out.append(ProjectDoctorFinding(
                id: "invalidRegistryUUID:\(row.path)",
                kind: .invalidRegistryUUID,
                severity: .high,
                title: "“\(row.name)” has an invalid ID in the projects list",
                detail: "Its entry carries something that isn't an ID. Creating the project's record gives it a stable one and links the entry to it.",
                projectName: row.name,
                path: row.path,
                repair: recordExists ? nil : .writeMissingRecord(path: row.path)
            ))
        }

        // Divergence between the two stores of one truth. The doctor
        // reconciles ids and existence; it was blind to the two fields a
        // user actually READS — the name and the path. Both divergences are
        // silent by construction: nothing in the app ever showed the record's
        // name (it renders into AGENTS.md, which the agent reads and the user
        // doesn't), and nothing ever compared the record's declared rootPath
        // to where the record was found.
        if let record {
            if record.name != row.name {
                out.append(ProjectDoctorFinding(
                    id: "recordNameMismatch:\(row.path)",
                    kind: .recordNameMismatch,
                    severity: .medium,
                    title: "“\(row.name)” is called something else in its own file",
                    detail: "Your projects list calls it “\(row.name)”, but the project's own file still says “\(record.name)” — the name Scarf tells the agent at the start of every chat in this project. Repairing copies the list's name into the file.",
                    projectName: row.name,
                    path: row.path,
                    repair: pathIsDuplicated ? nil : .renameRecordFromRegistry(path: row.path)
                ))
            }
            // A record found at X that says it belongs to Y. The overwhelming
            // cause is a folder moved or copied by hand: the record travels
            // with the files and keeps naming the old location, which bricks
            // Upgrade (it addresses the project by `record.rootPath`) and
            // silently mis-targets any writer that trusts the record. There
            // is no safe automatic repair — rewriting `rootPath` when the
            // move was actually a COPY detaches the original, and rewriting
            // the registry row when the declared path still exists points two
            // rows at one folder. So: say it, precisely, and let the user
            // decide.
            let declared = ProjectIdentity.normalizedPath(record.rootPath)
            let actual = ProjectIdentity.normalizedPath(row.path)
            if declared != actual {
                let originalStillThere = transport.fileExists(record.rootPath)
                out.append(ProjectDoctorFinding(
                    id: "recordPathDivergence:\(row.path)",
                    kind: .recordPathDivergence,
                    severity: .high,
                    title: "“\(row.name)” looks like it was moved",
                    detail: originalStillThere
                        ? "The project file in \(row.path) says the project lives at \(record.rootPath), and that folder still exists. This is what copying a project folder looks like. Scarf won't guess which one is real — until it's resolved, updates and template actions will act on \(record.rootPath), not on \(row.path)."
                        : "The project file in \(row.path) says the project lives at \(record.rootPath), which no longer exists — this folder was most likely moved. Scarf's updates and template actions still target the old path, so they'll fail or do nothing. Fix the “rootPath” in \(row.path)/.scarf/project.json, then re-run this check.",
                    projectName: row.name,
                    path: row.path
                ))
            }
        }

        // Agent-owned sidecars. Report-only, forever.
        for (file, label) in [
            ("dashboard.json", "dashboard"),
            ("manifest.json", "manifest"),
            ("config.json", "configuration")
        ] {
            let path = row.path + "/.scarf/" + file
            if case .malformed = sidecarState(path) {
                out.append(malformedSidecarFinding(path: path, projectName: row.name, label: label))
            }
        }

        // Path-reuse suspicion (best effort, LOW). Ids key on the path, so a
        // recycled path inherits the previous project's `[proj:<id>]` cron
        // jobs. A job attributed to this project that RUNS somewhere else is
        // the cheap, concrete symptom of exactly that.
        let effectiveID = record?.id ?? row.uuid ?? ProjectIdentity.deterministicID(
            forProjectPath: row.path,
            hostKey: ProjectIdentity.hostKey(for: context)
        )
        let prefix = "[proj:\(effectiveID.uuidString)]"
        let normalizedRoot = ProjectIdentity.normalizedPath(row.path)
        let strays = cronJobs.filter { job in
            guard job.name.hasPrefix(prefix), let workdir = job.workdir, !workdir.isEmpty else { return false }
            return ProjectIdentity.normalizedPath(workdir) != normalizedRoot
        }
        if !strays.isEmpty {
            out.append(ProjectDoctorFinding(
                id: "pathReuseSuspicion:\(row.path)",
                kind: .pathReuseSuspicion,
                severity: .low,
                title: "“\(row.name)” has scheduled jobs that run elsewhere",
                detail: "\(strays.count) scheduled \(strays.count == 1 ? "job is" : "jobs are") tagged for this project but set to run in a different folder. That can happen when a folder is reused for a new project and the old project's jobs stay behind. Worth a look; nothing is changed automatically.",
                projectName: row.name,
                path: row.path
            ))
        }

        return out
    }

    private nonisolated func malformedSidecarFinding(
        path: String,
        projectName: String,
        label: String
    ) -> ProjectDoctorFinding {
        ProjectDoctorFinding(
            id: "malformedSidecar:\(path)",
            kind: .malformedSidecar,
            severity: .medium,
            title: "“\(projectName)” has an unreadable \(label) file",
            detail: "\(path) isn't valid JSON (or is far too large), so Scarf skips it. Scarf won't rewrite it — the file belongs to whatever wrote it, and replacing it would throw away the only copy.",
            projectName: projectName,
            path: path
        )
    }

    // MARK: - Cross-row checks

    private nonisolated func duplicateFindings(rows: [ProjectEntry]) -> [ProjectDoctorFinding] {
        var out: [ProjectDoctorFinding] = []

        var byPath: [String: [ProjectEntry]] = [:]
        for row in rows { byPath[ProjectIdentity.normalizedPath(row.path), default: []].append(row) }
        for (path, group) in byPath where group.count > 1 {
            out.append(ProjectDoctorFinding(
                id: "duplicatePath:\(path)",
                kind: .duplicatePath,
                severity: .high,
                title: "\(group.count) entries point at the same folder",
                detail: "\(group.map { "“\($0.name)”" }.joined(separator: ", ")) all point at \(path). They share one project record, so edits to one appear under the others. Scarf won't guess which to remove — delete the extras from the sidebar.",
                path: path
            ))
        }

        var byName: [String: [ProjectEntry]] = [:]
        for row in rows { byName[row.name, default: []].append(row) }
        for (name, group) in byName where group.count > 1 {
            out.append(ProjectDoctorFinding(
                id: "duplicateName:\(name)",
                kind: .duplicateName,
                severity: .medium,
                title: "\(group.count) projects are called “\(name)”",
                detail: "Scarf still identifies projects by name in the sidebar, so selecting, renaming or removing one of these can act on the other. Rename one of them.",
                projectName: name
            ))
        }

        return out
    }

    /// Directories that look like projects but aren't listed.
    ///
    /// Sources, deliberately the cheap half of the enumeration design: the
    /// parents of the paths already in the registry (a project's siblings are
    /// where a dropped row's folder actually is), the context's default
    /// projects root, and cron `workdir`s (already read for the row checks).
    /// `state.db` / checkpoints / kanban are NOT consulted — they'd add a
    /// SQL surface and two more file formats for a small recall gain.
    private nonisolated func orphanFindings(
        rows: [ProjectEntry],
        cronJobs: [HermesCronJob]
    ) -> [ProjectDoctorFinding] {
        let known = Set(rows.map { ProjectIdentity.normalizedPath($0.path) })
        let home = ProjectIdentity.normalizedPath(context.paths.home)

        func isExcluded(_ normalized: String) -> Bool {
            Self.isExcludedFromScan(normalized, home: home)
        }
        func isComparable(_ normalized: String) -> Bool { normalized.hasPrefix("/") }

        let scanRoots = Self.scanRoots(
            rowPaths: rows.map(\.path),
            home: home,
            defaultProjectsRoot: context.defaultProjectsRoot
        )

        var candidates: [String] = []
        var seenCandidates: Set<String> = []
        func addCandidate(_ path: String) {
            guard candidates.count < Self.maxScanCandidates else { return }
            let normalized = ProjectIdentity.normalizedPath(path)
            guard isComparable(normalized),
                  !isExcluded(normalized),
                  !known.contains(normalized),
                  seenCandidates.insert(normalized).inserted
            else { return }
            candidates.append(normalized)
        }

        for root in scanRoots {
            guard let names = try? transport.listDirectory(root) else { continue }
            for name in names.prefix(Self.maxScanEntriesPerRoot) where !name.hasPrefix(".") {
                addCandidate(root + "/" + name)
            }
        }
        // Cron workdirs are a first-class signal in a fresh home, where the
        // checkpoint ledger and `sessions.cwd` are both still empty.
        for job in cronJobs {
            if let workdir = job.workdir, !workdir.isEmpty { addCandidate(workdir) }
        }

        let takenNames = Set(rows.map(\.name))
        let store = ProjectStore(context: context)
        return candidates.compactMap { path in
            let recordPath = path + "/.scarf/project.json"
            // Decodability, not JSON-validity: adoption may DERIVE a record
            // and write it here, and `{"note": "wip"}` is valid JSON that
            // would be silently replaced. See `recordState`.
            let state = recordState(recordPath)
            let name = (path as NSString).lastPathComponent

            // An unreadable record makes this a project we must NOT adopt:
            // adoption derives a record and writes it, which would overwrite
            // the only copy of whatever is in there. Report the damage
            // instead — the same rule that governs a LISTED project's record.
            if case .malformed = state {
                return malformedSidecarFinding(path: recordPath, projectName: name, label: "project record")
            }
            let looksLikeProject = state == .ok
                || transport.fileExists(path + "/.scarf/manifest.json")
            guard looksLikeProject else { return nil }

            // Adopting under a name another row already uses would make the
            // sidebar's name-keyed delete remove BOTH rows. Report it, and
            // let the user rename first.
            //
            // The name that will actually LAND is the guarded one: adoption
            // saves the on-disk record when there is one, and
            // `indexInRegistry` writes `record.name` — which an agent-written
            // record can set to anything, including another project's name.
            // Guarding the folder basename while writing `record.name` was
            // a check of a string the write never uses.
            // Only worth a read when there IS a decodable record — `.absent`
            // already told us the read would miss, and this runs once per
            // orphan candidate (up to 400) with an SSH round-trip each.
            let adoptedName = state == .ok
                ? adoptionName(path: path, store: store, fallback: name)
                : name
            let nameTaken = takenNames.contains(adoptedName)
            return ProjectDoctorFinding(
                id: "orphanProjectDir:\(path)",
                kind: .orphanProjectDir,
                severity: .medium,
                title: "“\(name)” looks like a project but isn't listed",
                detail: nameTaken
                    ? "\(path) has Scarf project files but no entry in your projects list, and adding it would list it as “\(adoptedName)” — a name another project already uses. Rename that one first — two projects sharing a name can't be told apart when removing one."
                    : "\(path) has Scarf project files but no entry in your projects list — usually a project whose entry was lost, or one created outside Scarf. Adding it keeps its existing ID and settings.",
                projectName: name,
                path: path,
                repair: nameTaken ? nil : .adoptOrphan(path: path, name: name)
            )
        }
    }

    /// `~/.hermes` is not a project, and every `~/.hermes/profiles/<name>`
    /// is a whole separate Hermes home rather than a working directory.
    /// Deliberately NOT the whole `~/.hermes` subtree: a Hermes home can
    /// legitimately sit above a projects directory (every test home does),
    /// and blanket-excluding it would blind the scan there.
    static func isExcludedFromScan(_ normalized: String, home: String) -> Bool {
        let profiles = home + "/profiles"
        return normalized == home
            || normalized == profiles
            || normalized.hasPrefix(profiles + "/")
    }

    /// The directories the orphan scan will list, in order.
    ///
    /// Pulled out of `orphanFindings` as a pure function because the one
    /// rule that matters most here — never scan a user's home directory —
    /// cannot be exercised through a local `ServerContext`, and it was
    /// broken for years precisely in the case a local test can't reach.
    ///
    /// **The `~`-home hole.** The scan compares paths TEXTUALLY against the
    /// registry, and `ProjectIdentity` deliberately never expands `~` (it
    /// must answer identically for a remote path it cannot stat). On an SSH
    /// context `paths.home` is the UNEXPANDED `~/.hermes`, which makes the
    /// home exclusion and the `userHome` guard below comparisons against a
    /// string no absolute path can ever equal — inert exactly where they
    /// mattered. A row at `/home/alan/proj` then turned `/home/alan` into a
    /// scan root: up to 300 entries listed with two `fileExists` each, over
    /// SSH, for one health check, reporting the user's whole home as
    /// candidate projects.
    ///
    /// With no expandable home we cannot NAME the home directory, but we can
    /// decline to scan anything shallow enough to BE one: a user home is two
    /// absolute segments on every platform Hermes runs on (`/home/alan`,
    /// `/Users/alan`, `/var/root`), so a scan root needs three.
    /// `/home/alan/projects` still scans; `/home/alan` never does. Applied
    /// ONLY when the home is non-comparable — a local context keeps its
    /// exact `userHome` guard and its existing behaviour.
    static func scanRoots(
        rowPaths: [String],
        home: String,
        defaultProjectsRoot: String
    ) -> [String] {
        let homeIsComparable = home.hasPrefix("/")
        func parent(_ path: String) -> String {
            (ProjectIdentity.normalizedPath(path) as NSString).deletingLastPathComponent
        }

        var roots: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            let normalized = ProjectIdentity.normalizedPath(path)
            guard normalized.hasPrefix("/"),
                  !isExcludedFromScan(normalized, home: home),
                  homeIsComparable
                    || normalized.split(separator: "/", omittingEmptySubsequences: true).count >= 3,
                  seen.insert(normalized).inserted,
                  roots.count < maxScanRoots
            else { return }
            roots.append(normalized)
        }

        // The user's home itself is never a scan root: a single project kept
        // directly under `~` would otherwise make the doctor list the whole
        // home directory, one `fileExists` pair per entry. `~/.hermes`'s
        // parent is the closest thing to `$HOME` available on both transports
        // without expanding anything.
        let userHome = (home as NSString).deletingLastPathComponent
        for path in rowPaths where parent(path) != userHome {
            add(parent(path))
        }
        add(defaultProjectsRoot)
        return roots
    }

    /// Fields the salvaging decode had to drop from rows that survived.
    ///
    /// The counterpart to the rule that field salvage does not BLOCK: it
    /// doesn't block, so it has to be visible, or a project quietly loses
    /// its folder / archived flag on the next save with nobody ever told.
    /// One finding per row (fields listed together) — a row with three bad
    /// fields is one problem with one fix, not three rows in a list.
    ///
    /// A dropped `uuid` is excluded only when `invalidRegistryUUID` was
    /// ACTUALLY raised for that row — it carries the repair that fixes it,
    /// and reporting the same damage twice buries the actionable row under
    /// an un-actionable one. Conditional rather than blanket, because that
    /// finding is withheld for a duplicated path: skipping the field
    /// unconditionally left a garbage uuid reported NOWHERE, on its way to
    /// being dropped for good by the next save.
    private nonisolated func salvagedFieldFindings(
        loaded: ProjectDashboardService.RegistryLoadResult,
        alreadyReported: [ProjectDoctorFinding]
    ) -> [ProjectDoctorFinding] {
        let uuidCovered = Set(
            alreadyReported
                .filter { $0.kind == .invalidRegistryUUID }
                .compactMap(\.projectName)
        )
        let dropped = loaded.salvage.salvaged.filter {
            $0.field != "uuid" || !uuidCovered.contains($0.row)
        }
        guard !dropped.isEmpty else { return [] }

        var fieldsByRow: [String: [String]] = [:]
        for entry in dropped where !(fieldsByRow[entry.row]?.contains(entry.field) ?? false) {
            fieldsByRow[entry.row, default: []].append(entry.field)
        }

        return fieldsByRow.keys.sorted().map { row in
            let fields = fieldsByRow[row] ?? []
            let list = fields.map { "“\($0)”" }.joined(separator: " and ")
            // The row's own path, when exactly one row answers to the name
            // — the report is filtered by path in the cockpit, and pointing
            // at the wrong project is worse than pointing at none.
            let matches = loaded.registry.projects.filter { $0.name == row }
            let path = matches.count == 1 ? matches[0].path : nil
            return ProjectDoctorFinding(
                id: "registryFieldSalvaged:\(row):\(fields.joined(separator: ","))",
                kind: .registryFieldSalvaged,
                severity: .medium,
                title: fields.count == 1
                    ? "One detail of “\(row)” couldn't be read"
                    : "\(fields.count) details of “\(row)” couldn't be read",
                detail: "The \(list) \(fields.count == 1 ? "value" : "values") in your projects file "
                    + "\(fields.count == 1 ? "wasn't" : "weren't") readable, so the project is listed "
                    + "without \(fields.count == 1 ? "it" : "them"). "
                    + "Set \(fields.count == 1 ? "it" : "them") again in Scarf, or fix the file — "
                    + "the next change Scarf saves will write the row without \(fields.count == 1 ? "that value" : "those values").",
                projectName: row,
                path: path
            )
        }
    }

    private nonisolated func historyFindings(
        loaded: ProjectDashboardService.RegistryLoadResult
    ) -> [ProjectDoctorFinding] {
        var out: [ProjectDoctorFinding] = []
        let registryPath = context.paths.projectsRegistry

        if let quarantine = loaded.quarantinePath {
            out.append(ProjectDoctorFinding(
                id: "registryHistory:quarantine:\(quarantine)",
                kind: .registryHistory,
                severity: .info,
                title: "A copy of the unreadable projects file was kept",
                detail: "It's at \(quarantine). Nothing was thrown away.",
                path: quarantine
            ))
        } else {
            // Only enumerate the quarantine directory when we aren't already
            // holding a fresh quarantine path: this is one listDirectory —
            // an SSH round-trip — for a purely informational row.
            let dir = (registryPath as NSString).deletingLastPathComponent
            let prefix = (registryPath as NSString).lastPathComponent + ".corrupt-"
            let kept = ((try? transport.listDirectory(dir)) ?? [])
                .filter { $0.hasPrefix(prefix) }
                .sorted()
            if let latest = kept.last {
                out.append(ProjectDoctorFinding(
                    id: "registryHistory:quarantine:\(dir)/\(latest)",
                    kind: .registryHistory,
                    severity: .info,
                    title: kept.count == 1
                        ? "An earlier unreadable projects file was kept"
                        : "\(kept.count) earlier unreadable projects files were kept",
                    detail: "The most recent is at \(dir)/\(latest). These are copies Scarf set aside when it couldn't read the file; they're safe to delete once you're satisfied nothing is missing.",
                    path: dir + "/" + latest
                ))
            }
        }

        let backup = registryPath + ".bak"
        if transport.fileExists(backup) {
            out.append(ProjectDoctorFinding(
                id: "registryHistory:backup:\(backup)",
                kind: .registryHistory,
                severity: .info,
                title: "A backup of the previous projects list exists",
                detail: "\(backup) holds the contents from just before the most recent change.",
                path: backup
            ))
        }
        return out
    }

    // MARK: - Repair

    /// Apply one finding's repair. Idempotent: re-running a repair whose
    /// work is already done writes nothing (every writer underneath
    /// short-circuits on an unchanged value), so a repair racing the file
    /// watcher — or a user double-tapping the button — converges rather
    /// than compounding.
    ///
    /// Re-reads the registry itself rather than trusting the report: a
    /// report can be seconds old, and the file is agent-writable.
    ///
    /// **Not serialized against the rest of the app.** A repair and a
    /// concurrent `ProjectsViewModel` mutation each do their own
    /// read-modify-write of `projects.json`, so the later save wins and the
    /// earlier change is lost — the same exposure every registry writer here
    /// has always had, not one this adds. The doctor narrows its own window
    /// by reading immediately before writing and by touching one field; a
    /// real fix is a registry-wide write lock, which belongs with the
    /// structured agent write path rather than here.
    public nonisolated func repair(_ finding: ProjectDoctorFinding) throws {
        guard let repair = finding.repair else {
            throw ProjectDoctorError.notRepairable(finding.title)
        }
        let store = ProjectStore(context: context)
        let dashboardService = ProjectDashboardService(context: context)

        // ONE authoritative read for both the block check and the mutation.
        // Reading twice left a window in which the file could go lossy
        // between "repairs are allowed" and "here is what I'm writing back".
        let loaded = dashboardService.loadRegistryDetailed()
        // UX, not enforcement: `saveRegistry` refuses a lossy write on its
        // own now, and would do so from underneath every branch below. This
        // says it in the doctor's own words, before a repair does half its
        // work (writing a record) and fails on the registry half.
        if let block = ProjectDoctorRepairBlock(loaded.loss) {
            throw ProjectDoctorError.repairsBlocked(block)
        }
        var registry = loaded.registry

        /// A record that exists but doesn't decode as a `ScarfProject` must
        /// never be written over — the same rule `diagnose` applies,
        /// re-checked here because the file can change between the report
        /// and the button. Decodability rather than JSON-validity: a
        /// `{"note": "wip"}` that parses as JSON is still not a record, and
        /// the write that follows this check replaces it wholesale.
        func refuseIfRecordIsUnreadable(_ path: String) throws {
            if case .malformed = recordState(ProjectStore.recordPath(forProjectPath: path)) {
                throw ProjectDoctorError.recordUnavailable(ProjectStore.recordPath(forProjectPath: path))
            }
        }

        /// The record at `path`, but only when it actually describes THIS
        /// project.
        ///
        /// `project.json` is agent-writable, and every writer underneath
        /// addresses a project by `record.rootPath`: `ProjectStore.save`
        /// writes `<record.rootPath>/.scarf/project.json` and
        /// `indexInRegistry` matches (or appends) the row for
        /// `record.rootPath`. So a record found at `/a/foo` that declares
        /// `rootPath: /a/bar` makes a repair of `/a/foo` silently rewrite
        /// `/a/bar`'s record and re-point `/a/bar`'s registry row — one
        /// hand-edited field, and the doctor damages a project the user
        /// never touched. There is no safe reconciliation to guess at
        /// (which of the two is wrong?), so it is refused and reported.
        func recordDescribingThisPath(_ path: String) throws -> ScarfProject? {
            guard let record = store.load(projectPath: path) else { return nil }
            guard ProjectIdentity.normalizedPath(record.rootPath)
                    == ProjectIdentity.normalizedPath(path)
            else {
                throw ProjectDoctorError.recordPathMismatch(
                    path: path, declared: record.rootPath
                )
            }
            return record
        }

        switch repair {
        case .reindexRegistryFromRecord(let path):
            guard let record = try recordDescribingThisPath(path) else {
                throw ProjectDoctorError.recordUnavailable(ProjectStore.recordPath(forProjectPath: path))
            }
            try store.indexInRegistry(record)

        case .writeMissingRecord(let path):
            guard let row = registry.projects.first(where: {
                ProjectIdentity.normalizedPath($0.path) == ProjectIdentity.normalizedPath(path)
            }) else {
                throw ProjectDoctorError.rowVanished(path)
            }
            // A record that appeared since the report is canonical — index it
            // instead of deriving a second answer over the top of it.
            if let existing = try recordDescribingThisPath(path) {
                try store.indexInRegistry(existing)
            } else {
                try refuseIfRecordIsUnreadable(path)
                try store.save(store.derive(from: row))
            }

        case .adoptOrphan(let path, let name):
            if let row = registry.projects.first(where: {
                ProjectIdentity.normalizedPath($0.path) == ProjectIdentity.normalizedPath(path)
            }) {
                // Someone added it between diagnose and repair. Finish the
                // job rather than duplicating the row.
                if let existing = try recordDescribingThisPath(row.path) {
                    try store.indexInRegistry(existing)
                } else {
                    try refuseIfRecordIsUnreadable(row.path)
                    try store.save(store.derive(from: row))
                }
                return
            }
            try refuseIfRecordIsUnreadable(path)
            let existing = try recordDescribingThisPath(path)
            // The record on disk, when there is one, keeps its own id and
            // settings — deriving only fills in what isn't there.
            let toSave = existing ?? store.derive(from: ProjectEntry(name: name, path: path))
            // Two rows sharing a name make the sidebar's name-keyed delete
            // remove both, so a collision that appeared since the report is
            // refused rather than created. Guarded on `toSave.name` — the
            // string `indexInRegistry` will actually write — and not on the
            // folder basename, which is only what we'd have called it if
            // there had been no record.
            guard !registry.projects.contains(where: { $0.name == toSave.name }) else {
                throw ProjectDoctorError.nameTaken(toSave.name)
            }
            try store.save(toSave)

        case .renameRecordFromRegistry(let path):
            guard let row = registry.projects.first(where: {
                ProjectIdentity.normalizedPath($0.path) == ProjectIdentity.normalizedPath(path)
            }) else {
                throw ProjectDoctorError.rowVanished(path)
            }
            // `recordDescribingThisPath` matters more here than anywhere:
            // this repair writes a NAME, and `indexInRegistry` matches the
            // row for `record.rootPath` — a record declaring someone else's
            // path would rename the wrong project.
            guard var record = try recordDescribingThisPath(path) else {
                throw ProjectDoctorError.recordUnavailable(ProjectStore.recordPath(forProjectPath: path))
            }
            // Re-checked against a fresh read: the divergence may have been
            // resolved (by a rename that now propagates) since the report.
            guard record.name != row.name else { return }
            record.name = row.name
            try store.save(record)

        case .removeRegistryRow(let path):
            // Normalized match, converging with `ProjectStore.indexInRegistry`:
            // a row spelled `/a/b/` is the row for `/a/b`, and a raw `==`
            // here would leave the trailing-slash twin behind claiming a
            // folder we just proved is gone.
            let target = ProjectIdentity.normalizedPath(path)
            let before = registry.projects.count
            registry.projects.removeAll {
                ProjectIdentity.normalizedPath($0.path) == target
            }
            let removed = before - registry.projects.count
            guard removed > 0 else {
                throw ProjectDoctorError.rowVanished(path)
            }
            // `allowEmpty` states the condition under which emptying is the
            // point: every row we loaded was a row at this dead path.
            //
            // Honest note, because the alternative is a comment that flatters
            // the code: `saveRegistry` consults `allowEmpty` only when the
            // list being written is empty, and `removed == before` is true in
            // exactly that case — so this is behaviourally identical to the
            // `true` it replaces. It is written as the condition anyway
            // because the condition is what we can actually justify, and
            // because a future `saveRegistry` that widens what the flag
            // permits would then not silently inherit a blanket exemption
            // here. The protection against blanking a list we misread is
            // upstream and real: the lossy-load refusal in `saveRegistry` and
            // in `repair`'s own block check.
            try dashboardService.saveRegistry(registry, allowEmpty: removed == before)
        }
    }

    /// Run every safe repair in `report`, in order, and return the failures
    /// keyed by finding id. Deliberately does not stop at the first failure:
    /// the repairs are independent, and a project whose disk went away
    /// shouldn't block the four rows that are fine.
    ///
    /// The caller re-runs `diagnose()` afterwards — repairs change what the
    /// next pass sees (creating a record settles the identity finding too),
    /// so the report in hand is stale the moment this returns.
    @discardableResult
    public nonisolated func repairAllSafe(_ report: ProjectDoctorReport) -> [String: String] {
        var failures: [String: String] = [:]
        for finding in report.safelyRepairable {
            do {
                try repair(finding)
            } catch {
                failures[finding.id] = error.localizedDescription
                #if canImport(os)
                Self.logger.error(
                    "repair \(finding.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                #endif
            }
        }
        return failures
    }

    // (`repairBlockReason()` used to live here, documented as the guard
    // `repair(_:)` relied on. It was never called — `repair(_:)` derives the
    // block from its own single authoritative read, precisely so the check
    // and the write see one file. Deleted rather than wired up: a
    // second read would reintroduce the window it was written to close.)

    // MARK: - Helpers

    /// The name adopting `path` would actually list it under: the on-disk
    /// record's `name` when there is a record that describes this very
    /// folder, otherwise the folder's own basename.
    ///
    /// A record whose `rootPath` points somewhere else is not this project's
    /// record — `repair` refuses to adopt from it — so it must not lend its
    /// name to the collision check either, or a mismatched record would make
    /// the doctor report a name collision that the refusal makes moot.
    private nonisolated func adoptionName(
        path: String, store: ProjectStore, fallback: String
    ) -> String {
        guard let record = store.load(projectPath: path),
              ProjectIdentity.normalizedPath(record.rootPath)
                == ProjectIdentity.normalizedPath(path)
        else { return fallback }
        return record.name
    }

    private nonisolated func parentPath(_ path: String) -> String {
        (ProjectIdentity.normalizedPath(path) as NSString).deletingLastPathComponent
    }

    /// Registry rows whose raw `uuid` is present but isn't a UUID. Empty
    /// when the file is missing, oversize or isn't an object — those are
    /// other findings' business.
    private nonisolated func rawInvalidUUIDPaths() -> Set<String> {
        guard let data = try? transport.readFile(context.paths.projectsRegistry),
              data.count <= ProjectDashboardService.maxJSONBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["projects"] as? [[String: Any]]
        else { return [] }
        var out: Set<String> = []
        for row in rows {
            guard let path = row["path"] as? String, let raw = row["uuid"] else { continue }
            if raw is NSNull { continue }
            if let string = raw as? String, UUID(uuidString: string) != nil { continue }
            out.insert(path)
        }
        return out
    }

    private enum SidecarState: Equatable { case absent, ok, malformed }

    /// Classify a sidecar from ONE read rather than a `fileExists` + a
    /// `readFile` (two round-trips on a remote context, per file, per
    /// project). A read that fails counts as absent: over SSH a missing file
    /// and an unreadable one fail identically, and reporting "malformed" for
    /// a file that isn't there would be worse than missing the rare
    /// permission-denied case.
    private nonisolated func sidecarState(_ path: String) -> SidecarState {
        guard let data = try? transport.readFile(path) else { return .absent }
        guard data.count <= ProjectDashboardService.maxJSONBytes else { return .malformed }
        return (try? JSONSerialization.jsonObject(with: data)) != nil ? .ok : .malformed
    }

    /// `sidecarState` for the one sidecar that is not merely READ but
    /// potentially DERIVED AND OVERWRITTEN: `<root>/.scarf/project.json`.
    ///
    /// Valid JSON is not the bar here. `{"note": "wip"}` parses, so the
    /// generic classifier calls it `.ok` — and every path that trusts `.ok`
    /// then goes on to `derive()` a fresh record and write it straight over
    /// the note. What makes a record safe to replace-if-missing is that it
    /// decodes as a `ScarfProject`; anything else in that filename is
    /// somebody's file, and the doctor's standing rule is that an
    /// agent-owned file it cannot read is reported, never rewritten.
    ///
    /// Same single read as `sidecarState` — the decode is free.
    private nonisolated func recordState(_ path: String) -> SidecarState {
        guard let data = try? transport.readFile(path) else { return .absent }
        guard data.count <= ProjectDashboardService.maxJSONBytes else { return .malformed }
        return (try? JSONDecoder().decode(ScarfProject.self, from: data)) != nil ? .ok : .malformed
    }

    private nonisolated func loadCronJobs() -> [HermesCronJob] {
        guard let data = try? transport.readFile(context.paths.cronJobsJSON),
              data.count <= ProjectDashboardService.maxJSONBytes
        else { return [] }
        return (try? JSONDecoder().decode(CronJobsFile.self, from: data))?.jobs ?? []
    }
}
