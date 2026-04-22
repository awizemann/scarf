import Testing
import Foundation
@testable import ScarfCore

/// Smoke test — catches "does the package link?"-class regressions.
@Suite struct ScarfCoreSmokeTests {
    @Test func packageLinks() {
        // If this compiles and runs, ScarfCore loaded.
    }
}

/// Exercises every `public init` generated in M0a. If any memberwise init's
/// parameter list drifted away from the stored properties (wrong order, wrong
/// type, missing field), the compiler fails here — the whole point of these
/// tests is to give the Linux CI something to catch that before a reviewer
/// has to build on a Mac.
@Suite struct M0aPublicInitTests {
    @Test func hermesSessionInitAndDerivations() {
        let s = HermesSession(
            id: "s1",
            source: "cli",
            userId: "u",
            model: "gpt-4",
            title: "Hello",
            parentSessionId: nil,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            endReason: nil,
            messageCount: 3,
            toolCallCount: 1,
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: 0.01,
            reasoningTokens: 50,
            actualCostUSD: nil,
            costStatus: nil,
            billingProvider: nil
        )
        #expect(s.displayTitle == "Hello")
        #expect(s.totalTokens == 350)
        #expect(s.duration == 60)
        #expect(s.isSubagent == false)
        #expect(s.costIsActual == false)
        #expect(s.displayCostUSD == 0.01)
        // Subagent variant
        let child = s.withTitle("Child")
        #expect(child.displayTitle == "Child")
    }

    @Test func hermesMessageInitAndRolePredicates() {
        let user = HermesMessage(
            id: 1, sessionId: "s", role: "user", content: "hi",
            toolCallId: nil, toolCalls: [], toolName: nil,
            timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil
        )
        #expect(user.isUser && !user.isAssistant && !user.isToolResult)

        let asst = HermesMessage(
            id: 2, sessionId: "s", role: "assistant", content: "hello",
            toolCallId: nil, toolCalls: [], toolName: nil,
            timestamp: nil, tokenCount: nil, finishReason: nil,
            reasoning: "thinking..."
        )
        #expect(asst.isAssistant && asst.hasReasoning)
    }

    @Test func hermesToolCallExplicitInit() {
        let call = HermesToolCall(callId: "c1", functionName: "read_file", arguments: "{\"path\":\"/tmp\"}")
        #expect(call.id == "c1")
        #expect(call.toolKind == .read)
        #expect(call.argumentsSummary == "/tmp")
    }

    @Test func hermesConfigEmptyAndMemberwise() {
        // `.empty` exercises every nested init internally — if any nested
        // settings struct's init drifted, HermesConfig.empty would fail to
        // compile. Importing and touching .empty proves the chain works.
        let c = HermesConfig.empty
        #expect(c.model == "unknown")
        #expect(c.display.skin == "default")
        #expect(c.terminal.cwd == ".")
        #expect(c.browser.inactivityTimeout == 120)
        #expect(c.security.redactSecrets == true)
        #expect(c.humanDelay.mode == "off")
        #expect(c.compression.enabled == true)
        #expect(c.checkpoints.enabled == true)
        #expect(c.logging.level == "INFO")
        #expect(c.discord.requireMention == true)
        #expect(c.telegram.reactions == false)
        #expect(c.slack.replyToMode == "first")
        #expect(c.matrix.autoThread == true)
        #expect(c.mattermost.replyMode == "off")
        #expect(c.whatsapp.unauthorizedDMBehavior == "pair")
        #expect(c.homeAssistant.cooldownSeconds == 30)
        #expect(c.auxiliary.vision.provider == "auto")
    }

    @Test func hermesCronJobCodableRoundTrip() throws {
        let json = """
        {
          "id": "job1",
          "name": "Daily Summary",
          "prompt": "summarize yesterday",
          "skills": ["email"],
          "model": null,
          "schedule": { "kind": "daily", "run_at": "09:00", "display": "Every day 9am", "expression": null },
          "enabled": true,
          "state": "scheduled",
          "deliver": "discord:general:chat-chan",
          "next_run_at": "2026-04-23T09:00:00Z",
          "last_run_at": null,
          "last_error": null,
          "pre_run_script": null,
          "delivery_failures": 0,
          "last_delivery_error": null,
          "timeout_type": "soft",
          "timeout_seconds": 300,
          "silent": false
        }
        """
        let job = try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
        #expect(job.id == "job1")
        #expect(job.stateIcon == "clock")
        #expect(job.deliveryDisplay == "Discord thread chat-chan in general")
        #expect(job.schedule.kind == "daily")
        #expect(job.silent == false)

        // Re-encode and decode again to confirm encoder output is valid.
        let encoded = try JSONEncoder().encode(job)
        let roundTripped = try JSONDecoder().decode(HermesCronJob.self, from: encoded)
        #expect(roundTripped.id == job.id)
    }

    @Test func hermesMCPServerInit() {
        let server = HermesMCPServer(
            name: "gh", transport: .stdio, command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            url: nil, auth: nil,
            env: ["GITHUB_TOKEN": "x"], headers: [:],
            timeout: 30, connectTimeout: 5, enabled: true,
            toolsInclude: [], toolsExclude: [],
            resourcesEnabled: true, promptsEnabled: true, hasOAuthToken: false
        )
        #expect(server.id == "gh")
        #expect(server.summary == "npx -y @modelcontextprotocol/server-github")

        let http = HermesMCPServer(
            name: "linear", transport: .http, command: nil, args: [],
            url: "https://mcp.linear.app/sse", auth: "oauth",
            env: [:], headers: [:], timeout: nil, connectTimeout: nil,
            enabled: true, toolsInclude: [], toolsExclude: [],
            resourcesEnabled: true, promptsEnabled: true, hasOAuthToken: true
        )
        #expect(http.summary == "https://mcp.linear.app/sse")
    }

    @Test func mcpServerPresetGalleryReadable() {
        #expect(!MCPServerPreset.gallery.isEmpty)
        #expect(MCPServerPreset.gallery.contains { $0.id == "filesystem" })
        // Every preset in the gallery should have a docsURL.
        for p in MCPServerPreset.gallery {
            #expect(!p.docsURL.isEmpty)
        }
    }

    @Test func hermesPathSetDerivations() {
        let local = HermesPathSet(home: "/Users/alan/.hermes", isRemote: false, binaryHint: nil)
        #expect(local.stateDB == "/Users/alan/.hermes/state.db")
        #expect(local.memoryMD == "/Users/alan/.hermes/memories/MEMORY.md")
        #expect(local.userMD == "/Users/alan/.hermes/memories/USER.md")
        #expect(local.projectsRegistry == "/Users/alan/.hermes/scarf/projects.json")
        // hermesBinary on local looks up real fs — we can only guarantee it
        // returns one of the candidates (or the fallback).
        #expect(HermesPathSet.hermesBinaryCandidates.contains(local.hermesBinary)
                || local.hermesBinary == HermesPathSet.hermesBinaryCandidates[0])

        let remote = HermesPathSet(home: "~/.hermes", isRemote: true, binaryHint: "/usr/local/bin/hermes")
        #expect(remote.hermesBinary == "/usr/local/bin/hermes")
        let remoteNoHint = HermesPathSet(home: "~/.hermes", isRemote: true, binaryHint: nil)
        #expect(remoteNoHint.hermesBinary == "hermes")
    }

    @Test func hermesSkillInit() {
        let skill = HermesSkill(
            id: "email.send", name: "send email", category: "Email",
            path: "/a/b", files: ["send.py"], requiredConfig: ["SMTP_HOST"]
        )
        let cat = HermesSkillCategory(id: "email", name: "Email", skills: [skill])
        #expect(cat.skills.first?.id == "email.send")
    }

    @Test func hermesSlashCommandInit() {
        let acp = HermesSlashCommand(name: "/clear", description: "Clear context", argumentHint: nil, source: .acp)
        let quick = HermesSlashCommand(name: "/brief", description: "Summary", argumentHint: "topic", source: .quickCommand)
        #expect(acp.source == .acp)
        #expect(quick.source == .quickCommand)
        #expect(acp.id == "/clear")
    }

    @Test func hermesToolInitAndKnownPlatformIcon() {
        let ts = HermesToolset(name: "browser", description: "Web", icon: "safari", enabled: true)
        #expect(ts.id == "browser")
        let plat = HermesToolPlatform(name: "cli", displayName: "CLI", icon: "terminal")
        #expect(plat.id == "cli")

        // KnownPlatforms lookup — guards that the icon-map path didn't break.
        #expect(KnownPlatforms.icon(for: "discord") == "bubble.left.and.bubble.right")
        #expect(KnownPlatforms.icon(for: "unknown") == "bubble.left")
        #expect(KnownPlatforms.all.count >= 13)
    }

    @Test func acpRequestAndEvents() throws {
        let req = ACPRequest(id: 1, method: "session/new", params: ["foo": AnyCodable("bar")])
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["method"] as? String == "session/new")
        #expect(decoded?["jsonrpc"] as? String == "2.0")

        let evt = ACPToolCallEvent(
            toolCallId: "t1", title: "read_file: /tmp", kind: "read",
            status: "pending", content: "", rawInput: ["path": "/tmp"]
        )
        #expect(evt.functionName == "read_file")
        #expect(evt.argumentsSummary == "/tmp")

        let upd = ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "read", status: "completed",
            content: "hello", rawOutput: nil
        )
        #expect(upd.status == "completed")

        let perm = ACPPermissionRequestEvent(
            toolCallTitle: "write_file: /etc/passwd", toolCallKind: "edit",
            options: [(optionId: "allow_once", name: "Allow once")]
        )
        #expect(perm.options.first?.optionId == "allow_once")

        let prompt = ACPPromptResult(
            stopReason: "end_turn", inputTokens: 100, outputTokens: 50,
            thoughtTokens: 20, cachedReadTokens: 10
        )
        #expect(prompt.stopReason == "end_turn")
    }

    @Test func projectDashboardInitChain() {
        let point = ChartDataPoint(x: "Mon", y: 3)
        let series = ChartSeries(name: "Calls", color: "blue", data: [point])
        let item = ListItem(text: "task 1", status: "done")
        let widget = DashboardWidget(
            type: "chart", title: "Calls per day",
            value: .number(12), icon: nil, color: nil, subtitle: nil,
            label: nil, content: nil, format: nil,
            columns: nil, rows: nil,
            chartType: "line", xLabel: "day", yLabel: "count",
            series: [series], items: [item],
            url: nil, height: nil
        )
        #expect(widget.id == "chart:Calls per day")
        #expect(widget.value?.displayString == "12")

        let theme = DashboardTheme(accent: "blue")
        let section = DashboardSection(title: "Main", columns: 2, widgets: [widget])
        let dash = ProjectDashboard(
            version: 1, title: "Demo", description: nil,
            updatedAt: "2026-01-01", theme: theme, sections: [section]
        )
        #expect(dash.sections.first?.columnCount == 2)

        let entry = ProjectEntry(name: "demo", path: "/a/b/demo")
        #expect(entry.dashboardPath == "/a/b/demo/.scarf/dashboard.json")

        let reg = ProjectRegistry(projects: [entry])
        #expect(reg.projects.first?.id == "demo")
    }

    @Test func widgetValueCodable() throws {
        let a = try JSONDecoder().decode(WidgetValue.self, from: Data("42".utf8))
        #expect(a == .number(42))
        #expect(a.displayString == "42")

        let b = try JSONDecoder().decode(WidgetValue.self, from: Data("\"hi\"".utf8))
        #expect(b == .string("hi"))

        // Fraction formatting path
        let c = WidgetValue.number(1.5)
        #expect(c.displayString.contains("1.5") || c.displayString.contains("1,5"))
    }

    @Test func queryDefaultsAndFileSizeUnit() {
        #expect(QueryDefaults.sessionLimit == 100)
        #expect(FileSizeUnit.kilobyte == 1_024.0)
    }
}
