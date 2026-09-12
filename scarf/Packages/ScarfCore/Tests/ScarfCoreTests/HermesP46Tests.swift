import Foundation
import Testing
@testable import ScarfCore

// MARK: - P46 finding 1: the shared-key rewrite is key-scoped, and the prefix
// is resolved against the file AS THE BATCH WILL LEAVE IT.

/// P44 moved every `_SHARED_KEYS` member of slack/telegram onto the section
/// `platform_section` bridges from (`gateway/config_loader.py:171-180` @
/// `v2026.9.7`). Two regressions fell out, and both are here.
@Suite("P46 · platform shared-key write scoping")
struct SharedKeyWriteScopeP46Tests {

    /// (a) The allowlist's unit is the `(platform, key)` PAIR, not the
    /// platform — a key whose reader is hard-coded to one spelling must not
    /// be moved off it, or the write stops reaching the form.
    ///
    /// P46b moved slack's and telegram's `gateway_restart_notification`
    /// READER onto `sharedPlatformScalar`, so those two pairs now belong on
    /// the allowlist and this test asserts the invariant over a pair that is
    /// still hard-coded: `discord.gateway_restart_notification`
    /// (`HermesConfig+YAML.swift`'s gateway-allowlist loop keeps the flat
    /// spelling for the six platforms nothing reads through the bridge).
    @Test func aSharedKeyWhoseReaderIsHardCodedTopLevelIsNotMoved() {
        for platform in ["discord", "matrix", "mattermost"] {
            let key = "\(platform).gateway_restart_notification"
            #expect(HermesPlatformSharedKeys.split(key: key) == nil,
                    "\(key) has no bridge-resolving reader and must not be split")
            let resolved = HermesPlatformSharedKeys.resolved(
                [key: "false"],
                configText: "platforms:\n  \(platform):\n    reply_to_mode: first\n"
            )
            #expect(resolved[key] == "false", "\(key) was moved off the spelling its reader uses")
            #expect(resolved.count == 1)
        }
    }

    /// …and the two pairs whose reader P46b DID move now move with it, which
    /// is the other half of the same rule.
    @Test func theRestartToggleMovesNowThatItsReaderDoes() {
        for platform in ["slack", "telegram"] {
            let key = "\(platform).gateway_restart_notification"
            #expect(HermesPlatformSharedKeys.split(key: key) != nil)
            let resolved = HermesPlatformSharedKeys.resolved(
                [key: "false"],
                configText: "platforms:\n  \(platform):\n    reply_to_mode: first\n"
            )
            #expect(resolved["platforms.\(platform).gateway_restart_notification"] == "false",
                    "the toggle still creates a top-level block: \(resolved)")
        }
    }

    /// The pairs that DO resolve the bridge still move.
    @Test func theBridgeResolvedPairsStillMove() {
        let resolved = HermesPlatformSharedKeys.resolved(
            ["platforms.slack.require_mention": "false"],
            configText: "slack:\n  allowed_channels:\n    - C1\n"
        )
        #expect(resolved["slack.require_mention"] == "false")
        #expect(resolved["platforms.slack.require_mention"] == nil)
    }

    /// (b) `TelegramSetupViewModel` sends one shared key and two unshared
    /// ones, all bare. Resolved against the PRE-save file the shared key
    /// went nested while `telegram.reactions` created the top-level block —
    /// which is then the bridge source, and `require_mention` is not in it.
    /// The batch invalidated its own resolution.
    @Test func aBatchThatCreatesTheTopLevelBlockPinsThePrefixToIt() throws {
        let batch = [
            "telegram.require_mention": "true",
            "telegram.reactions": "true",
            "telegram.disable_topic_auto_rename": "false",
        ]
        let resolved = HermesPlatformSharedKeys.resolved(
            batch,
            configText: "platforms:\n  telegram:\n    reply_to_mode: first\n"
        )
        #expect(resolved["telegram.require_mention"] == "true",
                "the batch's own bare keys create `telegram:`, which becomes the bridge source")
        #expect(resolved["platforms.telegram.require_mention"] == nil)
        #expect(resolved["telegram.reactions"] == "true")
        #expect(resolved["telegram.disable_topic_auto_rename"] == "false")
        #expect(resolved.count == 3)

        // And the round trip the write side owes: splice the resolved batch
        // in beside the pre-existing nested block and read it back.
        let yaml = "platforms:\n  telegram:\n    reply_to_mode: first\n"
            + "telegram:\n"
            + resolved.sorted { $0.key < $1.key }
                .map { "  " + ($0.key.split(separator: ".").last.map(String.init) ?? $0.key) + ": " + $0.value + "\n" }
                .joined()
        #expect(HermesConfig(yaml: yaml).telegram.requireMention == true)
    }

    /// A batch with no bare key of its own still follows the file.
    @Test func aBatchWithNoBareKeyFollowsTheFileOnDisk() {
        let resolved = HermesPlatformSharedKeys.resolved(
            ["platforms.telegram.require_mention": "true",
             "platforms.telegram.extra.rich_messages": "true"],
            configText: "platforms:\n  telegram:\n    reply_to_mode: first\n"
        )
        #expect(resolved["platforms.telegram.require_mention"] == "true")
        #expect(resolved["telegram.require_mention"] == nil)
    }
}

// MARK: - P46 finding 4: `hermes tools enable|disable` is exit-0-refusal family

/// Every refusal `tools_disable_enable_command` prints is a `_print_error`
/// followed by a bare `return`/`continue` (`hermes_cli/tools_config_mcp.py:237-285`
/// @ `v2026.9.7`), and the write is `save_config`, whose managed arm prints
/// and returns (`hermes_cli/config.py:2316-2318`). All exit 0, and the
/// success line is printed regardless.
@Suite("P46 · tools enable/disable verdict")
struct ToolsToggleVerdictP46Tests {

    @Test func aCleanToggleSucceeds() {
        let out = HermesToolsToggle.judge(output: "✓ Enabled: web\n", exitCode: 0)
        #expect(out.succeeded)
    }

    @Test func theDisableVerbIsAlsoASuccessLine() {
        #expect(HermesToolsToggle.judge(output: "✓ Disabled: web, memory\n", exitCode: 0).succeeded)
    }

    /// The one that mattered: a managed host prints BOTH.
    @Test func aManagedHostIsAFailureDespiteTheSuccessLine() throws {
        let output = """
            Cannot save configuration: /etc/hermes/config.yaml is managed by your administrator and cannot be changed.
            ✓ Enabled: web
            """
        let out = HermesToolsToggle.judge(output: output, exitCode: 0)
        #expect(!out.succeeded, "failureWins did not run")
        let detail = try #require(out.detail)
        #expect(detail.contains("managed by your administrator"))
    }

    @Test func everyNamedRefusalArmIsCaughtAtExitZero() throws {
        for line in [
            "✗ Unknown platform 'telegrm'. Valid: cli, discord, slack, telegram",
            "✗ Unknown toolset 'wb'",
            "✗ Toolset 'computer_use' is not available on platform 'telegram' (only: cli)",
            "✗ MCP server 'github' not found in config",
        ] {
            let out = HermesToolsToggle.judge(output: line + "\n✓ Enabled: web\n", exitCode: 0)
            #expect(!out.succeeded, "not caught: \(line)")
        }
    }

    /// Anchored: the success line interpolates the NAMES the caller passed,
    /// and the refusals interpolate a name or a platform.
    @Test func aToolsetNamedLikeAMarkerDoesNotFlipTheVerdict() {
        // A toolset whose own name contains a refusal phrase, echoed on the
        // success line, must not read as a refusal.
        let out = HermesToolsToggle.judge(
            output: "✓ Enabled: Unknown toolset 'x'\n", exitCode: 0)
        #expect(out.succeeded)
    }

    @Test func theArgvIsTheDocumentedShape() {
        #expect(HermesToolsToggle.argv(toolset: "web", platform: "cli", enabled: true)
                == ["tools", "enable", "web", "--platform", "cli"])
        #expect(HermesToolsToggle.argv(toolset: "web", platform: "cli", enabled: false)
                == ["tools", "disable", "web", "--platform", "cli"])
    }
}

// MARK: - P46 finding 5: an idle `/steer` is an ordinary turn

@Suite("P46 · idle /steer")
struct IdleSteerP46Tests {
    static let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    static let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")

    @Test func anIdleSteerWithAnArgumentIsAnOrdinaryPrompt() {
        #expect(RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: "steer", args: "use the other file",
            isAgentWorking: false, capabilities: Self.v0211))
    }

    /// While a turn IS running the prefix survives `_rewrite_prompt_for_interrupt`
    /// (`acp_adapter/server.py:686` returns the text unchanged when not idle)
    /// and `_cmd_steer` dispatches — the hint is true.
    @Test func aSteerDuringATurnIsStillASteer() {
        #expect(!RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: "steer", args: "use the other file",
            isAgentWorking: true, capabilities: Self.v0211))
    }

    /// Empty argument: `:681-682` returns the text untouched, so the
    /// dispatched command answers `Usage: /steer <guidance>` itself.
    @Test func anEmptyArgumentIsLeftToHermes() {
        for args in ["", "   "] {
            #expect(!RichChatViewModel.idleSteerIsOrdinaryPrompt(
                name: "steer", args: args,
                isAgentWorking: false, capabilities: Self.v0211))
        }
    }

    /// Below the v0.13 floor the text already goes to the LLM verbatim and
    /// `subFloorSlashNotice` owns the case — two notices would be one too many.
    @Test func belowTheFloorTheSubFloorNoticeOwnsIt() throws {
        #expect(!RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: "steer", args: "go", isAgentWorking: false, capabilities: Self.v012))
        #expect(RichChatViewModel.subFloorSlashNotice(
            name: "steer", capabilities: Self.v012) != nil)
    }

    @Test func onlySteerTakesThisArm() {
        #expect(!RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: "queue", args: "go", isAgentWorking: false, capabilities: Self.v0211))
        #expect(!RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: nil, args: "go", isAgentWorking: false, capabilities: Self.v0211))
    }

    @Test func theNoticeSaysWhatWasActuallySent() {
        let notice = RichChatViewModel.idleSteerNotice
        #expect(!notice.isEmpty)
        #expect(notice != RichChatViewModel.idleQueueNotice)
    }

    /// Both send paths must gate the optimistic hint on the working state and
    /// take the ordinary-turn arm otherwise. Source pins, because the arm is
    /// in a `switch` inside a SwiftUI view / a view model method.
    @Test func bothSendPathsGateTheSteerArmOnTheWorkingState() throws {
        for relative in [
            "scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift",
            "scarf/Scarf iOS/Chat/ChatView.swift",
        ] {
            let source = try String(
                contentsOf: P44Repo.root.appendingPathComponent(relative), encoding: .utf8)
            #expect(source.contains("case \"steer\" where"), "no steer arm in \(relative)")
            #expect(source.range(of: #"case "steer" where[^\n:]*wasAgentWorking"#,
                                 options: .regularExpression) != nil,
                    "the steer arm in \(relative) is not gated on `wasAgentWorking`")
            #expect(source.contains("idleSteerIsOrdinaryPrompt"),
                    "\(relative) never asks the idle question")
            #expect(source.contains("idleSteerNotice"),
                    "\(relative) never shows the notice")
        }
    }

    /// The Mac half additionally has to record the turn, or Stop cannot
    /// cancel it: `turnGeneration` / `inFlightPromptSessionId` are set only
    /// on the `!isNonInterruptive` branch.
    @Test func theMacPathMakesTheIdleSteerInterruptible() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift"),
            encoding: .utf8)
        let decl = try #require(source.range(of: "let isNonInterruptive = "))
        let tail = source[decl.upperBound...].prefix(400)
        #expect(tail.contains("!idleSteer"), """
            `isNonInterruptive` does not subtract the idle steer, so the \
            working indicator stays off and no turnGeneration is recorded
            """)
    }
}

// MARK: - P46 finding 6: the managed-install cache memoized a verdict

@Suite("P46 · managed-install marker cache")
struct ManagedInstallCacheP46Tests {

    private static func host(home: String) -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: home))
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// The regression: one connect where `hermes --version` did not answer
    /// locked the BELOW-FLOOR reading ("any marker ⇒ NixOS",
    /// `hermes_cli/config.py:327-330` @ v2026.6.19) in for the process.
    @Test func anUndetectedCapabilityDoesNotPoisonTheVerdict() {
        let cache = HermesManagedInstallCache(probe: { _ in "brew" })
        let ctx = Self.host(home: "/tmp/p46-home")
        let undetected = HermesCapabilities.parseLine("")
        #expect(!undetected.detected)
        let first = cache.managedInstall(for: ctx, capabilities: undetected)
        #expect(first.system == HermesManagedInstall.preContentsSystem,
                "below the floor any marker is the literal \"NixOS\"")

        // The version probe lands. The SAME cache must now answer for a
        // v0.20.5+ host, which reads the marker's CONTENTS.
        let detected = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(detected.hasManagedMarkerContents)
        let second = cache.managedInstall(for: ctx, capabilities: detected)
        // `brew` is in `ignoredValues` (`:70`) — a Homebrew install writes
        // the marker but is NOT administrator-managed, which is the whole
        // point of reading its contents. So the pane goes back to WRITABLE.
        #expect(second.isManaged == false,
                Comment(rawValue: "the verdict was memoized instead of the marker: \(String(describing: second.system))"))
    }

    /// And the marker itself is only read once — the round trip is what the
    /// cache exists to save.
    @Test func theMarkerIsProbedOnce() {
        let probes = Counter()
        let cache = HermesManagedInstallCache(probe: { _ in
            probes.bump()
            return "brew"
        })
        let ctx = Self.host(home: "/tmp/p46-home")
        for caps in [HermesCapabilities.parseLine(""),
                     HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"),
                     HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")] {
            _ = cache.managedInstall(for: ctx, capabilities: caps)
        }
        #expect(probes.value == 1)
    }

    /// `HermesVersionCache.refresh` is the "the host may have changed"
    /// gesture, so it drops the marker too.
    @Test func refreshDropsTheMarkerCache() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesVersionCache.swift"),
            encoding: .utf8)
        let refresh = try #require(source.range(of: "public func refresh(for context: ServerContext)"))
        let body = source[refresh.upperBound...].prefix(300)
        #expect(body.contains("HermesManagedInstallCache.shared.invalidate(for: context)"))
    }
}

// MARK: - P46 finding 7: the FLOW arms bypassed the per-key unquote opt-in

/// Decision 10's opt-in is per KEY, and a key's two YAML spellings must decode
/// alike. Expected values verified against PyYAML 6.0.3.
@Suite("P46 · flow-form unquote opt-in")
struct FlowUnquoteP46Tests {

    /// `yaml.safe_load` gives `['cAd']` for both spellings.
    @Test func anOptedInListDecodesEscapesInFlowFormToo() throws {
        let flow = HermesYAML.parseNestedYAML(
            "model_catalog:\n  excluded_providers: [\"c\\x41d\"]\n")
        #expect(flow.lists["model_catalog.excluded_providers"] == ["cAd"])
        let block = HermesYAML.parseNestedYAML(
            "model_catalog:\n  excluded_providers:\n    - \"c\\x41d\"\n")
        #expect(block.lists["model_catalog.excluded_providers"]
                == flow.lists["model_catalog.excluded_providers"],
                "one key, two answers, decided by the YAML shape on disk")
    }

    /// `yaml.safe_load` gives `{'mAx': 'high'}` for both spellings.
    @Test func anOptedInMapDecodesEscapesInFlowFormToo() {
        let flow = HermesYAML.parseNestedYAML(
            "agent:\n  reasoning_overrides: {\"m\\x41x\": high}\n")
        #expect(flow.maps["agent.reasoning_overrides"] == ["mAx": "high"])
        let block = HermesYAML.parseNestedYAML(
            "agent:\n  reasoning_overrides:\n    \"m\\x41x\": high\n")
        #expect(block.maps["agent.reasoning_overrides"] == flow.maps["agent.reasoning_overrides"])
    }

    /// A value's escapes too, not only the key.
    @Test func anOptedInMapValueIsUnquotedInFlowForm() {
        let flow = HermesYAML.parseNestedYAML(
            "agent:\n  reasoning_overrides: {m: \"hi\\x67h\"}\n")
        #expect(flow.maps["agent.reasoning_overrides"] == ["m": "high"])
    }

    /// A key Scarf does NOT write through `YAMLScalar` keeps the rule that
    /// applies everywhere else — the opt-in is per key, not global.
    @Test func aNonOptedInFlowListIsUnchanged() {
        let parsed = HermesYAML.parseNestedYAML(
            "skills:\n  trusted_project_dirs: [\"c\\x41d\"]\n")
        #expect(parsed.lists["skills.trusted_project_dirs"] == ["c\\x41d"])
        #expect(HermesYAML.parseFlatFlowList("\"c\\x41d\"") == ["c\\x41d"])
    }
}

// MARK: - P46 finding 9: a duplicate may not reuse the name

/// `resolve_job_ref` folds case and raises `AmbiguousJobReference` for both
/// jobs when two share a name (`cron/jobs.py:1840-1845` @ `v2026.9.7`), so
/// `hermes cron run <name>` breaks for the ORIGINAL as well as the copy.
@Suite("P46 · duplicate job naming")
struct DuplicateJobNameP46Tests {

    @Test func theFirstCopyIsSuffixed() {
        #expect(HermesCronDuplicateName.next(for: "Morning brief", existing: ["Morning brief"])
                == "Morning brief (copy)")
    }

    @Test func aTakenCopyNameCounts() {
        let existing = ["Morning brief", "Morning brief (copy)", "Morning brief (copy 2)"]
        #expect(HermesCronDuplicateName.next(for: "Morning brief", existing: existing)
                == "Morning brief (copy 3)")
    }

    /// Case-folded, because that is the comparison `resolve_job_ref` makes.
    @Test func collisionIsCaseFolded() {
        #expect(HermesCronDuplicateName.next(for: "Morning brief", existing: ["MORNING BRIEF (COPY)"])
                == "Morning brief (copy 2)")
    }

    /// A bot routine keeps its `[bot:…] ` prefix, or the Routines pane stops
    /// claiming the copy.
    @Test func aBotRoutineKeepsItsTag() throws {
        let copy = HermesCronDuplicateName.next(
            for: "[bot:research] Daily digest", existing: ["[bot:research] Daily digest"])
        #expect(copy == "[bot:research] Daily digest (copy)")
        #expect(BotRoutinePrefix.matches(jobName: copy, bot: "research"))
    }

    /// The iOS seed goes through `duplicatedAsNewJob`.
    @Test func theIOSSeedRenamesToo() {
        let job = HermesCronJob(
            id: "j1", name: "Nightly", prompt: "p",
            schedule: CronSchedule(kind: "interval"),
            enabled: true, state: "completed")
        let copy = job.duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"])
        #expect(copy.name == "Nightly (copy)")
    }

    /// And the two Mac seeds — the cron editor and the Bots pane — pass the
    /// host's existing names in rather than seeding the source's name.
    @Test func bothMacSeedsPassTheExistingNames() throws {
        for (relative, needle) in [
            ("scarf/scarf/Features/Cron/Views/CronView.swift", "existingNames: viewModel.jobs.map(\\.name)"),
            ("scarf/scarf/Features/Bots/Views/BotRoutinesView.swift", "existingNames: viewModel.allJobNames"),
        ] {
            let source = try String(
                contentsOf: P44Repo.root.appendingPathComponent(relative), encoding: .utf8)
            #expect(source.contains(needle), "\(relative) does not pass existingNames")
        }
        let editor = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/scarf/Features/Cron/Views/CronView.swift"), encoding: .utf8)
        #expect(editor.contains("HermesCronDuplicateName.next(for: job.name, existing: existingNames)"))
    }
}

// MARK: - P46 findings 10 + 17: the tarball pump

@Suite("P46 · tarball pump")
struct TarballPumpP46Tests {

    @Test func theYieldRuleFiresOnceEveryEightMegabytes() {
        let step = RemoteRestoreService.pumpYieldBytes
        #expect(!RemoteRestoreService.shouldYield(written: 0, lastYield: 0))
        #expect(!RemoteRestoreService.shouldYield(written: step - 1, lastYield: 0))
        #expect(RemoteRestoreService.shouldYield(written: step, lastYield: 0))
        #expect(RemoteRestoreService.shouldYield(written: 3 * step, lastYield: step))
        #expect(!RemoteRestoreService.shouldYield(written: 3 * step, lastYield: 3 * step))
    }

    /// A 1 GB pump owes ~128 suspensions; before the fix it owed zero.
    @Test func aLongPumpYieldsManyTimes() {
        var yields = 0
        var lastYield: Int64 = 0
        var written: Int64 = 0
        let chunk: Int64 = 64 * 1024
        while written < 1_073_741_824 {
            if RemoteRestoreService.shouldYield(written: written, lastYield: lastYield) {
                lastYield = written
                yields += 1
            }
            written += chunk
        }
        // 1 GiB / 64 KiB = 16384 chunks, one yield per 128 of them, minus the
        // first check (nothing written yet).
        #expect(yields == 127, Comment(rawValue: "a 1 GB push suspended \(yields) times"))
    }

    /// Finding 10: the happy path must actually contain the suspension point
    /// — the rule above is inert if the pump never calls it.
    @Test func thePumpBodyCallsTheYield() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift"),
            encoding: .utf8)
        let pump = try #require(source.range(of: "pump: while true {"))
        let body = source[pump.upperBound...].prefix(1200)
        #expect(body.contains("shouldYield(written: written, lastYield: lastYield)"))
        #expect(body.contains("await Task.yield()"))
    }

    /// Finding 17: `write(2)` returning 0 accepted nothing and set no errno,
    /// so the throw below would have reported a stale one. It takes the
    /// no-progress arm instead, under the same stall budget.
    @Test func aZeroLengthWriteTakesTheNoProgressArm() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift"),
            encoding: .utf8)
        #expect(source.contains("if sent == 0 || (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))"),
                "a zero-byte write still falls into the errno throw")
    }
}
