import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit phase B04: Kanban reads and completion, the Kanban toolset
/// onboarding platform, profile-route ranking and profile export naming.
///
/// The JSON fixtures below are VERBATIM output of the tagged Hermes
/// (`~/.hermes/hermes-agent-v0215` @ `v2026.9.24`, its own `.venv/bin/hermes`)
/// against a scratch `HERMES_HOME`, produced by:
///
///     hermes kanban create "Ship it" --assignee alice --json
///     hermes kanban create "Second" --json
///     hermes kanban comment --author=alan -- <id> "first note"
///     hermes kanban comment -- <id> 'second note, with "quotes"'
///     hermes kanban block -- <id> "waiting on design"
///     hermes kanban unblock -- <id>
///     hermes kanban complete -- <id>        # exit 1: completion blocked
///     hermes kanban show <id> --json
///     hermes kanban stats --json
@Suite struct HermesBlindB04KanbanProfilesTests {

    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    static let realShowJSON = #"""
    {"task":{"id":"t_0657ff64","title":"Ship it","body":null,"assignee":"alice","status":"ready","priority":0,"tenant":null,"workspace_kind":"scratch","workspace_path":null,"branch_name":null,"project_id":null,"created_by":"user","created_at":1790545185,"started_at":null,"completed_at":null,"result":null,"skills":[],"max_runtime_seconds":null,"max_retries":null,"model_override":null,"provider_override":null,"session_id":null,"workflow_template_id":null,"current_step_key":null,"completion_contract":"local-only","last_failure_error":null},"latest_summary":"waiting on design","parents":[],"children":[],"comments":[{"author":"alan","body":"first note","created_at":1790545192},{"author":"default","body":"second note, with \"quotes\"","created_at":1790545192},{"author":"default","body":"BLOCKED: waiting on design","created_at":1790545192}],"events":[{"kind":"created","payload":{"assignee":"alice","status":"ready","parents":[],"creator_task_id":null,"tenant":null,"workspace_kind":"scratch","workspace_path":null,"branch_name":null,"project_id":null,"skills":null,"goal_mode":null,"model_override":null,"provider_override":null},"created_at":1790545185,"run_id":null},{"kind":"commented","payload":{"author":"alan","len":10},"created_at":1790545192,"run_id":null},{"kind":"commented","payload":{"author":"default","len":26},"created_at":1790545192,"run_id":null},{"kind":"commented","payload":{"author":"default","len":26},"created_at":1790545192,"run_id":null},{"kind":"blocked","payload":{"reason":"waiting on design","kind":null,"recurrences":1,"source_status":"ready"},"created_at":1790545192,"run_id":1},{"kind":"unblocked","payload":null,"created_at":1790545193,"run_id":null},{"kind":"completion_blocked_empty_result","payload":{"result_preview":null,"summary_preview":null},"created_at":1790545193,"run_id":null}],"runs":[{"id":1,"profile":"alice","step_key":null,"status":"blocked","outcome":"blocked","summary":"waiting on design","error":null,"metadata":null,"worker_pid":null,"started_at":1790545192,"ended_at":1790545192}]}
    """#

    static let realStatsJSON = #"""
    {
      "by_status": {
        "ready": 2
      },
      "by_assignee": {
        "alice": {
          "ready": 1
        }
      },
      "oldest_ready_age_seconds": 9,
      "now": 1790545194
    }
    """#

    // MARK: - S13-F1: comments and events from `kanban show --json`

    @Test func realShowOutputKeepsEveryCommentWithStableUniqueIds() throws {
        let detail = try JSONDecoder().decode(
            HermesKanbanTaskDetail.self, from: Data(Self.realShowJSON.utf8))
        // Before the fix: 0 comments (the required `id` failed every element
        // and one `try?` dropped the array).
        #expect(detail.comments.map(\.body) == [
            "first note", "second note, with \"quotes\"", "BLOCKED: waiting on design",
        ])
        #expect(detail.comments.map(\.author) == ["alan", "default", "default"])
        #expect(detail.comments.map(\.id) == [1, 2, 3])
        #expect(detail.comments.allSatisfy { $0.taskId == "t_0657ff64" })
        #expect(!detail.comments[0].createdAt.isEmpty)

        // Events all decoded as id 0 before, so `ForEach(events)` had seven
        // rows with one identity.
        try #require(detail.events.count == 7)
        #expect(Set(detail.events.map(\.id)).count == 7)
        #expect(detail.events.map(\.kind).first == "created")
        #expect(detail.events.map(\.kind).last == "completion_blocked_empty_result")
        #expect(detail.events[4].runId == 1)
    }

    @Test func idsStayStableWhenAppendOnlyListsGrow() throws {
        let first = try JSONDecoder().decode(
            HermesKanbanTaskDetail.self, from: Data(Self.realShowJSON.utf8))
        // A new comment lands last (`list_comments` orders `created_at ASC`).
        let grown = Self.realShowJSON.replacingOccurrences(
            of: #"{"author":"default","body":"BLOCKED: waiting on design","created_at":1790545192}]"#,
            with: #"{"author":"default","body":"BLOCKED: waiting on design","created_at":1790545192},{"author":"bob","body":"late","created_at":1790545300}]"#)
        let second = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(grown.utf8))
        try #require(second.comments.count == 4)
        // Existing rows keep their identity; the new one gets a fresh one.
        #expect(Array(second.comments.prefix(3)) == first.comments)
        #expect(second.comments[3].id == 4)
    }

    @Test func oneMalformedCommentCostsOnlyThatComment() throws {
        let json = """
        {"task": {"id": "t_1", "title": "x", "status": "ready"},
         "comments": [
           {"author": "a", "body": "kept", "created_at": 1},
           {"author": "b", "body": {"not": "a string"}, "created_at": 2},
           {"author": "c", "body": "also kept", "created_at": 3}
         ],
         "events": [{"kind": "created", "created_at": "not-a-number", "run_id": "x"}]}
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        #expect(detail.comments.map(\.body) == ["kept", "also kept"])
        #expect(detail.comments.map(\.id) == [1, 2])
        try #require(detail.events.count == 1)
        #expect(detail.events[0].runId == nil)
    }

    @Test func distinctWireIdsAreKept() throws {
        let json = """
        {"task": {"id": "t_1", "title": "x", "status": "ready"},
         "comments": [{"id": 17, "body": "a"}, {"id": 21, "body": "b"}],
         "events": [{"id": 5, "kind": "created"}, {"id": 5, "kind": "claimed"}]}
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        #expect(detail.comments.map(\.id) == [17, 21])
        // Duplicate wire ids cannot be used as identities; positions are.
        #expect(detail.events.map(\.id) == [1, 2])
    }

    // MARK: - S13-F2: `kanban stats --json`

    @Test func realStatsWithAnAssignedTaskDecodes() throws {
        let stats = try JSONDecoder().decode(
            HermesKanbanStats.self, from: Data(Self.realStatsJSON.utf8))
        #expect(stats.byStatus == ["ready": 2])
        #expect(stats.byAssignee == ["alice": ["ready": 1]])
        #expect(stats.glanceString == "2 ready")
        #expect(stats.oldestReadyAgeSeconds == 9)
    }

    @Test func anUnexpectedBreakdownShapeDoesNotCostTheGlance() throws {
        let json = #"{"by_status": {"todo": 3}, "by_assignee": {"alice": 4}, "by_tenant": [1]}"#
        let stats = try JSONDecoder().decode(HermesKanbanStats.self, from: Data(json.utf8))
        #expect(stats.glanceString == "3 todo")
        #expect(stats.byAssignee.isEmpty)
    }

    // MARK: - S13-F3: evidence-less completion

    @Test func emptyCompletionGateFloorIsV0214() {
        #expect(!Self.v0213.hasKanbanEmptyCompletionGate)
        #expect(Self.v0214.hasKanbanEmptyCompletionGate)
        #expect(Self.v0215.hasKanbanEmptyCompletionGate)
        #expect(!HermesCapabilities.empty.hasKanbanEmptyCompletionGate)
    }

    @Test func completionNeedsAResultFromEveryColumnButReviewOnGatedHosts() throws {
        let sources: [KanbanBoardColumn] = [.upNext, .running, .blocked, .scheduled]
        for source in sources {
            let gated = try KanbanService.plan(
                for: KanbanTransition(from: source, to: .done), caps: Self.v0214)
            #expect(gated.requiresCompleteResult, "\(source) -> done on 0.21.4")
            let older = try KanbanService.plan(
                for: KanbanTransition(from: source, to: .done), caps: Self.v0213)
            #expect(!older.requiresCompleteResult, "\(source) -> done on 0.21.3")
            #expect(gated.steps.count == older.steps.count)
        }
        // Review approval is exempt (`_gate_empty_completion` returns early
        // for `review`, kanban_db.py:2877-2878 @ v2026.9.24).
        let review = try KanbanService.plan(
            for: KanbanTransition(from: .review, to: .done), caps: Self.v0215)
        #expect(!review.requiresCompleteResult)
    }

    // MARK: - S03-F3 / S13-F4: Kanban toolset for Scarf's (ACP) chats

    @Test func chatPlatformIsACPFromV0215Only() {
        #expect(!Self.v0214.hasACPPlatformToolsets)
        #expect(Self.v0215.hasACPPlatformToolsets)
        #expect(KanbanToolsetDetector.chatPlatform(for: Self.v0215) == "acp")
        #expect(KanbanToolsetDetector.chatPlatform(for: Self.v0214) == "cli")
        #expect(KanbanToolsetDetector.chatPlatform(for: .empty) == "cli")
    }

    /// Hermes's rule, checked against `_get_platform_tools(config, "acp")`
    /// from the tag's venv for each of these configs.
    @Test func classifyACPFollowsHermesResolution() {
        func state(_ yaml: String) -> KanbanToolsetState { KanbanToolsetDetector.classifyACP(yaml: yaml) }
        // The shape the audit found: kanban on cli only — ACP chats have none.
        #expect(state("platform_toolsets:\n  cli:\n  - hermes-cli\n  - kanban\n") == .disabled(platform: "acp"))
        // Absent acp list: the legacy top-level opt-in applies.
        #expect(state("toolsets:\n- kanban\n") == .enabled(via: .topLevelToolset))
        #expect(state("toolsets: [kanban]\n") == .enabled(via: .topLevelToolset))
        // A saved acp list is authoritative, even with the top-level opt-in.
        #expect(state("toolsets:\n- kanban\nplatform_toolsets:\n  acp:\n  - hermes-acp\n") == .disabled(platform: "acp"))
        #expect(state("toolsets:\n- kanban\nplatform_toolsets:\n  acp: []\n") == .disabled(platform: "acp"))
        // A null acp key is not a saved list: the top-level opt-in applies.
        #expect(state("toolsets:\n- kanban\nplatform_toolsets:\n  acp:\n  cli:\n  - hermes-cli\n") == .enabled(via: .topLevelToolset))
        #expect(state("platform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n") == .enabled(via: .platform("acp")))
        #expect(state("platform_toolsets:\n  acp: [hermes-acp, kanban]\n") == .enabled(via: .platform("acp")))
        #expect(state("platform_toolsets:\n  acp: \"[hermes-acp, kanban]\"\n") == .enabled(via: .platform("acp")))
        // A scalar is not a list: Hermes warns and uses the default.
        #expect(state("platform_toolsets:\n  acp: kanban\n") == .disabled(platform: "acp"))
    }

    /// Write with Scarf, read back with Scarf. Each rewritten YAML below was
    /// also fed to the tag's `_get_platform_tools(config, "acp")`: every one
    /// resolves to the `hermes-acp` default set plus `kanban`, removing nothing.
    @Test func enableACPRoundTrips() throws {
        let cases: [(input: String, expected: String)] = [
            // Most hosts: no acp list at all. Seeded with hermes-acp so the
            // chat keeps its default tools.
            ("model:\n  default: x\n",
             "model:\n  default: x\nplatform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n"),
            ("model:\n  default: x",
             "model:\n  default: x\nplatform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n"),
            // A block with other platforms: acp appended inside it, before the
            // next top-level key.
            ("platform_toolsets:\n  cli:\n  - hermes-cli\n  - kanban\nmodel:\n  default: x\n",
             "platform_toolsets:\n  cli:\n  - hermes-cli\n  - kanban\n  acp:\n  - hermes-acp\n  - kanban\nmodel:\n  default: x\n"),
            // An existing acp list gets kanban inserted, nothing else changes.
            ("platform_toolsets:\n  acp:\n  - file\n  - terminal\n",
             "platform_toolsets:\n  acp:\n  - file\n  - kanban\n  - terminal\n"),
            ("platform_toolsets:\n  acp: [hermes-acp]\n",
             "platform_toolsets:\n  acp: [hermes-acp, kanban]\n"),
            ("platform_toolsets:\n  acp: []\n",
             "platform_toolsets:\n  acp: [kanban]\n"),
            // Null key: items added under it, and the `null` value dropped.
            ("platform_toolsets:\n  acp: null\n  cli:\n  - hermes-cli\n",
             "platform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n  cli:\n  - hermes-cli\n"),
            // Brackets in a trailing comment are not a flow list.
            ("platform_toolsets:\n  acp: [hermes-acp] # see [docs]\n",
             "platform_toolsets:\n  acp: [hermes-acp, kanban] # see [docs]\n"),
            ("platform_toolsets:\n  acp:  # see [docs]\n  - hermes-acp\n",
             "platform_toolsets:\n  acp:  # see [docs]\n  - hermes-acp\n  - kanban\n"),
            // Top-level opt-in shadowed by a saved acp list: still written.
            ("toolsets:\n- kanban\nplatform_toolsets:\n  acp:\n  - hermes-acp\n",
             "toolsets:\n- kanban\nplatform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n"),
        ]
        for (input, expected) in cases {
            #expect(KanbanToolsetDetector.classifyACP(yaml: input) == .disabled(platform: "acp"))
            guard case .rewrite(let out) = KanbanToolsetEnabler.planEnableACP(yaml: input) else {
                Issue.record("expected a rewrite for:\n\(input)")
                continue
            }
            #expect(out == expected)
            #expect(KanbanToolsetDetector.classifyACP(yaml: out).isEnabled)
            // Idempotent: a second enable is a no-op.
            #expect(KanbanToolsetEnabler.planEnableACP(yaml: out) == .alreadyPresent)
        }
    }

    @Test func enableACPIsANoOpOrRefusalWhereItShouldBe() {
        #expect(KanbanToolsetEnabler.planEnableACP(yaml: "toolsets:\n- kanban\n") == .alreadyPresent)
        guard case .refuse = KanbanToolsetEnabler.planEnableACP(
            yaml: "platform_toolsets:\n  acp: kanban\n") else {
            Issue.record("a scalar acp value must be refused"); return
        }
        guard case .refuse = KanbanToolsetEnabler.planEnableACP(
            yaml: "platform_toolsets: {cli: [hermes-cli]}\n") else {
            Issue.record("an inline platform_toolsets must be refused, not given a second key"); return
        }
        guard case .refuse = KanbanToolsetEnabler.planEnableACP(
            yaml: "platform_toolsets:\n  acp: \"[hermes-acp]\"\n") else {
            Issue.record("a quoted list literal must be refused"); return
        }
    }

    /// The pre-0.21.5 `cli` path is unchanged: same plan as before this phase.
    @Test func cliPlanIsUnchanged() {
        let yaml = "platform_toolsets:\n  cli:\n  - browser\n  - web\n"
        #expect(KanbanToolsetEnabler.planEnable(yaml: yaml, platform: "cli")
                == .rewrite("platform_toolsets:\n  cli:\n  - browser\n  - kanban\n  - web\n"))
        #expect(KanbanToolsetEnabler.planEnable(yaml: "toolsets:\n- kanban\n", platform: "cli") == .alreadyPresent)
    }

    @Test func enableACPWritesTheFileAndTheDetectorAgrees() async throws {
        let home = try B04TempHome()
        defer { home.cleanup() }
        try "model:\n  default: x\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let detector = KanbanToolsetDetector(context: home.context)
        #expect(await detector.detect(platform: "acp") == .disabled(platform: "acp"))
        let result = await KanbanToolsetEnabler(context: home.context).enable(platform: "acp")
        #expect(result == .enabled)
        #expect(await detector.detect(platform: "acp") == .enabled(via: .platform("acp")))
        let written = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(written.contains("  acp:\n  - hermes-acp\n  - kanban\n"))
        // cli untouched, so a pre-0.21.5 reading of the same file is as before.
        #expect(await detector.detect(platform: "cli") == .disabled(platform: "cli"))
    }

    // MARK: - S13-F5: profile routes rank `user_id` and scope `bot_profile`

    static let routesYAML = """
    profile_routes:
      - name: loc
        platform: telegram
        profile: work
        chat_id: '100'
        thread_id: '5'
      - name: dm-user
        platform: telegram
        profile: personal
        user_id: '42'
      - name: blank-user
        platform: telegram
        profile: other
        user_id: ''
      - name: bot-scoped
        platform: telegram
        profile: work
        bot_profile: sales
    """

    @Test func routeFloors() {
        #expect(!Self.v0213.hasProfileRouteUserID)
        #expect(Self.v0214.hasProfileRouteUserID)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)").hasProfileRouteBotScope == false)
        #expect(Self.v0213.hasProfileRouteBotScope)
    }

    /// The v0.21.4+ order matches `parse_profile_routes` run on this block
    /// from the tag's venv: dm-user (16), loc (12), bot-scoped (0);
    /// blank-user skipped ("user_id cannot be null or empty").
    @Test func userIDOutranksLocationRulesOnV0214() throws {
        let block = ProfileRoutesYAML.parse(Self.routesYAML)
        try #require(block.routes.count == 4)
        let ranked = block.effectiveOrder(capabilities: Self.v0214)
        #expect(ranked.map(\.name) == ["dm-user", "loc", "bot-scoped"])
        #expect(ranked[0].specificity(capabilities: Self.v0214) == 16)
        let blank = block.routes[2]
        #expect(blank.userID == "")
        #expect(!blank.isAcceptedByHermes(capabilities: Self.v0214))
        #expect(blank.rejectionReason(capabilities: Self.v0214) != nil)
        #expect(block.routes[1].scopeSummary(capabilities: Self.v0214) == "telegram · user 42")
        #expect(block.routes[3].scopeSummary(capabilities: Self.v0214) == "telegram · bot sales · any server/channel")
        // Round trip: the keys Scarf does not edit stay in the file verbatim.
        let rewritten = ProfileRoutesWriter.render(routes: block.routes, keyIndent: 0)
        #expect(rewritten.contains { $0.contains("user_id: '42'") })
        #expect(rewritten.contains { $0.contains("bot_profile: sales") })
    }

    /// Before v0.21.4 Hermes ignores `user_id` (and before v0.21.3
    /// `bot_profile`), so the older reading is unchanged.
    @Test func olderHostsRankAsBefore() {
        let block = ProfileRoutesYAML.parse(Self.routesYAML)
        #expect(block.effectiveOrder(capabilities: Self.v0213).map(\.name)
                == ["loc", "dm-user", "blank-user", "bot-scoped"])
        #expect(block.routes[1].scopeSummary(capabilities: .empty) == "telegram · any server/channel")
        #expect(block.routes[3].scopeSummary(capabilities: .empty) == "telegram · any server/channel")
        #expect(block.routes[3].scopeSummary(capabilities: Self.v0213) == "telegram · bot sales · any server/channel")
    }
}

/// A throwaway local Hermes home for the enable round trip.
private struct B04TempHome {
    let url: URL
    let context: ServerContext

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        context = ServerContext.local(home: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}
