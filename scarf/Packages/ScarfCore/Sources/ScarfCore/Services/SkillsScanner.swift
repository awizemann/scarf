import Foundation
import os

/// Finds every installed skill under `~/.hermes/skills/` the way Hermes
/// does, and groups them into `HermesSkillCategory` buckets for the
/// Skills tab, the cron skill picker and the template exporter. Shared by
/// iOS and Mac; reads through the supplied transport.
///
/// **Discovery mirrors Hermes (S10-F1).** A skill is any directory holding
/// a `SKILL.md`, at any depth — `iter_skill_index_files` is an `os.walk`
/// (`agent/skill_utils.py:783-800` @ v2026.9.24). So all three layouts
/// Hermes actually produces are recognised:
///
/// * flat, `skills/<name>/SKILL.md` — the default for hub installs, which
///   Scarf always runs with `--yes` and no category
///   (`hermes_cli/skills_hub.py:700-708`);
/// * two-level, `skills/<category>/<name>/SKILL.md` — bundled skills;
/// * deep, `skills/mlops/research/dspy/SKILL.md` — official hub skills keep
///   every segment between `official` and the slug (`:706-708`).
///
/// This used to walk exactly two levels and never looked for `SKILL.md`,
/// so flat and deep skills were missing and their `references/` /
/// `scripts/` folders showed up as fake skills.
///
/// Pruning follows the same walk: `EXCLUDED_SKILL_DIRS` everywhere, the
/// support folders (`references`, `templates`, `assets`, `scripts`) only
/// inside a skill root, and the token-gated `_org/` mirror only for the
/// org named in `_org/.active_org`. Hermes keeps walking below a skill
/// root, so a skill nested inside another skill is found too.
///
/// **Naming.** `id` is the path relative to `skills/` (`dspy`,
/// `creative/pixel-art`, `mlops/research/dspy`) — `skill_view` and cron's
/// `--skill` accept that form (`tools/skills_tool.py:575-577`), and it is
/// unique where bare names may not be. `name` is the skill's directory
/// name (the lock-file / CLI name). `category` is everything between
/// `skills/` and the skill directory — the same thing `--category` means
/// at install time and what `skills update` derives from the install path
/// (`skills_hub.py:889-892`) — and is empty for a flat skill.
///
/// Synchronous + transport-backed: callers running on the MainActor
/// should wrap in `Task.detached` (the iOS pattern) since SFTP `stat` /
/// `listDirectory` calls block. Each directory costs one listing plus one
/// batched `statAll`.
public enum SkillsScanner: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "SkillsScanner")

    /// `EXCLUDED_SKILL_DIRS`, `agent/skill_utils.py:23-27` @ v2026.9.24.
    static let excludedDirs: Set<String> = [
        ".git", ".github", ".hub", ".archive", ".curator_backups", ".locks",
        ".venv", "venv", "node_modules", "site-packages", "__pycache__",
        ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]

    /// `SKILL_SUPPORT_DIRS`, `agent/skill_utils.py:31` — pruned only inside
    /// a directory that itself holds `SKILL.md`.
    static let supportDirs: Set<String> = ["references", "templates", "assets", "scripts"]

    /// `ORG_MIRROR_DIR_NAME` / `ORG_ACTIVE_MARKER`, `agent/skill_utils.py:36-37`.
    static let orgMirrorDir = "_org"
    static let orgActiveMarker = ".active_org"

    /// Hermes walks with `followlinks=True` and no depth limit. A symlink
    /// loop would spin forever over SSH, so stop well past any real layout.
    static let maxDepth = 12

    public static func scan(
        context: ServerContext,
        transport: any ServerTransport,
        disabledNames: Set<String> = [],
        pinnedNames: Set<String> = []
    ) -> [HermesSkillCategory] {
        let root = context.paths.skillsDir
        // Fresh install: skills/ may not exist yet — return [] without
        // logging an error.
        guard transport.fileExists(root) else { return [] }

        // `read_active_org_id`: the marker's trimmed text, or no org at all.
        let activeOrg: String? = {
            let marker = root + "/" + orgMirrorDir + "/" + orgActiveMarker
            guard let data = try? transport.readFile(marker),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        var found: [HermesSkill] = []

        /// One directory of the walk. `relative` is the path below
        /// `skills/` (empty at the root).
        func walk(_ dir: String, relative: [String]) {
            guard relative.count <= maxDepth,
                  let entries = try? transport.listDirectory(dir)
            else { return }
            let paths = entries.map { dir + "/" + $0 }
            // One round trip for the whole level on SSH; `nil` means the
            // batch can't be trusted, so ask one path at a time instead.
            let stats = transport.statAll(paths) ?? Dictionary(
                uniqueKeysWithValues: paths.compactMap { p in transport.stat(p).map { (p, $0) } }
            )
            let isDir: (String) -> Bool = { stats[dir + "/" + $0]?.isDirectory == true }
            let hasSkillMD = entries.contains { $0 == "SKILL.md" && !isDir($0) }

            if hasSkillMD, let name = relative.last {
                found.append(makeSkill(
                    path: dir,
                    relative: relative,
                    name: name,
                    entries: entries,
                    transport: transport,
                    disabledNames: disabledNames,
                    pinnedNames: pinnedNames
                ))
            }

            for entry in entries.sorted() where isDir(entry) {
                if excludedDirs.contains(entry) { continue }
                if hasSkillMD && supportDirs.contains(entry) { continue }
                // Org mirrors are token-gated: `_org/` is walked only when a
                // marker names an org, and then only that org's subdir.
                if relative.isEmpty && entry == orgMirrorDir && activeOrg == nil { continue }
                if relative == [orgMirrorDir] && entry != activeOrg { continue }
                walk(dir + "/" + entry, relative: relative + [entry])
            }
        }
        walk(root, relative: [])

        // Group by category, flat skills (empty category) first — the same
        // order `sorted()` on the category names gives.
        let grouped = Dictionary(grouping: found, by: \.category)
        return grouped.keys.sorted().map { key in
            HermesSkillCategory(
                id: key,
                name: key,
                skills: grouped[key, default: []].sorted { $0.id < $1.id }
            )
        }
    }

    private static func makeSkill(
        path: String,
        relative: [String],
        name: String,
        entries: [String],
        transport: any ServerTransport,
        disabledNames: Set<String>,
        pinnedNames: Set<String>
    ) -> HermesSkill {
        let files = entries
            .filter { !$0.hasPrefix(".") }
            // Guard artifacts, not skill content: the guarded
            // writers keep a one-deep `<name>.bak` beside what
            // they replace (GW-E2c gave the skill bootstrap
            // one) and copy unusable bytes aside as
            // `<name>.corrupt-<stamp>`. Listing either would
            // put a second, stale copy of every upgraded or
            // damaged skill in the file picker — and the
            // `.corrupt-` one is worse than the `.bak`: it is
            // the file the user is being told is broken,
            // offered back to them as editable content
            // (GW-F5 / SEC F5, DI L3).
            .filter { !isGuardArtifact($0) }
            .sorted()
        // The listing is already in hand, so skip the read (an SSH round
        // trip) for the common skill that ships no `skill.yaml`.
        let requiredConfig = entries.contains("skill.yaml")
            ? readRequiredConfig(yamlPath: path + "/skill.yaml", transport: transport)
            : []
        // v2.5 Hermes v0.11 SKILL.md frontmatter
        // (allowed_tools, related_skills, dependencies).
        // Opportunistic read — skills without those fields keep nil, and
        // the chip rows hide themselves.
        let v011 = readV011Fields(
            mdPath: path + "/SKILL.md",
            transport: transport
        )
        return HermesSkill(
            id: relative.joined(separator: "/"),
            name: name,
            category: relative.dropLast().joined(separator: "/"),
            path: path,
            files: files,
            requiredConfig: requiredConfig,
            allowedTools: v011.allowedTools,
            relatedSkills: v011.relatedSkills,
            dependencies: v011.dependencies,
            enabled: !disabledNames.contains(name),
            pinned: pinnedNames.contains(name)
        )
    }

    /// Is this filename something one of Scarf's guarded writers left
    /// beside a real file, rather than skill content?
    ///
    /// Two shapes, matching what the guards actually produce: the one-deep
    /// `<name>.bak`, and the quarantine copy `<name>.corrupt-<stamp>` —
    /// which is an INFIX, not a suffix, because the stamp (and an optional
    /// `-<uuid8>` collision tiebreaker) follows it. `internal` so the scan
    /// tests can pin both shapes without going through a filesystem.
    static func isGuardArtifact(_ name: String) -> Bool {
        name.hasSuffix(".bak") || name.contains(".corrupt-")
    }

    private static func readRequiredConfig(yamlPath: String, transport: any ServerTransport) -> [String] {
        guard let data = try? transport.readFile(yamlPath),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return SkillFrontmatterParser.parseRequiredConfig(content)
    }

    /// Read SKILL.md (Hermes v2026.4.23+) and parse its YAML frontmatter
    /// for the v0.11 fields. Nil-everything when the file is absent or
    /// has no frontmatter — fully back-compatible with older skills.
    private static func readV011Fields(
        mdPath: String,
        transport: any ServerTransport
    ) -> (allowedTools: [String]?, relatedSkills: [String]?, dependencies: [String]?) {
        guard let data = try? transport.readFile(mdPath),
              let content = String(data: data, encoding: .utf8)
        else { return (nil, nil, nil) }
        return SkillFrontmatterParser.parseV011Fields(content)
    }
}
