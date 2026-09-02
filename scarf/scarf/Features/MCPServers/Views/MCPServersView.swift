import SwiftUI
import ScarfCore
import ScarfDesign

struct MCPServersView: View {
    // Coordinator-cached (t-aud24) so it survives section switches.
    // `@Bindable` (not `let`) because the view needs `$viewModel` bindings
    // (`$viewModel.searchText`, `$viewModel.showPresetPicker`, …); the instance
    // is still coordinator-owned, not view-owned.
    @Bindable var viewModel: MCPServersViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(viewModel: MCPServersViewModel) {
        self.viewModel = viewModel
    }


    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            HSplitView {
                serversList
                    .frame(minWidth: 260, idealWidth: 320)
                serverDetail
                    .frame(minWidth: 500)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("MCP Servers")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading MCP servers…",
            isEmpty: viewModel.servers.isEmpty
        )
        .searchable(text: $viewModel.searchText, prompt: "Filter servers...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.load(force: true)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { viewModel.load() }
        .sheet(isPresented: $viewModel.showPresetPicker) {
            MCPServerPresetPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAddCustom) {
            MCPServerAddCustomView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showCatalog) {
            MCPCatalogSheet(
                text: viewModel.catalogText,
                isLoading: viewModel.isLoadingCatalog,
                onClose: { viewModel.showCatalog = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editingServer != nil },
            set: { if !$0 { viewModel.editingServer = nil } }
        )) {
            if let server = viewModel.editingServer {
                MCPServerEditorView(
                    // Without the context the editor defaults to `.local`
                    // and reads/writes **this Mac's** config.yaml while the
                    // user is looking at a remote host's servers — silently
                    // editing the wrong machine.
                    viewModel: MCPServerEditorViewModel(server: server, context: viewModel.context),
                    onSave: { changed in viewModel.finishEdit(reload: changed) },
                    onCancel: { viewModel.finishEdit(reload: false) }
                )
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.activeError != nil },
            set: { if !$0 { viewModel.activeError = nil } }
        )) {
            Button("OK") { viewModel.activeError = nil }
        } message: {
            Text(viewModel.activeError ?? "")
        }
        .alert("Server added", isPresented: Binding(
            get: { viewModel.activeNotice != nil },
            set: { if !$0 { viewModel.activeNotice = nil } }
        )) {
            Button("OK") { viewModel.activeNotice = nil }
        } message: {
            Text(viewModel.activeNotice ?? "")
        }
        // The overwrite decision is the user's, and it has to be made BEFORE
        // the CLI runs: `hermes mcp add` asks "already exists. Overwrite?"
        // ahead of the auth stage, and Scarf's stdin answers are positional,
        // so the plan must be built already knowing the answer. (F9)
        .alert(
            "Replace “\(viewModel.pendingOverwrite?.name ?? "")”?",
            isPresented: Binding(
                get: { viewModel.pendingOverwrite != nil },
                set: { if !$0 { viewModel.pendingOverwrite = nil } }
            ),
            presenting: viewModel.pendingOverwrite
        ) { pending in
            Button("Replace", role: .destructive) {
                viewModel.pendingOverwrite = nil
                pending.retry()
            }
            Button("Cancel", role: .cancel) { viewModel.pendingOverwrite = nil }
        } message: { pending in
            Text("An MCP server named “\(pending.name)” is already in your config. Replacing it overwrites that entry's command, URL, auth and tool filters. Its OAuth token file and any saved API key in ~/.hermes/.env are kept.")
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Servers")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Model Context Protocol endpoints — \(viewModel.servers.count) configured.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            HStack(spacing: ScarfSpace.s2) {
                // The button becomes Stop while a sweep runs: each probe
                // launches a real MCP server and waits on its handshake, so
                // a wedged one used to hold the whole sweep hostage with no
                // way out.
                if viewModel.isTestingAll {
                    Button {
                        viewModel.cancelTestAll()
                    } label: {
                        Label("Stop testing", systemImage: "stop.circle")
                    }
                    .buttonStyle(ScarfGhostButton())
                } else {
                    Button {
                        viewModel.testAll()
                    } label: {
                        Label("Test all", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(ScarfGhostButton())
                    .disabled(viewModel.servers.isEmpty)
                }

                if capabilitiesStore?.capabilities.hasMCPCatalog == true {
                    Button {
                        viewModel.browseCatalog()
                    } label: {
                        Label("Browse catalog", systemImage: "books.vertical")
                    }
                    .buttonStyle(ScarfGhostButton())
                }

                Button {
                    viewModel.showPresetPicker = true
                } label: {
                    Label("From preset", systemImage: "square.grid.2x2")
                }
                .buttonStyle(ScarfSecondaryButton())

                Button {
                    viewModel.showAddCustom = true
                } label: {
                    Label("Add server", systemImage: "plus")
                }
                .buttonStyle(ScarfPrimaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var serversList: some View {
        List(selection: Binding(
            get: { viewModel.selectedServerName },
            set: { viewModel.selectServer(name: $0) }
        )) {
            if !viewModel.stdioServers.isEmpty {
                Section("Local (stdio)") {
                    ForEach(viewModel.stdioServers) { server in
                        serverRow(server)
                            .tag(server.name as String?)
                    }
                }
            }
            if !viewModel.httpServers.isEmpty {
                Section("Remote (HTTP)") {
                    ForEach(viewModel.httpServers) { server in
                        serverRow(server)
                            .tag(server.name as String?)
                    }
                }
            }
            if !viewModel.sseServers.isEmpty {
                Section("Remote (SSE)") {
                    ForEach(viewModel.sseServers) { server in
                        serverRow(server)
                            .tag(server.name as String?)
                    }
                }
            }
            if viewModel.servers.isEmpty && !viewModel.isLoading {
                Section {
                    Text("No servers configured yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func serverRow(_ server: HermesMCPServer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: server.transport == .http ? "network" : "terminal")
                .foregroundStyle(server.enabled ? ScarfColor.accent : ScarfColor.foregroundMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                if !server.enabled {
                    Text("Disabled")
                        .font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
            Spacer()
            if viewModel.testingNames.contains(server.name) {
                ProgressView().controlSize(.small)
            } else if let result = viewModel.testResults[server.name] {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.succeeded ? ScarfColor.success : ScarfColor.danger)
                    .help(result.succeeded ? Text("\(result.tools.count) tools") : Text("Test failed"))
            }
        }
    }

    @ViewBuilder
    private var serverDetail: some View {
        VStack(spacing: 0) {
            if viewModel.showRestartBanner {
                RestartGatewayBanner(
                    onRestart: { viewModel.restartGateway() },
                    onDismiss: { viewModel.showRestartBanner = false }
                )
            }
            if let status = viewModel.statusMessage {
                Text(status)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.accentActive)
                    .padding(.horizontal, ScarfSpace.s3)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScarfColor.accentTint)
            }
            if let server = viewModel.selectedServer {
                MCPServerDetailView(
                    server: server,
                    testResult: viewModel.testResults[server.name],
                    isTesting: viewModel.testingNames.contains(server.name),
                    onTest: { viewModel.testServer(name: server.name) },
                    onToggleEnabled: { viewModel.toggleEnabled(name: server.name) },
                    onEdit: { viewModel.beginEdit() },
                    onDelete: { viewModel.deleteServer(name: server.name) }
                )
            } else {
                ContentUnavailableView(
                    "Select an MCP Server",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Pick one from the list, or add a new server from the toolbar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// v0.15 — read-only sheet that renders the raw `hermes mcp catalog` text
/// output (the CLI has no `--json`). Discovery only: no parsing into rows,
/// no install action.
private struct MCPCatalogSheet: View {
    let text: String
    let isLoading: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Catalog")
                        .scarfStyle(.headline)
                    Text("Nous-approved MCP servers — `hermes mcp catalog`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading catalog…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, ScarfSpace.s2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(ScarfColor.backgroundPrimary)
    }
}
