import AppKit
import Foundation
import ScarfCore
import os

struct HermesProfile: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let isActive: Bool
    let path: String
}

@Observable
final class ProfilesViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProfilesViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var profiles: [HermesProfile] = []
    var activeName: String = "default"
    var isLoading = false
    var message: String?
    var detailOutput: String = ""

    func load() {
        isLoading = true
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["profile", "list"], timeout: 20)
            let (parsed, active) = Self.parseProfileList(result.output)
            await MainActor.run {
                self.isLoading = false
                self.profiles = parsed
                self.activeName = active
            }
        }
    }

    func showDetail(_ profile: HermesProfile) {
        detailOutput = "Loading…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["profile", "show", profile.name], timeout: 15)
            await MainActor.run {
                self.detailOutput = result.output
            }
        }
    }

    /// Set the active profile via `hermes profile use <name>` without
    /// relaunching Scarf. Most users will reach for `switchAndRelaunch`
    /// instead — kept here so the context-menu "Use" item stays
    /// functional and so callers that genuinely want a no-relaunch
    /// switch (tests, scripted setups) have a path. Invalidates the
    /// resolver cache on success so the next `context.paths` access
    /// picks up the new home directory.
    func switchTo(_ profile: HermesProfile) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["profile", "use", profile.name], timeout: 60)
            await MainActor.run {
                if result.exitCode == 0 {
                    HermesProfileResolver.invalidateCache()
                    self.message = "Active profile set to \(profile.name) — restart Scarf to refresh."
                } else {
                    self.message = Self.failureMessage(result.output)
                }
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    /// Set the active profile and immediately relaunch Scarf. The
    /// canonical user-facing switch path (issue #70): a fresh process
    /// guarantees every service constructs from the new
    /// `~/.hermes/active_profile` value, sidestepping any in-process
    /// state that might still be holding the previous profile's
    /// data. Failures fall back to a "restart manually" toast.
    @MainActor
    func switchAndRelaunch(_ profile: HermesProfile) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["profile", "use", profile.name], timeout: 30)
            await MainActor.run {
                guard result.exitCode == 0 else {
                    self.message = Self.failureMessage(result.output)
                    self.load()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.message = nil
                    }
                    return
                }
                HermesProfileResolver.invalidateCache()
                do {
                    try AppRelauncher.relaunch()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.terminate(nil)
                    }
                } catch AppRelauncher.RelaunchError.debugBuild {
                    self.message = "Profile switched to \(profile.name). Restart Scarf manually (Xcode-launched instance)."
                    self.load()
                } catch {
                    self.message = "Profile switched to \(profile.name). Please quit and reopen Scarf manually."
                    self.load()
                }
            }
        }
    }

    func create(name: String, cloneConfig: Bool, cloneAll: Bool, noSkills: Bool = false) {
        var args = ["profile", "create", name]
        if cloneAll { args.append("--clone-all") }
        else if cloneConfig { args.append("--clone") }
        // v0.13+: Empty-profile creation. The wire is independent of
        // --clone / --clone-all per the v0.13 release notes — the user
        // can stack `--clone --no-skills` to clone config but skip
        // skills, which is a plausible workflow. The UI still disables
        // the toggle under --clone-all (Decision H, see ProfilesView)
        // but the wire is permissive.
        if noSkills { args.append("--no-skills") }
        runAndReload(args, success: "Profile '\(name)' created")
    }

    func rename(_ profile: HermesProfile, to newName: String) {
        runAndReload(["profile", "rename", profile.name, newName], success: "Renamed")
    }

    func delete(_ profile: HermesProfile) {
        runAndReload(["profile", "delete", profile.name], success: "Deleted \(profile.name)")
    }

    func export(_ profile: HermesProfile, to path: String) {
        runAndReload(["profile", "export", profile.name, "--output", path], success: "Exported")
    }

    func `import`(from path: String) {
        runAndReload(["profile", "import", path], success: "Imported")
    }

    /// The one useful line out of a CLI failure. Hermes is Python, so a
    /// crash arrives as a traceback whose *last* line is the actual error —
    /// the first 120 characters are just "Traceback (most recent call
    /// last):" and stack frames (gh#131). Same reduction as Sessions export.
    static func failureMessage(_ output: String) -> String {
        let last = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let last, !last.isEmpty else { return "Failed (no output)." }
        return "Failed: \(last.prefix(200))"
    }

    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            await MainActor.run {
                self.message = result.exitCode == 0 ? success : Self.failureMessage(result.output)
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    /// Parse `hermes profile list` output. Hermes emits a box-drawn Rich table:
    ///
    ///     Profile         Model    Gateway    Alias
    ///     ─────────────── ──────── ────────── ─────
    ///     ◆default        —        running    —
    ///     experimental    gpt-4    stopped    hermes-exp
    ///
    /// Active profiles are prefixed with `◆` (U+25C6). Columns are separated by
    /// whitespace; there are no vertical bars. We ignore box-drawing lines and
    /// the header row, then extract the name from column 0 of each data row.
    nonisolated private static func parseProfileList(_ output: String) -> (profiles: [HermesProfile], active: String) {
        var results: [HermesProfile] = []
        var active = "default"
        var sawHeader = false

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Box-drawing separator rows: contain only ─ (U+2500) and whitespace.
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) { continue }
            // Header row (first non-empty, non-separator line in the table).
            if !sawHeader && line.lowercased().contains("profile") && line.lowercased().contains("gateway") {
                sawHeader = true
                continue
            }
            // Data row. Strip active marker first.
            var working = line
            var isActive = false
            if working.hasPrefix("◆") {
                isActive = true
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if working.hasPrefix("*") {
                isActive = true
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let tokens = working.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let nameStr = tokens.first else { continue }
            // Reject rows whose first token is something like "Tip:" or a localized
            // label — real profile names are lowercase alphanumeric with - or _.
            guard nameStr.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { continue }
            if isActive { active = nameStr }
            results.append(HermesProfile(name: nameStr, isActive: isActive, path: ""))
        }
        return (results, active)
    }
}
