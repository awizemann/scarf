import Testing
import Foundation
@testable import ScarfCore

/// v2.5 portable project slash commands. Service is transport-based so
/// these tests use a `LocalTransport`-backed `ServerContext` rooted at a
/// tmp directory (same trick `M5FeatureVMTests` uses for cron / memory).
///
/// The factory-touching tests live in M5 (the canonical `.serialized`
/// suite) — these tests don't install a custom factory, they just rely
/// on `ServerContext` defaulting to LocalTransport for `.local` kinds,
/// so they're safe to run in parallel with everything else.
@Suite struct M9SlashCommandTests {

    // MARK: - Name validation

    @Test func nameValidationAcceptsLowercaseLettersDigitsHyphens() {
        #expect(ProjectSlashCommand.validateName("review") == nil)
        #expect(ProjectSlashCommand.validateName("deploy-staging") == nil)
        #expect(ProjectSlashCommand.validateName("step1") == nil)
    }

    @Test func nameValidationRejectsBadShapes() {
        #expect(ProjectSlashCommand.validateName("") != nil)
        #expect(ProjectSlashCommand.validateName("Review") != nil)       // uppercase
        #expect(ProjectSlashCommand.validateName("1leading") != nil)     // leading digit
        #expect(ProjectSlashCommand.validateName("with space") != nil)
        #expect(ProjectSlashCommand.validateName("under_score") != nil)  // underscore not allowed
        #expect(ProjectSlashCommand.validateName(String(repeating: "a", count: 65)) != nil)
    }

    // MARK: - Frontmatter parsing

    @Test func parseExtractsRequiredFields() throws {
        let raw = """
        ---
        name: review
        description: Code-review the current branch
        ---
        Review {{argument}}.
        """
        let cmd = try #require(
            ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/review.md")
        )
        #expect(cmd.name == "review")
        #expect(cmd.description == "Code-review the current branch")
        #expect(cmd.body.contains("Review {{argument}}."))
    }

    @Test func parseExtractsOptionalFields() throws {
        let raw = """
        ---
        name: deploy
        description: Deploy
        argumentHint: <env>
        model: claude-sonnet-4.5
        tags:
          - ops
          - deploy
        ---
        Deploy to {{argument}}.
        """
        let cmd = try #require(
            ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/deploy.md")
        )
        #expect(cmd.argumentHint == "<env>")
        #expect(cmd.model == "claude-sonnet-4.5")
        #expect(cmd.tags == ["ops", "deploy"])
    }

    @Test func parseRejectsMissingFrontmatter() {
        let raw = "Just a body, no frontmatter.\n"
        #expect(ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/x.md") == nil)
    }

    @Test func parseRejectsMissingRequiredFields() {
        let raw = """
        ---
        name: only
        ---
        Body.
        """
        // Missing description → nil.
        #expect(ProjectSlashCommandService.parse(raw, sourcePath: "/dev/null/x.md") == nil)
    }

    // MARK: - Argument substitution

    @Test func expandSubstitutesPlainArgument() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "Hello {{argument}}, how are you?",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let result = svc.expand(cmd, withArgument: "world")
        #expect(result.contains("Hello world, how are you?"))
        #expect(result.hasPrefix("<!-- scarf-slash:x -->\n"))
    }

    @Test func expandUsesDefaultWhenArgumentEmpty() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "Focus: {{argument | default: \"general\"}}.",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let empty = svc.expand(cmd, withArgument: "")
        #expect(empty.contains("Focus: general."))
        let provided = svc.expand(cmd, withArgument: "performance")
        #expect(provided.contains("Focus: performance."))
    }

    @Test func expandReplacesMultipleOccurrences() {
        let cmd = ProjectSlashCommand(
            name: "x",
            description: "x",
            body: "{{argument}} and {{argument}} again.",
            sourcePath: ""
        )
        let svc = ProjectSlashCommandService(context: .local)
        let result = svc.expand(cmd, withArgument: "foo")
        #expect(result.contains("foo and foo again."))
    }

    // MARK: - Round-trip on disk

    @Test func saveAndLoadRoundTripPreservesFields() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let ctx = ServerContext.local
        let svc = ProjectSlashCommandService(context: ctx)
        let original = ProjectSlashCommand(
            name: "review",
            description: "Code-review the branch",
            argumentHint: "<focus>",
            model: "claude-sonnet-4.5",
            tags: ["code-review"],
            body: "Review {{argument}}.\n",
            sourcePath: ""
        )
        try svc.save(original, at: tmp)

        let loaded = svc.loadCommands(at: tmp)
        #expect(loaded.count == 1)
        let r = try #require(loaded.first)
        #expect(r.name == "review")
        #expect(r.description == "Code-review the branch")
        #expect(r.argumentHint == "<focus>")
        #expect(r.model == "claude-sonnet-4.5")
        #expect(r.tags == ["code-review"])
        #expect(r.body.contains("Review {{argument}}."))
    }

    @Test func loadCommandsHandlesMissingDirGracefully() {
        let tmp = NSTemporaryDirectory() + "scarf-slash-missing-\(UUID().uuidString)"
        let svc = ProjectSlashCommandService(context: .local)
        // Dir doesn't exist → empty list, no throw.
        #expect(svc.loadCommands(at: tmp) == [])
    }

    @Test func deleteRemovesFileAndIsIdempotent() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let svc = ProjectSlashCommandService(context: .local)
        let cmd = ProjectSlashCommand(
            name: "tmp", description: "x", body: "x\n", sourcePath: ""
        )
        try svc.save(cmd, at: tmp)
        #expect(svc.loadCommands(at: tmp).count == 1)

        try svc.delete(named: "tmp", at: tmp)
        #expect(svc.loadCommands(at: tmp).isEmpty)
        // Deleting something already gone is a no-op.
        try svc.delete(named: "tmp", at: tmp)
    }

    @Test func saveRejectsInvalidName() async throws {
        let tmp = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let svc = ProjectSlashCommandService(context: .local)
        let bad = ProjectSlashCommand(
            name: "BadName", description: "x", body: "x\n", sourcePath: ""
        )
        do {
            try svc.save(bad, at: tmp)
            Issue.record("expected save to throw on uppercase name")
        } catch {
            // Expected
        }
    }

    // MARK: - ProjectContextBlock surfacing

    @Test func contextBlockListsSlashCommandsWhenPresent() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            configFieldsLine: "(none)",
            slashCommandNames: ["review", "deploy-staging"]
        ))
        #expect(block.contains("Project slash commands:"))
        #expect(block.contains("`/review`"))
        #expect(block.contains("`/deploy-staging`"))
        // Marker contract held: the block still has begin/end markers.
        #expect(block.hasPrefix("<!-- scarf-project:begin -->"))
        #expect(block.hasSuffix("<!-- scarf-project:end -->"))
    }

    @Test func contextBlockOmitsSlashCommandLineWhenEmpty() {
        let none = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            configFieldsLine: "(none)",
            slashCommandNames: []
        ))
        #expect(!none.contains("Project slash commands:"))
    }

    @Test func contextBlockIsIdempotent() {
        let a = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            configFieldsLine: "(none)",
            slashCommandNames: ["b", "a"] // unsorted on input
        ))
        let b = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "Demo",
            projectPath: "/tmp/demo",
            configFieldsLine: "(none)",
            slashCommandNames: ["a", "b"] // pre-sorted
        ))
        // Output is sorted internally — both inputs render identically.
        #expect(a == b)
    }

    // MARK: - v0.13 non-interruptive commands (WS-2 / Persistent Goals + /queue)

    @Test func nonInterruptiveListIncludesSteerAndQueueNotGoal() {
        // `/goal` and `/subgoal` are gateway-only and NOT advertised by
        // the ACP adapter, so they are no longer in this set (they used
        // to surface ACP slash-menu rows that no-op'd).
        let names = RichChatViewModel.nonInterruptiveCommands.map(\.name)
        #expect(names.contains("steer"))
        #expect(names.contains("queue"))
        #expect(!names.contains("goal"))
        #expect(!names.contains("subgoal"))
    }

    @MainActor
    @Test func availableCommandsNeverSurfacesGoalOrSubgoal() {
        // Even on a v0.13+ host with an active session, `/goal` and
        // `/subgoal` are not surfaced in the ACP slash menu.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.7)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(!names.contains("goal"))
        #expect(!names.contains("subgoal"))
    }

    @MainActor
    @Test func availableCommandsHidesQueueWhenCapabilityOff() {
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(.empty)
        let names = vm.availableCommands.map(\.name)
        #expect(!names.contains("queue"))
    }

    @MainActor
    @Test func availableCommandsExposesSteerAndQueueOnV013() {
        let vm = RichChatViewModel(context: .local)
        // /steer is gated on having an active session — nudging an
        // agent that isn't running has nothing to act on. Engage so
        // the filter lets it through.
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(names.contains("steer"))
        #expect(names.contains("queue"))
    }

    /// P37 finding 2: this test used to ASSERT the bug
    /// (`availableCommandsExposesSteerButHidesV013OnV012` expected `steer` on
    /// a v0.12 host). `steer` and `queue` are adjacent lines in the ACP
    /// adapter's command dict and arrived at the same tag
    /// (`acp_adapter/server.py:170`/`:171` @ `v2026.5.7`); `acp_adapter/` at
    /// `v2026.4.30` has neither. Both rows are hidden below the floor.
    @MainActor
    @Test func availableCommandsHidesBothSteerAndQueueOnV012() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(!names.contains("steer"))
        #expect(!names.contains("queue"))
    }

    @MainActor
    @Test func availableCommandsFollowsTheACPCompressSpellingFloor() {
        // The table that decides the spelling is the ACP adapter's, not
        // `hermes_cli/commands.py`: `_SLASH_COMMANDS` says `compact` through
        // v2026.7.20 (0.19.0) (`acp_adapter/server.py:459`) and `compress`
        // from v2026.7.30 (0.19.1) (`:574`), with no alias either way. So the
        // menu must change names at the floor, not pin one spelling.
        for (line, expected) in [
            ("Hermes Agent v0.12.0 (2026.4.30)", "compact"),
            ("Hermes Agent v0.19.0 (2026.7.20)", "compact"),
            ("Hermes Agent v0.19.1 (2026.7.30)", "compress"),
            ("Hermes Agent v0.20.0 (2026.8.3)", "compress"),
            ("Hermes Agent v0.21.1 (2026.9.7)", "compress")
        ] {
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("scratch-session")
            vm.publishCapabilities(HermesCapabilities.parseLine(line))
            let names = vm.availableCommands.map(\.name)
            let other = expected == "compress" ? "compact" : "compress"
            #expect(names.contains(expected), "\(line)")
            #expect(!names.contains(other), "\(line)")
            // Either spelling still lights the compress affordance.
            #expect(vm.supportsCompress, "\(line)")
        }
    }

    @MainActor
    @Test func availableCommandsUsesCompactOnUndetectedHost() {
        // An undetected host (`.empty` — the probe failed) must behave as the
        // OLDER one (C1): thirteen of the sixteen supported releases are
        // below the 0.19.1 rename, so `/compact` is the safer default.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        vm.publishCapabilities(.empty)
        let names = vm.availableCommands.map(\.name)
        #expect(names.contains("compact"))
        #expect(!names.contains("compress"))
        #expect(vm.supportsCompress)
    }

    @MainActor
    @Test func availableCommandsDedupesCompressAgainstACPAdvertised() {
        // When Hermes itself advertises `/compress` via
        // `available_commands_update`, the static fallback must not
        // duplicate it (or reintroduce `/compact`) alongside the
        // ACP-sourced entry.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        vm.publishCapabilities(caps)
        vm.handleACPEvent(
            .availableCommands(sessionId: "scratch-session", commands: [
                ["name": "compress", "description": "Compress the conversation history"]
            ])
        )
        let names = vm.availableCommands.map(\.name)
        #expect(names.filter { $0 == "compress" }.count == 1)
        #expect(!names.contains("compact"))
    }

    @Test func sessionRequiredCommandNamesCoversBothCompactSpellings() {
        // The grey-out set is capability-independent (static), so it
        // must cover both spellings even though only one is ever
        // surfaced in the menu at a time.
        // `compact` stays in the grey-out set even though the menu never
        // surfaces it: a 0.18.1+ host advertises the alias over ACP, and an
        // ACP-sourced `/compact` still needs a live session.
        #expect(RichChatViewModel.sessionRequiredCommandNames.contains("compact"))
        #expect(RichChatViewModel.sessionRequiredCommandNames.contains("compress"))
    }

    @MainActor
    @Test func recordQueuedPromptAppendsAndPopsFIFO() {
        let vm = RichChatViewModel(context: .local)
        vm.recordQueuedPrompt(text: "first")
        vm.recordQueuedPrompt(text: "second")
        vm.recordQueuedPrompt(text: "third")
        #expect(vm.queuedPrompts.count == 3)
        let popped = vm.popQueuedPrompt()
        #expect(popped?.text == "first")
        #expect(vm.queuedPrompts.count == 2)
        let next = vm.popQueuedPrompt()
        #expect(next?.text == "second")
        #expect(vm.queuedPrompts.first?.text == "third")
    }

    @MainActor
    @Test func subgoalNeverSurfacedInACPMenu() {
        // `/subgoal` is a gateway-only verb (not advertised by the ACP
        // adapter), so it never appears in the ACP slash menu — on any
        // host version.
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)"))
        var names = vm.availableCommands.map(\.name)
        #expect(!names.contains("subgoal"))
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)"))
        names = vm.availableCommands.map(\.name)
        #expect(!names.contains("subgoal"))
    }

    /// P34 replaces `v014ConfigCommandsRespectCapabilityGate`, which
    /// asserted the bug: it pinned `/yolo`, `/sessions` and
    /// `/codex-runtime` into the v0.14 ACP menu. All three are CLI/gateway
    /// CommandDefs (`hermes_cli/commands.py:181`, `:148`, `:156-158` @
    /// v2026.9.7) and appear nowhere under `acp_adapter/` at any tag, so
    /// the composer sending them burned a turn on the LLM. They are gone
    /// from the menu at v0.14 and at the target — the flags survive
    /// (source-verified floors, no consumer) with corrected doc comments.
    @MainActor
    @Test func v014ConfigCommandsAreNotInTheACPMenu() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        for line in [
            "Hermes Agent v0.13.0 (2026.5.7)",
            "Hermes Agent v0.14.0 (2026.5.16)",
            "Hermes Agent v0.21.1 (2026.9.7)"
        ] {
            let caps = HermesCapabilities.parseLine(line)
            vm.publishCapabilities(caps)
            let names = vm.availableCommands.map(\.name)
            #expect(!names.contains("yolo"), "\(line)")
            #expect(!names.contains("sessions"), "\(line)")
            #expect(!names.contains("codex-runtime"), "\(line)")
            // `hasYOLOSlashCommand` was deleted in P49 (round-5 decision 10):
            // no consumer, and `/yolo` is absent from `acp_adapter/` at every
            // tag. The sibling flags keep their verified v0.14 floor.
            #expect(caps.hasSessionsSlashCommand == caps.isV014OrLater)
        }
    }

    @MainActor
    @Test func recordQueuedPromptIgnoresBlank() {
        let vm = RichChatViewModel(context: .local)
        vm.recordQueuedPrompt(text: "")
        vm.recordQueuedPrompt(text: "   ")
        #expect(vm.queuedPrompts.isEmpty)
    }

    @MainActor
    @Test func popQueuedPromptOnEmptyReturnsNil() {
        let vm = RichChatViewModel(context: .local)
        #expect(vm.popQueuedPrompt() == nil)
    }

    @Test func isNonInterruptiveSlashRecognizesSteerAndQueueNotGoal() {
        // Non-MainActor: the helper itself isn't MainActor-isolated;
        // construct a VM on MainActor and read through it on the test
        // actor to keep the assertion focused on classification.
        // `/goal` is no longer an ACP non-interruptive command (gateway-
        // only); its typed-command path has its own explicit dispatch arm.
        Task { @MainActor in
            let vm = RichChatViewModel(context: .local)
            #expect(vm.isNonInterruptiveSlash("/queue summarize"))
            #expect(vm.isNonInterruptiveSlash("/queue"))
            #expect(vm.isNonInterruptiveSlash("/steer be careful"))
            #expect(!vm.isNonInterruptiveSlash("/goal finish v2.8"))
            #expect(!vm.isNonInterruptiveSlash("hello"))
            #expect(!vm.isNonInterruptiveSlash("/compress"))
        }
    }

    @MainActor
    @Test func resetClearsQueue() {
        let vm = RichChatViewModel(context: .local)
        vm.recordQueuedPrompt(text: "a")
        vm.recordQueuedPrompt(text: "b")
        #expect(vm.queuedPrompts.count == 2)
        vm.reset()
        #expect(vm.queuedPrompts.isEmpty)
    }

    // MARK: - Helpers

    static func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-slash-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    // MARK: - P34: the ACP slash roster the adapter actually dispatches

    /// The ACP adapter's whole slash surface, verbatim, walked across every
    /// `v2026.*` tag that ships an `acp_adapter/` (v2026.3.12 / 0.2.0 has
    /// none; v2026.3.17 / 0.3.0 is the first).
    ///
    /// - `help model tools context reset version` are in `_SLASH_COMMANDS`
    ///   from v2026.3.17 (`acp_adapter/server.py:453-463` @ v2026.7.20 has
    ///   the same six) — i.e. below Scarf's v0.6.0 support floor, so they
    ///   need no capability flag.
    /// - `steer` and `queue` join at v2026.5.7 (0.13.0) and are gated
    ///   elsewhere (`nonInterruptiveCommands` + `hasACPQueue`).
    /// - the compress command is spelled `compact` through v2026.7.20
    ///   (0.19.0) and `compress` from v2026.7.30 (0.19.1) — see
    ///   ``HermesCapabilities/hasACPCompressSpelling``.
    /// - at v2026.9.7 the dict moves to `acp_adapter/commands.py:44-66`
    ///   (`SlashCommandsMixin._COMMANDS`) with the same nine names — nine at
    ///   any ONE version, ten in total, because `compact` and `compress` are
    ///   the same slot spelled two ways and no tag has both — and
    ///   `_available_commands()` (`:69-74`) advertises exactly those.
    ///
    /// Unknown names are NOT errors: `_handle_slash_command` returns `None`
    /// for anything outside the dict and the text falls through to the LLM
    /// (`acp_adapter/commands.py:88-95` @ v2026.9.7), which is why a dead
    /// menu row costs a turn instead of showing a mistake.
    /// The cross-version UNION: ten names, because it holds BOTH spellings
    /// of the compress slot. Useful for "was this name ever an ACP command",
    /// useless for "is this the right name at THIS version" — see
    /// ``acpDispatchedNames(at:)``.
    static let acpDispatchedNamesUnion: Set<String> = [
        "help", "model", "tools", "context", "reset",
        "compact", "compress", "steer", "queue", "version"
    ]

    /// The nine names the adapter dispatches AT one version. The compress
    /// slot is resolved through the same function the roster uses, so a
    /// roster that offered `compact` on a v0.19.1 host (or `compress` on a
    /// v0.19.0 one) fails here instead of being waved through by the union.
    static func acpDispatchedNames(at caps: HermesCapabilities) -> Set<String> {
        [
            "help", "model", "tools", "context", "reset",
            RichChatViewModel.compressSlashName(capabilities: caps),
            "steer", "queue", "version"
        ]
    }

    /// Names Scarf used to offer that the ACP adapter has never dispatched
    /// at any of the 32 tags. `cost` never existed anywhere (the CLI verb is
    /// `usage`, `hermes_cli/commands.py:277` @ v2026.9.7); `clear` / `exit`
    /// are `cli_only` terminal commands (`:58`, `:302-303`);
    /// `reload-skills` (`:259-260`), `sessions` (`:148`), `codex-runtime`
    /// (`:156-158`) and `yolo` (`:181`) are CLI/gateway CommandDefs the ACP
    /// adapter does not wire.
    static let neverDispatchedByACP = [
        "clear", "cost", "reload-skills", "exit",
        "yolo", "sessions", "codex-runtime"
    ]

    /// The fallback roster on the target host is exactly the adapter's
    /// surface: `/new` (client-side) plus the seven interruptive ACP names.
    /// `/steer` and `/queue` come from `nonInterruptiveCommands`, not here.
    @Test func acpFallbackRosterMatchesTheAdapterAtV0211() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        let names = Set(
            RichChatViewModel.alwaysAvailableCommands(capabilities: caps).map(\.name)
        )
        #expect(names == ["new", "help", "model", "tools", "context", "reset", "compress", "version"])
    }

    /// Every name the fallback offers is either client-side (`/new`) or one
    /// the adapter dispatches at that version — on every supported host.
    @Test func everyFallbackNameIsDispatchedOrClientSide() {
        let hosts = [
            HermesCapabilities.empty,
            HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)"),
            HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)"),
            HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        ]
        for caps in hosts {
            let roster = RichChatViewModel.alwaysAvailableCommands(capabilities: caps)
            // The compress row must BE the version-appropriate spelling —
            // the point of making the expected set per-version.
            let compressRows = roster.map(\.name)
                .filter { $0 == "compact" || $0 == "compress" }
            #expect(compressRows == [RichChatViewModel.compressSlashName(capabilities: caps)],
                    "\(caps.versionLine): \(compressRows)")
            for cmd in roster {
                if cmd.name == "new" {
                    // Client-side: intercepted before the wire.
                    #expect(
                        RichChatViewModel.clientSideSlashCommand(for: "/new") != nil,
                        "\(caps.versionLine)"
                    )
                    continue
                }
                // Everything else IS sent to the transport verbatim, so it
                // must be a name the adapter dispatches.
                #expect(
                    RichChatViewModel.clientSideSlashCommand(for: "/\(cmd.name)") == nil,
                    "\(cmd.name) @ \(caps.versionLine)"
                )
                // Per-VERSION, not the union: the union holds both
                // `compact` and `compress`, so it could never catch a
                // roster offering the wrong spelling for the host.
                #expect(
                    Self.acpDispatchedNames(at: caps).contains(cmd.name),
                    "\(cmd.name) @ \(caps.versionLine)"
                )
            }
        }
    }

    /// `/cost` and the six other never-dispatched names are gone at every
    /// version, including an undetected host and a pre-floor one.
    @Test func neverDispatchedNamesAreAbsentAtEveryVersion() {
        let hosts = [
            HermesCapabilities.empty,
            HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)"),
            HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        ]
        for caps in hosts {
            let names = Set(
                RichChatViewModel.alwaysAvailableCommands(capabilities: caps).map(\.name)
            )
            for dead in Self.neverDispatchedByACP {
                #expect(!names.contains(dead), "\(dead) @ \(caps.versionLine)")
                #expect(
                    !RichChatViewModel.sessionRequiredCommandNames.contains(dead),
                    "\(dead) in the grey-out set"
                )
            }
        }
    }

    /// `reset`, `context` and `version` predate Scarf's v0.6.0 support floor
    /// (`_SLASH_COMMANDS` @ v2026.3.17, the first tag with an
    /// `acp_adapter/`), so they are offered unconditionally — including on
    /// an undetected host, where C1 says behave like the oldest one.
    @Test func resetContextVersionAreOfferedOnEveryHost() {
        let hosts = [
            HermesCapabilities.empty,
            HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        ]
        for caps in hosts {
            let names = Set(
                RichChatViewModel.alwaysAvailableCommands(capabilities: caps).map(\.name)
            )
            for live in ["reset", "context", "version"] {
                #expect(names.contains(live), "\(live) @ \(caps.versionLine)")
                #expect(RichChatViewModel.sessionRequiredCommandNames.contains(live))
            }
        }
    }

    /// Ordering: the fallback is only the pre-advertisement stand-in. Before
    /// `available_commands_update` arrives the menu is the fallback; once it
    /// arrives the advertised entries win and the fallback contributes no
    /// duplicate.
    @MainActor
    @Test func advertisedCommandsSupersedeTheFallbackRoster() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))

        // Pre-advertisement (the `session/load` case the fallback exists for).
        let before = vm.availableCommands
        #expect(before.contains { $0.name == "version" && $0.source == .alwaysAvailable })
        #expect(before.contains { $0.name == "reset" && $0.source == .alwaysAvailable })

        // The adapter advertises its nine (`_available_commands()`,
        // `acp_adapter/commands.py:69-74` @ v2026.9.7).
        vm.handleACPEvent(.availableCommands(sessionId: "scratch-session", commands: [
            ["name": "help", "description": "List available commands"],
            ["name": "model", "description": "Show current model and provider, or switch models"],
            ["name": "tools", "description": "List available tools with descriptions"],
            ["name": "context", "description": "Show conversation message counts by role"],
            ["name": "reset", "description": "Clear conversation history"],
            ["name": "compress", "description": "Compress conversation context"],
            ["name": "steer", "description": "Inject guidance into the currently running agent turn"],
            ["name": "queue", "description": "Queue a prompt to run after the current turn finishes"],
            ["name": "version", "description": "Show Hermes version"]
        ]))
        let after = vm.availableCommands
        for name in ["help", "model", "tools", "context", "reset", "compress", "steer", "queue", "version"] {
            #expect(after.filter { $0.name == name }.count == 1, "\(name)")
            #expect(after.first { $0.name == name }?.source == .acp, "\(name)")
        }
        // `/new` is Scarf's own affordance and survives the advertisement.
        #expect(after.contains { $0.name == "new" })
    }
}
