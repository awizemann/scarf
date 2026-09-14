import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Release blocker 4 — seven `.unconfirmed` arms reached a two-way `if`.
///
/// P54b's invariant: **`.unconfirmed` is gated on the CONFIDENCE ALONE**, not
/// on whether there is a line to quote. `HermesCLIVerdict.judge` reaches
/// `.unconfirmed` at exit 0 with no success marker AND no refusal marker, and
/// on that arm it still fills `detail` with `lines.last` wherever
/// `fallbackDetail` is on. So a two-way `outcome.detail ?? "<verb> failed"`
/// reaches the honest sentence only when the output was EMPTY: on the far
/// commoner case — exit 0 having printed something the verdict does not
/// recognise — it rendered an unrelated tail line as Hermes's refusal.
///
/// Every test below therefore drives a **NON-EMPTY** unconfirmed output. An
/// empty-output test passes against the old two-way code and proves nothing.
///
/// Pairing is the sharpest case in the other direction: both its verbs run
/// with `fallbackDetail: false`, so `detail` is nil and the old code asserted
/// a bare "Approve failed" / "Revoke failed" — a refusal on a run that
/// printed nothing either way.
/// The two ScarfCore consumers (`SkillsViewModel`, `ProjectSkillsViewModel`)
/// are covered by the same-named suite in the ScarfCore package tests, where
/// their code lives.
@Suite("Unconfirmed CLI verdicts get their own sentence, not a failure")
struct UnconfirmedVerdictArmTests {

    /// Exit 0, no success marker, no refusal marker, and something on stdout.
    /// The shape a container host (s6) or an unknown-verb agent reply makes.
    private static let noisySilence = """
    Loading configuration…
    Done.
    """

    private static let neutralSuffix = "printed no result. Check the host."

    /// A summary is HONEST when it says Hermes printed no result and does NOT
    /// assert a refusal or quote the unrelated tail line as one.
    private func expectNeutral(
        _ summary: String,
        verb: String,
        notClaiming refusal: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(summary == "\(verb) \(Self.neutralSuffix)",
                "expected the neutral sentence for \(verb), got: \(summary)",
                sourceLocation: sourceLocation)
        #expect(!summary.contains(refusal),
                "the summary asserts a refusal Hermes never made: \(summary)",
                sourceLocation: sourceLocation)
        #expect(!summary.contains("Done."),
                "the run's unrelated tail line is being quoted as the reason: \(summary)",
                sourceLocation: sourceLocation)
    }

    // MARK: - 1. mcp remove

    @Test("MCPServersViewModel: a noisy exit-0 remove is not called a failure")
    func mcpRemove() {
        let outcome = HermesMCPRemoveVerdict.judge(output: Self.noisySilence, exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail != nil, "the premise: `detail` is non-nil on this arm")
        expectNeutral(MCPServersViewModel.removeFailureSummary(outcome: outcome),
                      verb: "hermes mcp remove", notClaiming: "Remove failed")
    }

    /// The real refusal still quotes Hermes's own line — that is P40's fix and
    /// it stays.
    @Test("MCPServersViewModel: a real refusal still quotes its reason")
    func mcpRemoveRealRefusal() {
        let output = "✗ Server 'foo' not found in config."
        let outcome = HermesMCPRemoveVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.confidence == .failed)
        let summary = MCPServersViewModel.removeFailureSummary(outcome: outcome)
        #expect(summary.hasPrefix("Remove failed: "))
        #expect(summary.contains("not found in config"))
    }

    // MARK: - 2. tools enable/disable

    @Test("ToolsViewModel: a noisy exit-0 toggle is not called a failure", arguments: ["enable", "disable"])
    func toolsToggle(action: String) {
        let outcome = HermesToolsToggle.judge(output: Self.noisySilence, exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let summary = ToolsViewModel.toggleFailureSummary(
            outcome: outcome, output: Self.noisySilence, action: action, toolset: "web"
        )
        expectNeutral(summary, verb: "hermes tools \(action)", notClaiming: "Couldn’t \(action)")
    }

    // MARK: - 6 + 7. pairing approve / revoke

    /// `fallbackDetail: false`, so `detail` is NIL here — the two-way `if`
    /// could not have quoted anything and asserted the bare refusal instead.
    @Test("GatewayViewModel: a noisy exit-0 pairing change is not called a failure",
          arguments: [true, false])
    func pairing(approving: Bool) {
        let outcome = approving
            ? HermesPairingVerdict.approve(output: Self.noisySilence, exitCode: 0)
            : HermesPairingVerdict.revoke(output: Self.noisySilence, exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == nil, "the premise: `fallbackDetail` is off for both verbs")
        expectNeutral(
            MessagingGatewayViewModel.pairingFailureSummary(outcome: outcome, approving: approving),
            verb: approving ? "hermes pairing approve" : "hermes pairing revoke",
            notClaiming: approving ? "Approve failed" : "Revoke failed"
        )
    }

    /// A real pairing refusal still quotes Hermes's own line.
    @Test("GatewayViewModel: a real pairing refusal still quotes its reason")
    func pairingRealRefusal() {
        let output = "User 42 not found in approved list for discord."
        let outcome = HermesPairingVerdict.revoke(output: output, exitCode: 1)
        #expect(outcome.confidence == .failed)
        let summary = MessagingGatewayViewModel.pairingFailureSummary(outcome: outcome, approving: false)
        #expect(summary.contains("not found in approved list"), "got: \(summary)")
    }

    // MARK: - The catalogue row behind the neutral sentence

    /// All seven sites reuse ONE catalogue key — the interpolated
    /// `%@ printed no result. Check the host.`, which `WebhooksViewModel`
    /// already drives with a verb. No new row, and the row it uses must
    /// carry all six locales.
    @Test("the shared neutral-sentence key carries all six locales")
    func neutralSentenceKeyIsTranslated() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = try #require((json as? [String: Any])?["strings"] as? [String: Any])
        let key = "%@ printed no result. Check the host."
        let entry = try #require(strings[key] as? [String: Any], "\(key) has no catalogue row")
        let locs = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"] {
            #expect(locs[locale] != nil, "\(key) is missing \(locale)")
        }
    }
}
