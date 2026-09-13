import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-6 P53 — the `auth logout` verdict's third branch.
///
/// P47b's lesson, one verdict over: "a three-state verdict needs three
/// branches at the call site, not two." `HermesAuthLogoutVerdict.judge`
/// returns `.unconfirmed` for exit 0 with neither `Logged out of {provider}.`
/// (`hermes_cli/auth.py:2189` @ `v2026.9.7`) nor either idle line (`:2180`,
/// `:2185`) — C5's "we do not know". The credential-pool pane had a two-way
/// `if`, so that arm landed in the failure branch and, on a run that printed
/// nothing at all, rendered "Remove failed: exit 0": the exit code the
/// verdict had just declared meaningless, quoted at the user.
@Suite("`auth logout` answers its third state (P53)")
@MainActor
struct AuthLogoutUnconfirmedP53Tests {

    /// Exit 0, no output at all — the shape that produced "exit 0".
    @Test("a silent exit-0 logout says Hermes printed nothing, never `exit 0`")
    func aSilentRunNamesNoExitCode() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 0)
        #expect(!text.contains("exit 0"), """
            The strip quotes an exit code the verdict has already declared \
            meaningless: \(text)
            """)
        #expect(text.contains("printed no result"), "got: \(text)")
    }

    /// Exit 0 with output Hermes did print but neither marker matched.
    ///
    /// **Round-6 P59 reversed this arm.** P53 kept the tail, reasoning that
    /// on an unconfirmed verdict "the line is the only thing worth showing";
    /// P54b then settled the house rule the other way on `backup`,
    /// `sessions optimize` and `debug share` — `.unconfirmed` is gated on the
    /// CONFIDENCE ALONE, because `judge` fills `detail` with `lines.last` on
    /// that arm too and the tail is whatever the CLI happened to print last.
    /// Rendering it after "Remove failed: " asserts that Hermes gave that
    /// sentence as its reason for a refusal it never made — the same defect
    /// as quoting "exit 0", in a more convincing voice. The hand-picked
    /// fixture below reads well; `Scanning credentials ...` does not, and
    /// the formatter cannot tell them apart.
    @Test("an unconfirmed run names neither the tail nor the status")
    func anUnconfirmedRunQuotesNeither() {
        let outcome = HermesAuthLogoutVerdict.judge(
            output: "Provider anthropic is managed by your administrator.", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail?.isEmpty == false,
                "the fixture must carry a tail, or it cannot tell the two gates apart")
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 0)
        #expect(text == "hermes auth logout printed no result. Check the host.", """
            An unconfirmed run's tail is presented as the reason for a \
            refusal: \(text)
            """)
        #expect(!text.contains("exit 0"), "got: \(text)")
    }

    /// A real non-zero failure is unchanged — it keeps quoting Hermes's own
    /// reason, which is what tells a refusal from a missing verb.
    @Test("a non-zero failure still surfaces the CLI's reason")
    func aRealFailureKeepsItsReason() {
        let outcome = HermesAuthLogoutVerdict.judge(
            output: "Error: unknown provider 'nope'", exitCode: 2)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence != .unconfirmed)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 2)
        #expect(text.contains("unknown provider"), "got: \(text)")
    }

    /// The last resort, and the only arm that may name a status: a non-zero
    /// exit whose output was empty. There is nothing else to say.
    @Test("a silent non-zero failure falls back to the exit code")
    func aSilentNonZeroFailureNamesItsExitCode() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "", exitCode: 127)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 127)
        #expect(text.contains("127"), "got: \(text)")
    }

    /// Both idle arms stay a SUCCESS with a neutral note (round-5 decision 2)
    /// — the formatter must never see them.
    @Test("the idle arms never reach the failure formatter")
    func theIdleArmsAreStillSuccesses() {
        for line in ["No provider is currently logged in.", "No auth state found for anthropic."] {
            let outcome = HermesAuthLogoutVerdict.judge(output: line, exitCode: 0)
            #expect(outcome.succeeded, "\(line) stopped being a success")
            #expect(outcome.warning != nil, "\(line) lost its neutral note")
        }
    }
}

/// Round-6 P53 — decision 15's remaining local claim on a remote context.
///
/// Decision 15 gated the Signal pairing BUTTONS on `remotePairingNotice`
/// because the embedded terminal spawns on this Mac and writes the link into
/// the LOCAL `~/.hermes`, which a remote gateway never reads. The
/// prerequisite status row above them kept rendering `detectSignalCLI()`,
/// which probes this Mac's login-shell PATH — a fact about the wrong machine
/// on a remote window, and one that reads as an instruction ("install it
/// first") the user cannot usefully follow.
@Suite("The Signal prerequisite row follows the host (P53)")
struct SignalPrerequisiteRowP53Tests {

    private static func viewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .appendingPathComponent(
                "scarf/Features/Platforms/Views/PlatformSetup/SignalSetupView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The row's body, sliced so a mention anywhere else in the file (the
    /// buttons already key on the notice) cannot satisfy this.
    private static func prerequisiteRow(_ source: String) throws -> String {
        let start = try #require(
            source.range(of: "private var prerequisiteStatus: some View {"),
            "the prerequisite row is gone")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    private var "), "no following member")
        return String(rest[..<end.lowerBound])
    }

    @Test("the row keys on the remote notice before the local probe")
    func theRowAsksWhichHostFirst() throws {
        let row = try Self.prerequisiteRow(try Self.viewSource())
        #expect(row.contains("viewModel.remotePairingNotice"), """
            The prerequisite row still reports the LOCAL `detectSignalCLI()` \
            result on a remote context. Decision 15 fixed the buttons and \
            left the sentence above them making the same wrong claim.
            """)
        // And it must be the GATE, not an extra line beside the probe: the
        // local verdict may not render at all on a remote context.
        let probeIndex = try #require(row.range(of: "viewModel.signalCLIInstalled"))
        let noticeIndex = try #require(row.range(of: "viewModel.remotePairingNotice"))
        #expect(noticeIndex.lowerBound < probeIndex.lowerBound,
                "the local probe is read before the host is decided")
    }

    @Test("the row reuses the shared host sentence, it does not invent one")
    func theRowReusesTheSharedNotice() throws {
        let row = try Self.prerequisiteRow(try Self.viewSource())
        // `remotePairingNotice` is `PlatformSetupHelpers.remoteOnlyHostNotice`,
        // which names the host. A second hand-written sentence here would
        // drift from the buttons' one.
        #expect(!row.contains("Text(\"Pairing needs a terminal"),
                "the row hand-wrote its own host sentence instead of using the shared one")
    }

    /// The notice itself still names the host, which is the whole point of
    /// showing it instead of the PATH verdict.
    @Test("the shared notice names the host and only fires on a remote context")
    @MainActor
    func theSharedNoticeNamesTheHost() {
        #expect(PlatformSetupHelpers.remoteOnlyHostNotice(ServerContext.local) == nil,
                "a local context must still show the real PATH verdict")
        // The half that was missing (round-6 P53b): asserting only the nil
        // arm leaves a notice that fires correctly but says nothing about
        // WHICH machine — the defect the row was changed to fix.
        let remote = ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "box.local")))
        let notice = PlatformSetupHelpers.remoteOnlyHostNotice(remote)
        #expect(notice != nil, "a remote context shows no host notice at all")
        #expect(notice?.contains("Box") == true, """
            The notice does not name the host, so the row's sentence is as \
            ambiguous as the PATH verdict it replaced: \(notice ?? "nil")
            """)
    }
}
