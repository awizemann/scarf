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

    @MainActor
    @Test func availableCommandsExposesSteerButHidesV013OnV012() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(names.contains("steer"))
        #expect(!names.contains("queue"))
    }

    @MainActor
    @Test func availableCommandsUsesCompactNamePreV020() {
        // Pre-0.20 hosts must render byte-identical to today: the
        // fallback command list surfaces `/compact`, never `/compress`.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.6.1)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(names.contains("compact"))
        #expect(!names.contains("compress"))
    }

    @MainActor
    @Test func availableCommandsUsesCompressNameOnV020() {
        // v0.20+ hosts renamed the ACP command; the fallback list must
        // switch to `/compress` and never show `/compact` alongside it.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        vm.publishCapabilities(caps)
        let names = vm.availableCommands.map(\.name)
        #expect(names.contains("compress"))
        #expect(!names.contains("compact"))
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
        #expect(RichChatViewModel.sessionRequiredCommandNames.contains("compact"))
        #expect(RichChatViewModel.sessionRequiredCommandNames.contains("compress"))
    }

    @Test func parseGoalArgumentRecognizesClearVariants() {
        #expect(RichChatViewModel.parseGoalArgument("--clear") == .clear)
        #expect(RichChatViewModel.parseGoalArgument("clear") == .clear)
        #expect(RichChatViewModel.parseGoalArgument("Clear") == .clear)
        #expect(RichChatViewModel.parseGoalArgument("  --clear  ") == .clear)
    }

    @Test func parseGoalArgumentReturnsSetForArbitraryText() {
        #expect(
            RichChatViewModel.parseGoalArgument("finish v2.8 on time")
                == .set("finish v2.8 on time")
        )
        // Whitespace around set text is trimmed.
        #expect(
            RichChatViewModel.parseGoalArgument("   ship it   ")
                == .set("ship it")
        )
    }

    @Test func parseGoalArgumentReturnsEmptyForBlank() {
        #expect(RichChatViewModel.parseGoalArgument("") == .empty)
        #expect(RichChatViewModel.parseGoalArgument("   ") == .empty)
        #expect(RichChatViewModel.parseGoalArgument("\n\t") == .empty)
    }

    @MainActor
    @Test func recordActiveGoalSetsAndClears() {
        let vm = RichChatViewModel(context: .local)
        #expect(vm.activeGoal == nil)
        vm.recordActiveGoal(text: "ship v2.8")
        let goal = vm.activeGoal
        #expect(goal?.text == "ship v2.8")
        vm.recordActiveGoal(text: nil)
        #expect(vm.activeGoal == nil)
        // Empty / whitespace also clears.
        vm.recordActiveGoal(text: "x")
        vm.recordActiveGoal(text: "   ")
        #expect(vm.activeGoal == nil)
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

    // MARK: - /subgoal (Hermes v0.14)

    @Test func parseSubgoalArgumentRecognizesClear() {
        #expect(RichChatViewModel.parseSubgoalArgument("clear") == .clear)
        #expect(RichChatViewModel.parseSubgoalArgument("Clear") == .clear)
        #expect(RichChatViewModel.parseSubgoalArgument("--clear") == .clear)
        #expect(RichChatViewModel.parseSubgoalArgument("  --clear  ") == .clear)
    }

    @Test func parseSubgoalArgumentRecognizesRemoveN() {
        #expect(RichChatViewModel.parseSubgoalArgument("remove 1") == .remove(1))
        #expect(RichChatViewModel.parseSubgoalArgument("remove 12") == .remove(12))
        #expect(RichChatViewModel.parseSubgoalArgument("rm 3") == .remove(3))
        // Non-positive indices fall through to .add so Hermes can reject them.
        #expect(RichChatViewModel.parseSubgoalArgument("remove 0") == .add("remove 0"))
        #expect(RichChatViewModel.parseSubgoalArgument("remove -1") == .add("remove -1"))
        #expect(RichChatViewModel.parseSubgoalArgument("remove abc") == .add("remove abc"))
    }

    @Test func parseSubgoalArgumentRecognizesEmpty() {
        #expect(RichChatViewModel.parseSubgoalArgument("") == .empty)
        #expect(RichChatViewModel.parseSubgoalArgument("   ") == .empty)
    }

    @Test func parseSubgoalArgumentDefaultIsAdd() {
        #expect(
            RichChatViewModel.parseSubgoalArgument("don't break the API")
                == .add("don't break the API")
        )
        // Whitespace is trimmed.
        #expect(
            RichChatViewModel.parseSubgoalArgument("  no regressions  ")
                == .add("no regressions")
        )
    }

    @MainActor
    @Test func recordSubgoalAddedAppends() {
        let vm = RichChatViewModel(context: .local)
        vm.recordSubgoalAdded("a")
        vm.recordSubgoalAdded("b")
        vm.recordSubgoalAdded("c")
        #expect(vm.activeSubgoals == ["a", "b", "c"])
        // Whitespace-only input is a no-op.
        vm.recordSubgoalAdded("   ")
        #expect(vm.activeSubgoals == ["a", "b", "c"])
    }

    @MainActor
    @Test func recordSubgoalRemovedAtIndex() {
        let vm = RichChatViewModel(context: .local)
        vm.recordSubgoalAdded("a")
        vm.recordSubgoalAdded("b")
        vm.recordSubgoalAdded("c")
        // 1-indexed: removing 2 drops "b".
        vm.recordSubgoalRemoved(2)
        #expect(vm.activeSubgoals == ["a", "c"])
        // Out-of-range is a silent no-op.
        vm.recordSubgoalRemoved(99)
        vm.recordSubgoalRemoved(0)
        #expect(vm.activeSubgoals == ["a", "c"])
    }

    @MainActor
    @Test func recordSubgoalsClearedEmptiesList() {
        let vm = RichChatViewModel(context: .local)
        vm.recordSubgoalAdded("a")
        vm.recordSubgoalAdded("b")
        vm.recordSubgoalsCleared()
        #expect(vm.activeSubgoals.isEmpty)
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

    @MainActor
    @Test func v014ConfigCommandsRespectCapabilityGate() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        // None of /yolo /sessions /codex-runtime on a v0.13 host.
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)"))
        var names = vm.availableCommands.map(\.name)
        #expect(!names.contains("yolo"))
        #expect(!names.contains("sessions"))
        #expect(!names.contains("codex-runtime"))
        // All three show up on a v0.14 host.
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)"))
        names = vm.availableCommands.map(\.name)
        #expect(names.contains("yolo"))
        #expect(names.contains("sessions"))
        #expect(names.contains("codex-runtime"))
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
    @Test func resetClearsGoalAndQueue() {
        let vm = RichChatViewModel(context: .local)
        vm.recordActiveGoal(text: "x")
        vm.recordQueuedPrompt(text: "a")
        vm.recordQueuedPrompt(text: "b")
        #expect(vm.activeGoal != nil)
        #expect(vm.queuedPrompts.count == 2)
        vm.reset()
        #expect(vm.activeGoal == nil)
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
}
