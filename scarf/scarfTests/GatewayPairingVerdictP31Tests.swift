import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase P31 of the round-3 whole-surface audit: `pairing approve` and
/// `pairing revoke` are `-> None` handlers (`hermes_cli/pairing.py:56`, `:84`,
/// reached through a `-> None` `pairing_command` at `:3-19` @ `v2026.9.7`), so
/// every refusal they print arrives at Scarf as exit 0. Judged by exit code:
///
/// * a revoke Hermes REFUSED removed the row from the list, with no error, and
///   the row only reappeared when the follow-up `load(force: true)` landed;
/// * an approve Hermes REFUSED — an expired code, or a rate-limit lockout —
///   posted no message at all: the user clicked Approve and nothing happened.
///
/// Both are now judged by `HermesPairingVerdict`, and the refusal is quoted
/// verbatim into a sticky banner the user dismisses (round-3 decision 3).
/// Fixtures are the emitter's exact bytes at `v2026.9.7`.
@Suite("P31 — pairing verdicts")
@MainActor
struct GatewayPairingVerdictP31Tests {

    private static let roster = """

      No pending pairing requests.

      Approved Users (1):
      Platform     User ID              Name
      --------     -------              ----
      telegram     987654321            Ada Lovelace

    """

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p31-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A fake `hermes` that answers `pairing list` with a one-user roster and
    /// the mutation with whatever the test asked for — and GATES every
    /// `pairing list` after the first, so the assertion can run in the window
    /// between the verdict landing and the reload overwriting the roster.
    /// Without the gate a "the row survived a refused revoke" test would race
    /// the reload that puts it back either way, and pass on both sides of the
    /// fix.
    final class PairingCLI: @unchecked Sendable {
        private let lock = NSLock()
        private var listCalls = 0
        private let gate = DispatchSemaphore(value: 0)
        private let mutationOutput: String
        private let mutationExit: Int32

        init(mutationOutput: String, mutationExit: Int32 = 0) {
            self.mutationOutput = mutationOutput
            self.mutationExit = mutationExit
        }

        /// Let the gated reload through.
        func release() { gate.signal() }

        func runner() -> HermesCLIRunner {
            { [self] args, _ in
                guard args.first == "pairing" else { return ("", 0) }
                if args.dropFirst().first == "list" {
                    lock.lock(); listCalls += 1; let n = listCalls; lock.unlock()
                    if n > 1 { _ = gate.wait(timeout: .now() + 60) }
                    return (GatewayPairingVerdictP31Tests.roster, 0)
                }
                return (mutationOutput, mutationExit)
            }
        }
    }

    private static func loadedViewModel(_ cli: PairingCLI) async -> MessagingGatewayViewModel {
        let vm = MessagingGatewayViewModel(
            context: scratchContext(), capabilities: .empty, cliRunner: cli.runner())
        vm.load(force: true)
        await until(timeout: 10) { vm.approvedUsers.count == 1 }
        return vm
    }

    // MARK: - revoke

    /// `_cmd_revoke`'s refusal (`pairing.py:90`) at exit 0. Pre-fix this test
    /// sees an empty `approvedUsers` and a `nil` `pairingError`.
    @Test func aRefusedRevokeKeepsTheRowAndQuotesHermes() async {
        let cli = PairingCLI(mutationOutput: """

          User 987654321 not found in approved list for telegram.

        """)
        let vm = await Self.loadedViewModel(cli)
        guard let user = vm.approvedUsers.first else {
            Issue.record("fixture roster did not parse into an approved user")
            return
        }

        // Waits on `isBusy`, which BOTH the old exit-code arm and the new
        // verdict arm clear — waiting on `pairingError` would let the gated
        // reload's own timeout expire first and put the row back, which is
        // precisely the "vanished until the next load" window this test
        // exists to catch.
        vm.revokeUser(user)
        await Self.until(timeout: 10) { vm.isBusy == false }

        #expect(vm.pairingError == "User 987654321 not found in approved list for telegram.")
        #expect(
            vm.approvedUsers.contains { $0.id == user.id },
            "a revoke Hermes refused removed the row anyway"
        )
        cli.release()
    }

    /// The other side: the row DOES go when Hermes says it went
    /// (`pairing.py:88`), and no error is posted.
    @Test func aPerformedRevokeDropsTheRow() async {
        let cli = PairingCLI(mutationOutput: """

          Revoked access for user 987654321 on telegram.

        """)
        let vm = await Self.loadedViewModel(cli)
        guard let user = vm.approvedUsers.first else {
            Issue.record("fixture roster did not parse into an approved user")
            return
        }

        vm.revokeUser(user)
        await Self.until(timeout: 10) { vm.approvedUsers.isEmpty }

        #expect(vm.approvedUsers.isEmpty)
        #expect(vm.pairingError == nil)
        cli.release()
    }

    // MARK: - approve

    /// The lockout arm (`pairing.py:76-78`), exit 0. Pre-fix: no message at
    /// all. The countdown line is quoted verbatim alongside the refusal —
    /// it is the only remediation the operator gets.
    @Test func aLockedOutApproveShowsHermesLineWithItsCountdown() async {
        let cli = PairingCLI(mutationOutput: """

          Platform 'telegram' is locked out after too many failed approval attempts.
          Lockout clears in ~12 minute(s).
          To reset sooner, delete the '_lockout:telegram' entry from ~/.hermes/platforms/pairing/_rate_limits.json

        """)
        let vm = await Self.loadedViewModel(cli)

        vm.approvePairing(platform: "telegram", code: "req-7f3a")
        await Self.until(timeout: 10) { vm.pairingError != nil }

        #expect(vm.pairingError?.contains("is locked out after too many failed approval attempts.") == true)
        #expect(vm.pairingError?.contains("Lockout clears in ~12 minute(s).") == true)
        cli.release()
    }

    /// The expired-code arm (`pairing.py:80`), exit 0.
    @Test func anExpiredApproveIsReportedAndDismissable() async {
        let cli = PairingCLI(mutationOutput: """

          Pairing request or code 'req-7f3a' not found or expired for platform 'telegram'.
          Run 'hermes pairing list' to see pending requests.

        """)
        let vm = await Self.loadedViewModel(cli)

        vm.approvePairing(platform: "telegram", code: "req-7f3a")
        await Self.until(timeout: 10) { vm.pairingError != nil }
        #expect(
            vm.pairingError
                == "Pairing request or code 'req-7f3a' not found or expired for platform 'telegram'."
        )

        // Sticky: only the user's dismissal clears it.
        vm.dismissPairingError()
        #expect(vm.pairingError == nil)
        cli.release()
    }

    /// A successful approve posts no error.
    @Test func aPerformedApprovePostsNoError() async {
        let cli = PairingCLI(mutationOutput: """

          Approved! User Ada Lovelace (987654321) on telegram can now use the bot~
          They'll be recognized automatically on their next message.

        """)
        let vm = await Self.loadedViewModel(cli)

        vm.approvePairing(platform: "telegram", code: "req-7f3a")
        await Self.until(timeout: 10) { vm.isBusy == false }
        #expect(vm.pairingError == nil)
        cli.release()
    }
}
