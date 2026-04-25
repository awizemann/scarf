import SwiftUI
import ScarfCore
import ScarfDesign

struct ToolsView: View {
    @State private var viewModel: ToolsViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: ToolsViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            platformPicker
            toolsList
            if !viewModel.mcpStatus.isEmpty {
                Divider()
                mcpSection
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Tools")
        .task { await viewModel.load() }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tools")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Tool kits the agent can call. Toggle per platform; MCP servers extend this list.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
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
                    Text(verbatim: viewModel.selectedPlatform.displayName)
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
        case .connected: return ScarfColor.success
        case .configured: return ScarfColor.warning
        case .notConfigured: return ScarfColor.foregroundFaint
        case .error: return ScarfColor.danger
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
        HStack(spacing: ScarfSpace.s3) {
            Text(tool.icon)
                .font(.system(size: 18))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(ScarfFont.body.monospaced())
                    .fontWeight(.medium)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(tool.description)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { _ in Task { await onToggle() } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(ScarfColor.accent)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
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
