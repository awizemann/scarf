import Testing
import Foundation
@testable import scarf
import ScarfCore

/// P3 (Hermes v0.21.4 / v0.21.5 parity) — the Mac-side halves of the CLI
/// outcome fixes: the strings and argv the panes build from the ScarfCore
/// verdicts (`HermesV0214CLIOutcomeTests` holds the verdicts themselves).
@Suite struct HermesV0214CLIOutcomeAppTests {

    // MARK: - Health: sessions optimize refusal

    @Test func refusalNamesScarfWhenItIsAHolder() {
        let text = HealthViewModel.sessionsOptimizeRefusalSummary(
            holders: ["PID 4242 (hermes gateway run): state.db", "PID 777 (scarf): state.db"],
            isLocal: true, canForce: true, ownPID: 777)
        #expect(text.contains("PID 4242 (hermes gateway run): state.db"))
        #expect(text.contains("Scarf's own read-only view"))
        #expect(text.contains("Optimize anyway"))
    }

    /// Remote, or Scarf not listed: no claim about Scarf, no button named.
    @Test func refusalDoesNotBlameScarfWhenItIsNotListed() {
        for (isLocal, pid) in [(false, Int32(777)), (true, Int32(1))] {
            let text = HealthViewModel.sessionsOptimizeRefusalSummary(
                holders: ["PID 777 (scarf): state.db"], isLocal: isLocal, canForce: true, ownPID: pid)
            #expect(!text.contains("Scarf's own"))
            #expect(text.contains("Stop the gateway and other Hermes apps, then try again."))
        }
    }

    // MARK: - P7e item 6: remote optimize refusal naming Scarf's transient sqlite3 reader

    /// `RemoteSQLiteBackend` reads `state.db` by spawning a TRANSIENT
    /// `sqlite3 -readonly …` over SSH per query (`sqlite3Flags(queryOnly:)`)
    /// — it has no PID Scarf can compare against `ownPID` since it never ran
    /// locally, so `isLocal`-gated `PID \(ownPID) (` matching can never
    /// recognise it. Before this fix, a remote refusal whose only holder was
    /// this transient reader told the user to "stop other Hermes apps" —
    /// hunting for a process that has usually already exited.
    @Test func remoteRefusalNamesItsOwnTransientSQLiteReader() {
        let text = HealthViewModel.sessionsOptimizeRefusalSummary(
            holders: ["PID 55123 (sqlite3 -readonly -json /home/alan/.hermes/state.db)"],
            isLocal: false, canForce: true)
        #expect(text.contains("Scarf's own read was in progress — retry"))
        #expect(!text.contains("Stop the gateway and other Hermes apps"))
    }

    /// A real remote holder alongside the transient reader still gets the
    /// normal "stop it" copy — the transient-reader shortcut only fires when
    /// EVERY named holder is one.
    @Test func remoteRefusalWithARealHolderIsNotShortCircuited() {
        let text = HealthViewModel.sessionsOptimizeRefusalSummary(
            holders: [
                "PID 55123 (sqlite3 -readonly -json /home/alan/.hermes/state.db)",
                "PID 9001 (hermes gateway run): state.db",
            ],
            isLocal: false, canForce: true)
        #expect(!text.contains("Scarf's own read was in progress"))
        #expect(text.contains("Stop the gateway and other Hermes apps, then try again."))
    }

    /// Local hosts don't use the remote CLI reader at all — the shortcut
    /// must never fire there even if a holder happens to be named `sqlite3`.
    @Test func localHostNeverTakesTheTransientReaderShortcut() {
        let text = HealthViewModel.sessionsOptimizeRefusalSummary(
            holders: ["PID 55123 (sqlite3 -readonly /tmp/x.db)"], isLocal: true, canForce: true, ownPID: 1)
        #expect(!text.contains("Scarf's own read was in progress"))
    }

    /// The pane still runs the base argv (P47's source scan relies on it)
    /// and `--force` rides only on the forced run.
    @Test func healthForceArgvIsGated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(
            contentsOf: root.appendingPathComponent("scarf/Features/Health/ViewModels/HealthViewModel.swift"),
            encoding: .utf8)
        #expect(code.contains("force ? HermesSessionsOptimizeVerdict.forceArguments(capabilities: capabilities) : []"))
        #expect(!code.contains("\"--force\""))
    }

    // MARK: - Cron: model pin argv

    @Test func createPinsOnlyWhenAsked() throws {
        let pinned = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "p", name: "n", deliver: "", skills: [],
            script: "", repeatCount: "", pinModel: true)
        // `--pin` is an option: it must precede the end-of-options marker.
        let pin = try #require(pinned.firstIndex(of: "--pin"))
        let end = try #require(pinned.firstIndex(of: "--"))
        #expect(pin < end)
        let plain = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "p", name: "n", deliver: "", skills: [],
            script: "", repeatCount: "")
        #expect(!plain.contains("--pin"))
    }

    @Test func editSendsOnlyAPinChange() {
        #expect(CronViewModel.modelPinEditArguments(wasPinned: false, pinned: true) == ["--pin"])
        #expect(CronViewModel.modelPinEditArguments(wasPinned: true, pinned: false) == ["--unpin"])
        #expect(CronViewModel.modelPinEditArguments(wasPinned: true, pinned: true) == [])
        #expect(CronViewModel.modelPinEditArguments(wasPinned: false, pinned: false) == [])
        // Older host / hidden toggle.
        #expect(CronViewModel.modelPinEditArguments(wasPinned: true, pinned: nil) == [])
    }

    // MARK: - Peers: DM reply slot

    @Test func queuedAndStillRunningNeverReadNoReply() {
        let queued = HermesPeerCLI.DMResult(
            peer: "spark", profile: nil, sessionID: "s", reply: "", delivery: .queued(status: "queued"))
        let queuedText = PeersViewModel.dmReplyText(queued, target: "spark")
        #expect(queuedText != "(no reply)")
        #expect(queuedText.contains("don't resend"))

        let notice = "Peer 'spark' accepted the message but its turn is still running after 600s: … Do NOT resend."
        let running = HermesPeerCLI.DMResult(
            peer: "", profile: nil, sessionID: "", reply: "", delivery: .stillRunning(notice: notice))
        #expect(PeersViewModel.dmReplyText(running, target: "spark") == notice)
    }

    /// C1: the only pre-v0.21.4 shape renders exactly as before.
    @Test func repliedDMUnchanged() {
        let empty = HermesPeerCLI.DMResult(peer: "spark", profile: nil, sessionID: "s", reply: "")
        #expect(PeersViewModel.dmReplyText(empty, target: "spark") == "(no reply)")
        let said = HermesPeerCLI.DMResult(peer: "spark", profile: nil, sessionID: "s", reply: "hi")
        #expect(PeersViewModel.dmReplyText(said, target: "spark") == "hi")
    }
}
