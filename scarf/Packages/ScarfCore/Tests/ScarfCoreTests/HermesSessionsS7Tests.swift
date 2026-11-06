import Testing
import Foundation
@testable import ScarfCore

/// S7: sessions failure detection, `sessions refresh-prompts`, `curator lock`.
@Suite struct HermesSessionsS7Tests {

    static let noSession = "No session 'abc'. Run: hermes sessions list to find the id."
    static let v0226 = HermesCapabilities.parseLine("Hermes Agent v0.22.6 (2026.9.24)")
    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.9.24)")

    // MARK: marker classification — every host

    @Test func noSessionMarkerMatchesRealText() {
        #expect(HermesSessionsCLI.isNoSession(Self.noSession))
        #expect(HermesSessionsCLI.isNoSession("No session matches 'zz'."))
        #expect(!HermesSessionsCLI.isNoSession("No session database at /x (nothing to repair)."))
        #expect(!HermesSessionsCLI.isNoSession("No sessions found."))
    }

    @Test func exportVerdictNowCatchesNoSession() {
        let outcome = HermesCLIVerdict.judge(
            output: Self.noSession, exitCode: 0,
            successMarkers: HermesCLIMarkers.sessionsExportSuccess,
            failureMarkers: HermesCLIMarkers.sessionsExportFailure,
            successAnchored: true)
        #expect(!outcome.succeeded)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail == Self.noSession)
    }

    @Test func chainDeleteSharesThePrefix() {
        #expect(SessionChainDelete.isNoSession(Self.noSession))
    }

    // MARK: exit-code handling, gated

    @Test func nonZeroExitIsFailureOnlyWhenGated() {
        #expect(HermesSessionsCLI.isFailure(output: "", exitCode: 1, nonZeroExitIsFailure: Self.v0226.hasSessionsNonZeroExit))
        #expect(!HermesSessionsCLI.isFailure(output: "", exitCode: 1, nonZeroExitIsFailure: Self.v0225.hasSessionsNonZeroExit))
        // The marker wins on every host.
        #expect(HermesSessionsCLI.isFailure(output: Self.noSession, exitCode: 0, nonZeroExitIsFailure: false))
        #expect(!HermesSessionsCLI.isFailure(output: "ok", exitCode: 0, nonZeroExitIsFailure: true))
    }

    // MARK: refresh-prompts argv + verdict

    @Test func refreshArgv() {
        #expect(HermesSessionsRefreshPrompts.argv() == ["sessions", "refresh-prompts", "--json"])
        #expect(HermesSessionsRefreshPrompts.argv(sessionId: "-odd")
                == ["sessions", "refresh-prompts", "--session=-odd", "--json"])
    }

    @Test func refreshGating() {
        #expect(Self.v0226.hasSessionsRefreshPrompts)
        #expect(!Self.v0225.hasSessionsRefreshPrompts)
        #expect(Self.v0226.hasCuratorLock)
        #expect(!Self.v0225.hasCuratorLock)
    }

    @Test func refreshJudgeParsesPayload() {
        let r = HermesSessionsRefreshPrompts.judge(
            stdout: #"{"epoch": 3, "session_id": null, "sessions": 7}"#, stderr: "warn {x}", exitCode: 0)
        #expect(r.succeeded)
        #expect(r.sessionCount == 7)
    }

    @Test func refreshJudgeRejectsRefusalsAndNoise() {
        #expect(!HermesSessionsRefreshPrompts.judge(stdout: "No session matches 'x'.", stderr: "", exitCode: 1).succeeded)
        // Exit 0 without a payload (unknown verb routed elsewhere) is never success.
        #expect(!HermesSessionsRefreshPrompts.judge(stdout: "Sure! I refreshed it.", stderr: "", exitCode: 0).succeeded)
        #expect(!HermesSessionsRefreshPrompts.judge(stdout: #"{"sessions": true, "epoch": 1}"#, stderr: "", exitCode: 0).succeeded)
        #expect(!HermesSessionsRefreshPrompts.judge(stdout: #"{"epoch": 1, "sessions": 2}"#, stderr: "", exitCode: 2).succeeded)
    }

    // MARK: curator lock

    @Test func lockArgv() {
        #expect(HermesCuratorLock.argv(skill: "axolotl", locked: true) == ["curator", "lock", "--", "axolotl"])
        #expect(HermesCuratorLock.argv(skill: "-x", locked: false) == ["curator", "unlock", "--", "-x"])
    }

    @Test func lockJudge() {
        #expect(HermesCuratorLock.judge(
            output: "curator: locked 'axolotl'. The agent can no longer change it: …", exitCode: 0, locked: true).succeeded)
        #expect(HermesCuratorLock.judge(
            output: "curator: unlocked 'axolotl'. The agent may edit it again.", exitCode: 0, locked: false).succeeded)
        // Wrong direction's line is not a success.
        #expect(!HermesCuratorLock.judge(
            output: "curator: unlocked 'axolotl'.", exitCode: 0, locked: true).succeeded)
        #expect(!HermesCuratorLock.judge(
            output: "curator: no skill named 'zz' in the active profile — nothing to lock.", exitCode: 1, locked: true).succeeded)
        #expect(!HermesCuratorLock.judge(output: "", exitCode: 0, locked: true).succeeded)
    }

    @Test func lockStateParsing() {
        let json = #"""
        {"a": {"locked": true, "pinned": false}, "b": {"locked": false}, "c": {"locked": 1},
         "d": {"pinned": true}, "e": "junk", "f": {"locked": true}}
        """#
        #expect(HermesCuratorLock.parseLockedSkillNames(Data(json.utf8)) == ["a", "f"])
        #expect(HermesCuratorLock.parseLockedSkillNames(Data("not json".utf8)).isEmpty)
        #expect(HermesCuratorLock.parseLockedSkillNames(Data("[]".utf8)).isEmpty)
    }
}
