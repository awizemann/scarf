import SwiftUI
import ScarfCore
import ScarfDesign

/// The Project Doctor: one reconciliation pass over the projects registry,
/// each project's own record, and the folders on disk — with a repair button
/// beside anything Scarf can safely fix itself.
///
/// Registry-wide on purpose. The interesting defects are relationships
/// BETWEEN projects (two entries at one folder, a folder no entry names), so
/// a per-project view could never see them; the sheet is reachable from the
/// cockpit's health row and from the registry-damage banner.
struct ProjectDoctorSheet: View {
    @Environment(\.serverContext) private var serverContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ProjectDoctorViewModel?
    /// The destructive repair awaiting confirmation. Removing a row is the
    /// only thing here that throws something away, so it asks first.
    @State private var pendingDestructive: ProjectDoctorFinding?
    /// Last repair summary we already announced — Repair All re-scans (which
    /// republishes the same `repairSummary`), so this guards against a
    /// double announcement rather than keying off `didSet`-style diffing.
    @State private var announcedRepairSummary: String?
    /// Focus lands here after Repair All finishes. Without it, focus stayed
    /// on the (now possibly gone) "Repair All" button after the list
    /// reshuffled — stranded with nothing under it.
    @AccessibilityFocusState private var focusedOnStatus: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
            Divider()
            footerBar
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .task {
            let vm = viewModel ?? ProjectDoctorViewModel(context: serverContext)
            viewModel = vm
            await vm.scan()
        }
        .onChange(of: viewModel?.repairSummary) { _, summary in
            // Doctor repair completion never announced anything — a
            // VoiceOver user watching "Repairing…" had no signal it was
            // done short of polling the button label. Announce once per
            // summary, then move focus back to the status line so it isn't
            // stranded on a button that may have disappeared.
            guard let summary, summary != announcedRepairSummary else { return }
            announcedRepairSummary = summary
            AccessibilityNotification.Announcement(AttributedString(summary)).post()
            focusedOnStatus = true
        }
        .alert(
            "Couldn't finish the repair",
            isPresented: Binding(
                get: { viewModel?.repairError != nil },
                set: { if !$0 { viewModel?.dismissRepairError() } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel?.dismissRepairError() }
        } message: {
            Text(viewModel?.repairError ?? "")
        }
        .confirmationDialog(
            // The finding says what its own repair will do — one row or
            // several — rather than the sheet assuming one.
            pendingDestructive?.confirmTitle ?? "",
            isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Entry", role: .destructive) {
                guard let finding = pendingDestructive else { return }
                pendingDestructive = nil
                Task { await viewModel?.repair(finding) }
            }
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
        } message: {
            Text(pendingDestructive?.confirmMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Doctor")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityFocused($focusedOnStatus)
            }
            Spacer()
            if viewModel?.isScanning == true {
                ProgressView().controlSize(.small)
            }
            Button("Check Again") {
                Task { await viewModel?.scan() }
            }
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        guard let report = viewModel?.report else {
            return viewModel?.isScanning == true ? "Checking your projects…" : "Not checked yet."
        }
        return report.summary
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = viewModel?.report {
            if let block = report.repairBlock {
                blockNotice(block)
            }
            if report.findings.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(report.findings) { finding in
                        findingRow(finding, blocked: report.repairBlock != nil)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            VStack {
                Spacer()
                ProgressView("Checking your projects…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(ScarfColor.success)
            Text("Everything checks out")
                .font(.callout.weight(.medium))
            Text("Your projects list, each project's own record, and the folders on disk all agree.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blockNotice(_ block: ProjectDoctorRepairBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(ScarfColor.danger)
                .accessibilityHidden(true)
            Text(block.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.danger.opacity(0.12))
    }

    private func findingRow(_ finding: ProjectDoctorFinding, blocked: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: finding.severity))
                .foregroundStyle(tint(for: finding.severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.callout.weight(.medium))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = finding.path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            // The icon carries severity visually but is `.accessibilityHidden`
            // — copy StatusGridCellView's pattern (severity as a spoken
            // value alongside the combined title/detail/path, not just a
            // hidden glyph) so VoiceOver isn't blind to it.
            .accessibilityValue(Text(severityLabel(finding.severity)))
            Spacer(minLength: 8)
            if let repair = finding.repair, !blocked {
                Button(repair.actionLabel) {
                    if repair.isDestructive {
                        pendingDestructive = finding
                    } else {
                        Task { await viewModel?.repair(finding) }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func severityLabel(_ severity: ProjectDoctorSeverity) -> String {
        switch severity {
        case .info: return String(localized: "Info")
        case .low: return String(localized: "Low severity")
        case .medium: return String(localized: "Medium severity")
        case .high: return String(localized: "High severity")
        }
    }

    private func symbol(for severity: ProjectDoctorSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .low: return "questionmark.circle"
        case .medium: return "exclamationmark.triangle"
        case .high: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for severity: ProjectDoctorSeverity) -> Color {
        switch severity {
        case .info: return ScarfColor.foregroundMuted
        case .low: return ScarfColor.foregroundMuted
        case .medium: return ScarfColor.warning
        case .high: return ScarfColor.danger
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if let summary = viewModel?.repairSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = viewModel?.report?.safelyRepairable.count, count > 0 {
                Button(isRepairingAll ? "Repairing…" : "Repair All (\(count))") {
                    Task { await viewModel?.repairAllSafe() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
                .help("Runs only the safe repairs. Removing entries and adding folders stay one-by-one.")
            }
            Button("Done") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isRepairingAll: Bool {
        viewModel?.repairingFindingID == ProjectDoctorViewModel.repairAllID
    }

    /// Any scan or repair in flight. One flag for every control: repairs
    /// share a registry read-modify-write, so overlapping them would lose an
    /// update, and a scan mid-repair would render a report that is already
    /// out of date.
    private var isBusy: Bool {
        (viewModel?.isScanning ?? false) || (viewModel?.repairingFindingID != nil)
    }
}
