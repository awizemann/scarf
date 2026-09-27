import Testing
import Foundation
@testable import ScarfCore

/// R06 (Hermes v0.21.5 audit, S10): the installed-skills scan, the curator
/// pin source, and the shared plugin directory walk. Every case builds a
/// real scratch Hermes home and reads it back through `LocalTransport`, so
/// the walk, the stat batching and the file reads are all exercised.
@Suite("Skills & plugins readers (R06)")
struct SkillsPluginsR06Tests {

    private static func scratchHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Write `text` at `relative` below `home`, creating parents.
    private static func put(_ relative: String, in home: URL, _ text: String = "x") throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func skillMD(_ name: String) -> String {
        "---\nname: \(name)\ndescription: test\n---\n# \(name)\n"
    }

    private static func scan(_ home: URL, pinned: Set<String> = [], disabled: Set<String> = []) -> [HermesSkill] {
        SkillsScanner.scan(
            context: .local(home: home),
            transport: LocalTransport(),
            disabledNames: disabled,
            pinnedNames: pinned
        ).flatMap(\.skills)
    }

    // MARK: - S10-F1: discovery at any depth

    @Test("flat, two-level and deep skills are all found, with Hermes-shaped ids")
    func allThreeLayouts() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Flat hub install with support folders (the audit's live shape).
        try Self.put("skills/agents-sdk/SKILL.md", in: home, Self.skillMD("agents-sdk"))
        try Self.put("skills/agents-sdk/references/api.md", in: home)
        try Self.put("skills/agents-sdk/scripts/run.sh", in: home)
        // Bundled two-level.
        try Self.put("skills/creative/pixel-art/SKILL.md", in: home, Self.skillMD("pixel-art"))
        // Official deep install.
        try Self.put("skills/mlops/research/dspy/SKILL.md", in: home, Self.skillMD("dspy"))
        try Self.put("skills/mlops/research/dspy/templates/t.md", in: home)

        let skills = Self.scan(home)
        #expect(skills.map(\.id).sorted() == ["agents-sdk", "creative/pixel-art", "mlops/research/dspy"])

        let flat = try #require(skills.first { $0.id == "agents-sdk" })
        #expect(flat.name == "agents-sdk")
        #expect(flat.category == "")
        #expect(flat.path == home.path + "/skills/agents-sdk")
        // The support folders are listed as the skill's files, never as skills.
        #expect(flat.files == ["SKILL.md", "references", "scripts"])

        let deep = try #require(skills.first { $0.id == "mlops/research/dspy" })
        #expect(deep.name == "dspy")
        #expect(deep.category == "mlops/research")

        let two = try #require(skills.first { $0.id == "creative/pixel-art" })
        #expect(two.category == "creative")
    }

    @Test("categories group by the path between skills/ and the skill, flat first")
    func grouping() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("skills/zeta/SKILL.md", in: home, Self.skillMD("zeta"))
        try Self.put("skills/creative/b/SKILL.md", in: home, Self.skillMD("b"))
        try Self.put("skills/creative/a/SKILL.md", in: home, Self.skillMD("a"))
        try Self.put("skills/mlops/research/dspy/SKILL.md", in: home, Self.skillMD("dspy"))

        let categories = SkillsScanner.scan(context: .local(home: home), transport: LocalTransport())
        #expect(categories.map(\.name) == ["", "creative", "mlops/research"])
        #expect(categories[1].skills.map(\.name) == ["a", "b"])
    }

    @Test("folders without SKILL.md are neither skills nor categories")
    func noSkillMDNoSkill() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // The old walk rendered `notes` as a skill of category `stray`.
        try Self.put("skills/stray/notes/readme.md", in: home)
        try Self.put("skills/empty-category/.keep", in: home)
        try Self.put("skills/loose-file.md", in: home)
        #expect(Self.scan(home).isEmpty)
    }

    @Test("excluded dirs are pruned everywhere; support dirs only inside a skill")
    func pruning() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // EXCLUDED_SKILL_DIRS: the curator archive and hub quarantine.
        try Self.put("skills/.archive/old/SKILL.md", in: home, Self.skillMD("old"))
        try Self.put("skills/.hub/quarantine/q/SKILL.md", in: home, Self.skillMD("q"))
        try Self.put("skills/tool/node_modules/dep/SKILL.md", in: home, Self.skillMD("dep"))
        // A skill-shaped folder inside a skill's support dir is skill content.
        try Self.put("skills/host/SKILL.md", in: home, Self.skillMD("host"))
        try Self.put("skills/host/references/inner/SKILL.md", in: home, Self.skillMD("inner"))
        // …but a category literally named `templates` (no SKILL.md) is walked.
        try Self.put("skills/templates/starter/SKILL.md", in: home, Self.skillMD("starter"))
        // Hermes keeps walking below a skill root outside the support dirs.
        try Self.put("skills/host/extras/nested/SKILL.md", in: home, Self.skillMD("nested"))

        #expect(Self.scan(home).map(\.id).sorted() == ["host", "host/extras/nested", "templates/starter"])
    }

    @Test("the _org mirror is walked only for the org named in .active_org")
    func orgMirrorGate() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("skills/_org/acme/deploy/SKILL.md", in: home, Self.skillMD("deploy"))
        try Self.put("skills/_org/other/leak/SKILL.md", in: home, Self.skillMD("leak"))
        #expect(Self.scan(home).isEmpty, "no marker: no org skills load")

        try Self.put("skills/_org/.active_org", in: home, "acme\n")
        #expect(Self.scan(home).map(\.id) == ["_org/acme/deploy"])
    }

    @Test("guard artifacts stay out of a flat skill's files")
    func guardArtifactsFlat() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["SKILL.md", "SKILL.md.bak", "SKILL.md.corrupt-20260907T101112Z", "notes.md"] {
            try Self.put("skills/flat/\(name)", in: home, Self.skillMD("flat"))
        }
        let skill = try #require(Self.scan(home).first)
        #expect(skill.files == ["SKILL.md", "notes.md"])
    }

    @Test("disabled and pinned state key on the bare skill name at any depth")
    func stateByName() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("skills/mlops/research/dspy/SKILL.md", in: home, Self.skillMD("dspy"))
        try Self.put("skills/flat/SKILL.md", in: home, Self.skillMD("flat"))
        let skills = Self.scan(home, pinned: ["dspy"], disabled: ["flat"])
        #expect(skills.first { $0.name == "dspy" }?.pinned == true)
        #expect(skills.first { $0.name == "flat" }?.enabled == false)
    }

    // MARK: - S10-F3: pins come from .usage.json

    @Test("pinned names are read from skills/.usage.json records")
    func pinsFromUsageSidecar() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Shape written by `save_usage` (indent=2, sort_keys) with the
        // `_empty_record` keys, trimmed.
        try Self.put("skills/.usage.json", in: home, """
        {
          "dspy": {"created_by": "agent", "pinned": true, "state": "active", "use_count": 3},
          "flat": {"created_by": null, "pinned": false, "state": "active"},
          "legacy": {"use_count": 1},
          "odd": {"pinned": 1},
          "junk": "not a record"
        }
        """)
        // A `.curator_state` that happens to carry the old keys must not count.
        try Self.put("skills/.curator_state", in: home,
                     #"{"paused": false, "run_count": 2, "pinned": ["ghost"]}"#)

        let pinned = SkillsViewModel.readPinnedSkillNames(context: .local(home: home))
        #expect(pinned == ["dspy"])
    }

    /// Byte-for-byte what Hermes wrote: `tools.skill_usage.mark_agent_created`
    /// + `set_pinned("agents-sdk", True)` / `set_pinned("host", False)` run
    /// from the v2026.9.24 worktree's venv against a scratch HERMES_HOME.
    @Test("a sidecar Hermes itself wrote yields exactly its pinned skill")
    func pinsFromHermesWrittenSidecar() throws {
        let hermesWritten = """
        {
          "agents-sdk": {
            "archived_at": null,
            "created_at": "2026-09-27T01:47:56.145746+00:00",
            "created_by": "agent",
            "first_seen_at": null,
            "last_patched_at": null,
            "last_reused_patch_generation": 0,
            "last_used_at": null,
            "last_viewed_at": null,
            "patch_count": 0,
            "patch_generation": 0,
            "pinned": true,
            "state": "active",
            "use_count": 0,
            "view_count": 0
          },
          "host": {
            "archived_at": null,
            "created_at": "2026-09-27T01:47:56.149929+00:00",
            "created_by": "agent",
            "first_seen_at": null,
            "last_patched_at": null,
            "last_reused_patch_generation": 0,
            "last_used_at": null,
            "last_viewed_at": null,
            "patch_count": 0,
            "patch_generation": 0,
            "pinned": false,
            "state": "active",
            "use_count": 0,
            "view_count": 0
          }
        }
        """
        #expect(SkillsViewModel.parsePinnedSkillNames(Data(hermesWritten.utf8)) == ["agents-sdk"])
    }

    @Test("no sidecar or a corrupt one means no pins")
    func pinsMissingOrCorrupt() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(SkillsViewModel.readPinnedSkillNames(context: .local(home: home)).isEmpty)
        try Self.put("skills/.usage.json", in: home, "{not json")
        #expect(SkillsViewModel.readPinnedSkillNames(context: .local(home: home)).isEmpty)
        #expect(SkillsViewModel.parsePinnedSkillNames(Data("[]".utf8)).isEmpty)
    }

    @Test("the view model's load marks a pinned skill end to end")
    @MainActor
    func loadMarksPinned() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("skills/research/dspy/SKILL.md", in: home, Self.skillMD("dspy"))
        try Self.put("skills/other/SKILL.md", in: home, Self.skillMD("other"))
        try Self.put("skills/.usage.json", in: home, #"{"dspy": {"pinned": true}}"#)

        let vm = SkillsViewModel(context: .local(home: home), transport: LocalTransport())
        // Pre-seeded so `load` doesn't probe a real `hermes --version`.
        vm.capabilities = HermesCapabilities(
            versionLine: "hermes 0.21.5",
            semver: HermesCapabilities.SemVer(major: 0, minor: 21, patch: 5),
            dateVersion: nil
        )
        await vm.load()
        let skills = vm.categories.flatMap(\.skills)
        #expect(skills.first { $0.name == "dspy" }?.pinned == true)
        #expect(skills.first { $0.name == "other" }?.pinned == false)
    }

    // MARK: - S10-F4: shared plugin walk

    @Test("plugin activation comes from config.yaml lists, never a .disabled marker")
    func pluginActivationFromConfig() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("plugins/on/plugin.yaml", in: home, "name: on\nversion: 1.2.0\n")
        try Self.put("plugins/off/plugin.yaml", in: home, "name: off\n")
        try Self.put("plugins/idle/plugin.yaml", in: home, "name: idle\n")
        // The iOS view used to read this marker; Hermes never writes it.
        try Self.put("plugins/idle/.disabled", in: home, "")
        try Self.put("plugins/marked/plugin.json", in: home, #"{"name": "marked", "tool_override": true}"#)
        try Self.put("plugins/marked/.disabled", in: home, "")
        // Nested one level, enabled by its registry key.
        try Self.put("plugins/observability/langfuse/plugin.yaml", in: home, "name: langfuse\n")
        try Self.put("config.yaml", in: home, """
        plugins:
          enabled:
          - on
          - marked
          - observability/langfuse
          disabled:
          - off
        """)

        let ctx = ServerContext.local(home: home)
        let rows = HermesPluginDirectoryScanner.walk(dir: ctx.paths.pluginsDir, context: ctx)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["on", "off", "idle", "marked", "langfuse"])
        #expect(byName["on"]?.activation == .enabled)
        #expect(byName["on"]?.version == "1.2.0")
        #expect(byName["off"]?.activation == .disabled)
        #expect(byName["idle"]?.activation == .notEnabled)
        #expect(byName["marked"]?.activation == .enabled)
        #expect(byName["marked"]?.toolOverride == true)
        #expect(byName["langfuse"]?.activation == .enabled)
        #expect(byName["langfuse"]?.path == home.path + "/plugins/observability/langfuse")
        #expect(rows.allSatisfy { $0.name != "observability" }, "a category folder is not a plugin")
    }

    @Test("no config.yaml means every user plugin is not enabled")
    func pluginNoConfig() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("plugins/lonely/plugin.yaml", in: home, "name: lonely\n")
        let ctx = ServerContext.local(home: home)
        let rows = HermesPluginDirectoryScanner.walk(dir: ctx.paths.pluginsDir, context: ctx)
        #expect(rows.map(\.activation) == [.notEnabled])
    }
}
