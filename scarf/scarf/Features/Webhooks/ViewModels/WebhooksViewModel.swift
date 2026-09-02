import Foundation
import ScarfCore
import os

nonisolated struct HermesWebhook: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let deliver: String
    let events: [String]
    let routeSuffix: String    // The URL suffix shown by hermes after subscription
    /// `--deliver-only` route: the rendered prompt is delivered directly,
    /// the agent never runs. The CLI marks these `(direct — no agent)`.
    let deliverOnly: Bool

    init(name: String, description: String, deliver: String, events: [String], routeSuffix: String, deliverOnly: Bool = false) {
        self.name = name
        self.description = description
        self.deliver = deliver
        self.events = events
        self.routeSuffix = routeSuffix
        self.deliverOnly = deliverOnly
    }

    init(_ entry: HermesWebhookEntry) {
        self.init(
            name: entry.name,
            description: entry.description,
            deliver: entry.deliver,
            events: entry.events,
            routeSuffix: entry.url.isEmpty ? "/webhooks/\(entry.name)" : entry.url,
            deliverOnly: entry.deliverOnly
        )
    }
}

@Observable
final class WebhooksViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "WebhooksViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var webhooks: [HermesWebhook] = []
    var isLoading = false
    var message: String?
    /// Whether `message` is a failure. The header banner used to render
    /// every message in the success colour, so an honest "subscribe failed"
    /// still read as green-checkmark good news. (F9)
    var messageIsError = false

    /// True when hermes's webhook gateway isn't configured. In that state,
    /// `hermes webhook list` returns setup instructions rather than a list of
    /// subscriptions — the UI should show a "Setup required" panel instead of
    /// trying to parse the output as webhook entries.
    var webhookPlatformNotEnabled: Bool = false

    /// `hasLoaded` lets a plain section re-entry skip the `webhook list` SSH
    /// call (the VM is cached in `AppCoordinator` and persists across switches);
    /// Reload and post-mutation reloads pass `force: true` (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    /// Set by `subscribe` to the normalized name it believes it just
    /// created. The next completed `load` checks the reloaded list for it —
    /// a second, independent confirmation alongside the `Secret:` line, so a
    /// drift in either the create output or this parser can't leave a
    /// "Subscribed" banner over a subscription that isn't there. (F9)
    @ObservationIgnored private var pendingSubscribeConfirmation: String?

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["webhook", "list"], timeout: 30)
            let notEnabled = Self.detectNotEnabled(result.output)
            let parsed = notEnabled ? [] : HermesWebhookList.parse(result.output).map(HermesWebhook.init)
            await MainActor.run {
                self.isLoading = false
                self.webhookPlatformNotEnabled = notEnabled
                self.webhooks = parsed
                if let pending = self.pendingSubscribeConfirmation {
                    self.pendingSubscribeConfirmation = nil
                    if !notEnabled, !parsed.contains(where: { $0.name == pending }) {
                        self.message = String(
                            localized: "Hermes reported creating /\(pending), but it isn’t in the subscription list. Check `hermes webhook list` on the host.",
                            comment: "Webhook subscribe claimed success but the reload disagrees"
                        )
                        self.messageIsError = true
                        self.createdSecret = nil
                    }
                }
            }
        }
    }

    /// Detect the "not enabled" state by the setup-instructions marker hermes emits.
    /// Checked before parsing so we don't synthesize bogus entries from instructional
    /// text.
    nonisolated private static func detectNotEnabled(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("webhook platform is not enabled")
            || lower.contains("run the gateway setup wizard")
            || lower.contains("webhook_enabled=true")
    }

    /// The HMAC secret and URL a just-created subscription reported.
    ///
    /// `webhook subscribe` MINTS a secret when the form leaves the field
    /// empty (`secrets.token_urlsafe(32)`) and prints it exactly once, in
    /// the create output. Scarf used to throw that stdout away — so the
    /// common path (let Hermes generate it) produced a subscription the
    /// user could never sign requests for, with no way to recover the value
    /// short of reading `webhook_subscriptions.json` on the host by hand.
    struct CreatedWebhookSecret: Identifiable, Sendable, Equatable {
        var id: String { name }
        let name: String
        let url: String
        let secret: String
    }

    /// Set after a successful subscribe; the view presents it as a
    /// copy-once sheet. Cleared when the user dismisses.
    var createdSecret: CreatedWebhookSecret?

    func subscribe(name: String, prompt: String, events: String, description: String, skills: String, deliver: String, chatID: String, secret: String) {
        guard !name.isEmpty else { return }
        var args = ["webhook", "subscribe"]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        if !events.isEmpty { args += ["--events", events] }
        if !description.isEmpty { args += ["--description", description] }
        if !skills.isEmpty { args += ["--skills", skills] }
        if !deliver.isEmpty { args += ["--deliver", deliver] }
        if !chatID.isEmpty { args += ["--deliver-chat-id", chatID] }
        // `--secret` puts a user-typed HMAC secret in this process's argv,
        // where it is visible to any local `ps`/`/proc` reader for the life
        // of the CLI run. Hermes offers no stdin or env path for it on
        // `webhook subscribe`, so there is no alternative short of not
        // supporting the field — and leaving it empty (the default, and what
        // the placeholder recommends) makes Hermes mint the secret itself
        // and avoids the exposure entirely. Same trade-off, and same note,
        // as the WhatsApp token argv in F2.
        if !secret.isEmpty { args += ["--secret", secret] }
        args += ["--", name]
        // `_cmd_subscribe` normalizes before writing: lowercased, spaces to
        // hyphens. The reload check has to look for THAT name, not what the
        // user typed, or a "Weather Hook" subscribe would look absent.
        let storedName = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            // `_cmd_subscribe` exits 0 on EVERY failure path — an invalid
            // name, `--deliver-only` without a real target, a bad script —
            // each is a `print(...)` then a bare `return`, so the exit code
            // alone reported "Subscribed /<name>" for subscriptions that
            // were never written. The success line is the real signal: on a
            // genuine create/update the CLI always prints `Secret:`
            // (whether it minted the value or echoed the one we passed), and
            // on every failure path it prints nothing of the sort. (F9)
            let created = Self.parseCreatedSecret(result.output, name: storedName)
            await MainActor.run {
                if let created {
                    self.message = "Subscribed /\(storedName)"
                    self.messageIsError = false
                    self.createdSecret = created
                    self.pendingSubscribeConfirmation = storedName
                } else {
                    // Surface the CLI's own words — "Invalid name 'x y'.
                    // Use lowercase alphanumeric…" is actionable in a way
                    // that a bare "Failed" is not.
                    self.createdSecret = nil
                    self.message = Self.subscribeFailureMessage(result.output)
                    self.messageIsError = true
                }
                self.load(force: true)
                let delay: TimeInterval = created == nil ? 6 : 2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    /// Pull the CLI's own failure line out of a `webhook subscribe` that
    /// wrote nothing. Every failure path in `_cmd_subscribe` prints a line
    /// starting `Error:`; fall back to the last non-empty line, then to a
    /// generic message, so the banner is never empty.
    nonisolated static func subscribeFailureMessage(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let error = lines.first(where: { $0.hasPrefix("Error:") }) {
            return String(error.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? String(
            localized: "Subscribe failed — Hermes wrote no subscription and gave no reason.",
            comment: "Webhook subscribe failed with no CLI output"
        )
    }

    /// Pull `Secret:` / `URL:` out of the create output.
    ///
    /// Both are printed as two-space-indented `Label: value` lines. The
    /// secret is `token_urlsafe`, so it never contains whitespace — taking
    /// the rest of the line and trimming is exact. A miss returns `nil`
    /// (no sheet) rather than a blank one: showing an empty "your secret"
    /// box would be worse than staying quiet.
    nonisolated static func parseCreatedSecret(_ output: String, name: String) -> CreatedWebhookSecret? {
        var secret = ""
        var url = ""
        for raw in output.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if secret.isEmpty, trimmed.hasPrefix("Secret:") {
                secret = String(trimmed.dropFirst("Secret:".count)).trimmingCharacters(in: .whitespaces)
            } else if url.isEmpty, trimmed.hasPrefix("URL:") {
                url = String(trimmed.dropFirst("URL:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !secret.isEmpty else { return nil }
        return CreatedWebhookSecret(name: name, url: url, secret: secret)
    }

    func remove(_ webhook: HermesWebhook) {
        runAndReload(["webhook", "remove", webhook.name], success: "Removed")
    }

    func test(_ webhook: HermesWebhook) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["webhook", "test", webhook.name], timeout: 30)
            await MainActor.run {
                self.message = result.exitCode == 0 ? "Test fired — check logs" : "Test failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            await MainActor.run {
                self.message = result.exitCode == 0 ? success : "Failed"
                self.load(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    // The old `parseWebhookList` lived here. It opened a new record only
    // on a line with no leading whitespace — a line `webhook.py::_cmd_list`
    // never prints, since every row it emits is indented under a `  ◆ name`
    // bullet. It therefore matched nothing and the section rendered empty
    // regardless of how many subscriptions existed. Parsing now lives in
    // `ScarfCore.HermesWebhookList`, against fixtures transcribed from that
    // emitter.
}
