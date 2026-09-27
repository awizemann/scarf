import SwiftUI
import ScarfCore
import ScarfDesign
import os

/// iOS read-only Webhooks view (v2.6).
///
/// Lists `hermes webhook list` output so mobile users can see what
/// dynamic webhook subscriptions the remote agent is honoring. Create /
/// remove / test actions stay on Mac for v2.6 — most webhook setup
/// involves pasting URLs / secrets that are inconvenient on a phone.
///
/// Reuses the same tolerant text parser the Mac WebhooksViewModel uses.
struct WebhooksView: View {
    let config: IOSServerConfig

    @State private var webhooks: [WebhookRow] = []
    @State private var notEnabled = false
    @State private var isLoading = true
    @State private var lastError: String?
    @Environment(\.serverContext) private var contextFromEnv

    private var context: ServerContext {
        // The view receives `IOSServerConfig` directly (matches the
        // sibling Skills/Settings tabs); use that to construct a
        // context bound to the active server. Falls back to env when
        // the navigation host hasn't injected a config-derived ctx.
        config.toServerContext(id: contextFromEnv.id)
    }

    var body: some View {
        List {
            if let err = lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                }
            }

            if notEnabled {
                Section("Setup required") {
                    Text("The webhook gateway platform isn't enabled on this server. Run `hermes setup` from the Mac app or a shell to enable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if webhooks.isEmpty && !isLoading {
                Section {
                    ContentUnavailableView(
                        "No webhooks subscribed",
                        systemImage: "arrow.up.right.square",
                        description: Text("Run `hermes webhook subscribe …` from the Mac app to register one.")
                    )
                }
            } else {
                ForEach(webhooks) { hook in
                    Section(hook.name) {
                        if !hook.description.isEmpty {
                            LabeledContent("Description", value: hook.description)
                        }
                        if !hook.deliver.isEmpty {
                            LabeledContent("Deliver", value: hook.deliver)
                        }
                        if !hook.events.isEmpty {
                            LabeledContent("Events", value: hook.events.joined(separator: ", "))
                        }
                        LabeledContent("Route", value: hook.routeSuffix)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = context
        guard let result = await Self.runHermesList(context: ctx) else {
            // The command never ran (SSH down, timeout) — not "no webhooks".
            self.notEnabled = false
            self.webhooks = []
            self.lastError = String(localized: "Couldn't run hermes webhook list on this server")
            return
        }
        // The shared Mac parser (S07-F5): `webhook list` indents EVERY line
        // (`  ◆ name`, `    URL: …`), which the old private parser here —
        // opening a record only on an unindented line — never matched, so
        // every host showed "Couldn't parse" with an empty list.
        switch HermesWebhookList.listing(result) {
        case .notEnabled:
            self.notEnabled = true
            self.webhooks = []
            self.lastError = nil
        case .entries(let entries):
            self.notEnabled = false
            self.webhooks = entries.map(WebhookRow.init)
            self.lastError = nil
        case .unparsed:
            // Text came back but it is neither a listing nor the empty
            // state — say so rather than show a silent empty list.
            self.notEnabled = false
            self.webhooks = []
            self.lastError = String(localized: "Couldn't parse webhook list output")
        }
    }

    nonisolated private static func runHermesList(context: ServerContext) async -> String? {
        let transport = context.makeTransport()
        do {
            let r = try await transport.asyncRunProcess(
                executable: context.paths.hermesBinary,
                args: ["webhook", "list"],
                stdin: nil,
                timeout: 30
            )
            return r.stdoutString + r.stderrString
        } catch {
            return nil
        }
    }

    private struct WebhookRow: Identifiable {
        var id: String { name }
        let name: String
        let description: String
        let deliver: String
        let events: [String]
        let routeSuffix: String

        init(_ entry: HermesWebhookEntry) {
            name = entry.name
            description = entry.description
            deliver = entry.deliver
            events = entry.events
            // The CLI prints the full URL; the route is its path.
            let path = URL(string: entry.url)?.path ?? ""
            routeSuffix = path.isEmpty ? "/webhooks/\(entry.name)" : path
        }
    }
}
