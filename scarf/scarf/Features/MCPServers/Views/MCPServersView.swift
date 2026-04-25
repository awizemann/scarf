import SwiftUI
import ScarfCore
import ScarfDesign

struct MCPServersView: View {
    @State private var viewModel: MCPServersViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: MCPServersViewModel(context: context))
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
                    viewModel.load()
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
        .sheet(isPresented: Binding(
            get: { viewModel.editingServer != nil },
            set: { if !$0 { viewModel.editingServer = nil } }
        )) {
            if let server = viewModel.editingServer {
                MCPServerEditorView(
                    viewModel: MCPServerEditorViewModel(server: server),
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
                Button {
                    viewModel.testAll()
                } label: {
                    Label("Test all", systemImage: "bolt.horizontal")
                }
                .buttonStyle(ScarfGhostButton())
                .disabled(viewModel.servers.isEmpty)

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
