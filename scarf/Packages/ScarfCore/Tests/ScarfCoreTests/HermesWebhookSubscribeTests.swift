import Foundation
import Testing
@testable import ScarfCore

/// U1/U2 (Hermes v0.23.2+): masked `Secret:` line + `--signature`.
/// Shapes from `hermes_cli/webhook.py:70-73,267-270,325` and
/// `hermes_cli/subcommands/webhook.py:31` @ v0.23.4.
@Suite struct HermesWebhookSubscribeTests {

    static let v0231 = HermesCapabilities.parseLine("Hermes Agent v0.23.1 (2026.11.10)")
    static let v0232 = HermesCapabilities.parseLine("Hermes Agent v0.23.2 (2026.11.14)")

    static let plainOutput = """

      Created webhook subscription: gh
      URL:    http://localhost:8644/webhooks/gh
      Secret: abcDEF123_-plainsecretvalue0000000000000
      Events: (all)
    """

    static let maskedOutput = """

      Created webhook subscription: gh
      URL:    http://localhost:8644/webhooks/gh
      Profile: default
      Secret: abcD...0000 (full value in ~/.hermes/webhook_subscriptions.json)
      Events: (all)
      Signature: generic
    """

    @Test func plainSecretIsTakenAsPrinted() {
        let created = HermesWebhookSubscribe.parseCreated(Self.plainOutput)
        #expect(created?.url == "http://localhost:8644/webhooks/gh")
        #expect(created?.secret == .plain("abcDEF123_-plainsecretvalue0000000000000"))
        // A plain secret never touches the file.
        let resolved = HermesWebhookSubscribe.resolveSecret(
            created!.secret, name: "gh", subscriptionsPath: "/h/webhook_subscriptions.json",
            readData: { _ in Issue.record("must not read"); return nil })
        #expect(resolved == .value("abcDEF123_-plainsecretvalue0000000000000"))
    }

    @Test func maskedSecretIsReadFromSubscriptionsFile() throws {
        let created = try #require(HermesWebhookSubscribe.parseCreated(Self.maskedOutput))
        #expect(created.secret == .masked(displayPath: "~/.hermes/webhook_subscriptions.json"))
        let json = #"{"other": {"secret": "nope"}, "gh": {"description": "", "events": [], "secret": "full-real-secret", "deliver": "log", "signature": "generic"}}"#
        var readPath: String?
        let resolved = HermesWebhookSubscribe.resolveSecret(
            created.secret, name: "gh",
            subscriptionsPath: HermesWebhookSubscribe.subscriptionsPath(home: "/srv/hermes/"),
            readData: { readPath = $0; return Data(json.utf8) })
        #expect(readPath == "/srv/hermes/webhook_subscriptions.json")
        #expect(resolved == .value("full-real-secret"))
    }

    @Test(arguments: [nil, "not json", #"{"gh": {"deliver": "log"}}"#, #"{"other": {"secret": "x"}}"#])
    func maskedSecretUnreadableReportsPathNotMask(_ body: String?) throws {
        let created = try #require(HermesWebhookSubscribe.parseCreated(Self.maskedOutput))
        let resolved = HermesWebhookSubscribe.resolveSecret(
            created.secret, name: "gh", subscriptionsPath: "/h/webhook_subscriptions.json",
            readData: { _ in body.map { Data($0.utf8) } })
        #expect(resolved == .unreadable(path: "/h/webhook_subscriptions.json"))
    }

    @Test func failureOutputHasNoSecret() {
        #expect(HermesWebhookSubscribe.parseCreated("Error: Invalid name 'x y'.") == nil)
    }

    static func argv(_ caps: HermesCapabilities, _ sig: HermesWebhookSignature?) -> [String] {
        HermesWebhookSubscribe.argv(
            name: "gh", prompt: "p", events: "push", description: "", skills: "",
            deliver: "log", chatID: "", secret: "", signature: sig, capabilities: caps)
    }

    @Test func preV0232ArgvIsUnchangedEvenWithASignature() {
        #expect(Self.argv(Self.v0231, .github)
            == ["webhook", "subscribe", "--prompt", "p", "--events", "push", "--deliver", "log", "--", "gh"])
        #expect(!Self.v0231.hasWebhookSignatureOption)
    }

    @Test(arguments: HermesWebhookSignature.allCases)
    func v0232PassesSignatureBeforeSeparator(_ sig: HermesWebhookSignature) {
        #expect(Self.argv(Self.v0232, sig)
            == ["webhook", "subscribe", "--prompt", "p", "--events", "push", "--deliver", "log",
                "--signature", sig.rawValue, "--", "gh"])
    }

    @Test func signatureChoicesMatchArgparse() {
        #expect(HermesWebhookSignature.allCases.map(\.rawValue) == ["generic", "github", "gitlab", "linear"])
    }
}
