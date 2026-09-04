import Foundation
import os
import ScarfCore

/// Brings an existing — basic or pre-first-class — Scarf project up to the
/// full first-class structure the cockpit surfaces, **idempotently**, by
/// composing the same writers the New Project scaffolder uses, in
/// stable-id-first order.
///
/// This is the **deterministic half** of "Upgrade Project." It guarantees
/// the project has a stable identity + the structural facets every panel
/// needs; the agent then *enriches* it (a real dashboard, slash commands,
/// cron jobs, a starter mini-app) in the chat hand-off via the
/// `scarf-template-author` skill (enrich mode) + the `scarf-miniapp-author`
/// skill. **Fleet is out of scope** for upgrade.
///
/// **Invariants.** Every step is idempotent and BOUNDED — it never clobbers
/// user content outside managed markers, and never overwrites a real
/// `dashboard.json`. It is SECRET-SAFE (touches no secret values). The only
/// step that can abort the whole run is the identity write (`project.json`):
/// without a stable id nothing else is meaningful, and an id minted *after*
/// id-keyed facets would orphan them. Everything after identity is
/// best-effort + logged (NON-FATAL) so one facet failing doesn't sink the
/// upgrade. Re-running on an already-upgraded project is a no-op.
struct ProjectUpgradeService: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectUpgradeService")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Bump when the deterministic pass gains steps, so the cockpit can
    /// offer a re-upgrade to projects stamped with an older version.
    nonisolated static let currentUpgradeVersion = 1

    /// What the structure pass ensured/changed — for UI feedback and the
    /// chat hand-off prompt.
    struct Outcome: Sendable {
        /// Stable id (existing or freshly minted) — the key everything else
        /// hangs off.
        let projectID: UUID
        /// The Kanban tenant (existing or minted); `nil` when the board step
        /// was skipped (host without Kanban).
        let board: String?
        /// A placeholder `dashboard.json` was written *this run* (false when
        /// the project already had one — we never overwrite a real dashboard).
        let dashboardSeeded: Bool
        /// The project was already stamped at the current upgrade version
        /// before this run (a re-run / no-op).
        let wasAlreadyUpgraded: Bool
    }

    // MARK: - Upgrade

    /// Run the deterministic structure pass on `project`. `hasKanban` gates
    /// the board step (never mint a tenant on a host without Kanban — the
    /// cockpit hides the Board panel there). Throws only if the identity
    /// write fails.
    nonisolated func upgrade(_ project: ProjectEntry, hasKanban: Bool) throws -> Outcome {
        let transport = context.makeTransport()
        let scarfDir = project.path + "/.scarf"

        let wasAlreadyUpgraded = (readProvenanceVersion(projectPath: project.path) ?? 0) >= Self.currentUpgradeVersion

        // 0. Ensure `.scarf/` exists (mkdir -p across transports; idempotent).
        try transport.createDirectory(scarfDir)

        // 1. Kanban board/tenant FIRST, where Kanban exists. The tenant is
        //    name/slug-keyed (NOT uuid-keyed), so minting it before the
        //    identity record is safe — and doing so means the record derived
        //    in step 2 picks it up (keeping `project.json.board` in sync with
        //    `manifest.json`) and the AGENTS.md block renders the board line
        //    on the very first pass. Idempotent (returns the existing
        //    `scarf:<slug>` or mints one).
        var board: String?
        if hasKanban {
            do {
                board = try KanbanTenantResolver(context: context).resolveOrMint(for: project)
            } catch {
                Self.logger.warning("upgrade: kanban tenant mint failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. IDENTITY — stable uuid + canonical `.scarf/project.json` + the
        //    registry index. `load ?? derive` reuses an existing record/uuid
        //    (preserving the stable id) and only mints when genuinely bare; a
        //    bare derive reads the tenant minted above, so its `board` is
        //    already correct. For an EXISTING record that predates the tenant,
        //    reflect the tenant into the record explicitly — a full re-derive
        //    would reset `createdAt` / `hostBindings`. This is the ONLY step
        //    whose failure aborts (identity is foundational), and persisting
        //    the uuid here keeps a later `derive()` from minting a fresh one
        //    and orphaning any uuid-keyed facet.
        let store = ProjectStore(context: context)
        var record = store.load(projectPath: project.path) ?? store.derive(from: project)
        if let board, record.board != board { record.board = board }
        do {
            try store.save(record)
        } catch {
            // The ONLY fatal step — log the cause before propagating so the
            // `try?` at the call site (AppCoordinator.upgradeProject) isn't
            // undebuggable. The cockpit banner persists (provenance was never
            // stamped → `needsUpgrade` stays true) and the user can retry.
            Self.logger.error("upgrade: identity write failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let projectID = record.id

        // The downstream writers key on path but want the stable uuid in the
        // entry; rebuild it so they all agree on the id we just persisted.
        let entry = ProjectEntry(
            name: project.name,
            path: project.path,
            folder: project.folder,
            archived: project.archived,
            uuid: projectID
        )

        // 3. AGENTS.md managed block — create-or-splice, bounded, idempotent.
        //    Runs after the tenant exists so the rendered block carries the
        //    board line; gives the agent Scarf platform context on its next run.
        do {
            try ProjectAgentContextService(context: context).refresh(for: entry)
        } catch {
            Self.logger.warning("upgrade: AGENTS.md refresh failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // 4. Ensure a `dashboard.json` so the Dashboard panel lights up —
        //    placeholder ONLY if none exists. Never clobber a real dashboard;
        //    the agent replaces the placeholder during enrichment.
        var dashboardSeeded = false
        let dashboardPath = scarfDir + "/dashboard.json"
        if !transport.fileExists(dashboardPath) {
            do {
                let data = try ProjectScaffolder.makePlaceholderDashboard(name: project.name, description: nil)
                try transport.writeFile(dashboardPath, data: data)
                dashboardSeeded = true
            } catch {
                Self.logger.warning("upgrade: placeholder dashboard write failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 5. Stamp provenance (also the "already upgraded?" guard the cockpit
        //    banner reads). Best-effort — the upgrade already happened.
        writeProvenance(projectPath: project.path)

        Self.logger.info("upgraded project \(project.name, privacy: .public) (id \(projectID.uuidString, privacy: .public), board \(board ?? "—", privacy: .public), dashboardSeeded \(dashboardSeeded, privacy: .public))")
        return Outcome(
            projectID: projectID,
            board: board,
            dashboardSeeded: dashboardSeeded,
            wasAlreadyUpgraded: wasAlreadyUpgraded
        )
    }

    /// Whether `project` still needs the deterministic upgrade pass (no
    /// provenance, or stamped at an older version). Drives the cockpit's
    /// "Upgrade available" affordance. Cheap — a single small read.
    nonisolated func needsUpgrade(_ project: ProjectEntry) -> Bool {
        (readProvenanceVersion(projectPath: project.path) ?? 0) < Self.currentUpgradeVersion
    }

    // MARK: - Provenance (`.scarf/upgrade.json`)

    /// Lightweight record of the last deterministic upgrade. Deliberately
    /// separate from `project.json` (which is the portable cross-host record)
    /// — this is per-materialization "the structure pass ran here."
    private nonisolated struct Provenance: Codable {
        var schemaVersion: Int
        var upgradeVersion: Int
        var upgradedAt: String
    }

    private nonisolated func provenancePath(projectPath: String) -> String {
        projectPath + "/.scarf/upgrade.json"
    }

    private nonisolated func readProvenanceVersion(projectPath: String) -> Int? {
        let path = provenancePath(projectPath: projectPath)
        let transport = context.makeTransport()
        // ONE probe, not two: a failed read is already "no provenance
        // version" here, so the `fileExists` that preceded it only ever
        // bought a second round-trip for the same answer (PERF L1).
        guard let data = try? transport.readFile(path) else { return nil }
        return (try? JSONDecoder().decode(Provenance.self, from: data))?.upgradeVersion
    }

    private nonisolated func writeProvenance(projectPath: String) {
        let provenance = Provenance(
            schemaVersion: 1,
            upgradeVersion: Self.currentUpgradeVersion,
            upgradedAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(provenance) else { return }
        do {
            try context.makeTransport().writeFile(provenancePath(projectPath: projectPath), data: data)
        } catch {
            Self.logger.warning("upgrade: couldn't write provenance for \(projectPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
