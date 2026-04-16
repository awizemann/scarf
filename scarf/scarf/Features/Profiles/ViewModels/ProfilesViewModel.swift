import Foundation
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
    private let fileService = HermesFileService()

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

    func switchTo(_ profile: HermesProfile) {
        runAndReload(["profile", "use", profile.name], success: "Active profile set to \(profile.name)")
    }

    func create(name: String, cloneConfig: Bool, cloneAll: Bool) {
        var args = ["profile", "create", name]
        if cloneAll { args.append("--clone-all") }
        else if cloneConfig { args.append("--clone") }
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

    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            await MainActor.run {
                self.message = result.exitCode == 0 ? success : "Failed: \(result.output.prefix(120))"
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
