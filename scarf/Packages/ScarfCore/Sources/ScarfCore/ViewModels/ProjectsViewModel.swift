import Foundation
import Observation
import os

/// A user-initiated project mutation that did not happen.
///
/// Split into title + message because that is exactly the shape an
/// alert wants, and because the title alone ("Couldn't rename
/// “site”") is the part worth reading — the message carries the
/// underlying reason, which is often a filesystem error string.
public struct ProjectMutationFailure: Equatable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// Damage the last registry load had to work around, in the form a
/// banner can render.
///
/// `~/.hermes/scarf/projects.json` is agent-writable forever, so this
/// is a routine event rather than an exceptional one. Phase 1 made the
/// reader survive it; this is the part that says so out loud.
public struct RegistryDamageNotice: Equatable, Sendable {
    /// Where the unreadable file was copied, when the file could not be
    /// parsed as a project list at all.
    public var quarantinePath: String?
    /// The rolling one-deep backup, when one exists on disk.
    public var backupPath: String?
    /// Rows that could not be decoded and were left out.
    public var droppedCount: Int
    /// `"<project>.<field>"` for each field dropped from a surviving row.
    public var salvagedFields: [String]
    /// The file is there but empty or unreadable. Nothing was dropped and
    /// nothing was quarantined, yet the list on screen is not the file's
    /// contents — without this the banner stayed silent while every
    /// registry write was being refused.
    public var unreadable: Bool

    public init(
        quarantinePath: String? = nil,
        backupPath: String? = nil,
        droppedCount: Int = 0,
        salvagedFields: [String] = [],
        unreadable: Bool = false
    ) {
        self.quarantinePath = quarantinePath
        self.backupPath = backupPath
        self.droppedCount = droppedCount
        self.salvagedFields = salvagedFields
        self.unreadable = unreadable
    }

    /// Identity of THIS damage, so a dismissal sticks across the many
    /// reloads a file watcher fires while the file stays broken — and
    /// so *new* damage still reopens the banner.
    ///
    /// Deliberately excludes `backupPath`: it describes what we can
    /// offer the user, not what went wrong. Including it meant any
    /// later save creating `projects.json.bak` flipped the signature
    /// and reopened a banner the user had already dismissed.
    public var signature: String {
        "\(quarantinePath ?? "-")|\(droppedCount)|\(salvagedFields.joined(separator: ","))|\(unreadable)"
    }

    /// The copy the user backed up to, if any — what "Show in Finder"
    /// should select. The quarantine copy wins: it is the file that
    /// holds the bytes we could not read.
    public var revealPath: String? { quarantinePath ?? backupPath }

    /// Banner headline. Only promises a backup when there actually is
    /// one to point at — in the salvaged-field case nothing was set
    /// aside, so claiming otherwise sends the user looking for a file
    /// that doesn't exist.
    public var headline: String {
        revealPath == nil
            ? "Part of your projects list couldn't be read"
            : "Projects list was damaged — a backup was saved"
    }

    /// One plain sentence describing what was lost. No jargon: the user
    /// did not write this file and should not have to know its shape.
    public var summary: String {
        if quarantinePath != nil {
            // NOT "and started a fresh list" any more: since the write
            // chokepoint refuses a lossy registry, nothing is written until
            // the file is fixed. Saying otherwise would tell the user their
            // projects had been replaced when in fact everything is paused.
            return "Scarf couldn't read your projects file, so it kept a copy of it aside. Changes are paused until the file is repaired or removed."
        }
        if unreadable {
            return "Your projects file is empty or couldn't be read, so this list may not be your real one. Changes are paused until it's restored or removed."
        }
        if droppedCount > 0, !salvagedFields.isEmpty {
            return "\(droppedCount) \(droppedCount == 1 ? "project" : "projects") couldn't be read and were left out, and some details on other projects were skipped."
        }
        if droppedCount > 0 {
            return "\(droppedCount) \(droppedCount == 1 ? "project" : "projects") couldn't be read and were left out of the list."
        }
        return "Some project details couldn't be read and were skipped."
    }
}

@Observable
@MainActor
public final class ProjectsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProjectsViewModel")
    public let context: ServerContext
    private let service: ProjectDashboardService

    public init(context: ServerContext = .local) {
        self.context = context
        self.service = ProjectDashboardService(context: context)
    }


    public var projects: [ProjectEntry] = []
    public var selectedProject: ProjectEntry?
    public var dashboard: ProjectDashboard?
    public var dashboardError: String?
    public var isLoading = false

    /// The last user-initiated mutation that did not happen, for the
    /// view to alert on. `nil` whenever the last one succeeded — every
    /// mutator clears it on entry, so a retry that works takes the
    /// alert down with it.
    public private(set) var mutationError: ProjectMutationFailure?

    /// Damage found in the registry the last time it was loaded, for
    /// the view's banner. `nil` when the file read cleanly, or when the
    /// user has dismissed this exact damage.
    public private(set) var registryDamage: RegistryDamageNotice?

    /// Signatures of the damage the user has dismissed. Kept so the
    /// banner stays down across the many reloads a watcher fires while
    /// the file remains broken, while NEW damage still reopens it.
    ///
    /// A SET rather than one slot: an agent that rewrites the registry
    /// between two bad shapes would otherwise defeat dismissal
    /// entirely, each shape clearing the other's dismissal and
    /// re-raising the banner on every tick. Emptied on a clean load.
    @ObservationIgnored private var dismissedDamageSignatures: Set<String> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0

    /// Synchronous registry load — used by tests and one-shot call sites that
    /// read `projects` immediately afterward. A synchronous load on a remote
    /// context does blocking scp/SSH, so do NOT call this from a repeated /
    /// hot path (e.g. the file-watcher `.onChange`) — use `reload()` there.
    public func load() {
        // A synchronous load is a fresh, authoritative read, so it
        // supersedes any reload still in flight: bump the generation
        // token or an older detached read — one a watcher tick started
        // before this call — can land afterwards and clobber both the
        // project list and the damage banner with staler data.
        reloadGeneration &+= 1
        let loaded = service.loadRegistryDetailed()
        apply(registry: loaded.registry)
        applyDamage(Self.damageNotice(for: loaded, service: service))
        if let selected = selectedProject { loadDashboard(for: selected) }
    }

    /// Off-main registry (+ selected dashboard) refresh for hot paths like the
    /// file-watcher `.onChange`. Reads through the transport on a detached
    /// task, then commits to observable state back on the main actor — so a
    /// watcher tick never blocks the UI thread on a remote context (gh#102).
    public func reload() async {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let ctx = context
        let task = Task { [weak self] in
            // Recency by generation token, not `isCancelled`: a newer reload
            // bumps `reloadGeneration`, so an older read — even one that
            // crosses the dashboard suspension below — drops its commit rather
            // than clobbering fresher data. (`isCancelled` alone can't order
            // the `dashboard` write, which sits behind a second await.) The
            // synchronous `load()` this replaced couldn't interleave at all.
            // The salvage seam runs off-main with the read it belongs
            // to: `damageNotice` may stat the `.bak` file, which is a
            // live SSH round-trip on a remote context and must never
            // happen on the main actor from a watcher tick.
            let loaded = await Task.detached { () -> (ProjectRegistry, RegistryDamageNotice?) in
                let svc = ProjectDashboardService(context: ctx)
                let result = svc.loadRegistryDetailed()
                return (result.registry, ProjectsViewModel.damageNotice(for: result, service: svc))
            }.value
            guard let self, generation == self.reloadGeneration else { return }
            self.apply(registry: loaded.0)
            self.applyDamage(loaded.1)
            if let selected = self.selectedProject {
                await self.reloadDashboard(for: selected, generation: generation)
            }
        }
        reloadTask = task
        await task.value
    }

    private func apply(registry: ProjectRegistry) {
        projects = registry.projects
        if let selected = selectedProject, !projects.contains(where: { $0.name == selected.name }) {
            selectedProject = nil
            dashboard = nil
        }
    }

    /// Turn a registry load result into banner-ready damage, or `nil`
    /// when the file read cleanly.
    ///
    /// `nonisolated` on purpose: `reload()` calls this from inside its
    /// detached read so the `.bak` stat — a real SSH round-trip on a
    /// remote context — never lands on the main actor.
    nonisolated static func damageNotice(
        for result: ProjectDashboardService.RegistryLoadResult,
        service: ProjectDashboardService
    ) -> RegistryDamageNotice? {
        guard result.salvaged else { return nil }
        // Only stat the backup once we already know something is wrong;
        // a clean load — the overwhelmingly common case, once per
        // watcher tick — costs nothing extra.
        let backup = service.context.paths.projectsRegistry + ".bak"
        return RegistryDamageNotice(
            quarantinePath: result.quarantinePath,
            backupPath: service.transport.fileExists(backup) ? backup : nil,
            droppedCount: result.salvage.droppedCount,
            salvagedFields: result.salvage.salvagedFields,
            unreadable: result.unreadablePath != nil
        )
    }

    /// Commit damage to the banner state, honouring a prior dismissal
    /// of this exact damage.
    private func applyDamage(_ notice: RegistryDamageNotice?) {
        guard let notice else {
            // The file reads cleanly again: drop the banner AND every
            // dismissal, so if it breaks again later the user is told.
            registryDamage = nil
            dismissedDamageSignatures.removeAll()
            return
        }
        guard !dismissedDamageSignatures.contains(notice.signature) else {
            registryDamage = nil
            return
        }
        registryDamage = notice
    }

    /// Take the registry-damage banner down. The same damage will not
    /// reopen it; different damage will.
    public func dismissRegistryDamage() {
        guard let current = registryDamage else { return }
        dismissedDamageSignatures.insert(current.signature)
        registryDamage = nil
    }

    /// Clear the mutation alert.
    public func dismissMutationError() {
        mutationError = nil
    }

    /// Load the registry for a mutation, or `nil` when the file did not
    /// read cleanly and the mutation must not proceed.
    ///
    /// **A lossy load must never be written back.** A salvaged decode
    /// hands us the SURVIVING subset: the rows it couldn't read are
    /// missing, and a surviving row may be missing a field. Saving that
    /// subset makes the loss permanent — the dropped projects are gone
    /// from `projects.json`, and a row rewritten without its `uuid`
    /// gets a fresh identity from `ProjectStore` and silently detaches
    /// from its own record, cron jobs and fleet siblings. The one-deep
    /// `.bak` only survives until the next save. So the read half of
    /// this phase learned to tolerate damage; the WRITE half has to
    /// refuse it, loudly, rather than quietly finish the job the bad
    /// agent write started.
    ///
    /// Synchronous like the mutators that call it: these are one-shot,
    /// user-initiated paths, not the hot watcher path `reload()` covers.
    private func registryForMutation(_ action: String) -> ProjectRegistry? {
        // Same reasoning as `load()`: this mutation is about to become
        // the newest truth, so invalidate any reload already in flight.
        // Safe to bump here — a mutator runs to its commit without a
        // suspension point, so no newer reload can start in between.
        reloadGeneration &+= 1
        let loaded = service.loadRegistryDetailed()
        applyDamage(Self.damageNotice(for: loaded, service: service))
        // UX, not enforcement. `ProjectDashboardService.saveRegistry` is the
        // guard — it refuses this write whether or not we look. What this
        // adds is the ALERT: the verb the user clicked, before the mutator
        // does its collision checks and commits in-memory state.
        //
        // It refuses on `loss`, the app-wide definition (whole rows gone,
        // file quarantined, file unreadable), NOT on `salvaged`. Refusing
        // every salvage — which is what this did — meant one row with a
        // hand-typed uuid froze renaming, archiving and folders for every
        // project, while the doctor happily repaired the same file. The
        // banner still reports field salvage; the doctor now raises a
        // finding for it; neither stops the user working.
        if let loss = loaded.loss {
            fail("Couldn't \(action)", reason: loss.message)
            return nil
        }
        return loaded.registry
    }

    /// Record a failed mutation for the view to alert on, and log it.
    private func fail(_ title: String, _ error: any Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        mutationError = ProjectMutationFailure(title: title, message: reason)
        logger.error("\(title, privacy: .public): \(reason, privacy: .public)")
    }

    /// Record a refusal that isn't an error — a name collision, a
    /// project that has since vanished from the registry.
    private func fail(_ title: String, reason: String) {
        mutationError = ProjectMutationFailure(title: title, message: reason)
    }

    public func selectProject(_ project: ProjectEntry) {
        selectedProject = project
        loadDashboard(for: project)
    }

    @discardableResult
    public func addProject(name: String, path: String) -> Bool {
        mutationError = nil
        guard var registry = registryForMutation("add “\(name)”") else { return false }
        guard !registry.projects.contains(where: { $0.name == name }) else {
            fail("Couldn't add “\(name)”", reason: "A project with that name is already in the list.")
            return false
        }
        // Same policy `project_register` enforces, at the app's own door.
        // A root of `/` or `$HOME` makes every containment check downstream
        // vacuous, and the folder picker will happily hand over either.
        if let refusal = ProjectRootPolicy.refusal(for: path, context: context) {
            fail("Couldn't add “\(name)”", reason: refusal.message)
            return false
        }
        let entry = ProjectEntry(name: name, path: path)
        registry.projects.append(entry)
        // The in-memory list is committed only on a successful write.
        // The previous version added the row either way, so a failed
        // save left a project the user could see and use all session
        // that was simply gone at relaunch — the silent failure this
        // whole change exists to remove.
        do {
            try service.saveRegistry(registry)
        } catch {
            fail("Couldn't add “\(name)”", error)
            return false
        }
        projects = registry.projects
        selectProject(entry)
        return true
    }

    @discardableResult
    public func removeProject(_ project: ProjectEntry) -> Bool {
        mutationError = nil
        guard var registry = registryForMutation("remove “\(project.name)”") else { return false }
        // Without this guard a removal of something already gone would
        // save an unchanged list — and if that list is empty, the
        // `allowEmpty` below deliberately bypasses Phase 1's
        // empty-overwrite refusal, blanking the file while reporting
        // success.
        // KEYED BY IDENTITY, NOT NAME. `uuid` when the row has one, a
        // normalized path compare otherwise — the same rule
        // `ProjectTemplateUninstaller.matches` uses. Matching on the display
        // name meant removing one project deleted EVERY row that shared its
        // name, and duplicate names are a state the doctor reports as
        // survivable precisely because they were supposed to be
        // individually resolvable. It also meant a rename racing a removal
        // took out the wrong row.
        let doomed: (ProjectEntry) -> Bool = { candidate in
            if let target = project.uuid, let id = candidate.uuid { return id == target }
            return ProjectIdentity.normalizedPath(candidate.path)
                == ProjectIdentity.normalizedPath(project.path)
        }
        guard registry.projects.contains(where: doomed) else {
            fail("Couldn't remove “\(project.name)”", reason: "That project is no longer in the list.")
            return false
        }
        registry.projects.removeAll(where: doomed)
        do {
            // Deliberate removal: removing the user's last project must
            // still be able to leave the registry empty.
            try service.saveRegistry(registry, allowEmpty: true)
        } catch {
            // Keep the project on screen: it is still in the file, and
            // showing it gone would be a lie the next launch corrects.
            fail("Couldn't remove “\(project.name)”", error)
            return false
        }
        projects = registry.projects
        // Only AFTER the registry write committed. Revoking grants and
        // stripping the AGENTS.md block for a project that is still listed
        // (because the save threw) would be damage, not cleanup.
        ProjectLifecycleService(context: context).cleanUpAfterRemoval(of: project)
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
        return true
    }

    // MARK: - v2.3 registry verbs (folder / archive / rename)

    /// Move a project into a folder. `nil` folder returns the project
    /// to the top level. No-op when the target already matches.
    @discardableResult
    public func moveProject(_ project: ProjectEntry, toFolder folder: String?) -> Bool {
        mutateEntry(project, action: "move “\(project.name)”") { $0.folder = folder }
    }

    /// Rename a project. `name` is the registry's unique key + the
    /// Identifiable id; rejects renames that would collide with an
    /// existing project's name. Returns true on success.
    @discardableResult
    public func renameProject(_ project: ProjectEntry, to newName: String) -> Bool {
        mutationError = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Unreachable from RenameProjectSheet (it disables Save on
            // an empty field), but the invariant this phase asserts is
            // that NO mutator returns false without saying why.
            fail("Couldn't rename “\(project.name)”", reason: "A project needs a name.")
            return false
        }
        guard trimmed != project.name else { return true }
        guard var registry = registryForMutation("rename “\(project.name)”") else { return false }
        guard !registry.projects.contains(where: { $0.name == trimmed }) else {
            fail("Couldn't rename “\(project.name)”", reason: "A project named “\(trimmed)” is already in the list.")
            return false
        }
        guard let index = registry.projects.firstIndex(where: { $0.name == project.name }) else {
            fail("Couldn't rename “\(project.name)”", reason: "That project is no longer in the list.")
            return false
        }
        let old = registry.projects[index]
        // `uuid` is CARRIED OVER, never re-derived. It is the project's stable
        // identity — the key of `<path>/.scarf/project.json`, the fleet
        // grouping key, and the `[proj:<uuid>]` cron tag. Dropping it here (as
        // this did) left the registry row id-less, so the next `ProjectStore`
        // pass minted a FRESH random UUID: the renamed project silently
        // detached from its own record, its cron jobs, and its fleet siblings.
        // A rename changes the label; it must never change the identifier.
        registry.projects[index] = ProjectEntry(
            name: trimmed,
            path: old.path,
            folder: old.folder,
            archived: old.archived,
            uuid: old.uuid
        )
        do {
            try service.saveRegistry(registry)
        } catch {
            fail("Couldn't rename “\(project.name)”", error)
            return false
        }
        projects = registry.projects
        propagateRenameToRecord(registry.projects[index], from: project.name)
        if selectedProject?.name == project.name {
            selectedProject = registry.projects[index]
        }
        return true
    }

    /// Carry the new name into `<root>/.scarf/project.json`.
    ///
    /// The registry is the INDEX; the record is the portable, canonical
    /// copy — and it is the one that renders. `ProjectStore.renderAgentContextBlock`
    /// reads `project.name` off the record, so before this the old name was
    /// injected into every project chat's AGENTS.md block forever, and
    /// `project_get` / the fleet panel disagreed with the sidebar about what
    /// the project is called. A rename that updates one of two stores is not
    /// a rename.
    ///
    /// Best-effort ON PURPOSE, and after the registry write rather than
    /// before it: the registry save is the one that must succeed (it is what
    /// the user sees), and a record that is missing, unreadable or on an
    /// unreachable remote must not roll back a rename that already landed.
    /// The doctor's `recordNameMismatch` finding is the backstop — a
    /// divergence that survives this is now SAID rather than silent.
    private func propagateRenameToRecord(_ entry: ProjectEntry, from oldName: String) {
        let store = ProjectStore(context: context)
        guard var record = store.load(projectPath: entry.path) else { return }
        guard record.name != entry.name else { return }
        record.name = entry.name
        do {
            try store.save(record)
        } catch {
            // Not a `fail(...)`: the rename SUCCEEDED. Surfacing an alert
            // here would tell the user their rename didn't work when it did.
            logger.warning(
                "renamed “\(oldName, privacy: .public)” in the registry but couldn't update its project record: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Soft-archive a project. Stays on disk + in the registry; the
    /// sidebar just hides it unless `showArchived` is on.
    @discardableResult
    public func archiveProject(_ project: ProjectEntry) -> Bool {
        // Clear the selection only if the archive actually persisted —
        // otherwise the user loses their place to a write that didn't
        // happen.
        guard mutateEntry(project, action: "archive “\(project.name)”", { $0.archived = true }) else {
            return false
        }
        // Archive is no longer an inert display bool. The watchers stop
        // (`dashboardPaths` / `projectScarfDirs` exclude archived rows) and
        // the project's scheduled jobs are paused — otherwise "archived"
        // named a state the system was not in: cron still firing into a
        // folder the user had put away, and a tick still paying for it.
        //
        // Grants are deliberately NOT revoked here: archiving is reversible
        // and unarchiving cannot restore a consent decision, so revoking
        // would make a reversible action quietly lossy. Removal revokes;
        // archive pauses.
        //
        // OFF THE MAIN ACTOR (charter C10). This spawns one `hermes cron
        // pause` per job, each with a 30s timeout — on a wedged remote a
        // project with six jobs would freeze the window for three minutes.
        // Detached and fire-and-forget: the archive itself already
        // committed, the pause is a best-effort follow-up, and nothing on
        // screen is waiting for it.
        let lifecycle = ProjectLifecycleService(context: context)
        let target = project
        Task.detached(priority: .utility) { lifecycle.setCronPaused(true, for: target) }
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
        return true
    }

    /// Restore an archived project to the default view.
    @discardableResult
    public func unarchiveProject(_ project: ProjectEntry) -> Bool {
        guard mutateEntry(project, action: "restore “\(project.name)”", { $0.archived = false })
        else { return false }
        // Symmetric with `archiveProject`. Without this, archiving would be
        // a one-way door wearing a toggle's clothes: the jobs would stay
        // paused and the user would have no reason to look for them.
        // Detached for the same reason `archiveProject` detaches — see there.
        let lifecycle = ProjectLifecycleService(context: context)
        let target = project
        Task.detached(priority: .utility) { lifecycle.setCronPaused(false, for: target) }
        return true
    }

    /// Distinct folder labels across the current project set, sorted
    /// alphabetically. Drives the sidebar's DisclosureGroups + the
    /// Move-to-Folder sheet's existing-folder list.
    public var folders: [String] {
        let set = Set(projects.compactMap(\.folder).filter { !$0.isEmpty })
        return set.sorted()
    }

    // MARK: - Helpers

    /// - Parameter action: the verb phrase for the failure alert, e.g.
    ///   `move “site”` → "Couldn't move “site”". Every caller is a
    ///   thing the user clicked, so every failure has to be sayable.
    @discardableResult
    private func mutateEntry(
        _ project: ProjectEntry,
        action: String,
        _ mutation: (inout ProjectEntry) -> Void
    ) -> Bool {
        mutationError = nil
        guard var registry = registryForMutation(action) else { return false }
        guard let index = registry.projects.firstIndex(where: { $0.name == project.name }) else {
            fail("Couldn't \(action)", reason: "That project is no longer in the list.")
            return false
        }
        var entry = registry.projects[index]
        mutation(&entry)
        registry.projects[index] = entry
        do {
            try service.saveRegistry(registry)
        } catch {
            fail("Couldn't \(action)", error)
            return false
        }
        projects = registry.projects
        if selectedProject?.name == project.name {
            selectedProject = entry
        }
        return true
    }

    public func refreshDashboard() {
        guard let project = selectedProject else { return }
        loadDashboard(for: project)
    }

    /// Archived rows are EXCLUDED. Watching an archived project's dashboard
    /// is per-tick transport cost (an SSH round-trip each, on a remote) for
    /// a surface the sidebar hides — and it is half of what made "archived"
    /// a lie: the project was still being polled, still refreshing, still
    /// re-rendering, just invisible.
    public var dashboardPaths: [String] {
        projects.filter { !$0.archived }.map(\.dashboardPath)
    }

    /// Per-project `.scarf/` directories — watched alongside `dashboardPaths`
    /// so that file-reading widgets (markdown_file, log_tail, image) refresh
    /// when their underlying files are added / removed / renamed inside the
    /// directory by a cron job. In-place file appends within an existing
    /// file are NOT detected here; the cron job should write atomically
    /// (write-then-rename) or `touch` dashboard.json after each run.
    /// Archived rows excluded — see `dashboardPaths`.
    public var projectScarfDirs: [String] {
        projects.filter { !$0.archived }.map(\.scarfDir)
    }

    private func loadDashboard(for project: ProjectEntry) {
        dashboardError = nil
        if !service.dashboardExists(for: project) {
            dashboard = nil
            dashboardError = "No dashboard found at \(project.dashboardPath)"
            return
        }
        if let loaded = service.loadDashboard(for: project) {
            dashboard = loaded
        } else {
            dashboard = nil
            dashboardError = "Failed to parse dashboard JSON"
        }
    }

    /// Off-main variant of `loadDashboard(for:)` for `reload()`. Does the
    /// `dashboardExists` + `loadDashboard` transport reads on a detached task,
    /// then commits the result back on the main actor.
    private func reloadDashboard(for project: ProjectEntry, generation: Int) async {
        let ctx = context
        let outcome: (dashboard: ProjectDashboard?, error: String?) = await Task.detached {
            let svc = ProjectDashboardService(context: ctx)
            guard svc.dashboardExists(for: project) else {
                return (nil, "No dashboard found at \(project.dashboardPath)")
            }
            if let loaded = svc.loadDashboard(for: project) { return (loaded, nil) }
            return (nil, "Failed to parse dashboard JSON")
        }.value
        guard generation == reloadGeneration else { return }
        dashboardError = outcome.error
        dashboard = outcome.dashboard
    }
}
