import Testing
import Foundation
@testable import scarf

/// F2 / t-e96cc0ad — the app-side halves: cron's end-of-options marker and
/// the webhook secret Hermes mints and prints exactly once.
@Suite struct CronEndOfOptionsTests {

    @Test("a prompt that opens with a dash is a positional, not a flag")
    func createPutsPositionalsBehindEndOfOptions() {
        let argv = CronViewModel.createJobArguments(
            schedule: "0 9 * * *",
            prompt: "--deliver isn't working, investigate",
            name: "digest",
            deliver: "log",
            skills: [],
            script: "",
            repeatCount: ""
        )
        let marker = try! #require(argv.firstIndex(of: "--"))
        #expect(Array(argv[marker...]) == ["--", "0 9 * * *", "--deliver isn't working, investigate"])
        // Every flag stays AHEAD of the marker — argparse reads each token
        // after it as a positional, so a flag behind it would be rejected
        // as an unrecognized extra argument.
        #expect(argv.firstIndex(of: "--name")! < marker)
        #expect(argv.firstIndex(of: "--deliver")! < marker)
    }

    @Test("the no-agent form still sends its empty prompt positional")
    func noAgentKeepsTheEmptyPrompt() {
        let argv = CronViewModel.createJobArguments(
            schedule: "30m", prompt: "", name: "", deliver: "",
            skills: [], script: "run.sh", repeatCount: "", workdir: "", noAgent: true
        )
        #expect(argv.suffix(3) == ["--", "30m", ""])
        #expect(argv.firstIndex(of: "--no-agent")! < argv.firstIndex(of: "--")!)
    }

    @Test("the marker appears exactly once even with every flag populated")
    func markerIsNotDuplicated() {
        let argv = CronViewModel.createJobArguments(
            schedule: "30m", prompt: "p", name: "n", deliver: "log",
            skills: ["a", "b"], script: "s.sh", repeatCount: "3",
            workdir: "/tmp", noAgent: false
        )
        #expect(argv.filter { $0 == "--" }.count == 1)
    }
}

@Suite struct WebhookGeneratedSecretTests {

    /// Verbatim shape of `hermes webhook subscribe` output (v2026.8.31,
    /// `hermes_cli/webhook.py`), including its two-space indent.
    private let output = """

      Created webhook subscription: github_push
      URL:    https://example.test/webhooks/github_push
      Secret: 8Vn3_kQm-Zr7TbW1xYc4pLd9sEfGhJkN0oPqRsTuVwY
      Events: push, pull_request
      Deliver: log

      Configure your service to POST to the URL above.
      Use the secret for HMAC-SHA256 signature validation.
    """

    @Test("the minted secret and URL are recovered from the create output")
    func parsesSecretAndURL() throws {
        let created = try #require(
            WebhooksViewModel.parseCreatedSecret(output, name: "github_push")
        )
        #expect(created.secret == "8Vn3_kQm-Zr7TbW1xYc4pLd9sEfGhJkN0oPqRsTuVwY")
        #expect(created.url == "https://example.test/webhooks/github_push")
        #expect(created.name == "github_push")
    }

    @Test("output without a Secret line yields nil rather than a blank sheet")
    func missingSecretYieldsNil() {
        #expect(WebhooksViewModel.parseCreatedSecret("Updated webhook subscription: x", name: "x") == nil)
        #expect(WebhooksViewModel.parseCreatedSecret("", name: "x") == nil)
    }

    @Test("the first Secret line wins — later prose mentioning it cannot overwrite")
    func firstSecretLineWins() throws {
        let noisy = output + "\n  Secret: not-the-real-one\n"
        let created = try #require(WebhooksViewModel.parseCreatedSecret(noisy, name: "github_push"))
        #expect(created.secret == "8Vn3_kQm-Zr7TbW1xYc4pLd9sEfGhJkN0oPqRsTuVwY")
    }
}
