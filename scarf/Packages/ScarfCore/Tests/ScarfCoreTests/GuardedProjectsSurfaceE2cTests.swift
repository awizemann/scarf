import Testing
import Foundation
@testable import ScarfCore

/// GW-E2c — the ScarfCore half of the projects/skills/bots write surface
/// converted off destroy-shaped read-modify-write: `AGENTS.md`'s
/// `removeBlock`, mini-app `state.json`, the Skills editor's `SKILL.md`, and
/// a bot's `profile.yaml`.
///
/// W1 shape throughout: real files, real `LocalTransport`. The bug being
/// tested is always what the WRITER BELIEVES about a file it could not read,
/// and a fake transport that answers honestly proves nothing about that. The
/// unreadable cases use mode 0000, which only produces an unreadable file for
/// a non-root user, so they self-skip under root.
@Suite struct GuardedProjectsSurfaceE2cTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    /// The body is `@MainActor` rather than `sending`: `SkillsViewModel`'s
    /// selection methods are explicitly main-actor isolated (P22 — they mutate
    /// `@Observable` UI state), and from a nonisolated closure the view model
    /// created inside it would have to be *sent* into every call.
    private static func withScratch(_ body: @MainActor (URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-e2c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        try await body(base)
    }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - ProjectContextBlock.removeBlock (AGENTS.md)

    private static func agentsMd(withBlock block: String) -> String {
        "# My project\n\nMy own notes.\n\n"
            + ProjectContextBlock.beginMarker + "\n" + block + "\n"
            + ProjectContextBlock.endMarker + "\n\nMore of my notes.\n"
    }

    @Test func removeBlockStripsTheBlockAndBacksUpWhatItReplaced() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let path = project + "/AGENTS.md"
            let original = Self.agentsMd(withBlock: "scarf stuff")
            try Self.write(original, to: path)

            try ProjectContextBlock.removeBlock(forProjectAt: project, context: .local)

            let after = try #require(Self.text(path))
            #expect(!after.contains(ProjectContextBlock.beginMarker))
            #expect(after.contains("My own notes."))
            #expect(after.contains("More of my notes."))
            #expect(
                Self.text(path + ".bak") == original,
                "the sibling writeBlock keeps a .bak; this half must produce the same one"
            )
        }
    }

    @Test func removeBlockRefusesOnAnUnreadableAgentsMdAndLeavesItIntact() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let path = project + "/AGENTS.md"
            let original = Self.agentsMd(withBlock: "scarf stuff")
            try Self.write(original, to: path)
            try Self.chmod(path, 0o000)

            #expect(throws: ProjectContextBlock.WriteError.self) {
                try ProjectContextBlock.removeBlock(forProjectAt: project, context: .local)
            }

            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == original, "a blipped read must never republish a splice")
        }
    }

    @Test func removeBlockOnAnAbsentAgentsMdIsASilentNoOp() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            try FileManager.default.createDirectory(
                atPath: project, withIntermediateDirectories: true
            )
            try ProjectContextBlock.removeBlock(forProjectAt: project, context: .local)
            #expect(!FileManager.default.fileExists(atPath: project + "/AGENTS.md"))
        }
    }

    // MARK: - MiniAppStore (state.json)

    @Test func miniAppStoreWritesFreshStateWhenTheFileIsAbsent() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let store = MiniAppStore(context: .local)
            try store.set(projectPath: project, miniAppId: "app", key: "k", value: "\"v\"")
            #expect(store.get(projectPath: project, miniAppId: "app", key: "k") == "\"v\"")
        }
    }

    @Test func miniAppStoreRefusesToRepublishOverAnUnreadableStateFile() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let store = MiniAppStore(context: .local)
            try store.set(projectPath: project, miniAppId: "app", key: "keep", value: "\"me\"")
            let path = MiniAppStore.statePath(projectPath: project, miniAppId: "app")
            let original = try #require(Self.text(path))
            try Self.chmod(path, 0o000)

            #expect(throws: GuardedStoreError.self) {
                try store.set(projectPath: project, miniAppId: "app", key: "new", value: "\"x\"")
            }

            try Self.chmod(path, 0o644)
            #expect(
                Self.text(path) == original,
                "one blip used to publish {} over the mini-app's whole state"
            )
        }
    }

    /// Mini-app state is app-owned and re-creatable, so it follows the
    /// SIDECAR half of the store's doctrine: undecodable bytes are copied
    /// aside and the file is rebuilt, rather than frozen forever.
    @Test func miniAppStoreQuarantinesUndecodableStateAndRebuilds() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let path = MiniAppStore.statePath(projectPath: project, miniAppId: "app")
            try Self.write("{ this is not json", to: path)
            QuarantineMemo.shared.reset()

            let store = MiniAppStore(context: .local)
            try store.set(projectPath: project, miniAppId: "app", key: "k", value: "\"v\"")

            #expect(store.get(projectPath: project, miniAppId: "app", key: "k") == "\"v\"")
            let dir = (path as NSString).deletingLastPathComponent
            let copies = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasPrefix("state.json.corrupt-") } ?? []
            #expect(copies.count == 1, "the unusable bytes must survive somewhere")
            // A quarantined predecessor is NOT a backup (P8 DI-M2).
            #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
        }
    }

    @Test func miniAppStoreKeepsABakOfTheStateItReplaces() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let store = MiniAppStore(context: .local)
            try store.set(projectPath: project, miniAppId: "app", key: "a", value: "1")
            let path = MiniAppStore.statePath(projectPath: project, miniAppId: "app")
            let first = try #require(Self.text(path))
            try store.set(projectPath: project, miniAppId: "app", key: "b", value: "2")
            #expect(Self.text(path + ".bak") == first)
            #expect(store.get(projectPath: project, miniAppId: "app", key: "a") == "1")
        }
    }

    // MARK: - ProjectLifecycleService.cleanUpAfterRemoval (GW-F2, DI M4)

    /// The old body gated on `fileExists` and then diffed a `try?` read taken
    /// before against one taken after. An unreadable AGENTS.md therefore
    /// reported a clean removal with the block still in it. Now the refusal
    /// becomes a warning the removal reports.
    @Test func removalCleanupWarnsInsteadOfSilentlySkippingAnUnreadableAgentsMd() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let agents = project + "/AGENTS.md"
            let original = Self.agentsMd(withBlock: "scarf block")
            try Self.write(original, to: agents)
            try Self.chmod(agents, 0o000)

            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let result = ProjectLifecycleService(context: ctx)
                .cleanUpAfterRemoval(of: ProjectEntry(name: "proj", path: project))

            #expect(result.contextBlockStripped == false)
            #expect(
                result.warnings.contains { $0.contains("AGENTS.md") },
                "the refusal has to be reported, not swallowed by a fileExists gate"
            )

            try Self.chmod(agents, 0o644)
            #expect(Self.text(agents) == original)
        }
    }

    /// Healthy paths unchanged: the block is stripped and REPORTED stripped,
    /// and a project whose folder is gone is a quiet no-op — not a warning.
    @Test func removalCleanupReportsTheStripItActuallyPerformed() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj").path
            let agents = project + "/AGENTS.md"
            try Self.write(Self.agentsMd(withBlock: "scarf block"), to: agents)
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let service = ProjectLifecycleService(context: ctx)

            let stripped = service.cleanUpAfterRemoval(
                of: ProjectEntry(name: "proj", path: project)
            )
            #expect(stripped.contextBlockStripped)
            #expect(stripped.warnings.isEmpty)
            #expect(Self.text(agents)?.contains(ProjectContextBlock.beginMarker) == false)

            // Second pass: nothing left to strip.
            let again = service.cleanUpAfterRemoval(
                of: ProjectEntry(name: "proj", path: project)
            )
            #expect(again.contextBlockStripped == false)
            #expect(again.warnings.isEmpty)

            // A project whose folder is gone entirely.
            let vanished = service.cleanUpAfterRemoval(
                of: ProjectEntry(name: "gone", path: base.appendingPathComponent("gone").path)
            )
            #expect(vanished.contextBlockStripped == false)
            #expect(vanished.warnings.isEmpty)
        }
    }

    // MARK: - SkillsViewModel (SKILL.md)

    /// The whole point of the conversion: the `""`-loader case must have no
    /// path to a save. The editor cannot even be armed.
    @MainActor
    @Test func unreadableSkillCannotBeEditedOrSavedBack() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let home = base.appendingPathComponent("hermes")
            let ctx = ServerContext.local(home: home)
            let skillDir = ctx.paths.skillsDir + "/writing/haiku"
            let path = skillDir + "/SKILL.md"
            let original = "---\nname: haiku\n---\n\nfive seven five\n"
            try Self.write(original, to: path)
            try Self.chmod(path, 0o000)

            let vm = SkillsViewModel(context: ctx)
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/haiku", name: "haiku", category: "writing",
                    path: skillDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            #expect(vm.skillContent.isEmpty)
            #expect(vm.canEditSelectedFile == false)
            #expect(vm.contentError != nil, "the user has to be told why Edit is dead")

            // Even driving the editor by hand can't publish the empty buffer.
            vm.startEditing()
            #expect(vm.isEditing == false)
            vm.editText = ""
            await vm.saveEdit()

            try Self.chmod(path, 0o644)
            #expect(
                Self.text(path) == original,
                "the loader's empty buffer must never reach the file"
            )
        }
    }

    /// GW-F2 (DI M11): the containment guard used to `return` bare, and
    /// `saveEdit` reads "no contentError" as "it saved" — so a rejected path
    /// closed the editor on a confirmation and dropped the user's edits.
    @MainActor
    @Test func skillPathOutsideTheSkillsDirRefusesLoudlyInsteadOfSilently() async throws {
        try await Self.withScratch { base in
            let home = base.appendingPathComponent("hermes")
            let ctx = ServerContext.local(home: home)
            // A real, readable file that is simply NOT under ~/.hermes/skills.
            let outsideDir = base.appendingPathComponent("elsewhere").path
            let path = outsideDir + "/SKILL.md"
            let original = "somebody else's file\n"
            try Self.write(original, to: path)

            let vm = SkillsViewModel(context: ctx)
            await vm.selectSkill(
                HermesSkill(
                    id: "x/outside", name: "outside", category: "x",
                    path: outsideDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            vm.editText = "overwritten\n"
            await vm.saveEdit()

            #expect(vm.contentError != nil, "a rejected path is not a successful save")
            #expect(vm.isEditing == false)
            #expect(Self.text(path) == original, "and nothing was written outside the root")
        }
    }

    @MainActor
    @Test func readableSkillEditsSaveAndKeepABak() async throws {
        try await Self.withScratch { base in
            let home = base.appendingPathComponent("hermes")
            let ctx = ServerContext.local(home: home)
            let skillDir = ctx.paths.skillsDir + "/writing/haiku"
            let path = skillDir + "/SKILL.md"
            let original = "---\nname: haiku\n---\n\nfive seven five\n"
            try Self.write(original, to: path)

            let vm = SkillsViewModel(context: ctx)
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/haiku", name: "haiku", category: "writing",
                    path: skillDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            #expect(vm.skillContent == original)
            #expect(vm.canEditSelectedFile)
            vm.startEditing()
            #expect(vm.isEditing)
            vm.editText = original + "\nedited\n"
            await vm.saveEdit()

            #expect(vm.isEditing == false)
            #expect(vm.contentError == nil)
            #expect(Self.text(path) == original + "\nedited\n")
            #expect(Self.text(path + ".bak") == original)
        }
    }

    // MARK: - Skill load/save affordances (GW follow-ups)

    /// `isLoadingContent` is what the Mac and iOS skill viewers now render a
    /// "Reading file…" row from. It must be a transient that always settles —
    /// a stuck `true` is a permanent spinner over a file that is already on
    /// screen, and a `true` left behind by a refusal hides the refusal notice
    /// the F4 wave added.
    @MainActor
    @Test func isLoadingContentSettlesForEverySelectionOutcome() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let home = base.appendingPathComponent("hermes")
            let ctx = ServerContext.local(home: home)
            let vm = SkillsViewModel(context: ctx)
            #expect(vm.isLoadingContent == false, "nothing selected, nothing loading")

            // 1. A readable file.
            let goodDir = ctx.paths.skillsDir + "/writing/haiku"
            try Self.write("five seven five\n", to: goodDir + "/SKILL.md")
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/haiku", name: "haiku", category: "writing",
                    path: goodDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            #expect(vm.isLoadingContent == false)
            #expect(vm.canEditSelectedFile)

            // 2. A file the guarded reader refuses. The spinner must give way
            //    to the refusal notice, not sit on top of it.
            let badDir = ctx.paths.skillsDir + "/writing/locked"
            try Self.write("secret\n", to: badDir + "/SKILL.md")
            try Self.chmod(badDir + "/SKILL.md", 0o000)
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/locked", name: "locked", category: "writing",
                    path: badDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            #expect(vm.isLoadingContent == false)
            #expect(vm.contentError != nil)
            try Self.chmod(badDir + "/SKILL.md", 0o644)

            // 3. A skill with no files at all — the branch that never starts a
            //    load has to clear the flag too.
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/empty", name: "empty", category: "writing",
                    path: ctx.paths.skillsDir + "/writing/empty",
                    files: [], requiredConfig: []
                )
            )
            #expect(vm.isLoadingContent == false)
        }
    }

    /// The contract the iOS `SkillEditorSheet` now reads to decide whether to
    /// dismiss: a FAILED save leaves `isEditing` true (and `contentError` set)
    /// so the sheet stays open on the user's buffer instead of closing on it
    /// like a success. The Mac editor has always behaved this way.
    @MainActor
    @Test func aFailedSaveKeepsTheEditorArmedOnTheUsersBuffer() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let home = base.appendingPathComponent("hermes")
            let ctx = ServerContext.local(home: home)
            let skillDir = ctx.paths.skillsDir + "/writing/haiku"
            let path = skillDir + "/SKILL.md"
            let original = "---\nname: haiku\n---\n\nfive seven five\n"
            try Self.write(original, to: path)

            let vm = SkillsViewModel(context: ctx)
            await vm.selectSkill(
                HermesSkill(
                    id: "writing/haiku", name: "haiku", category: "writing",
                    path: skillDir, files: ["SKILL.md"], requiredConfig: []
                )
            )
            vm.startEditing()
            #expect(vm.isEditing)

            // Read-only directory: the guarded write's `.bak` and its atomic
            // replace both need to create files here, so the save fails after
            // the editor was legitimately armed.
            try Self.chmod(skillDir, 0o500)
            defer { try? Self.chmod(skillDir, 0o755) }
            vm.editText = original + "\nedited\n"
            await vm.saveEdit()

            #expect(vm.contentError != nil, "the user has to be told the save failed")
            #expect(
                vm.isEditing,
                "the sheet reads this to stay open — dismissing here drops the buffer"
            )
            #expect(vm.editText == original + "\nedited\n", "and the buffer survives")
        }
    }

    // MARK: - BotsService (profile.yaml)

    private static func makeBots(root: String) -> BotsService {
        BotsService(
            transport: LocalTransport(),
            paths: HermesPathSet(home: root, isRemote: false, binaryHint: nil),
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        )
    }

    @Test func saveIdentityRefusesOnAnUnreadableProfileYAMLAndLeavesItIntact() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let root = base.appendingPathComponent(".hermes").path
            let path = root + "/profiles/zeta/profile.yaml"
            let original = "name: Zeta\nrole: helper\nsomething_hermes_owns: keep-me\n"
            try Self.write(original, to: path)
            try Self.chmod(path, 0o000)

            let service = Self.makeBots(root: root)
            #expect(throws: BotsError.self) {
                try service.saveIdentity(
                    HermesBotIdentity(
                        profileName: "zeta",
                        profileDirectory: root + "/profiles/zeta",
                        displayName: "Zeta",
                        profileDescription: "changed"
                    )
                )
            }

            try Self.chmod(path, 0o644)
            #expect(
                Self.text(path) == original,
                "a fileExists blip used to make the merge base \"\" and publish a stub"
            )
        }
    }

    @Test func saveIdentityMergesAHealthyProfileAndBacksItUp() async throws {
        try await Self.withScratch { base in
            let root = base.appendingPathComponent(".hermes").path
            let path = root + "/profiles/zeta/profile.yaml"
            let original = "name: Zeta\nrole: helper\nsomething_hermes_owns: keep-me\n"
            try Self.write(original, to: path)

            let service = Self.makeBots(root: root)
            try service.saveIdentity(
                HermesBotIdentity(
                        profileName: "zeta",
                        profileDirectory: root + "/profiles/zeta",
                        displayName: "Zeta",
                        profileDescription: "changed"
                    )
            )

            let after = try #require(Self.text(path))
            #expect(after.contains("keep-me"), "the YAML preservation contract still holds")
            #expect(after.contains("changed"))
            #expect(Self.text(path + ".bak") == original)
        }
    }

    // MARK: - The shrinking allowlist

    /// A converted site's `UNGUARDED-WRITE(R)` annotation is a lie, and the
    /// E1 scanner enforces the allowlist only as it shrinks. Pin the
    /// E2c manifest the same way E2a pinned its own.
    @Test func everyE2cWriterRoutesThroughAGuardAndDroppedItsAnnotation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → ScarfCoreTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → ScarfCore
            .deletingLastPathComponent()  // → Packages
            .deletingLastPathComponent()  // → scarf
            .deletingLastPathComponent()  // → repo root
        let writers = [
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppStore.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/BotsService.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift",
            "scarf/scarf/Core/Services/ProjectConfigService.swift",
            "scarf/scarf/Core/Services/ProjectManifestStore.swift",
            "scarf/scarf/Core/Services/KanbanTenantResolver.swift",
            "scarf/scarf/Core/Services/ProjectModelPresetBinding.swift",
            "scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift",
            "scarf/scarf/Core/Services/SkillBootstrapService.swift",
            "scarf/scarf/Core/Services/SlashCommandBootstrapService.swift",
            "scarf/scarf/Core/Services/ProjectUpgradeService.swift",
        ]
        for relative in writers {
            let url = root.appendingPathComponent(relative)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "missing \(relative) — the manifest is stale"
            )
            #expect(
                source.contains("GuardedTextFile(") || source.contains("GuardedJSONStore")
                    || source.contains("ProjectManifestStore("),
                "\(relative) is an E2c-converted writer and must reach its file through a guard"
            )
            #expect(
                !source.contains("UNGUARDED-WRITE(R)"),
                "\(relative) still carries an R annotation — a converted site's annotation is a lie"
            )
        }
    }
}
