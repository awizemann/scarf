import SwiftUI

struct MCPServerDetailView: View {
    let server: HermesMCPServer
    let testResult: MCPTestResult?
    let isTesting: Bool
    let onTest: () -> Void
    let onToggleEnabled: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                overview
                if server.transport == .stdio {
                    envSection
                } else {
                    headersSection
                }
                toolsSection
                timeoutsSection
                if let result = testResult {
                    MCPServerTestResultView(result: result)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog(
            "Remove \(server.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the server from config.yaml and deletes any OAuth token.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: server.transport == .http ? "network" : "terminal")
                        .foregroundStyle(.secondary)
                    Text(server.name)
                        .font(.title2.bold())
                    if !server.enabled {
                        Text("Disabled")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    if server.hasOAuthToken {
                        Label("OAuth", systemImage: "key.fill")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(server.transport.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    onTest()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(isTesting)
                Button {
                    onToggleEnabled()
                } label: {
                    Label(server.enabled ? "Disable" : "Enable", systemImage: server.enabled ? "pause.circle" : "play.circle")
                }
                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            switch server.transport {
            case .stdio:
                summaryRow(label: "Command", value: server.command ?? "—")
                if !server.args.isEmpty {
                    summaryRow(label: "Args", value: server.args.joined(separator: " "))
                }
            case .http:
                summaryRow(label: "URL", value: server.url ?? "—")
                if let auth = server.auth, !auth.isEmpty {
                    summaryRow(label: "Auth", value: auth)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment Variables")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if server.env.isEmpty {
                Text("No env vars configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.env.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("••••••••••")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Headers")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if server.headers.isEmpty {
                Text("No headers configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.headers.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("••••••••••")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tool Filters")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            summaryRow(label: "Include", value: server.toolsInclude.isEmpty ? "(all)" : server.toolsInclude.joined(separator: ", "))
            summaryRow(label: "Exclude", value: server.toolsExclude.isEmpty ? "—" : server.toolsExclude.joined(separator: ", "))
            summaryRow(label: "Resources", value: server.resourcesEnabled ? "enabled" : "disabled")
            summaryRow(label: "Prompts", value: server.promptsEnabled ? "enabled" : "disabled")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var timeoutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeouts")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            summaryRow(label: "Connect", value: server.connectTimeout.map { "\($0)s" } ?? "default")
            summaryRow(label: "Call", value: server.timeout.map { "\($0)s" } ?? "default")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
