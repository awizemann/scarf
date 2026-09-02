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
                let memory = svc.loadMemory(profile: profile)
                let user = svc.loadUserProfile(profile: profile)
                ScarfMon.event(.diskIO, "memory.load.bytes", count: 0, bytes: memory.utf8.count + user.utf8.count)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.memoryProvider = config.memoryProvider
                    self.profiles = profiles
                    self.activeProfile = profile
                    self.memoryContent = memory
                    self.userContent = user
                    self.isLoading = false
                }
            }
        }
    }

    func switchProfile(_ profile: String) {
        activeProfile = profile
        let svc = fileService
        Task.detached { [weak self] in
            let memory = svc.loadMemory(profile: profile)
            let user = svc.loadUserProfile(profile: profile)
            await MainActor.run { [weak self] in
                self?.memoryContent = memory
                self?.userContent = user
            }
        }
    }

    /// Reads the on-disk copy of `target` for the active profile, off the main
    /// actor. Used by the editor to refresh a clean buffer on demand.
    func reload(_ target: EditTarget) async -> String {
        let svc = fileService
        let profile = activeProfile
        return await Task.detached {
            switch target {
            case .memory: return svc.loadMemory(profile: profile)
            case .user:   return svc.loadUserProfile(profile: profile)
            }
        }.value
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
        isSaving = true
        defer { isSaving = false }

        let outcome: SaveOutcome = await Task.detached {
            if !force {
                let current: String
                switch target {
                case .memory: current = svc.loadMemory(profile: profile)
                case .user:   current = svc.loadUserProfile(profile: profile)
                }
                guard current == baseline else { return .conflict(onDisk: current) }
            }
            switch target {
            case .memory: svc.saveMemory(text, profile: profile)
            case .user:   svc.saveUserProfile(text, profile: profile)
            }
            return .saved
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
