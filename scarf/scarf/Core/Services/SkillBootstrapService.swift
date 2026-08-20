import Foundation
import os
import ScarfCore

/// Copies skills shipped inside the app bundle into the user's
/// `~/.hermes/skills/` so they're always available without the user
/// having to install a template first. Idempotent + version-gated:
/// skips when the destination is the same version, copies on missing
/// or older, leaves a user-edited newer destination alone.
///
/// **Why this exists.** The "New Project from Scratch" wizard hands
/// off to the agent and expects it to invoke `scarf-template-author`,
/// which is the comprehensive interview-and-scaffold skill. That skill
/// is currently distributed as part of the `awizemann/template-author`
/// template — so installing the wizard's skill story with "first install
/// this template" would be a worse first-run experience than today's.
/// Bootstrapping it from the app bundle decouples the skill's
/// availability from any one template install.
///
/// **What gets bootstrapped.** Every subdirectory of
/// `Bundle.main/Resources/Skills/` is treated as one skill (its name
/// is the directory name). Currently that's just
/// `scarf-template-author`; future built-in skills can drop their dir
/// next to it and be picked up automatically.
struct SkillBootstrapService: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "SkillBootstrapService")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Walk every skill in the app bundle and ensure its installed
    /// copy at `~/.hermes/skills/<name>/` is at least the bundled
    /// version. Throws on transport failures (e.g. a missing
    /// `~/.hermes` for a remote without one set up); callers should
    /// log and continue — a failed bootstrap shouldn't block app
    /// launch.
    nonisolated func ensureBundledSkillsInstalled() throws {
        guard let bundleSkillsDir = Self.bundleSkillsDir() else {
            Self.logger.info("no bundled Skills/ directory; skipping bootstrap")
            return
        }
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: bundleSkillsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.logger.warning("couldn't list bundled skills dir: \(error.localizedDescription, privacy: .public)")
            return
        }

        let transport = context.makeTransport()
        let destRoot = context.paths.skillsDir
        try transport.createDirectory(destRoot)

        for skillDir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let skillName = skillDir.lastPathComponent
            do {
                try installSkill(from: skillDir, named: skillName, transport: transport)
            } catch {
                Self.logger.warning("couldn't bootstrap skill \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Per-skill install

    /// Hermes treats `~/.hermes/skills/<dir>/` as either a category folder
    /// containing skill subdirectories OR a skill itself; Scarf's
    /// `SkillsScanner` only recognizes the two-level layout
    /// (`<category>/<skill>/SKILL.md`). v2.7.0 of this service installed
    /// bundled skills FLAT (`~/.hermes/skills/<skill>/SKILL.md`), which
    /// Hermes accepts (so the agent still loaded them) but Scarf's
    /// Skills view ignored — leaving users wondering why
    /// `scarf-template-author` was missing from the GUI. v2.10.1 fixes
    /// the layout by installing under a `scarf/` category folder
    /// (`~/.hermes/skills/scarf/<skill>/SKILL.md`) and migrating any
    /// flat install in place. The migration is one-way; once the user
    /// is on the new layout, the flat path is never re-created.
    private nonisolated static let bundledSkillCategory = "scarf"

    private nonisolated func installSkill(
        from sourceDir: URL,
        named skillName: String,
        transport: any ServerTransport
    ) throws {
        // Migration: if a prior Scarf version installed this skill at
        // the flat top-level path, remove it before writing the new
        // categorized copy. Safe because the flat path was always
        // a Scarf-owned bootstrap target — never a user-authored
        // skill — so we're not stomping on user edits.
        let flatDir = context.paths.skillsDir + "/" + skillName
        let flatSkillMd = flatDir + "/SKILL.md"
        let categorizedRoot = context.paths.skillsDir + "/" + Self.bundledSkillCategory
        let destDir = categorizedRoot + "/" + skillName
        let destSkillMd = destDir + "/SKILL.md"

        if transport.fileExists(flatSkillMd) && flatDir != destDir {
            do {
                try transport.removeFile(flatSkillMd)
                // Best-effort cleanup of companion files + the now-empty
                // directory. Failures here are non-fatal — leaving a
                // stale dir is benign (SkillsScanner ignores it because
                // it has no SKILL.md inside any subdirectory).
                if let companions = try? transport.listDirectory(flatDir) {
                    for entry in companions where entry != "SKILL.md" {
                        try? transport.removeFile(flatDir + "/" + entry)
                    }
                }
                try? transport.removeFile(flatDir)
                Self.logger.info(
                    "migrated flat skill install \(skillName, privacy: .public) → \(Self.bundledSkillCategory)/ category"
                )
            } catch {
                Self.logger.warning(
                    "couldn't remove flat skill install for \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public); install will continue but Skills view may show duplicates until the flat copy is removed manually"
                )
            }
        }

        let bundledSkillMd = sourceDir.appendingPathComponent("SKILL.md")
        let bundledData = try Data(contentsOf: bundledSkillMd)
        let bundledVersion = Self.parseVersion(bundledData) ?? "0.0.0"

        let installedVersion: String? = {
            guard transport.fileExists(destSkillMd) else { return nil }
            guard let data = try? transport.readFile(destSkillMd) else { return nil }
            return Self.parseVersion(data)
        }()

        // Only copy when the destination is missing OR older than the
        // bundled copy. A user with a newer hand-edited skill keeps
        // their version untouched.
        if let installed = installedVersion,
           Self.semverCompare(installed, bundledVersion) >= 0 {
            Self.logger.info(
                "skill \(skillName, privacy: .public) at \(installed, privacy: .public) is current (bundled: \(bundledVersion, privacy: .public)); skipping"
            )
            return
        }

        try transport.createDirectory(categorizedRoot)
        try transport.createDirectory(destDir)
        try transport.writeFile(destSkillMd, data: bundledData)
        // Only the actual write above counts as an install — the
        // early-return above (destination already current) is
        // deliberately silent, matching `hermes_control_action`'s
        // edge-triggered pattern: report the transition, not every check.
        Analytics.record("skill_installed", props: ["source": "bundled"])

        // Carry any companion files (assets, examples, etc.) the skill
        // ships alongside SKILL.md. Walks one level deep — skills don't
        // ship deep trees today and wider compat for that can wait
        // until a use case appears.
        if let extras = try? FileManager.default.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in extras where url.lastPathComponent != "SKILL.md" {
                let data = try Data(contentsOf: url)
                let dest = destDir + "/" + url.lastPathComponent
                try transport.writeFile(dest, data: data)
            }
        }

        Self.logger.info(
            "bootstrapped skill \(skillName, privacy: .public) at v\(bundledVersion, privacy: .public) (was: \(installedVersion ?? "missing", privacy: .public))"
        )
    }

    // MARK: - Frontmatter version parse

    /// Pull the `version: X.Y.Z` value from a SKILL.md's YAML
    /// frontmatter. Returns nil when no version line is present so
    /// the caller can treat the destination as "unknown" and replace
    /// it with the bundled copy on the safe side.
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

    /// Three-component numeric semver compare. Returns -1, 0, +1.
    /// Non-numeric components fall back to lexicographic — fine for
    /// the conservative "skip if installed >= bundled" use case.
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

    /// Locate the bundled-skills directory inside the app bundle.
    /// We ship skills inside a `.bundle` folder so Xcode preserves the
    /// internal directory structure (a plain folder of resources gets
    /// flattened by `PBXFileSystemSynchronizedRootGroup`). The
    /// `BuiltinSkills.bundle` is then walked at runtime exactly like
    /// any directory of `<skill-name>/SKILL.md` entries. Returns nil
    /// when the app wasn't bundled with skills (unit test hosts,
    /// local dev runs against a stripped-down bundle).
    nonisolated private static func bundleSkillsDir() -> URL? {
        Bundle.main.url(forResource: "BuiltinSkills", withExtension: "bundle")
    }
}
