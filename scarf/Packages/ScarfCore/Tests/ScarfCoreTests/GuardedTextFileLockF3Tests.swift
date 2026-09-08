import Testing
import Foundation
@testable import ScarfCore

/// GW-F3 / DI H4 + M9 — cross-writer serialization for `GuardedTextFile`.
///
/// The audit's finding was not "a write can fail"; it was that two writers of
/// ONE file each did a whole-file read-modify-write, and interleaved, the
/// loser's edit vanished silently AND the one-deep `.bak` was overwritten with
/// the winner's pre-image, so the previous good copy went too. These tests run
/// real concurrent writers against a real file through `LocalTransport`,
/// because the bug lives in the ordering of real syscalls — a fake transport
/// that serializes by construction would prove exactly nothing.
@Suite struct GuardedTextFileLockF3Tests {

    private static func makeScratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func cleanUp(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// A local context rooted at `dir`, so `RegistryWriteLock` puts the lock
    /// file beside the target and two writers contend on one inode.
    private static func localContext(home: URL) -> ServerContext {
        .local(home: home)
    }

    private static func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The finding itself

    /// TWO concurrent read-modify-writers of one `config.yaml`, each
    /// appending its own line. Unserialized, this is the classic lost update:
    /// both read the same base, both build a whole file from it, and whoever
    /// renames last erases the other's line. Under the lock, both survive.
    ///
    /// Run enough times that an accidental pass is not plausible: the
    /// unlocked version of this loop loses an edit within the first handful
    /// of rounds on every machine it was tried on.
    @Test func twoConcurrentWritersBothSurvive() async throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }

        for round in 0..<12 {
            let path = scratch.appendingPathComponent("config-\(round).yaml")
            try "base:\n".write(to: path, atomically: true, encoding: .utf8)
            let context = Self.localContext(home: scratch)

            await withTaskGroup(of: Void.self) { group in
                for writer in ["alpha", "beta"] {
                    group.addTask {
                        // The whole hold on ONE thread: the lock's reentrancy
                        // is thread-local and must never span an `await`.
                        await Task.detached {
                            let file = GuardedTextFile(context: context, label: "config.yaml")
                            try? file.mutate(path.path) { loaded in
                                // A deliberate pause INSIDE the hold, in the
                                // window between the read and the publish.
                                // Unlocked this is where the other writer's
                                // whole file lands and is then erased.
                                Thread.sleep(forTimeInterval: 0.01)
                                return loaded.text + "\(writer): 1\n"
                            }
                        }.value
                    }
                }
            }

            let final = try #require(Self.text(path), "round \(round): file vanished")
            #expect(final.contains("alpha: 1"), "round \(round): alpha's edit was lost — \(final)")
            #expect(final.contains("beta: 1"), "round \(round): beta's edit was lost — \(final)")
            #expect(final.hasPrefix("base:\n"), "round \(round): the pre-existing content was lost")
        }
    }

    /// Contention that outlasts the wait bound must surface as the existing
    /// FAILURE channel (`ProjectRegistryError.registryBusy`, which every
    /// adopter already turns into its own `false`/`.failed`), never as a
    /// hang. This is the charter C10 half of the design: a bounded wait then
    /// an honest error beats a frozen caller.
    @Test func contentionPastTheBoundIsBusyNotAHang() async throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent("config.yaml")
        try "base:\n".write(to: path, atomically: true, encoding: .utf8)
        let context = Self.localContext(home: scratch)
        let file = GuardedTextFile(context: context, label: "config.yaml")

        // A foreign holder: the lock file exists with somebody else's token
        // and a FRESH mtime, so it is neither ours to release nor stale
        // enough to break.
        let lockPath = path.path + ".lock"
        try "owner=someone-else\npid=1\n".write(
            toFile: lockPath, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let started = Date()
        var thrown: Error?
        do {
            try file.mutate(path.path, acquireTimeout: 0.2) { _ in "clobbered\n" }
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(thrown != nil, "a held lock must fail the write, not proceed")
        if case .some(ProjectRegistryError.registryBusy) = thrown as? ProjectRegistryError {
            // The expected channel.
        } else {
            Issue.record("expected registryBusy, got \(String(describing: thrown))")
        }
        #expect(elapsed < 5, "the wait must be bounded, not a hang (took \(elapsed)s)")
        // And the file is untouched: a refused acquire must never publish.
        #expect(Self.text(path) == "base:\n")
    }

    /// The lock is REENTRANT within a thread, which is what lets a call site
    /// take an outer `withLock` (the MCP patcher's publish → re-read →
    /// restore) and still call `mutate` inside it. Without reentrancy that is
    /// a self-deadlock, so this test is a deadlock canary.
    @Test func nestedHoldsOnOneThreadDoNotDeadlock() throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent("config.yaml")
        try "base:\n".write(to: path, atomically: true, encoding: .utf8)
        let file = GuardedTextFile(context: Self.localContext(home: scratch), label: "config.yaml")

        try file.withLock(path.path) {
            try file.mutate(path.path) { $0.text + "inner: 1\n" }
            try file.mutate(path.path) { $0.text + "inner: 2\n" }
        }
        #expect(Self.text(path) == "base:\ninner: 1\ninner: 2\n")
        // The outermost scope removes the lock file on the way out.
        #expect(!FileManager.default.fileExists(atPath: path.path + ".lock"))
    }

    /// `mutate` returning `nil` publishes NOTHING — not an empty file, not a
    /// re-write of the same bytes — and refreshes no `.bak`. That is what
    /// makes "no change" free for the idempotent reconcile paths
    /// (`KeychainEnvMirror.reconcileAll`, `GatewayConfigWriter.saveList`).
    @Test func mutateReturningNilPublishesNothing() throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent(".env")
        try "A=1\n".write(to: path, atomically: true, encoding: .utf8)
        let file = GuardedTextFile(context: Self.localContext(home: scratch), label: ".env")

        let wrote = try file.mutate(path.path) { _ in nil }
        #expect(wrote == false)
        #expect(Self.text(path) == "A=1\n")
        #expect(!FileManager.default.fileExists(atPath: path.path + ".bak"))
    }

    /// A refusal still refuses under the lock — the serialization is added
    /// TO the guard, not in place of it — and the lock file is released on
    /// the throwing path so the next writer is not wedged behind it.
    @Test func aRefusalReleasesTheLock() throws {
        guard getuid() != 0 else { return }   // mode 0000 is readable as root
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent("MEMORY.md")
        try "prose\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: path.path
        ) }

        let file = GuardedTextFile(context: Self.localContext(home: scratch), label: "MEMORY.md")
        #expect(throws: GuardedTextFile.Refusal.self) {
            try file.mutate(path.path) { _ in "clobbered\n" }
        }
        #expect(
            !FileManager.default.fileExists(atPath: path.path + ".lock"),
            "a refusal must not leave the lock file behind"
        )
    }

    /// An UNSERIALIZED `GuardedTextFile` (the transport-only initializer, used
    /// for the per-project and per-skill files) must keep working exactly as
    /// before and create no lock file. The lock is opt-in per file, by design.
    @Test func theTransportOnlyInitializerTakesNoLock() throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent("SKILL.md")
        try "---\n".write(to: path, atomically: true, encoding: .utf8)

        let file = GuardedTextFile(transport: LocalTransport(), label: "SKILL.md")
        #expect(file.lockContext == nil)
        try file.mutate(path.path) { $0.text + "body\n" }
        #expect(Self.text(path) == "---\nbody\n")
        #expect(!FileManager.default.fileExists(atPath: path.path + ".lock"))
    }

    // MARK: - Lock coverage, enforced against the source

    /// **The per-file coverage table**, and the enforcement that no adopter
    /// can reach `write` around it.
    ///
    /// LOCKED — the four hermes-GLOBAL files. Each has several writers, at
    /// least one of which is not user-driven (a launch-time reconcile, a
    /// template install, the `scarf-projects` MCP helper's sibling
    /// processes), so two whole-file rewrites genuinely interleave:
    ///
    /// | file          | writers                                                                   |
    /// |---------------|---------------------------------------------------------------------------|
    /// | `config.yaml` | Settings direct-YAML, gateway allowlist, Kanban enable/disable, MCP patch |
    /// | `.env`        | `HermesEnvService` set/unset, `KeychainEnvMirror` mirror/unmirror/reconcile |
    /// | `MEMORY.md`   | memory editor (mac + iOS), template install appendix, uninstall strip     |
    /// | `USER.md`     | memory editor (mac + iOS)                                                 |
    ///
    /// NOT LOCKED, deliberately — the per-project and per-skill files:
    /// `AGENTS.md` (`ProjectContextBlock`), `SKILL.md` (`SkillsViewModel`), a
    /// bot's `profile.yaml` (`BotsService`). Each is written by ONE
    /// user-driven surface, at a path no other writer shares (a project's own
    /// folder, a skill's own folder, a profile's own folder), and the
    /// project-lifecycle paths that touch `AGENTS.md` are already sequenced
    /// behind install/uninstall. A lock file per project folder and per skill
    /// folder would be new agent-visible litter in directories Scarf does not
    /// own, bought for a race nobody has produced. If a second writer of one
    /// of those files ever appears, move it into the locked column — do not
    /// blanket-lock now.
    @Test func everyWriterOfAProtectedFileGoesThroughTheLock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → ScarfCoreTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → ScarfCore
            .deletingLastPathComponent()  // → Packages
            .deletingLastPathComponent()  // → scarf
            .deletingLastPathComponent()  // → repo root

        // Every file that writes one of the four protected files. A writer
        // here must construct its `GuardedTextFile` with `context:` — the
        // serialized initializer — because the transport-only one silently
        // takes no lock, which is exactly the "somebody forgot" failure this
        // batch exists to make impossible.
        let lockedWriters = [
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSMemoryViewModel.swift",
            "scarf/scarf/Core/Services/HermesFileService.swift",
            "scarf/scarf/Core/Services/HermesEnvService.swift",
            "scarf/scarf/Core/Services/KeychainEnvMirror.swift",
            "scarf/scarf/Core/Services/ProjectTemplateInstaller.swift",
            "scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift",
            "scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift",
        ]
        for relative in lockedWriters {
            let url = root.appendingPathComponent(relative)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "missing \(relative) — the coverage table is stale"
            )
            #expect(
                source.contains("GuardedTextFile(context:"),
                """
                \(relative) writes a protected hermes-global file and must build \
                its GuardedTextFile with `context:` (the SERIALIZED initializer). \
                `GuardedTextFile(transport:…)` takes no lock — see the coverage \
                table on this test.
                """
            )
            // …and it must actually enter through a locking entry point.
            #expect(
                source.contains(".mutate(") || source.contains(".withLock("),
                """
                \(relative) builds a serialized GuardedTextFile but never enters \
                `mutate` or `withLock` — the lock is decorative unless the whole \
                read-modify-write is inside one hold.
                """
            )
        }
    }

    /// DI M9 — `.env` has ONE guard implementation. `KeychainEnvMirror` used
    /// to hand-roll `GuardedJSONStore.inspect` + its own zero-byte
    /// reclassification + its own `write` for the same file `HermesEnvService`
    /// guarded with `GuardedTextFile`. Two implementations of one file's
    /// discipline is the per-writer disease one layer up, and it had already
    /// produced two different `.bak` stories.
    @Test func envHasExactlyOneGuardImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for relative in [
            "scarf/scarf/Core/Services/KeychainEnvMirror.swift",
            "scarf/scarf/Core/Services/HermesEnvService.swift",
        ] {
            let source = try #require(
                try? String(
                    contentsOf: root.appendingPathComponent(relative), encoding: .utf8
                )
            )
            #expect(
                !source.contains("GuardedJSONStore("),
                """
                \(relative) writes `.env`, whose guard is `GuardedTextFile` — \
                a second, hand-rolled discipline for one file is DI M9 all over \
                again.
                """
            )
        }
    }

    /// The two `.env` writers must be able to interleave without either
    /// losing its work: `HermesEnvService.setMany` rewrites the whole file
    /// and `KeychainEnvMirror` splices a marker block into it. This is the
    /// M9 unification's end-to-end shape, exercised through the `.env`
    /// guard's own `mutate` from two threads.
    @Test func envRoundTripsUnderOneDiscipline() async throws {
        let scratch = try Self.makeScratch()
        defer { Self.cleanUp(scratch) }
        let path = scratch.appendingPathComponent(".env")
        try "ANTHROPIC_API_KEY=hermes-owned\n".write(to: path, atomically: true, encoding: .utf8)
        let context = Self.localContext(home: scratch)

        await withTaskGroup(of: Void.self) { group in
            for key in ["SCARF_A", "SCARF_B", "SCARF_C"] {
                group.addTask {
                    await Task.detached {
                        let file = GuardedTextFile(context: context, label: ".env")
                        try? file.mutate(path.path, maxBytes: Int.max) { loaded in
                            Thread.sleep(forTimeInterval: 0.005)
                            return loaded.text + "\(key)=1\n"
                        }
                    }.value
                }
            }
        }

        let final = try #require(Self.text(path))
        // Hermes's own credential — the thing a lost update destroys — and
        // every writer's line survive together.
        #expect(final.contains("ANTHROPIC_API_KEY=hermes-owned"))
        #expect(final.contains("SCARF_A=1"))
        #expect(final.contains("SCARF_B=1"))
        #expect(final.contains("SCARF_C=1"))
    }
}
