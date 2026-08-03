import Testing
@testable import ScarfCore

/// Wave C3 — `hermes approvals suggest` + `hermes cron runs` (v0.20).
///
/// Fixtures: the empty-proposals JSON and the cron-runs empty sentinel are
/// verbatim captures from a live local Hermes v0.20 (`hermes approvals
/// suggest --json`, `hermes cron runs`). The populated fixtures follow the
/// exact emit code in `hermes_cli/approvals_suggest.py` (payload dict,
/// `json.dumps(..., indent=2)`) and `hermes_cli/cron.py::cron_runs`
/// (`f"{id}  {status:<9}  job={job_id}  source={source}  {claimed_at}"`
/// plus a 4-space-indented error line).
@Suite struct HermesV020ParityWaveC3Tests {

    // MARK: - approvals suggest: JSON parser

    /// Verbatim live capture from `hermes approvals suggest --json`.
    static let emptySuggestJSON = """
    {
      "db": "/Users/awizemann/.hermes/state.db",
      "days": 90,
      "proposals": []
    }
    """

    static let populatedSuggestJSON = """
    {
      "db": "/Users/awizemann/.hermes/state.db",
      "days": 90,
      "proposals": [
        {
          "n": 1,
          "pattern": "git push *",
          "kind": "glob",
          "count": 7,
          "classes": [
            "git force push"
          ],
          "examples": [
            "git push --force-with-lease origin main",
            "git push -f origin feat/x"
          ]
        },
        {
          "n": 2,
          "pattern": "container lifecycle (docker/podman restart)",
          "kind": "class",
          "count": 3,
          "classes": [
            "container lifecycle (docker/podman restart)"
          ],
          "examples": [
            "docker compose restart web && docker compose logs --tail 20 web"
          ]
        }
      ]
    }
    """

    @Test func suggestParserEmptyProposalsParsesToEmptyArray() {
        let proposals = HermesApprovalsSuggestParser.parse(json: Self.emptySuggestJSON)
        #expect(proposals != nil)
        #expect(proposals?.isEmpty == true)
    }

    @Test func suggestParserPopulatedPayload() throws {
        let proposals = try #require(HermesApprovalsSuggestParser.parse(json: Self.populatedSuggestJSON))
        #expect(proposals.count == 2)

        let first = proposals[0]
        #expect(first.n == 1)
        #expect(first.pattern == "git push *")
        #expect(first.kind == "glob")
        #expect(first.count == 7)
        #expect(first.classes == ["git force push"])
        #expect(first.examples.count == 2)
        #expect(first.id == 1)

        let second = proposals[1]
        #expect(second.kind == "class")
        #expect(second.pattern == "container lifecycle (docker/podman restart)")
        #expect(second.count == 3)
    }

    @Test func suggestParserRejectsNonJSONAndErrorText() {
        #expect(HermesApprovalsSuggestParser.parse(json: "") == nil)
        #expect(HermesApprovalsSuggestParser.parse(json: "usage: hermes approvals suggest [-h]") == nil)
        #expect(HermesApprovalsSuggestParser.parse(json: "{\"db\": \"x\"}") == nil)
    }

    @Test func suggestParserApplyResult() {
        let json = "{\"applied\": [\"git push *\"], \"allowlist_size\": 5}"
        let result = HermesApprovalsSuggestParser.parseApplyResult(json: json)
        #expect(result == HermesApprovalsSuggestParser.ApplyResult(applied: ["git push *"], allowlistSize: 5))
        #expect(HermesApprovalsSuggestParser.parseApplyResult(json: "nope") == nil)
    }

    // MARK: - approvals suggest: argv

    @Test func suggestArgsDefaultOmitsKnobs() {
        #expect(HermesApprovalsSuggestParser.suggestArgs() == ["approvals", "suggest", "--json"])
    }

    @Test func suggestArgsWithKnobs() {
        #expect(HermesApprovalsSuggestParser.suggestArgs(days: 30, minCount: 3)
                == ["approvals", "suggest", "--json", "--days", "30", "--min-count", "3"])
    }

    @Test func applyArgsSingleIndex() {
        #expect(HermesApprovalsSuggestParser.applyArgs(indices: [2])
                == ["approvals", "suggest", "--apply", "2", "--json"])
    }

    @Test func applyArgsDedupesSortsAndDropsInvalid() {
        #expect(HermesApprovalsSuggestParser.applyArgs(indices: [3, 1, 3, 0, -2])
                == ["approvals", "suggest", "--apply", "1,3", "--json"])
        #expect(HermesApprovalsSuggestParser.applyArgs(indices: []) == nil)
        #expect(HermesApprovalsSuggestParser.applyArgs(indices: [0]) == nil)
    }

    // MARK: - cron runs: text parser

    /// Verbatim live capture from `hermes cron runs` with no history.
    @Test func cronRunsParserEmptySentinel() {
        #expect(HermesCronRunsParser.parse(text: "No cron execution attempts recorded.\n") == [])
        #expect(HermesCronRunsParser.parse(text: "") == [])
    }

    /// Row format per `cron_runs` in hermes_cli/cron.py — status is
    /// left-padded to 9 columns; failed rows carry an indented error line.
    static let cronRunsText = """
    9f2c1e77aa004d0f8e21bb6f01c5d9ab  completed  job=job-a1b2c3  source=scheduler  2026-08-03T09:00:02-04:00
    1d40b7c2f4e94b0abc99310277e6a001  failed     job=job-a1b2c3  source=manual  2026-08-02T17:31:44-04:00
        RuntimeError: model call timed out after 300s
    77aa0c3d5e6f47b2a1908877dd41e0cd  running    job=job-zz99  source=webhook  2026-08-03T10:15:00-04:00
    """

    @Test func cronRunsParserPopulatedListing() {
        let runs = HermesCronRunsParser.parse(text: Self.cronRunsText)
        #expect(runs.count == 3)

        #expect(runs[0].id == "9f2c1e77aa004d0f8e21bb6f01c5d9ab")
        #expect(runs[0].status == "completed")
        #expect(runs[0].jobID == "job-a1b2c3")
        #expect(runs[0].source == "scheduler")
        #expect(runs[0].claimedAt == "2026-08-03T09:00:02-04:00")
        #expect(runs[0].error == nil)

        #expect(runs[1].status == "failed")
        #expect(runs[1].source == "manual")
        #expect(runs[1].error == "RuntimeError: model call timed out after 300s")

        #expect(runs[2].status == "running")
        #expect(runs[2].jobID == "job-zz99")
    }

    @Test func cronRunsParserMultiLineErrorAndGarbageRows() {
        let text = """
        abc123  failed     job=j1  source=scheduler  2026-08-01T00:00:00
            line one
            line two
        this row is not parseable
        """
        let runs = HermesCronRunsParser.parse(text: text)
        #expect(runs.count == 1)
        #expect(runs[0].error == "line one\nline two")
    }

    @Test func cronRunsParserIgnoresLeadingOrphanIndent() {
        // An indented line with no preceding row must not crash or emit.
        #expect(HermesCronRunsParser.parse(text: "    stray error\n") == [])
    }

    // MARK: - cron runs: argv

    @Test func cronRunsArgs() {
        #expect(HermesCronRunsParser.args() == ["cron", "runs"])
        #expect(HermesCronRunsParser.args(jobID: "job-a1b2c3") == ["cron", "runs", "job-a1b2c3"])
        #expect(HermesCronRunsParser.args(jobID: "j", limit: 50) == ["cron", "runs", "j", "--limit", "50"])
        #expect(HermesCronRunsParser.args(jobID: "") == ["cron", "runs"])
    }

    @Test func cronRunsArgsClampsLimitToCLIRange() {
        #expect(HermesCronRunsParser.args(limit: 0) == ["cron", "runs", "--limit", "1"])
        #expect(HermesCronRunsParser.args(limit: 9999) == ["cron", "runs", "--limit", "500"])
    }

    // MARK: - gating

    @Test func bothSurfacesGateOnV020() {
        let v020 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(v020.hasApprovalsSuggest)
        #expect(v020.hasCronRuns)

        let v019 = HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)")
        #expect(!v019.hasApprovalsSuggest)
        #expect(!v019.hasCronRuns)
    }
}
