import SwiftUI
import ScarfCore
import ScarfDesign

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
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ScarfColor.accentTint)
                Image(systemName: server.transport == .http ? "network" : "terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(ScarfColor.accent)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .scarfStyle(.title2)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    ScarfBadge(server.enabled ? "active" : "disabled",
                               kind: server.enabled ? .success : .neutral)
                    if server.hasOAuthToken {
                        ScarfBadge("oauth", kind: .info)
                    }
                }
                Text(server.transport.displayName)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            HStack(spacing: ScarfSpace.s2) {
                Button {
                    onTest()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal")
                    }
                }
                .buttonStyle(ScarfGhostButton())
                .disabled(isTesting)
                .help("Test")

                Button {
                    onToggleEnabled()
                } label: {
                    Image(systemName: server.enabled ? "pause.circle" : "play.circle")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help(server.enabled ? "Disable" : "Enable")

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(ScarfPrimaryButton())

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ScarfDestructiveButton())
                .help("Remove")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
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
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
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
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
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
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Headers")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
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
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tool Filters")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            summaryRow(label: "Include", value: server.toolsInclude.isEmpty ? "(all)" : server.toolsInclude.joined(separator: ", "))
            summaryRow(label: "Exclude", value: server.toolsExclude.isEmpty ? "—" : server.toolsExclude.joined(separator: ", "))
            summaryRow(label: "Resources", value: server.resourcesEnabled ? "enabled" : "disabled")
            summaryRow(label: "Prompts", value: server.promptsEnabled ? "enabled" : "disabled")
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    private var timeoutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeouts")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            summaryRow(label: "Connect", value: server.connectTimeout.map { "\($0)s" } ?? "default")
            summaryRow(label: "Call", value: server.timeout.map { "\($0)s" } ?? "default")
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }
}
