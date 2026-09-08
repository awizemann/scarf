import Foundation
import ScarfCore

@Observable
final class MemoryViewModel {
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var memoryContent = ""
    var userContent = ""
    var memoryProvider = ""
    var profiles: [String] = []
    var activeProfile = ""
    var isLoading = false
    var isSaving = false
    /// The last READ failure, or `nil`. Set when a memory file is provably
    /// there but could not be read (GW-F2, audit DI H3): the previously
    /// published content stays on screen untouched rather than being
    /// replaced by the `""` a failed read used to produce. Cleared by the
    /// next successful load — `load()` runs on appear and on every watcher
    /// tick, so this can never wedge the editor.
    var loadError: String?

    enum EditTarget: Hashable {
        case memory, user
    }

    /// Result of a conflict-aware save. `.conflict` means the file on disk no
    /// longer matches the baseline the draft was branched from, so the write
    /// was NOT performed — the caller must offer reload-or-overwrite rather
    /// than silently winning the race.
    enum SaveOutcome: Equatable {
        case saved
        case conflict(onDisk: String)
        /// The guarded writer REFUSED, or the transport failed. The file on
        /// disk is untouched and the draft is still the user's — the old
        /// code swallowed both cases and reported `.saved`.
        case failed(message: String)
    }

    var memoryCharCount: Int { memoryContent.count }
    var userCharCount: Int { userContent.count }

    var hasExternalProvider: Bool {
        let stripped = memoryProvider
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return !stripped.isEmpty && stripped != "file"
    }

    var hasMultipleProfiles: Bool { !profiles.isEmpty }

    func load() {
        isLoading = true
        let svc = fileService
        let currentProfile = activeProfile
        // Sync transport calls would beach-ball the UI on remote — dispatch
        // off main, then commit results back on MainActor. v2.8: wrapped
        // in ScarfMon so we can see how many SSH RTTs this load actually
        // costs (4 sequential SFTP reads on the slow path).
        Task.detached { [weak self] in
            await ScarfMon.measureAsync(.diskIO, "memory.load") {
                let config = svc.loadConfig()
                let profiles = svc.loadMemoryProfiles()
                let profile = currentProfile.isEmpty ? config.memoryProfile : currentProfile
                // Each file independently: one unreadable file must not blank
                // the other, and NEITHER may be published as `""` from a
                // failure — the editor's conflict check reads these.
                let loaded = Self.readBoth(svc, profile: profile)
                let (memory, user, failure) = (loaded.memory, loaded.user, loaded.failure)
                let loadedBytes = (memory?.utf8.count ?? 0) + (user?.utf8.count ?? 0)
                ScarfMon.event(.diskIO, "memory.load.bytes", count: 0, bytes: loadedBytes)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.memoryProvider = config.memoryProvider
                    self.profiles = profiles
                    self.activeProfile = profile
                    if let memory { self.memoryContent = memory }
                    if let user { self.userContent = user }
                    self.loadError = failure
                    self.isLoading = false
                }
            }
        }
    }

    /// Read both memory files, each independently: one unreadable file must
    /// not blank the other, and NEITHER may be published as `""` from a
    /// failure — the editor's conflict check reads these (GW-F2).
    /// `nil` text means "not read", never "empty".
    private nonisolated static func readBoth(
        _ svc: HermesFileService, profile: String
    ) -> (memory: String?, user: String?, failure: String?) {
        var failure: String?
        var memory: String?
        var user: String?
        do { memory = try svc.loadMemory(profile: profile) }
        catch { failure = error.localizedDescription }
        do { user = try svc.loadUserProfile(profile: profile) }
        catch { failure = failure ?? error.localizedDescription }
        return (memory, user, failure)
    }

    func switchProfile(_ profile: String) {
        activeProfile = profile
        let svc = fileService
        Task.detached { [weak self] in
            let loaded = Self.readBoth(svc, profile: profile)
            let (memory, user, failure) = (loaded.memory, loaded.user, loaded.failure)
            await MainActor.run { [weak self] in
                if let memory { self?.memoryContent = memory }
                if let user { self?.userContent = user }
                self?.loadError = failure
            }
        }
    }

    /// Reads the on-disk copy of `target` for the active profile, off the main
    /// actor. Used by the editor to refresh a clean buffer on demand.
    ///
    /// `nil` means the read FAILED (GW-F2). The caller must not treat that as
    /// disk content: offering `""` as "the new version" to replace a draft is
    /// how a blip turned into a published empty file.
    func reload(_ target: EditTarget) async -> String? {
        let svc = fileService
        let profile = activeProfile
        // `(text, error)` rather than `Result`: the error is carried as a
        // Sendable message string, and `String` is not an `Error`.
        let outcome: (text: String?, message: String?) = await Task.detached {
            do {
                switch target {
                case .memory: return (try svc.loadMemory(profile: profile), nil)
                case .user:   return (try svc.loadUserProfile(profile: profile), nil)
                }
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value
        loadError = outcome.message
        return outcome.text
    }

    /// Conflict-aware write. Re-reads the file immediately before writing and
    /// refuses the write when it no longer matches `baseline` — the same merge
    /// discipline `BotAgentViewModel.saveSoul` uses for SOUL.md. `force: true`
    /// is the user's explicit "overwrite" answer to that conflict.
    ///
    /// This is the only write path: an unconditional save here is what let a
    /// watcher tick and a running agent trade blind last-write-wins over the
    /// user's draft.
    @discardableResult
    func save(_ text: String, target: EditTarget, baseline: String, force: Bool = false) async -> SaveOutcome {
        let svc = fileService
        let profile = activeProfile
        // Mapped HERE, on the main actor: `EditTarget`'s `Equatable`
        // conformance is main-actor-isolated, so comparing it inside the
        // detached body is a Swift 6 isolation error.
        let fileTarget: HermesFileService.MemoryFileTarget =
            target == .memory ? .memory : .userProfile
        isSaving = true
        defer { isSaving = false }

        let outcome: SaveOutcome = await Task.detached {
            // The conflict check MUST NOT run against a failed read (GW-F2,
            // audit DI H3). It used to compare the baseline against
            // `readFile ?? ""`, so one dropped round-trip presented as
            // `.conflict(onDisk: "")` — "the file changed to empty, reload to
            // take the new version" — and the reload-then-save published that
            // emptiness through the guard. A read that fails is now a
            // `.failed`, which moves nothing and keeps the draft.
            //
            // The check and the write are ONE lock hold now (GW-F3). They
            // used to be a read here and a write below, with the read's
            // proof threaded down — so even once config.yaml and .env got
            // serialized, a lock around the write alone would have left this
            // window open: the bytes the comparison passed were read before
            // the hold began, and a template install landing its memory
            // appendix in between would have been published away with a
            // `.bak` cut from the wrong pre-image. `saveMemoryFile` does the
            // comparison against a read taken UNDER the lock, and publishes
            // in the same hold. Still exactly one read on the healthy path.
            do {
                let result = try svc.saveMemoryFile(
                    text,
                    target: fileTarget,
                    profile: profile,
                    // `force` is the user's explicit "overwrite" answer to a
                    // conflict the UI already showed them.
                    ifMatches: force ? nil : baseline
                )
                switch result {
                case .saved: return .saved
                case .conflict(let onDisk): return .conflict(onDisk: onDisk)
                }
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }.value

        // Deliberately does NOT commit `text` into memoryContent/userContent.
        // The editor's draft baseline and this published copy have to move in
        // one step: publishing here first makes the view's `onChange` observer
        // run while the draft still carries the OLD baseline, which reads as a
        // conflict against the write we just made ourselves. The caller
        // commits, after it has advanced the baseline.
        return outcome
    }
}
