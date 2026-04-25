import SwiftUI
import ScarfCore
import ScarfDesign

struct HealthView: View {
    @State private var viewModel: HealthViewModel
    @State private var expandedSection: UUID?
    @State private var selectedTab = 0
    @State private var showShareConfirm = false
    @State private var showDiagnostics = false

    init(context: ServerContext) {
        _viewModel = State(initialValue: HealthViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            headerBar
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("Status").tag(0)
                    Text("Diagnostics").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
                Button("Run Dump") {
                    viewModel.runDump()
                    showDiagnostics = true
                }
                .buttonStyle(ScarfGhostButton())
                Button("Share Debug Report…") {
                    showShareConfirm = true
                }
                .buttonStyle(ScarfSecondaryButton())
                .disabled(viewModel.isSharingDebug)
            }
            .padding(.horizontal, ScarfSpace.s6)
            .padding(.vertical, ScarfSpace.s2)
            if showDiagnostics && !viewModel.diagnosticsOutput.isEmpty {
                Divider()
                diagnosticsPanel
            }
            Divider()
            ScrollView {
                sectionGrid(selectedTab == 0 ? viewModel.statusSections : viewModel.doctorSections)
                    .padding(.horizontal, ScarfSpace.s6)
                    .padding(.vertical, ScarfSpace.s5)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Health")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Running health checks…",
            isEmpty: viewModel.statusSections.isEmpty && viewModel.doctorSections.isEmpty
        )
        .onAppear {
            viewModel.load()
            viewModel.startDashboardMonitoring()
        }
        .onDisappear { viewModel.stopDashboardMonitoring() }
        .confirmationDialog("Upload debug report?", isPresented: $showShareConfirm) {
            Button("Upload", role: .destructive) {
                viewModel.runDebugShare()
                showDiagnostics = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This uploads logs, config (with secrets redacted), and system info to Nous Research support infrastructure. Review the output below before sharing the returned URL.")
        }
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostic Output")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Hide") { showDiagnostics = false }
                    .controlSize(.mini)
            }
            ScrollView {
                Text(viewModel.diagnosticsOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Hermes process status, diagnostics, and the local web dashboard.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            HStack(spacing: 12) {
                MiniCount(count: viewModel.okCount, color: ScarfColor.success, icon: "checkmark.circle.fill")
                MiniCount(count: viewModel.warningCount, color: ScarfColor.warning, icon: "exclamationmark.triangle.fill")
                MiniCount(count: viewModel.issueCount, color: ScarfColor.danger, icon: "xmark.circle.fill")
            }
            Button("Refresh") { viewModel.load() }
                .buttonStyle(ScarfSecondaryButton())
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: ScarfSpace.s4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.hermesRunning ? ScarfColor.success : ScarfColor.danger)
                        .frame(width: 8, height: 8)
                    (viewModel.hermesRunning ? Text("Hermes Running") : Text("Hermes Stopped"))
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    if let pid = viewModel.hermesPID {
                        Text("PID \(pid)")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                if !viewModel.version.isEmpty {
                    Text(viewModel.version)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                if viewModel.hasUpdate {
                    Label(viewModel.updateInfo, systemImage: "arrow.triangle.2.circlepath")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
                if let msg = viewModel.actionMessage {
                    Label(msg, systemImage: "arrow.triangle.2.circlepath")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
                Spacer()
                HStack(spacing: ScarfSpace.s2) {
                    Button("Start") { viewModel.startHermes() }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(viewModel.hermesRunning)
                    Button("Stop") { viewModel.stopHermes() }
                        .buttonStyle(ScarfSecondaryButton())
                        .disabled(!viewModel.hermesRunning)
                    Button("Restart") { viewModel.restartHermes() }
                        .buttonStyle(ScarfGhostButton())
                        .disabled(!viewModel.hermesRunning)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, ScarfSpace.s6)
            .padding(.vertical, ScarfSpace.s3)
            if !viewModel.context.isRemote {
                Divider()
                webDashboardRow
            }
        }
    }

    /// Status + controls for `hermes dashboard` (the web UI introduced in
    /// v0.10.x). Hidden for remote contexts — the dashboard binds 127.0.0.1
    /// and remote tunneling is deferred.
    private var webDashboardRow: some View {
        HStack(spacing: ScarfSpace.s4) {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .foregroundStyle(viewModel.dashboardStatus.running ? ScarfColor.success : ScarfColor.foregroundMuted)
                    .font(.system(size: 12))
                if viewModel.dashboardStatus.running {
                    Text("Web Dashboard on :\(viewModel.dashboardStatus.port)")
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                } else {
                    Text("Web Dashboard")
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text("not running")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
            HStack(spacing: ScarfSpace.s2) {
                if viewModel.dashboardStatus.running {
                    Button("Open in Browser") { viewModel.openDashboardInBrowser() }
                        .buttonStyle(ScarfPrimaryButton())
                    Button("Stop") { viewModel.stopDashboard() }
                        .buttonStyle(ScarfGhostButton())
                        .disabled(viewModel.dashboardStatus.busy)
                } else {
                    Button("Launch Dashboard") { viewModel.launchDashboard() }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(viewModel.dashboardStatus.busy)
                }
                if viewModel.dashboardStatus.busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.vertical, ScarfSpace.s3)
    }

    // MARK: - Grid

    private func sectionGrid(_ sections: [HealthSection]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(sections) { section in
                SectionCard(
                    section: section,
                    isExpanded: expandedSection == section.id,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedSection = expandedSection == section.id ? nil : section.id
                        }
                    }
                )
            }
        }
    }
}

// MARK: - Section Card

struct SectionCard: View {
    let section: HealthSection
    let isExpanded: Bool
    let onTap: () -> Void

    private var okCount: Int { section.checks.filter { $0.status == .ok }.count }
    private var warnCount: Int { section.checks.filter { $0.status == .warning }.count }
    private var errorCount: Int { section.checks.filter { $0.status == .error }.count }

    private var accentColor: Color {
        if errorCount > 0 { return ScarfColor.danger }
        if warnCount > 0 { return ScarfColor.warning }
        return ScarfColor.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: section.icon)
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            if okCount > 0 {
                                HStack(spacing: 2) {
                                    Circle().fill(ScarfColor.success).frame(width: 5, height: 5)
                                    Text("\(okCount)").font(ScarfFont.caption2).foregroundStyle(ScarfColor.foregroundMuted)
                                }
                            }
                            if warnCount > 0 {
                                HStack(spacing: 2) {
                                    Circle().fill(ScarfColor.warning).frame(width: 5, height: 5)
                                    Text("\(warnCount)").font(ScarfFont.caption2).foregroundStyle(ScarfColor.foregroundMuted)
                                }
                            }
                            if errorCount > 0 {
                                HStack(spacing: 2) {
                                    Circle().fill(ScarfColor.danger).frame(width: 5, height: 5)
                                    Text("\(errorCount)").font(ScarfFont.caption2).foregroundStyle(ScarfColor.foregroundMuted)
                                }
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(section.checks) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Check Row

struct CheckRow: View {
    let check: HealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.system(size: 9))
                .frame(width: 12, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(check.label)
                    .font(.caption)
                if let detail = check.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusIcon: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch check.status {
        case .ok: return ScarfColor.success
        case .warning: return ScarfColor.warning
        case .error: return ScarfColor.danger
        }
    }
}

// MARK: - Mini Count

struct MiniCount: View {
    let count: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption2)
            Text("\(count)")
                .font(.caption.monospaced().bold())
        }
    }
}
