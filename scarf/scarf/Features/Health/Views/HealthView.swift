import SwiftUI

struct HealthView: View {
    @State private var viewModel = HealthViewModel()
    @State private var expandedSection: UUID?
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            Picker("", selection: $selectedTab) {
                Text("Status").tag(0)
                Text("Diagnostics").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                sectionGrid(selectedTab == 0 ? viewModel.statusSections : viewModel.doctorSections)
                    .padding()
            }
        }
        .navigationTitle("Health")
        .onAppear { viewModel.load() }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if !viewModel.version.isEmpty {
                    Text(viewModel.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if viewModel.hasUpdate {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        Text(viewModel.updateInfo)
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                }

                Spacer()

                HStack(spacing: 12) {
                    MiniCount(count: viewModel.okCount, color: .green, icon: "checkmark.circle.fill")
                    MiniCount(count: viewModel.warningCount, color: .orange, icon: "exclamationmark.triangle.fill")
                    MiniCount(count: viewModel.issueCount, color: .red, icon: "xmark.circle.fill")
                }

                Button("Refresh") { viewModel.load() }
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.hermesRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.hermesRunning ? "Hermes Running" : "Hermes Stopped")
                        .font(.caption.bold())
                    if let pid = viewModel.hermesPID {
                        Text("PID \(pid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let msg = viewModel.actionMessage {
                    Label(msg, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Start") { viewModel.startHermes() }
                        .disabled(viewModel.hermesRunning)
                    Button("Stop") { viewModel.stopHermes() }
                        .disabled(!viewModel.hermesRunning)
                    Button("Restart") { viewModel.restartHermes() }
                        .disabled(!viewModel.hermesRunning)
                }
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
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
        if errorCount > 0 { return .red }
        if warnCount > 0 { return .orange }
        return .green
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
                                    Circle().fill(.green).frame(width: 5, height: 5)
                                    Text("\(okCount)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if warnCount > 0 {
                                HStack(spacing: 2) {
                                    Circle().fill(.orange).frame(width: 5, height: 5)
                                    Text("\(warnCount)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if errorCount > 0 {
                                HStack(spacing: 2) {
                                    Circle().fill(.red).frame(width: 5, height: 5)
                                    Text("\(errorCount)").font(.caption2).foregroundStyle(.secondary)
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
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
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
