import Foundation
import ScarfCore
import os

/// Persisted entry for a user-added server. `ServerContext` itself is a value
/// type we rebuild from these fields at runtime — we persist the minimum that
/// uniquely identifies a connection, not the whole context struct, so future
/// fields we add to `ServerContext` don't force a migration.
struct ServerEntry: Identifiable, Codable, Hashable, Sendable {
    var id: ServerID
    var displayName: String
    var kind: ServerKind
    /// User preference: this server is the one Scarf opens into when a
    /// fresh window has no prior binding (first launch or File → New).
    /// At most one entry should have this set — `ServerRegistry` enforces
    /// mutual exclusivity. If none do, Local is the implicit default.
    var openOnLaunch: Bool = false

    var context: ServerContext {
        ServerContext(id: id, displayName: displayName, kind: kind)
    }
}

/// On-disk envelope for `servers.json`. Schema-versioned so future changes
/// can migrate without losing data.
private struct RegistryFile: Codable {
    var schemaVersion: Int
    var entries: [ServerEntry]
}

/// App-scoped store for user-added servers. `local` is synthesized (not
/// persisted) and always appears first in `allContexts`. Remote entries are
/// loaded from `~/Library/Application Support/scarf/servers.json`.
///
/// Observable so SwiftUI views binding to `entries` redraw when a server is
/// added, renamed, or removed.
@Observable
@MainActor
final class ServerRegistry: GuardedSidecarStore {
    private static let logger = Logger(subsystem: "com.scarf", category: "ServerRegistry")
    private static let currentSchemaVersion = 1

    /// A `servers.json` bigger than this is not a server list — it is
    /// something else wearing the name, and decoding it on the launch path
    /// is the wrong risk. Generous: 4 MB is tens of thousands of entries.
    nonisolated static let maxBytes = 4 * 1024 * 1024
    nonisolated static let label = "servers.json"
    /// REFUSE FOREVER. The rows are the user's SSH connections and exist
    /// nowhere else (the `.scarfservers` export is opt-in and usually
    /// absent), so unusable bytes are copied aside for the human and every
    /// write stays refused until the file is readable again. The
    /// reclassification this used to hand-roll — for the decode failure AND
    /// for the size cap — now comes from `GuardedSidecarStore`.
    nonisolated static let damagePolicy = GuardedDamagePolicy.refuseForever

    nonisolated let transport: any ServerTransport

    /// Remote (user-added) entries. Observable: views redraw on mutation.
    private(set) var entries: [ServerEntry] = []

    /// What went wrong with `servers.json`, if anything. Non-nil means the
    /// list on screen is NOT what is on disk and every save is being
    /// refused — `ManageServersView` renders it, because a silent refusal
    /// is exactly the failure this conversion exists to end.
    ///
    /// (`ProjectsViewModel.registryDamage` is the same idea for
    /// `projects.json`; this file has no watcher and no doctor, so the
    /// notice is deliberately simpler.)
    struct StoreDamage: Equatable, Sendable {
        /// The file we could not use.
        var path: String
        /// Where unusable bytes were copied for the user, when we held
        /// bytes at all.
        var quarantinePath: String?
        /// A save has already been attempted and refused since the damage
        /// appeared — i.e. the user's edit is in memory only.
        var refusedSave: Bool = false
    }

    private(set) var storeDamage: StoreDamage?

    /// A save that was NOT refused and still did not land — a full disk, a
    /// read-only volume, a permissions change under us (GW-F6 / audit DI
    /// M5). This used to be a bare `logger.error` in the `catch` below: the
    /// user's edit stayed on screen, the banner stayed hidden, and Scarf had
    /// silently become an in-memory registry. It is deliberately NOT
    /// `storeDamage` — nothing is damaged, nothing is being refused, and the
    /// remedy (free some space, fix the permissions, retry) is a different
    /// sentence — but it renders in the same banner slot.
    private(set) var saveFailure: String?

    /// True when anything is wrong enough that `ManageServersView` should
    /// show a banner: the file is damaged, or a write failed outright.
    var hasStoreProblem: Bool { storeDamage != nil || saveFailure != nil }

    private let storePath: String

    /// The inspection the in-memory `entries` were built from — the same
    /// one every save is validated against, so a save can never publish a
    /// list derived from a read that failed. `nil` means "never inspected",
    /// which `GuardedSidecarStore.publish` REFUSES rather than treating as
    /// a proven-absent file (unreachable today: `init` loads).
    private var lastInspection: GuardedJSONStore.Inspection?

    /// - Parameters:
    ///   - storeURL: override for tests; production uses
    ///     `~/Library/Application Support/scarf/servers.json`.
    ///   - transport: the guarded store's transport. `servers.json` is a
    ///     Mac-local file, so this is always `LocalTransport` in the app;
    ///     the seam exists so tests can inject a blip-injecting fake.
    init(storeURL: URL? = nil, transport: any ServerTransport = LocalTransport()) {
        self.storePath = (storeURL ?? Self.defaultStoreURL()).path
        self.transport = transport
        load()
    }

    private static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = support.appendingPathComponent("scarf", isDirectory: true)
        return dir.appendingPathComponent("servers.json")
    }

    // MARK: - Lookup

    /// The implicit local server plus every persisted remote entry, in list
    /// order. Use this when populating UI like the toolbar switcher.
    var allContexts: [ServerContext] {
        [.local] + entries.map { $0.context }
    }

    /// Resolve an ID to a context, or `nil` if the entry no longer exists.
    /// Used by the multi-window root to detect "this window points at a
    /// server you've since removed" and show a dedicated empty state.
    func context(for id: ServerID) -> ServerContext? {
        if id == ServerContext.local.id { return .local }
        if let entry = entries.first(where: { $0.id == id }) {
            return entry.context
        }
        return nil
    }

    /// The server a fresh window should open into. Returns the ID of the
    /// remote entry flagged `openOnLaunch`, or Local's ID if none is
    /// flagged (or if the flagged entry was removed out from under us).
    /// Consumed by the `WindowGroup`'s `defaultValue` closure.
    var defaultServerID: ServerID {
        entries.first(where: { $0.openOnLaunch })?.id ?? ServerContext.local.id
    }

    /// Flip the default server to `id`. Passing `ServerContext.local.id`
    /// clears the flag on every remote entry, making Local the implicit
    /// default. Passing an unknown ID is a no-op. Persisted on return.
    ///
    /// Intentionally doesn't fire `onEntriesChanged` — that hook means "the
    /// set of servers changed" and drives the menu-bar fanout rebuild. A
    /// default-flag flip doesn't change the set; SwiftUI views reading
    /// `defaultServerID` redraw via `@Observable`'s tracking of `entries`.
    func setDefaultServer(_ id: ServerID) {
        var changed = false
        for idx in entries.indices {
            let shouldBeDefault = (entries[idx].id == id)
            if entries[idx].openOnLaunch != shouldBeDefault {
                entries[idx].openOnLaunch = shouldBeDefault
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    // MARK: - Mutations

    /// Optional callback fired whenever `entries` changes. The app wires
    /// this to `ServerLiveStatusRegistry.rebuild()` so the menu-bar fanout
    /// stays in sync without polling the entries array.
    var onEntriesChanged: (() -> Void)?

    @discardableResult
    func addServer(displayName: String, config: SSHConfig) -> ServerEntry {
        let entry = ServerEntry(
            id: ServerID(),
            displayName: displayName,
            kind: .ssh(config)
        )
        entries.append(entry)
        save()
        onEntriesChanged?()
        // Registry-level so every add path (Manage Servers, and anything
        // added later) is covered exactly once. `transport` is the only
        // prop: nothing about the host, user, port, or identity file is
        // safe to send, and every entry this method creates is `.ssh` by
        // construction — Local is implicit and never "added".
        //
        // The taxonomy's `key_source` prop is deliberately absent here: it
        // describes the iOS onboarding flow's generate/import-key choice,
        // which has no macOS analogue (the Mac defers entirely to
        // ssh-agent or an existing on-disk identity file). Emitting a
        // fabricated value would be worse than omitting the prop.
        Analytics.record(.serverAdded(transport: .ssh))
        return entry
    }

    func updateServer(_ id: ServerID, displayName: String?, config: SSHConfig?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if let name = displayName { entries[idx].displayName = name }
        if let cfg = config { entries[idx].kind = .ssh(cfg) }
        save()
        onEntriesChanged?()
    }

    func removeServer(_ id: ServerID) {
        // Grab the entry BEFORE removing it so we can tear down its transport
        // state. Without this the user would leak a ControlMaster socket
        // (~10min TTL) and a snapshot cache dir (indefinite) per removed
        // server — harmless individually, ugly at scale.
        let removed = entries.first { $0.id == id }
        entries.removeAll { $0.id == id }
        save()

        // Only when an entry was actually there: `removeServer` is safe to
        // call with an unknown id (the cache cleanup below still runs), and
        // a no-op removal is not a user-visible event.
        if let removed {
            let transport: UsageEvent.Transport
            if case .local = removed.kind { transport = .local } else { transport = .ssh }
            Analytics.record(.serverRemoved(transport: transport))
        }

        if let removed, case .ssh(let config) = removed.kind {
            let transport = SSHTransport(contextID: id, config: config, displayName: removed.displayName)
            transport.closeControlMaster()
            // Drop any circuit-breaker state (gh#138) so a future re-add of
            // the same host starts clean.
            SSHConnectionGate.shared.reset(SSHConnectionGate.key(host: config.host, port: config.port))
        }
        SSHTransport.pruneSnapshotCache(for: id)
        // Drop process-wide cache entries keyed on this ServerID so a future
        // re-add with a colliding ID (theoretical — UUIDs are random, but be
        // defensive) doesn't serve stale data.
        Task.detached { await ServerContext.invalidateCaches(for: id) }

        onEntriesChanged?()
    }

    // MARK: - App-launch sweep

    /// Remove snapshot cache directories whose UUID isn't in the current
    /// registry. Handles the case where the user removed a server while the
    /// app was closed — we want the cache to converge to the registry's
    /// state at launch rather than carrying forever.
    func sweepOrphanCaches() {
        var keep: Set<ServerID> = [ServerContext.local.id]
        for entry in entries { keep.insert(entry.id) }
        SSHTransport.sweepOrphanSnapshots(keeping: keep)
        SSHTransport.sweepStaleControlSockets()
    }

    // MARK: - Export / Import

    /// Result summary returned from `importEntries(from:)`. The UI renders
    /// it as a one-line confirmation so the user knows whether anything
    /// changed (e.g. picking a stale export file imports zero entries
    /// because every ID is already present).
    struct ImportSummary: Equatable {
        var imported: Int
        var skippedDuplicates: Int
        /// Whether the imported entries actually reached `servers.json`
        /// (GW-F6 / audit DI M7). `false` when the save was refused (the
        /// file is damaged) or failed outright — in which case the import
        /// lives in this session only, and telling the user "Imported 3
        /// servers" full stop would be the same green-checkmark-for-failure
        /// GW-F4 removed everywhere else.
        var persisted: Bool = true
        /// Why it did not persist, ready to append to the summary line.
        var persistFailure: String?
    }

    /// Errors raised by `importEntries(from:)` for the user-facing alert.
    /// Validation is conservative — we'd rather refuse a malformed file
    /// than half-import garbage and leave the registry in a weird state.
    enum ImportError: Error, LocalizedError {
        case unreadable(String)
        case malformed(String)
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable(let m): return "Couldn't read the file: \(m)"
            case .malformed(let m): return "The file isn't a valid Scarf servers export: \(m)"
            case .unsupportedSchema(let v): return "This export uses schema v\(v), which this version of Scarf doesn't recognize."
            }
        }
    }

    /// Encode the current registry as a portable export. `displayName`,
    /// `host`, `user`, `port`, `identityFile` (path string only),
    /// `remoteHome`, `projectsRoot`, `hermesBinaryHint`, `openOnLaunch`,
    /// and the entry's stable UUID travel. **No secrets** ride along —
    /// SSH private keys live at the path referenced by `identityFile`,
    /// not in `servers.json`. Importing on a different Mac requires the
    /// user to copy their `~/.ssh/` keys separately (or re-point each
    /// entry's identityFile in Edit Server).
    func exportFile() throws -> Data {
        let payload = ExportFile(
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Merge entries from a `.scarfservers` file. Dedupe is by UUID
    /// — entries whose ID already exists are skipped (the existing
    /// entry wins, since it may carry edits the user made post-export).
    /// `openOnLaunch` is normalized after import: at most one entry
    /// can be the default, and conflicts resolve in favor of the
    /// pre-existing default.
    @discardableResult
    func importEntries(from data: Data) throws -> ImportSummary {
        let payload: ExportFile
        do {
            payload = try JSONDecoder().decode(ExportFile.self, from: data)
        } catch {
            throw ImportError.malformed(error.localizedDescription)
        }
        guard payload.schemaVersion == Self.currentSchemaVersion else {
            throw ImportError.unsupportedSchema(payload.schemaVersion)
        }

        let existingIDs = Set(entries.map(\.id))
        var imported = 0
        var skipped = 0
        for incoming in payload.entries {
            if existingIDs.contains(incoming.id) {
                skipped += 1
                continue
            }
            var copy = incoming
            // Don't let an imported entry seize the default slot if the
            // user already has one assigned. Normalization below also
            // drops `openOnLaunch` if more than one survives.
            if entries.contains(where: { $0.openOnLaunch }) {
                copy.openOnLaunch = false
            }
            entries.append(copy)
            imported += 1
        }

        // Belt-and-suspenders: if multiple entries somehow ended up
        // flagged as default (e.g. user imported an export that itself
        // had the flag on a different entry than the local default),
        // keep only the first one.
        var sawDefault = false
        for idx in entries.indices {
            if entries[idx].openOnLaunch {
                if sawDefault { entries[idx].openOnLaunch = false }
                else { sawDefault = true }
            }
        }

        let outcome = save()
        if imported > 0 { onEntriesChanged?() }
        return ImportSummary(
            imported: imported,
            skippedDuplicates: skipped,
            persisted: outcome.didPersist,
            persistFailure: outcome.failureMessage
        )
    }

    /// Disk envelope distinct from `RegistryFile`. Adds the export
    /// timestamp; structurally compatible so a hand-edited export
    /// could in theory be dropped at `~/Library/Application
    /// Support/scarf/servers.json` and load — we don't rely on that,
    /// but keeping the shape close means one less migration surface
    /// when we eventually add fields here.
    private struct ExportFile: Codable {
        var schemaVersion: Int
        var exportedAt: String
        var entries: [ServerEntry]
    }

    // MARK: - Persistence

    /// Read `servers.json` under the `GuardedJSONStore` discipline
    /// (GW-E2b). Before this, `load()` was `try? read; catch { entries = [] }`
    /// and `save()` was a bare `Data.write(.atomic)` — the `projects.json`
    /// destroy shape verbatim, on the one file that holds every server the
    /// user configured, and entirely outside the transport layer where no
    /// enforcement could see it.
    ///
    /// **This file REFUSES; it does not quarantine-and-rebuild.** The rows
    /// are the user's SSH connections and exist nowhere else (the export
    /// file is opt-in and usually absent), so the `projects.json` rule
    /// applies: unusable bytes are copied aside for the human and every
    /// write stays refused until the file is readable again. That is why
    /// `inspect` + a local decode is used here rather than
    /// `inspectDecoding`, whose `.quarantined` state is deliberately
    /// WRITABLE for rebuildable indices.
    ///
    /// Cost on the launch path (Charter C10): one local `read` on the happy
    /// path, exactly as before. The stat + retry probe runs only when that
    /// read already failed. No sleeps, no retry loops.
    /// Re-read `servers.json` from disk and act on what is there NOW.
    ///
    /// **Re-inspect; never trust the cached verdict (GW-F2).** The whole
    /// point of a retry is that the world may have changed — the file was
    /// restored from the quarantine copy, the volume came back, the
    /// permissions were fixed — so this runs the full proof-based inspection
    /// again rather than re-testing `storeDamage`.
    ///
    /// Two outcomes, and which one applies depends on whether the user has
    /// edits that never reached disk:
    ///
    /// - **The file is healthy again and the session has UNPUBLISHED edits**
    ///   (`storeDamage?.refusedSave == true`): the in-memory list is what the
    ///   user believes their registry is, so it is published on top of the
    ///   recovered file — with the guard's one-deep `.bak` capturing whatever
    ///   was just recovered, so the hand-repair is not lost either.
    /// - **The file is healthy again and nothing is pending**: the disk wins
    ///   and the list is reloaded from it, exactly as at launch.
    ///
    /// Still damaged ⇒ still refusing, with the banner updated to whatever
    /// the fresh inspection found (the quarantine path can appear, or
    /// disappear — a size-refused file has no `.corrupt-` copy at all).
    func retryLoad() {
        let hadPendingEdits = storeDamage?.refusedSave == true
        saveFailure = nil
        load(adoptingDiskEntries: !hadPendingEdits)
        if hadPendingEdits, storeDamage == nil {
            // The file reads again and `lastInspection` is fresh proof, so
            // the publish this session has been refusing can finally happen.
            save()
        }
    }

    /// Publish the in-memory list again after a non-refusal write failure
    /// (DI M5). Nothing to re-inspect here: `lastInspection` is still the
    /// proof from a healthy read — the write, not the read, is what failed.
    func retrySave() {
        save()
    }

    private func load(adoptingDiskEntries: Bool = true) {
        // A retry that finds the file STILL damaged must not forget that
        // this session is holding edits nothing has published: forgetting it
        // would make the next retry adopt the disk and silently discard
        // them. `refusedSave` is a fact about the session, not about the
        // inspection, so it survives a re-read.
        let hadPendingEdits = storeDamage?.refusedSave ?? false
        let inspection = inspect(storePath)
        switch inspection.state {
        case .absent:
            // Proven-absent (or nothing we can prove is there): a fresh
            // install has no servers, and an empty list IS the truth.
            lastInspection = inspection
            if adoptingDiskEntries { entries = [] }
            storeDamage = nil

        case .present:
            guard let data = inspection.bytes else {
                lastInspection = inspection
                if adoptingDiskEntries { entries = [] }
                storeDamage = nil
                return
            }
            do {
                let file = try JSONDecoder().decode(RegistryFile.self, from: data)
                lastInspection = inspection
                if adoptingDiskEntries { entries = file.entries }
                storeDamage = nil
            } catch {
                // We HELD the bytes but they are not a server list. Copy
                // them aside so the user (or a support session) can
                // recover the hosts by hand, then refuse: rebuilding from
                // empty here would publish `[]` over a recoverable file.
                let copy = GuardedJSONStore.quarantine(
                    data: data, path: storePath, transport: transport, label: Self.label
                )
                Self.logger.error(
                    "servers.json could not be decoded: \(error.localizedDescription, privacy: .public); refusing writes"
                )
                lastInspection = GuardedJSONStore.Inspection(
                    state: .unreadable(path: storePath), bytes: data, quarantineCopy: copy
                )
                storeDamage = StoreDamage(
                    path: storePath, quarantinePath: copy, refusedSave: hadPendingEdits
                )
            }

        case .unreadable(let path):
            // Stat-confirmed but unreadable twice, or zero bytes (Scarf
            // never writes an empty servers.json, so zero bytes is somebody
            // else's truncation). `entries` is deliberately left ALONE —
            // the old code's `entries = []` here is the whole bug.
            Self.logger.error(
                "servers.json at \(path, privacy: .public) is unreadable; keeping the in-memory list and refusing writes"
            )
            lastInspection = inspection
            storeDamage = StoreDamage(
                path: path, quarantinePath: inspection.quarantineCopy, refusedSave: hadPendingEdits
            )

        case .quarantined:
            // Unreachable: `damagePolicy == .refuseForever` reclassifies the
            // size-cap quarantine to `.unreadable` before we see it, which
            // is precisely the branch this file used to hand-roll. Kept
            // exhaustive rather than defaulted so a policy change surfaces
            // here as a compile-time decision.
            Self.logger.error("servers.json quarantine reached the writable branch; refusing writes")
            lastInspection = GuardedJSONStore.Inspection(
                state: .unreadable(path: storePath), bytes: inspection.bytes
            )
            storeDamage = StoreDamage(
                path: storePath, quarantinePath: inspection.quarantineCopy, refusedSave: hadPendingEdits
            )
        }
    }

    /// Publish the in-memory list, refusing when the last load was damage
    /// and keeping a one-deep `.bak` of the bytes being replaced (both are
    /// `GuardedJSONStore.write`'s job). Healthy-path bytes are unchanged:
    /// same envelope, same `[.prettyPrinted, .sortedKeys]` encoder, same
    /// atomic replace — `LocalTransport.unguardedWriteFile` is
    /// `Data.write(options: .atomic)` with the same `mkdir -p` the old code
    /// did by hand.
    /// What a `save()` actually did. Returned so the surfaces that report an
    /// outcome to the user (import, above) can report the REAL one instead
    /// of a fabricated success (GW-F6 / audit DI M7).
    enum SaveOutcome: Equatable {
        case saved
        /// The guard refused: the predecessor is damage. The edit lives in
        /// `entries` and the banner says so.
        case refused(String)
        /// The write was allowed and failed anyway — disk full, read-only
        /// volume, permissions (DI M5).
        case failed(String)

        var didPersist: Bool { self == .saved }

        var failureMessage: String? {
            switch self {
            case .saved: return nil
            case .refused(let m), .failed(let m): return m
            }
        }
    }

    @discardableResult
    private func save() -> SaveOutcome {
        do {
            let file = RegistryFile(schemaVersion: Self.currentSchemaVersion, entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try publish(data, to: storePath, after: lastInspection)
            // The file now provably holds exactly these bytes, so the next
            // save backs THEM up rather than re-reading.
            lastInspection = GuardedJSONStore.Inspection(state: .present, bytes: data)
            storeDamage = nil
            saveFailure = nil
            return .saved
        } catch let refusal as GuardedStoreError {
            // Not "failed to save" — REFUSED to save. The user's edit lives
            // in `entries` and the banner says so; retrying would only
            // overwrite a file nobody has read.
            Self.logger.error("Refusing to save servers.json: \(refusal.localizedDescription, privacy: .public)")
            storeDamage = StoreDamage(
                path: storePath,
                quarantinePath: storeDamage?.quarantinePath,
                refusedSave: true
            )
            return .refused(refusal.localizedDescription)
        } catch {
            // NOT a refusal — the guard said yes and the WRITE failed
            // (GW-F6 / audit DI M5). This was a bare log line, which made
            // "your servers are only in memory now" a silent state: no
            // banner, no alert, the edit still on screen. Unlike a refusal
            // there is nothing damaged to reload, so `storeDamage` stays
            // nil and this gets its own message and its own remedy.
            Self.logger.error("Failed to save servers.json: \(error.localizedDescription)")
            saveFailure = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }
}
