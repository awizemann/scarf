import Foundation
import ScarfCore
import os

struct HermesWebhook: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let deliver: String
    let events: [String]
    let routeSuffix: String    // The URL suffix shown by hermes after subscription
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

    /// True when hermes's webhook gateway isn't configured. In that state,
    /// `hermes webhook list` returns setup instructions rather than a list of
    /// subscriptions — the UI should show a "Setup required" panel instead of
    /// trying to parse the output as webhook entries.
    var webhookPlatformNotEnabled: Bool = false

    /// `hasLoaded` lets a plain section re-entry skip the `webhook list` SSH
    /// call (the VM is cached in `AppCoordinator` and persists across switches);
    /// Reload and post-mutation reloads pass `force: true` (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["webhook", "list"], timeout: 30)
            let notEnabled = Self.detectNotEnabled(result.output)
            let parsed = notEnabled ? [] : Self.parseWebhookList(result.output)
            await MainActor.run {
                self.isLoading = false
                self.webhookPlatformNotEnabled = notEnabled
                self.webhooks = parsed
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
        if !secret.isEmpty { args += ["--secret", secret] }
        args += ["--", name]
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            let minted = result.exitCode == 0
                ? Self.parseCreatedSecret(result.output, name: name)
                : nil
            await MainActor.run {
                self.message = result.exitCode == 0 ? "Subscribed /\(name)" : "Failed"
                self.createdSecret = minted
                self.load(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.message = nil
                }
            }
        }
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

    /// Tolerant parser for `hermes webhook list`. The CLI output format is evolving,
    /// so we extract what we can and degrade gracefully for unknown shapes.
    /// `nonisolated` so it can be invoked from `Task.detached`.
    nonisolated private static func parseWebhookList(_ output: String) -> [HermesWebhook] {
        var results: [HermesWebhook] = []
        var currentName = ""
        var currentDesc = ""
        var currentDeliver = ""
        var currentEvents: [String] = []
        var currentRoute = ""

        func flush() {
            if !currentName.isEmpty {
                results.append(HermesWebhook(
                    name: currentName,
                    description: currentDesc,
                    deliver: currentDeliver,
                    events: currentEvents,
                    routeSuffix: currentRoute.isEmpty ? "/webhooks/\(currentName)" : currentRoute
                ))
            }
            currentName = ""; currentDesc = ""; currentDeliver = ""
            currentEvents = []; currentRoute = ""
        }

        for raw in output.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // New webhook block: non-indented, alphanumeric/underscore.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                flush()
                let candidate = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if candidate.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                    currentName = candidate
                }
                continue
            }
            if trimmed.lowercased().hasPrefix("description:") {
                currentDesc = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("deliver:") {
                currentDeliver = String(trimmed.dropFirst("deliver:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("events:") {
                let list = String(trimmed.dropFirst("events:".count)).trimmingCharacters(in: .whitespaces)
                currentEvents = list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if trimmed.lowercased().hasPrefix("url:") || trimmed.lowercased().hasPrefix("route:") {
                currentRoute = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return results
    }
}
