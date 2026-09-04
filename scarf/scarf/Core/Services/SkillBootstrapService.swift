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
        // Ahead of the bundle guard on purpose: removing a skill that
        // misinforms the agent doesn't depend on us having anything to
        // install, and a build whose bundled skills are missing is exactly
        // a build that shouldn't also skip the cleanup.
        pruneKnownBadSkills()

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

        var written = 0
        for skillDir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let skillName = skillDir.lastPathComponent
            do {
                if try installSkill(from: skillDir, named: skillName, transport: transport) {
                    written += 1
                }
            } catch {
                Self.logger.warning("couldn't bootstrap skill \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // ONE event per bootstrap run that actually wrote something, not one
        // per skill: this runs unattended on every launch, so a per-skill
        // `skill_installed` would drown the user-driven installs that share
        // that event name (and `"bundled"` is no longer part of
        // `skill_installed`'s vocabulary anywhere). A run that wrote nothing
        // — the steady state, every launch after the first — is silent,
        // matching the edge-triggered pattern the rest of the taxonomy uses.
        if let event = Self.bootstrapEvent(written: written) {
            Analytics.record(event)
        }
    }

    /// The one `skills_bootstrapped` event of a bootstrap run, or
    /// `nil` when the run wrote nothing and must stay silent. Pure, so the
    /// emit/don't-emit decision is testable — `Analytics.record` itself is a
    /// no-op under XCTest.
    nonisolated static func bootstrapEvent(written: Int) -> UsageEvent? {
        guard written > 0 else { return nil }
        return .skillsBootstrapped(countBucket: .init(count: written))
    }

    /// Coarse count bucket for `skills_bootstrapped`. Only ever called with
    /// `written > 0`, but `..<1` is mapped anyway so no caller can produce a
    /// token outside the documented three.
    nonisolated static func bootstrapCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1, 1: return "1"
        case 2...5: return "2_5"
        default: return "gt_5"
        }
    }

    // MARK: - Known-bad skills

    /// Skills that claim Scarf's name but describe a Scarf that doesn't
    /// exist, removed from the namespace this service owns on every
    /// bootstrap.
    ///
    /// `scarf-project-workflows` is the founding member: an installed
    /// skill (found on a user's machine 2026-09-03, predating the real
    /// bundled ones) documenting fabricated CLI verbs, a dashboard schema
    /// Scarf never rendered, and a link to an unrelated company that
    /// happens to share the name. It competed for activation with
    /// `scarf-template-author` on every project task, and an agent that
    /// won the coin flip wrote files Scarf couldn't read. Prose in a skill
    /// can't out-argue another skill; deleting it can.
    ///
    /// **Deliberately narrow.** Only exact directory-name matches, and
    /// only under the `scarf/` category directory this service writes
    /// (plus the legacy flat path it used to write, which
    /// `installSkill`'s migration also owns). A user's own skill of the
    /// same name would have to be sitting inside Scarf's namespace to be
    /// caught, and nothing outside `~/.hermes/skills/scarf/` is ever
    /// touched — the user's other skills, and every category folder Scarf
    /// didn't create, are none of this pass's business.
    nonisolated static let knownBadSkillNames: Set<String> = [
        "scarf-project-workflows",
    ]

    /// Delete every denylisted skill from the two locations this service
    /// owns. Failures are logged and skipped: a stale bad skill is worse
    /// than the alternative but not worth failing a launch over, and the
    /// next bootstrap tries again.
    /// - Returns: the directories actually removed, for the tests and the
    ///   log. Empty on the steady state — every launch after the first.
    ///
    /// **The flat level is not Scarf's to delete.** `~/.hermes/skills/<name>/`
    /// is where Hermes puts EVERY skill a user installs by hand — dozens of
    /// them on a working machine — and this pass ran there with nothing but a
    /// name to go on. A user who wrote their own `scarf-project-workflows`
    /// (a plausible name for a skill about Scarf) would have watched Scarf
    /// silently delete it at launch, with no undo and no mention. The
    /// namespace directory `~/.hermes/skills/scarf/` is Scarf's; the flat
    /// level is the user's, and a flat deletion now requires POSITIVE proof
    /// that the file there is one Scarf wrote (`isScarfAuthored`) rather than
    /// the absence of proof that it isn't.
    @discardableResult
    nonisolated func pruneKnownBadSkills() -> [String] {
        let transport = context.makeTransport()
        var removed: [String] = []
        let categorizedRoot = context.paths.skillsDir + "/" + Self.bundledSkillCategory
        for name in Self.knownBadSkillNames.sorted() {
            let flatDir = context.paths.skillsDir + "/" + name
            for dir in [categorizedRoot + "/" + name, flatDir] {
                guard transport.fileExists(dir) else { continue }
                if dir == flatDir, !Self.isScarfAuthoredSkill(at: dir, transport: transport) {
                    Self.logger.info(
                        "leaving \(dir, privacy: .public) alone — it isn't a Scarf-authored skill"
                    )
                    continue
                }
                do {
                    // The whole directory in ONE call, and deliberately
                    // before any walk of its children.
                    //
                    // Locally this is `FileManager.removeItem`, which
                    // handles a populated directory on its own AND unlinks
                    // a SYMLINK without following it. Walking children
                    // first would invert that: `listDirectory` resolves
                    // through a symlink, so a `scarf-project-workflows`
                    // that is a link into the user's own skills would have
                    // us deleting files on the far side of it — outside
                    // the namespace this pass is allowed to touch.
                    try transport.removeFile(dir)
                    removed.append(dir)
                    Self.logger.info(
                        "removed known-bad skill \(name, privacy: .public) from \(dir, privacy: .public)"
                    )
                } catch {
                    // SSH's `removeFile` is `rm -f`, which refuses a
                    // populated directory (and, being `-f` not `-r`, can
                    // never recurse anywhere it shouldn't). Empty it and
                    // retry — one level, because skills don't ship trees.
                    // A symlink never reaches here: `rm -f` unlinks it in
                    // the attempt above.
                    var recovered = false
                    if let entries = try? transport.listDirectory(dir) {
                        for entry in entries {
                            try? transport.removeFile(dir + "/" + entry)
                        }
                        if (try? transport.removeFile(dir)) != nil {
                            removed.append(dir)
                            recovered = true
                            Self.logger.info(
                                "removed known-bad skill \(name, privacy: .public) from \(dir, privacy: .public)"
                            )
                        }
                    }
                    if !recovered {
                        Self.logger.warning(
                            "couldn't remove known-bad skill \(name, privacy: .public) at \(dir, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
        return removed
    }

    /// Whether the skill directory at `dir` holds a SKILL.md that Scarf
    /// itself shipped.
    ///
    /// The signature is the pair of frontmatter fields every bundled skill
    /// carries and a third-party skill has no reason to: `author: Alan
    /// Wizemann` together with a homepage under this project's own
    /// repository. Both must be inside the frontmatter block, so a skill
    /// that merely mentions either in its prose doesn't qualify.
    ///
    /// Deliberately a POSITIVE test. The question at the flat level is never
    /// "can I rule out that this is the user's?" — it is "can I prove this is
    /// mine?", and anything short of proof leaves the directory alone.
    /// Symlinks: `readFile` follows one, so a link pointing into the user's
    /// own skills yields the user's SKILL.md, which fails this test and is
    /// spared.
    nonisolated static func isScarfAuthoredSkill(
        at dir: String,
        transport: any ServerTransport
    ) -> Bool {
        guard let data = try? transport.readFile(dir + "/SKILL.md"),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        var inFrontmatter = false
        var sawAuthor = false
        var sawHomepage = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter { inFrontmatter = true; continue }
                break
            }
            guard inFrontmatter else { break }
            if trimmed.hasPrefix("author:"),
               trimmed.dropFirst("author:".count)
                   .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) == "Alan Wizemann" {
                sawAuthor = true
            }
            if trimmed.contains("github.com/awizemann/scarf") { sawHomepage = true }
        }
        return sawAuthor && sawHomepage
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

    /// - Returns: `true` when this call actually wrote the skill (missing or
    ///   outdated destination), `false` when the installed copy was already
    ///   current and nothing was touched. The caller sums these into the one
    ///   `skills_bootstrapped` event.
    private nonisolated func installSkill(
        from sourceDir: URL,
        named skillName: String,
        transport: any ServerTransport
    ) throws -> Bool {
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

        // Same rule as `pruneKnownBadSkills`: the flat level is the user's,
        // and a name collision is not evidence of authorship. A flat copy
        // v2.7.0 installed carries Scarf's own frontmatter and still
        // migrates; a user's own skill that happens to share the name is
        // left where it is (they'll see it twice in the Skills view, which
        // is a great deal better than seeing it never again).
        if transport.fileExists(flatSkillMd), flatDir != destDir,
           Self.isScarfAuthoredSkill(at: flatDir, transport: transport) {
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
            return false
        }

        try transport.createDirectory(categorizedRoot)
        try transport.createDirectory(destDir)
        try transport.writeFile(destSkillMd, data: bundledData)

        // Carry any companion files (assets, examples, etc.) the skill
        // ships alongside SKILL.md. Walks one level deep — skills don't
        // ship deep trees today and wider compat for that can wait
        // until a use case appears.
        //
        // Companion failures are LOGGED, never thrown. `SKILL.md` is already
        // written at this point, so throwing here reported the whole install
        // as failed while leaving a perfectly good skill on disk — and since
        // the version check then said "current", the missing companions were
        // never retried on any later launch. A skill shipping a companion
        // SUBDIRECTORY made `Data(contentsOf:)` throw exactly that way.
        if let extras = try? FileManager.default.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in extras where url.lastPathComponent != "SKILL.md" {
                let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile ?? false
                guard isRegularFile else {
                    Self.logger.warning(
                        "skipping non-file companion \(url.lastPathComponent, privacy: .public) in bundled skill \(skillName, privacy: .public) — one level deep only"
                    )
                    continue
                }
                do {
                    try transport.writeFile(
                        destDir + "/" + url.lastPathComponent, data: try Data(contentsOf: url)
                    )
                } catch {
                    Self.logger.warning(
                        "couldn't install companion \(url.lastPathComponent, privacy: .public) for \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        Self.logger.info(
            "bootstrapped skill \(skillName, privacy: .public) at v\(bundledVersion, privacy: .public) (was: \(installedVersion ?? "missing", privacy: .public))"
        )
        return true
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

    /// Semver compare. Returns -1, 0, +1.
    ///
    /// The numeric core is compared component-wise, and — per semver §11 —
    /// a version WITH a prerelease tag ranks BELOW the same core without
    /// one. Splitting on "." alone got that exactly backwards: `2.0.0-rc1`
    /// became `["2", "0", "0-rc1"]`, whose last component compares
    /// lexicographically GREATER than `"0"`, so an installed release
    /// candidate outranked the finished `2.0.0` and the bundled skill was
    /// never installed over it — the one case this comparison exists to
    /// catch, since a prerelease is precisely what a shipped version
    /// replaces.
    ///
    /// Build metadata (`+sha`) is ignored, as semver requires.
    nonisolated static func semverCompare(_ a: String, _ b: String) -> Int {
        func split(_ version: String) -> (core: [String], prerelease: String?) {
            let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
            let core = (parts.first ?? "").split(separator: ".").map(String.init)
            return (core, parts.count > 1 ? parts[1] : nil)
        }
        let lhs = split(a)
        let rhs = split(b)

        for i in 0..<max(lhs.core.count, rhs.core.count) {
            let l = i < lhs.core.count ? lhs.core[i] : "0"
            let r = i < rhs.core.count ? rhs.core[i] : "0"
            if let li = Int(l), let ri = Int(r) {
                if li < ri { return -1 }
                if li > ri { return 1 }
            } else {
                if l < r { return -1 }
                if l > r { return 1 }
            }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return 0
        case (nil, _): return 1     // 2.0.0 > 2.0.0-rc1
        case (_, nil): return -1    // 2.0.0-rc1 < 2.0.0
        case (let l?, let r?):
            if l == r { return 0 }
            return l < r ? -1 : 1
        }
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
