import Foundation
import os
import ScarfCore

/// Copies global Scarf slash commands shipped inside the app bundle into
/// `~/.hermes/scarf/slash-commands/` so they're available in every chat
/// without the user having to author them per-project. Idempotent +
/// version-gated: skips when the destination is at or above the bundled
/// version, copies on missing or older, leaves a user-edited newer
/// destination alone.
///
/// **Why this exists.** Per-project slash commands (the original
/// `ProjectSlashCommandService` path) require the user to be in a project
/// chat to see them. The Scarf-specific helper commands (`/scarf-new`,
/// `/scarf-help`, `/scarf-dashboard`, `/scarf-cron`, `/scarf-export`,
/// `/scarf-widget`) are useful from any chat — including pre-session and
/// non-project chats — so they need a global store. This service is the
/// twin of `SkillBootstrapService` for the slash-command side; both run
/// on launch from `scarfApp.init`.
///
/// **What gets bootstrapped.** Every `.md` file at the top level of
/// `Bundle.main/Resources/BuiltinSlashCommands.bundle/` is treated as one
/// command. The file's basename (without `.md`) determines the slash
/// command name and the on-disk filename. Currently ships six
/// `scarf-*` commands; new commands can drop into the same bundle dir
/// and be picked up automatically.
///
/// **Version comparison.** The frontmatter `version: X.Y.Z` is the source
/// of truth. A bundled v1.1.0 will overwrite an installed v1.0.0; a
/// bundled v1.0.0 won't overwrite an installed v1.1.0 (so a user who
/// hand-edited the command keeps their version). Missing frontmatter
/// `version` falls back to "0.0.0".
struct SlashCommandBootstrapService: Sendable {
    private nonisolated static let logger = Logger(
        subsystem: "com.scarf",
        category: "SlashCommandBootstrapService"
    )

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Walk every `.md` command in the app bundle and ensure its installed
    /// copy at `~/.hermes/scarf/slash-commands/<name>.md` is at least the
    /// bundled version. Throws on transport failures (e.g. a missing
    /// `~/.hermes` for a remote without one set up); callers should log
    /// and continue — a failed bootstrap shouldn't block app launch.
    nonisolated func ensureBundledCommandsInstalled() throws {
        guard let bundleCommandsDir = Self.bundleCommandsDir() else {
            Self.logger.info("no bundled SlashCommands/ directory; skipping bootstrap")
            return
        }
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: bundleCommandsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.logger.warning(
                "couldn't list bundled slash-commands dir: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let transport = context.makeTransport()
        let destRoot = context.paths.globalSlashCommandsDir
        try transport.createDirectory(destRoot)

        for commandFile in entries where commandFile.pathExtension.lowercased() == "md" {
            let commandName = commandFile.deletingPathExtension().lastPathComponent
            do {
                try installCommand(
                    from: commandFile,
                    named: commandName,
                    transport: transport
                )
            } catch {
                Self.logger.warning(
                    "couldn't bootstrap slash command \(commandName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Per-command install

    /// `internal` (not `private`) for the same reason
    /// `SkillBootstrapService.installSkill` is: GW-E2c's skip-on-unreadable
    /// case needs to be reachable without a populated app bundle.
    nonisolated func installCommand(
        from sourceFile: URL,
        named commandName: String,
        transport: any ServerTransport
    ) throws {
        let destPath = context.paths.globalSlashCommandsDir + "/" + commandName + ".md"

        let bundledData = try Data(contentsOf: sourceFile)
        let bundledVersion = Self.parseVersion(bundledData) ?? "0.0.0"

        // **Proof, not inference (GW-E2c)** — the same conversion, for the
        // same reason, as `SkillBootstrapService`'s version gate: a failed
        // read used to read as "missing" and downgrade the user's
        // hand-edited command to the bundled copy, permanently (the version
        // check then said "current" on every later launch).
        let guarded = GuardedJSONStore(transport: transport, label: "slash command")
        var inspection = guarded.inspect(destPath, maxBytes: SkillBootstrapService.maxBootstrapBytes)
        // GW-F6 / audit DI L2. `GuardedJSONStore`'s "zero bytes is damage"
        // rule is right for a JSON sidecar Scarf never writes empty — but
        // this destination is MARKDOWN, and `GuardedTextFile`'s rule 1 is
        // the one that applies: an empty markdown file is a legal thing a
        // person (or a truncating editor) made, and it has nothing to lose.
        // Left as damage it was permanently un-bootstrappable: the file
        // read as unreadable, the install skipped, and no later launch ever
        // repaired a BUNDLED file the user had zeroed.
        if case .unreadable = inspection.state, inspection.bytes?.isEmpty == true {
            inspection = GuardedJSONStore.Inspection(state: .absent, bytes: nil)
        }
        let installedVersion: String?
        switch inspection.state {
        case .absent:
            installedVersion = nil
        case .unreadable(let damaged):
            Self.logger.warning(
                "slash command \(commandName, privacy: .public) at \(damaged, privacy: .public) exists but couldn't be read; skipping the bootstrap rather than replacing a file we can't see"
            )
            return
        case .quarantined:
            Self.logger.warning(
                "slash command \(commandName, privacy: .public) at \(destPath, privacy: .public) is past the bootstrap size cap; skipping"
            )
            return
        case .present:
            installedVersion = Self.parseVersion(inspection.bytes ?? Data())
        }

        // Only copy when the destination is missing OR older than the
        // bundled copy. A user with a newer hand-edited command keeps
        // their version untouched.
        if let installed = installedVersion,
           Self.semverCompare(installed, bundledVersion) >= 0 {
            Self.logger.info(
                "slash command \(commandName, privacy: .public) at v\(installed, privacy: .public) is current (bundled: v\(bundledVersion, privacy: .public)); skipping"
            )
            return
        }

        // Guarded publish — one-deep `<name>.md.bak` of the version being
        // upgraded away from.
        try guarded.write(bundledData, to: destPath, after: inspection)

        Self.logger.info(
            "bootstrapped slash command \(commandName, privacy: .public) at v\(bundledVersion, privacy: .public) (was: \(installedVersion ?? "missing", privacy: .public))"
        )
    }

    // MARK: - Frontmatter version parse
    //
    // Mirrors `SkillBootstrapService`'s parser so the version-gating
    // semantics are identical. Slash command frontmatter looks like:
    //
    //   ---
    //   name: scarf-help
    //   description: …
    //   version: 1.0.0
    //   ---
    //
    // The slash-command body parser (`ProjectSlashCommandService.parse`)
    // doesn't read `version` itself — we only need it here for the
    // bootstrap upgrade decision.

    nonisolated static func parseVersion(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var inFrontmatter = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter {
                    inFrontmatter = true
                    continue
                } else {
                    return nil
                }
            }
            guard inFrontmatter else { return nil }
            if trimmed.hasPrefix("version:") {
                let value = trimmed
                    .dropFirst("version:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    nonisolated static func semverCompare(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map { String($0) }
        let rhs = b.split(separator: ".").map { String($0) }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : "0"
            let r = i < rhs.count ? rhs[i] : "0"
            if let li = Int(l), let ri = Int(r) {
                if li < ri { return -1 }
                if li > ri { return 1 }
            } else {
                if l < r { return -1 }
                if l > r { return 1 }
            }
        }
        return 0
    }

    // MARK: - Bundle access

    nonisolated private static func bundleCommandsDir() -> URL? {
        Bundle.main.url(forResource: "BuiltinSlashCommands", withExtension: "bundle")
    }
}
