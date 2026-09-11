import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P40c — the third arm on the four gateway banners, and the source sweeps'
/// own decoys.
@Suite("GatewayAndPluginsVerdictP40c")
struct GatewayAndPluginsVerdictP40cTests {

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p40c-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    /// The verdict a foreground restart produces: `.unconfirmed`, carrying
    /// the foreground note. Built through `judge` rather than by hand so the
    /// banners are tested against the shape the CLI actually yields.
    private static func foregroundRestart() -> HermesCLIOutcome {
        HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: "Starting gateway...\nCommand timed out after 30s.",
            exitCode: -1
        )
    }

    /// The other `.unconfirmed` shape: exit 0, nothing printed at all — the
    /// s6 dispatch (`hermes_cli/gateway.py:5608-5629` @ v2026.9.7).
    private static func silentStop() -> HermesCLIOutcome {
        HermesGatewayServiceVerdict.judge(verb: .stop, output: "", exitCode: 0)
    }

    @Test func thePremiseHolds() {
        #expect(Self.foregroundRestart().confidence == .unconfirmed)
        #expect(Self.silentStop().confidence == .unconfirmed)
    }

    // MARK: - the Gateway pane

    @MainActor private static func gatewayViewModel(
        mutation output: String, exitCode: Int32
    ) -> MessagingGatewayViewModel {
        MessagingGatewayViewModel(
            context: scratchContext(),
            capabilities: .empty,
            cliRunner: { args, _ in
                args.first == "gateway" && args.count > 1 && args[1] != "status" && args[1] != "list"
                    ? (output, exitCode)
                    : ("", 0)
            }
        )
    }

    @MainActor private static func until(
        timeout: TimeInterval, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The finding: the pane branched on `succeeded`, so an s6 Stop that
    /// Hermes carried out in silence was reported "Gateway stop failed" in
    /// the red style. Neutral wording, and NOT a failure.
    @MainActor @Test func aSilentStopIsNeutralNotRed() async throws {
        let vm = Self.gatewayViewModel(mutation: "", exitCode: 0)
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try #require(vm.actionMessage)
        #expect(vm.actionFailed == false, "a could-not-confirm is not a failure")
        #expect(message.contains("Stop sent"))
        #expect(message.contains("could not confirm"))
        #expect(!message.contains("failed"))
    }

    /// And the foreground restart, whose note has to survive onto the bar.
    @MainActor @Test func aForegroundRestartCarriesItsNote() async throws {
        let vm = Self.gatewayViewModel(
            mutation: "Starting gateway...\nCommand timed out after 30s.", exitCode: -1
        )
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try #require(vm.actionMessage)
        #expect(vm.actionFailed == false)
        #expect(message.contains("Restart sent"))
        #expect(message.contains("foreground"))
        #expect(!message.contains("Gateway restarted"), "nothing claims the state it could not see")
    }

    /// The two arms that were already right stay right.
    @MainActor @Test func aRealFailureIsStillRed() async {
        let vm = Self.gatewayViewModel(mutation: "✗ Gateway service restart failed.", exitCode: 1)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(vm.actionFailed == true)
        #expect(vm.actionMessage?.contains("Gateway restart failed") == true)
    }

    // MARK: - the Health panel

    @Test func healthsControlMessageHasAThirdArm() {
        let unconfirmed = HealthViewModel.controlMessage(
            verb: .stop, done: "Gateway stopped", failed: "Stop failed",
            outcome: Self.silentStop()
        )
        #expect(unconfirmed.contains("Stop sent"))
        #expect(!unconfirmed.contains("Stop failed"))

        // The other two are untouched.
        #expect(HealthViewModel.controlMessage(
            verb: .start, done: "Gateway started", failed: "Start failed",
            outcome: HermesGatewayServiceVerdict.judge(
                verb: .start, output: "✓ Service started", exitCode: 0)
        ) == "Gateway started")
        #expect(HealthViewModel.controlMessage(
            verb: .start, done: "Gateway started", failed: "Start failed",
            outcome: HermesGatewayServiceVerdict.judge(
                verb: .start, output: "✗ Gateway service start failed.", exitCode: 1)
        ).hasPrefix("Start failed"))
    }

    // MARK: - the Platforms pane

    @MainActor @Test func platformsRestartBarIsNotRedOnAnUnconfirmed() {
        let banner = PlatformsViewModel.restartBanner(Self.foregroundRestart())
        #expect(banner.isFailure == false)
        #expect(banner.text.contains("Restart sent"))
        #expect(banner.text.contains("foreground"))

        let failure = PlatformsViewModel.restartBanner(
            HermesGatewayServiceVerdict.judge(
                verb: .restart, output: "✗ Gateway service restart failed.", exitCode: 1)
        )
        #expect(failure.isFailure == true)
    }

    // MARK: - the MCP servers pane

    /// Two halves here: an `.unconfirmed` restart must not land in
    /// `activeError`, AND it must not clear the "restart needed" banner —
    /// Scarf could not confirm the restart, so the prompt has not earned its
    /// dismissal.
    @MainActor @Test func mcpUnconfirmedRestartIsNotAnErrorAndKeepsTheBanner() throws {
        let banner = MCPServersViewModel.restartBanner(Self.foregroundRestart())
        guard case .unconfirmed(let text) = banner else {
            Issue.record("expected the neutral arm, got \(banner)")
            return
        }
        #expect(text.contains("Restart sent"))

        #expect(MCPServersViewModel.restartBanner(
            HermesGatewayServiceVerdict.judge(verb: .restart, output: "✓ Restarted gateway", exitCode: 0)
        ) == .confirmed("Gateway restarted"))
        #expect(MCPServersViewModel.restartBanner(
            HermesGatewayServiceVerdict.judge(
                verb: .restart, output: "✗ Gateway service restart failed.", exitCode: 1)
        ) == .failed("Restart failed: ✗ Gateway service restart failed."))
    }

    // MARK: - the sweeps' own decoys

    /// The sweep matched line by line, so an argv split across a newline
    /// walked straight past it. The blob form sees it.
    @Test func theGatewaySweepSeesAnArgvSplitAcrossLines() {
        let split = "let argv = [\"gateway\",\n              \"start\"]"
        let blob = String(split.filter { !$0.isWhitespace })
        #expect(GatewayAndPluginsVerdictP40Tests.gatewayArgvPatterns.contains {
            blob.range(of: $0, options: .regularExpression) != nil
        }, "a reformatted argv is the same argv")
    }

    /// The interpolated form the sweep could not see at all.
    @Test func theGatewaySweepSeesAnInterpolatedVerb() {
        for source in ["runHermes([\"gateway \\(verb)\"])", "run([\"gateway\\(verb.rawValue)\"])"] {
            let blob = String(source.filter { !$0.isWhitespace })
            #expect(GatewayAndPluginsVerdictP40Tests.gatewayArgvPatterns.contains {
                blob.range(of: $0, options: .regularExpression) != nil
            }, Comment(rawValue: "missed the interpolated argv: \(source)"))
        }
    }

    /// …and the token that used to match `verbose`. `["gateway", verbose]` is
    /// not an argv this sweep is about, and flagging it would train the next
    /// reader to add exemptions.
    @Test func theVariableFormTokenNoLongerMatchesVerbose() {
        let decoy = String("run([\"gateway\", verbose ? \"-v\" : \"\"])".filter { !$0.isWhitespace })
        #expect(!GatewayAndPluginsVerdictP40Tests.gatewayArgvPatterns.contains {
            decoy.range(of: $0, options: .regularExpression) != nil
        })
        // The real variable form still matches, including a named one.
        for real in ["[\"gateway\",verb]", "[\"gateway\",serviceVerb]"] {
            #expect(GatewayAndPluginsVerdictP40Tests.gatewayArgvPatterns.contains {
                real.range(of: $0, options: .regularExpression) != nil
            }, Comment(rawValue: "lost the variable form: \(real)"))
        }
    }

    /// The premise the sweeps rest on: the blob reader actually reads.
    @Test func theSweepReadsTheSources() throws {
        let files = try GatewayAndPluginsVerdictP40Tests.strippedSourceFiles()
        #expect(files.count > 200)
        #expect(files.contains { $0.where.hasSuffix("HermesCLIOutcome.swift") })
    }
}
