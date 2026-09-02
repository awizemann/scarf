import SwiftUI
import ScarfCore
import ScarfDesign

struct MCPServerAddCustomView: View {
    let viewModel: MCPServersViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var name: String = ""
    @State private var transport: MCPTransport = .stdio
    @State private var command: String = "npx"
    @State private var argsText: String = ""
    @State private var url: String = ""
    @State private var auth: String = "none"
    @State private var sseReadTimeout: String = ""
    @State private var showCatalog = false
    /// Manifest `tools.default_excluded` from the picked catalog entry, if
    /// any — written to `mcp_servers.<name>.tools.exclude` right after the
    /// server is added, mirroring what `hermes mcp install` does at install
    /// time (mcp_catalog.py `_apply_tool_selection`/`_write_tools_exclude`).
    @State private var pendingDefaultExcludedTools: [String] = []
    /// Manifest `tools.default_enabled` — an allow-list written to
    /// `mcp_servers.<name>.tools.include`. Mutually exclusive with the
    /// exclude list above; Scarf previously dropped this half entirely.
    @State private var pendingDefaultEnabledTools: [String] = []
    /// Bearer token for `Header` auth. Typed here so the CLI's masked
    /// value read gets a real key — the old blind `y` pipe answered that
    /// prompt with the literal string `y` and Hermes wrote it into
    /// `~/.hermes/.env` as this server's API key.
    @State private var apiKey: String = ""
    /// See `clearCatalogDefaultsIfRetargeted`.
    @State private var appliedCatalogIdentity: String?

    /// `.sse` is a v0.13+ surface; pre-v0.13 hosts only see stdio + http.
    /// Iterating `MCPTransport.allCases` directly would render the SSE
    /// segment unconditionally and Hermes would reject the resulting CLI
    /// invocation at argparse time.
    private var availableTransports: [MCPTransport] {
        var t: [MCPTransport] = [.stdio, .http]
        if capabilitiesStore?.capabilities.hasMCPSSETransport ?? false {
            t.append(.sse)
        }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Custom MCP Server")
                    .scarfStyle(.headline)
                Spacer()
                // The roster is a verbatim v0.21.0 snapshot (65 entries, up
                // from 20 in v0.20.4; blender stays removed). Offering it on
                // an older host would advertise entries that host's
                // `hermes mcp install` has never heard of, so it follows the
                // branch's gating convention and only appears on v0.20.4+.
                // (`tools.default_excluded` needs no extra floor: the
                // config-side `tools.exclude` consumer Scarf writes to
                // already existed at v0.20.4 — see OptionalMCPCatalog.swift.)
                if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
                    Button("Browse Catalog…") { showCatalog = true }
                }
                Button("Cancel") { dismiss() }
                Button("Add") {
                    submit()
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(!canSubmit)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionBox(title: "Identity") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name").font(.caption.bold())
                            TextField("my_server", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Name")
                            Text("Becomes the key under mcp_servers: in config.yaml.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    sectionBox(title: "Transport") {
                        Picker("", selection: $transport) {
                            ForEach(availableTransports) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    switch transport {
                    case .stdio:
                        stdioSection
                    case .http:
                        httpSection
                    case .sse:
                        sseSection
                    }
                    Text("Env vars, headers, and tool filters can be edited after the server is added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $showCatalog) {
            OptionalMCPCatalogPickerView { entry in
                applyCatalogEntry(entry)
                showCatalog = false
            } onCancel: {
                showCatalog = false
            }
        }
        // The pending tool lists belong to the catalog entry the user
        // picked. Once they retarget the form at a different server, those
        // tool names no longer describe it — keeping them would filter
        // tools on a server the user hand-wrote.
        .onChange(of: name) { _, _ in clearCatalogDefaultsIfRetargeted() }
        .onChange(of: url) { _, _ in clearCatalogDefaultsIfRetargeted() }
        .onChange(of: command) { _, _ in clearCatalogDefaultsIfRetargeted() }
        .onChange(of: transport) { _, _ in clearCatalogDefaultsIfRetargeted() }
    }

    /// Prefills the add-form fields from a picked catalog entry. Stdio
    /// entries (e.g. `n8n`) only carry a name/description in the roster —
    /// Scarf doesn't run the catalog's `install:` bootstrap, so the user
    /// still has to fill in `command`/`args` by hand after picking.
    ///
    /// The prefilled transport is the manifest's `transport.type`, which is
    /// what makes the saved config match what `hermes mcp install` writes:
    /// `.http` submits through `addMCPServerHTTP`, which emits `url:` with
    /// no `transport:` key (Hermes's streamable-HTTP default) rather than
    /// the `transport: sse` line that would route Hermes to `sse_client`.
    private func applyCatalogEntry(_ entry: OptionalMCPCatalogEntry) {
        name = entry.name
        transport = availableTransports.contains(entry.transport) ? entry.transport : .http
        if let url = entry.url {
            self.url = url
        }
        switch entry.authKind {
        case .oauth: auth = "oauth"
        case .apiKey, .none: auth = "none"
        }
        pendingDefaultExcludedTools = entry.defaultExcludedTools
        pendingDefaultEnabledTools = entry.defaultEnabledTools
        appliedCatalogIdentity = currentIdentity
    }

    /// Identity of the server the pending tool lists describe, captured
    /// when a catalog entry is applied. Comparing against it is what lets
    /// `clearCatalogDefaultsIfRetargeted` distinguish "the user edited the
    /// form away from the entry" from "`applyCatalogEntry` is mid-write" —
    /// its own field writes fire `onChange` too.
    private var currentIdentity: String {
        "\(transport.rawValue)|\(name)|\(url)|\(command)"
    }

    /// Drops catalog-derived tool defaults once the form no longer
    /// describes the picked entry. The pending lists name *that* entry's
    /// tools; carrying them onto a hand-written server silently filters
    /// tools the user never chose to filter. Previously they were set once
    /// and never cleared at all.
    private func clearCatalogDefaultsIfRetargeted() {
        guard appliedCatalogIdentity != nil, currentIdentity != appliedCatalogIdentity else { return }
        clearCatalogDefaults()
    }

    private func clearCatalogDefaults() {
        pendingDefaultExcludedTools = []
        pendingDefaultEnabledTools = []
        appliedCatalogIdentity = nil
    }

    private var stdioSection: some View {
        sectionBox(title: "Command") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command").font(.caption.bold())
                    TextField("npx", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Command")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Args (one per line)").font(.caption.bold())
                    TextEditor(text: $argsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
                        )
                }
            }
        }
    }

    private var httpSection: some View {
        sectionBox(title: "Endpoint") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(.caption.bold())
                    TextField("https://...", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("URL")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auth").font(.caption.bold())
                    Picker("", selection: $auth) {
                        Text("None").tag("none")
                        Text("OAuth 2.1").tag("oauth")
                        Text("Header").tag("header")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Authentication")
                }
                if auth == "header" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API key / Bearer token").font(.caption.bold())
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("API key or Bearer token")
                        Text("Hermes stores this in `~/.hermes/.env` and references it from config.yaml — the key itself is never written into config.yaml.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sseSection: some View {
        sectionBox(title: "Endpoint (SSE)") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(.caption.bold())
                    TextField("https://.../sse", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("URL")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSE Read Timeout (seconds)").font(.caption.bold())
                    TextField("default 300", text: $sseReadTimeout)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                        .accessibilityLabel("SSE Read Timeout (seconds)")
                    Text("Hermes-side keepalive interval. Leave blank to use the default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canSubmit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        switch transport {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .sse:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let args = argsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resolvedAuth: String? = (auth == "none") ? nil : auth
        switch transport {
        case .stdio, .http:
            viewModel.addCustom(
                name: trimmedName,
                transport: transport,
                command: command.trimmingCharacters(in: .whitespaces),
                args: args,
                url: url.trimmingCharacters(in: .whitespaces),
                auth: resolvedAuth,
                apiKey: apiKey,
                defaultEnabledTools: pendingDefaultEnabledTools,
                defaultExcludedTools: pendingDefaultExcludedTools
            )
        case .sse:
            let trimmedTimeout = sseReadTimeout.trimmingCharacters(in: .whitespaces)
            let parsedTimeout: Int? = trimmedTimeout.isEmpty ? nil : Int(trimmedTimeout)
            viewModel.addCustomSSE(
                name: trimmedName,
                url: url.trimmingCharacters(in: .whitespaces),
                sseReadTimeout: parsedTimeout,
                auth: resolvedAuth,
                apiKey: apiKey,
                defaultEnabledTools: pendingDefaultEnabledTools,
                defaultExcludedTools: pendingDefaultExcludedTools
            )
        }
        // Consumed — never leave them set for a subsequent add.
        clearCatalogDefaults()
        apiKey = ""
        dismiss()
    }

    @ViewBuilder
    private func sectionBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
