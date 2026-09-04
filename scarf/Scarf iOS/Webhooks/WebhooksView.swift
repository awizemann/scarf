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
        let result = await Task.detached {
            return Self.runHermesList(context: ctx)
        }.value
        if Self.detectNotEnabled(result) {
            self.notEnabled = true
            self.webhooks = []
            self.lastError = nil
            return
        }
        self.notEnabled = false
        let parsed = Self.parse(result)
        self.webhooks = parsed
        // When the CLI returned text but the parser produced nothing, the
        // user otherwise sees a silent empty list. Surface a parse-failure
        // message so they know to dig deeper.
        self.lastError = (parsed.isEmpty && !result.isEmpty)
            ? "Couldn't parse webhook list output"
            : nil
    }

    nonisolated private static func runHermesList(context: ServerContext) -> String {
        let transport = context.makeTransport()
        do {
            let r = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: ["webhook", "list"],
                stdin: nil,
                timeout: 30
            )
            return r.stdoutString + r.stderrString
        } catch {
            return ""
        }
    }

    nonisolated private static func detectNotEnabled(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("webhook platform is not enabled")
            || lower.contains("run the gateway setup wizard")
            || lower.contains("webhook_enabled=true")
    }

    /// Tolerant block-parser. Each subscription begins on a non-indented
    /// line; description / deliver / events / url details follow as
    /// indented `key: value` lines. Mirrors the Mac parser shape so
    /// future drift only has to be fixed in one canonical place if/when
    /// we promote this VM into ScarfCore.
    nonisolated private static func parse(_ output: String) -> [WebhookRow] {
        var results: [WebhookRow] = []
        var name = ""
        var desc = ""
        var deliver = ""
        var events: [String] = []
        var route = ""

        func flush() {
            if !name.isEmpty {
                results.append(WebhookRow(
                    name: name,
                    description: desc,
                    deliver: deliver,
                    events: events,
                    routeSuffix: route.isEmpty ? "/webhooks/\(name)" : route
                ))
            }
            name = ""; desc = ""; deliver = ""; events = []; route = ""
        }

        for raw in output.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                flush()
                let candidate = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                // \A…\z, not ^…$: ICU's $ matches before a trailing line
                // terminator (SEC-L1); the name feeds a rendered route path.
                if candidate.range(of: "\\A[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil {
                    name = candidate
                }
                continue
            }
            if trimmed.lowercased().hasPrefix("description:") {
                desc = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("deliver:") {
                deliver = String(trimmed.dropFirst("deliver:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("events:") {
                let list = String(trimmed.dropFirst("events:".count)).trimmingCharacters(in: .whitespaces)
                events = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if trimmed.lowercased().hasPrefix("url:") || trimmed.lowercased().hasPrefix("route:") {
                route = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return results
    }

    private struct WebhookRow: Identifiable {
        var id: String { name }
        let name: String
        let description: String
        let deliver: String
        let events: [String]
        let routeSuffix: String
    }
}
