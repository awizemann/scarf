import SwiftUI
import ScarfCore
import ScarfDesign

/// Dashboard — first screen the user sees on launch. Visual layer follows
/// `design/static-site/ui-kit/Dashboard.jsx`: page header with subtitle and
/// trailing actions, a 4-card status row, a "Last 7 days" stats section
/// with 5 metric cards and a `View Insights` link, and a "Recent sessions"
/// card list. The mockup also shows a "Recent activity" column; we don't
/// have an activity feed wired into `DashboardViewModel` so that pane is
/// elided for now (TODO when we surface activity items via the data layer).
struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var showDiagnostics = false
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: DashboardViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    if let err = viewModel.lastReadError {
                        readErrorBanner(err)
                    }
                    statusRow
                    statsSection
                    recentTwoColumn
                }
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Dashboard")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading dashboard…",
            isEmpty: viewModel.recentSessions.isEmpty
        )
        .task { await viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
        .sheet(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(context: viewModel.context)
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("At-a-glance status of your Hermes agent.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            HStack(spacing: ScarfSpace.s2) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ScarfSecondaryButton())

                Button {
                    coordinator.selectedSection = .chat
                } label: {
                    Label("New Session", systemImage: "plus")
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

    // MARK: - Read-error banner

    private func readErrorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't read Hermes state on \(viewModel.context.displayName)")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(err)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showDiagnostics = true
            } label: {
                Label("Run Diagnostics…", systemImage: "stethoscope")
            }
            .buttonStyle(ScarfSecondaryButton())
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1)
                )
        )
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: ScarfSpace.s3) {
            StatusCard(
                label: "Hermes",
                value: viewModel.hermesRunning ? "Running" : "Stopped",
                icon: "circle.fill",
                tone: viewModel.hermesRunning ? .running : .neutral,
                sub: nil
            )
            StatusCard(
                label: "Model",
                value: viewModel.config.model,
                icon: "cpu",
                tone: .neutral,
                sub: viewModel.config.provider.isEmpty ? nil : viewModel.config.provider
            )
            StatusCard(
                label: "Provider",
                value: viewModel.config.provider,
                icon: "cloud",
                tone: .neutral,
                sub: nil
            )
            StatusCard(
                label: "Gateway",
                value: viewModel.gatewayState?.statusText ?? "unknown",
                icon: "network",
                tone: viewModel.gatewayState?.isRunning == true ? .running : .neutral,
                sub: nil
            )
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Last 7 days")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                Button {
                    coordinator.selectedSection = .insights
                } label: {
                    Label("View Insights", systemImage: "chart.bar")
                        .scarfStyle(.caption)
                }
                .buttonStyle(ScarfGhostButton())
            }
            HStack(spacing: ScarfSpace.s3) {
                StatCard(label: "Sessions", value: "\(viewModel.stats.totalSessions)", sub: nil, accent: false)
                StatCard(label: "Messages", value: "\(viewModel.stats.totalMessages)", sub: nil, accent: false)
                StatCard(label: "Tool Calls", value: "\(viewModel.stats.totalToolCalls)", sub: nil, accent: false)
                StatCard(
                    label: "Tokens",
                    value: formatTokens(viewModel.stats.totalInputTokens + viewModel.stats.totalOutputTokens),
                    sub: tokenSubLabel,
                    accent: false
                )
                let cost = viewModel.stats.totalActualCostUSD > 0 ? viewModel.stats.totalActualCostUSD : viewModel.stats.totalCostUSD
                if cost > 0 {
                    StatCard(
                        label: "Cost",
                        value: cost.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                        sub: nil,
                        accent: true
                    )
                }
            }
        }
    }

    private var tokenSubLabel: String? {
        let inT = viewModel.stats.totalInputTokens
        let outT = viewModel.stats.totalOutputTokens
        guard inT + outT > 0 else { return nil }
        return "\(formatTokens(inT)) in · \(formatTokens(outT)) out"
    }

    // MARK: - Recent sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Recent sessions")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                Button {
                    coordinator.selectedSection = .sessions
                } label: {
                    Text("View all →")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                if viewModel.recentSessions.isEmpty && !viewModel.isLoading {
                    Text("No sessions yet")
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(ScarfSpace.s5)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(viewModel.recentSessions.enumerated()), id: \.element.id) { idx, session in
                        SessionRow(session: session, preview: viewModel.sessionPreviews[session.id])
                            .padding(.horizontal, ScarfSpace.s4)
                            .padding(.vertical, ScarfSpace.s3 - 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                coordinator.selectedSessionId = session.id
                                coordinator.selectedSection = .sessions
                            }
                        if idx < viewModel.recentSessions.count - 1 {
                            Rectangle()
                                .fill(ScarfColor.border)
                                .frame(height: 1)
                        }
                    }
                }
            }
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

    // MARK: - Recent two-column

    /// Recent sessions on the left, recent activity on the right —
    /// matches Dashboard.jsx's 1.3fr / 1fr grid. On narrow windows the
    /// activity column collapses below the sessions column via a
    /// ViewThatFits-style fallback.
    private var recentTwoColumn: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: ScarfSpace.s4) {
                recentSessionsSection
                    .frame(maxWidth: .infinity)
                recentActivitySection
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                recentSessionsSection
                recentActivitySection
            }
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Recent activity")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                Button {
                    coordinator.selectedSection = .activity
                } label: {
                    Text("View all →")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                if viewModel.recentActivity.isEmpty && !viewModel.isLoading {
                    Text("No activity yet")
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(ScarfSpace.s5)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(viewModel.recentActivity.enumerated()), id: \.element.id) { idx, entry in
                        DashActivityRow(entry: entry) {
                            coordinator.selectedSessionId = entry.sessionId
                            coordinator.selectedSection = .activity
                        }
                        if idx < viewModel.recentActivity.count - 1 {
                            Rectangle()
                                .fill(ScarfColor.border)
                                .frame(height: 1)
                        }
                    }
                }
            }
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
}

private struct DashActivityRow: View {
    let entry: ActivityEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: ScarfSpace.s2 + 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(toneBackground)
                    Image(systemName: entry.kind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(toneForeground)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.toolName)
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                    Text(entry.summary.isEmpty ? "—" : entry.summary)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let ts = entry.timestamp {
                    Text(ts, style: .relative)
                        .font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toneBackground: Color {
        switch entry.kind {
        case .read:    return ScarfColor.success.opacity(0.16)
        case .edit:    return ScarfColor.info.opacity(0.16)
        case .execute: return ScarfColor.warning.opacity(0.18)
        case .fetch:   return ScarfColor.Tool.web.opacity(0.16)
        case .browser: return ScarfColor.Tool.search.opacity(0.16)
        case .other:   return ScarfColor.backgroundTertiary
        }
    }

    private var toneForeground: Color {
        switch entry.kind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }
}

// MARK: - StatusCard

struct StatusCard: View {
    enum Tone { case running, neutral }

    let label: String
    let value: String
    let icon: String
    let tone: Tone
    let sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if tone == .running {
                    Circle()
                        .fill(ScarfColor.success)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Text(label)
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Text(value)
                .font(ScarfFont.body.monospaced())
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let sub {
                Text(sub)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s3 + 2)
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

// MARK: - StatCard

struct StatCard: View {
    let label: String
    let value: String
    let sub: String?
    let accent: Bool

    init(label: String, value: String, sub: String? = nil, accent: Bool = false) {
        self.label = label
        self.value = value
        self.sub = sub
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent ? ScarfColor.accent : ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s3 + 2)
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

// MARK: - SessionRow (shared with Sessions feature)

struct SessionRow: View {
    let session: HermesSession
    var preview: String?
    /// Optional project display name to render as a chip below the title.
    var projectName: String? = nil

    var body: some View {
        HStack(spacing: ScarfSpace.s3) {
            Image(systemName: session.sourceIcon)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview ?? session.displayTitle)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = session.startedAt {
                        Text(date, style: .relative)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                    if let projectName, !projectName.isEmpty {
                        Label(projectName, systemImage: "folder.fill")
                            .font(ScarfFont.caption2)
                            .foregroundStyle(ScarfColor.accent)
                            .labelStyle(.titleAndIcon)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 5)
                            .background(ScarfColor.accentTint, in: Capsule())
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Label("\(session.messageCount)", systemImage: "bubble.left")
                Label("\(session.toolCallCount)", systemImage: "wrench")
                if session.apiCallCount > 0 {
                    Label("\(session.apiCallCount)", systemImage: "network")
                        .help("API calls (Hermes v2026.4.23+)")
                }
                if let cost = session.displayCostUSD, cost > 0 {
                    Label(cost.formatted(.currency(code: "USD").precision(.fractionLength(4))), systemImage: "dollarsign.circle")
                }
            }
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }
}
