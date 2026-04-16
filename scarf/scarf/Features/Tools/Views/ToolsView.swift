import SwiftUI

struct ToolsView: View {
    @State private var viewModel = ToolsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            platformPicker
            Divider()
            toolsList
            if !viewModel.mcpStatus.isEmpty {
                Divider()
                mcpSection
            }
        }
        .navigationTitle("Tools")
        .task { await viewModel.load() }
    }

    private var platformPicker: some View {
        HStack(spacing: 12) {
            // macOS renders Menu items using NSMenu, which only honors text and
            // SF Symbol images — custom-drawn Circle() shapes don't appear in the
            // dropdown. We use a filled SF Symbol "circlebadge.fill" and the status
            // text suffix so users can tell offline from connected inside the menu.
            Menu {
                ForEach(viewModel.availablePlatforms) { platform in
                    Button {
                        Task { await viewModel.switchPlatform(platform) }
                    } label: {
                        let status = viewModel.connectivity[platform.name] ?? .notConfigured
                        Label(
                            menuLabel(platform: platform, status: status),
                            systemImage: statusSymbol(status)
                        )
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: KnownPlatforms.icon(for: viewModel.selectedPlatform.name))
                    Text(viewModel.selectedPlatform.displayName)
                        .fontWeight(.medium)
                    statusDot(for: viewModel.connectivity[viewModel.selectedPlatform.name] ?? .notConfigured)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let tooltip = statusDescription(viewModel.connectivity[viewModel.selectedPlatform.name] ?? .notConfigured) {
                Text(tooltip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Text("\(viewModel.toolsets.filter(\.enabled).count) of \(viewModel.toolsets.count) enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusDot(for status: PlatformConnectivity) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    /// SF Symbol name used inside NSMenu (where Circle shapes don't render).
    private func statusSymbol(_ status: PlatformConnectivity) -> String {
        switch status {
        case .connected: return "circle.fill"
        case .configured: return "circle.dotted"
        case .notConfigured: return "circle"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    /// Menu-item label with an offline/connected suffix so status is readable even
    /// if the color of the SF Symbol doesn't come through NSMenu tinting.
    private func menuLabel(platform: HermesToolPlatform, status: PlatformConnectivity) -> String {
        switch status {
        case .connected: return platform.displayName
        case .configured: return "\(platform.displayName) (offline)"
        case .notConfigured: return "\(platform.displayName) (not configured)"
        case .error: return "\(platform.displayName) (error)"
        }
    }

    private func statusColor(_ status: PlatformConnectivity) -> Color {
        switch status {
        case .connected: return .green
        case .configured: return .orange
        case .notConfigured: return .secondary.opacity(0.4)
        case .error: return .red
        }
    }

    private func statusDescription(_ status: PlatformConnectivity) -> String? {
        switch status {
        case .connected: return "Connected"
        case .configured: return "Configured · not running"
        case .notConfigured: return "Not configured"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var toolsList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.toolsets) { tool in
                    ToolRow(tool: tool) {
                        await viewModel.toggleTool(tool)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .id(viewModel.selectedPlatform.name)
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP Servers")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if viewModel.mcpStatus.contains("No MCP servers") {
                Label("No MCP servers configured", systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.mcpStatus)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRow: View {
    let tool: HermesToolset
    let onToggle: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(tool.icon)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { _ in Task { await onToggle() } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
