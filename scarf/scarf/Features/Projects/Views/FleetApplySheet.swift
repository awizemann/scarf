import SwiftUI
import ScarfCore
import ScarfDesign

/// "Apply to Fleet" — pick which of the current host's config fields to
/// push (model preset / board / cron) and which other hosts to push them
/// to, preview the per-host plan, then apply. Config-as-policy, Phase-1
/// item #4.
///
/// Additive + reversible + non-fatal: the plan shows exactly what will
/// change and what's kept (a board that already exists is preserved to
/// protect its tasks); cron jobs are recreated paused with prompts
/// rewritten to each host's project root.
struct FleetApplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: FleetApplyViewModel
    /// Called after a successful apply so the Fleet panel can reload its
    /// gather and reflect the new config.
    private let onApplied: () -> Void

    init(
        source: FleetMaterialization,
        candidates: [FleetMaterialization],
        contexts: [ServerContext],
        onApplied: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: FleetApplyViewModel(
            source: source, candidates: candidates, contexts: contexts
        ))
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 560)
        .task { await viewModel.prepare() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apply to Fleet")
                .font(.title3.bold())
            Text("Push **\(viewModel.source.project.name)**'s config from \(hostName(viewModel.source)) to other hosts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .configuring, .applying:
            configuring
        case .done(let results):
            if results.isEmpty {
                CockpitEmptyState(icon: "checkmark.circle", text: "Nothing to apply.")
            } else {
                resultsView(results)
            }
        }
    }

    private var configuring: some View {
        VStack(alignment: .leading, spacing: 18) {
            fieldsSection
            hostsSection
            // What this apply will NOT do (per-host presets, script-only
            // cron, unrecreatable schedules) — stated before the user
            // commits, never dropped silently.
            if !viewModel.caveats.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.caveats, id: \.self) { caveat in
                        Label(caveat, systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(ScarfColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if viewModel.selectedFields.contains(.cron) {
                Label(
                    "Cron jobs are recreated **paused** on each host, with their prompts rewritten to that host's project path. Enable them per host afterward.",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply which config")
                .font(.subheadline.weight(.semibold))
            if viewModel.offeredFields.isEmpty {
                Text("This host has no model preset, board, or cron config to push.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(FleetApplyField.allCases.filter { viewModel.offeredFields.contains($0) }, id: \.self) { field in
                    Toggle(isOn: Binding(
                        get: { viewModel.isFieldSelected(field) },
                        set: { viewModel.toggleField(field, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label).font(.callout)
                            Text(fieldDetail(field))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(viewModel.isApplying)
                }
            }
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To which hosts")
                .font(.subheadline.weight(.semibold))
            ForEach(viewModel.candidates) { host in
                hostRow(host)
            }
        }
    }

    private func hostRow(_ host: FleetMaterialization) -> some View {
        let selected = viewModel.isTargetSelected(host.serverId)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { viewModel.isTargetSelected(host.serverId) },
                set: { viewModel.toggleTarget(host.serverId, $0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hostName(host)).font(.callout)
                    Text(host.project.rootPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(viewModel.isApplying)

            // Per-host plan preview for the current field selection.
            if selected, let target = viewModel.plan.targets.first(where: { $0.serverId == host.serverId }) {
                dispositionChips(target)
                    .padding(.leading, 22)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    private func dispositionChips(_ target: FleetApplyPlan.Target) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if target.actions.isEmpty {
                Text("No fields selected.").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(target.actions, id: \.field) { action in
                HStack(spacing: 6) {
                    Image(systemName: action.disposition.isApply ? "arrow.right.circle.fill" : "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(action.disposition.isApply ? ScarfColor.accentActive : ScarfColor.foregroundMuted)
                    Text("\(action.field.label): \(action.disposition.detail)")
                        .font(.caption2)
                        .foregroundStyle(action.disposition.isApply ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: - Results

    private func resultsView(_ results: [FleetApplyExecutor.TargetResult]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            outcomeBanner(results)
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: result.hadFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(result.hadFailure ? ScarfColor.warning : ScarfColor.success)
                        Text(result.displayName).font(.callout.weight(.medium))
                    }
                    ForEach(result.fields) { field in
                        HStack(spacing: 6) {
                            Image(systemName: statusIcon(field.status))
                                .font(.caption2)
                                .foregroundStyle(statusColor(field.status))
                                .frame(width: 14)
                            Text("\(field.field.label): \(field.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 20)
                        // The actual reason, straight from hermes's stderr /
                        // the thrown error — "1 failed" is not actionable.
                        if let detail = field.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(ScarfColor.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 40)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScarfColor.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
            }
        }
    }

    /// Fleet-level outcome line. A push that failed on any host must NOT
    /// read as success — this replaces the old unconditional "Applied to N
    /// hosts" heading, which stayed neutral-to-green through a half-failed
    /// fleet apply.
    @ViewBuilder
    private func outcomeBanner(_ results: [FleetApplyExecutor.TargetResult]) -> some View {
        let outcome = FleetApplyViewModel.outcome(for: results)
        let (icon, color, text): (String, Color, String) = {
            switch outcome {
            case .allApplied:
                return ("checkmark.circle.fill", ScarfColor.success,
                        "Applied to \(results.count) host\(results.count == 1 ? "" : "s")")
            case .partialFailure(let failed, let total):
                return ("exclamationmark.triangle.fill", ScarfColor.danger,
                        "Partly failed — \(failed) of \(total) hosts had errors")
            case .allFailed(let total):
                return ("xmark.octagon.fill", ScarfColor.danger,
                        "Failed on all \(total) host\(total == 1 ? "" : "s")")
            case .nothingApplied:
                return ("minus.circle", ScarfColor.foregroundMuted,
                        "Nothing was applied")
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            if viewModel.didCancel {
                Text("Cancelled — hosts below that show \"cancelled\" were never touched.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch viewModel.phase {
            case .configuring:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    Task { await viewModel.apply() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canApply)
            case .applying:
                Button("Stop") { viewModel.cancel() }
                    .disabled(viewModel.didCancel)
                Spacer()
                ProgressView().controlSize(.small)
                Text(viewModel.didCancel ? "Stopping…" : "Applying…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .done:
                Spacer()
                Button("Done") {
                    onApplied()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func hostName(_ m: FleetMaterialization) -> String {
        if let n = m.serverDisplayName, !n.isEmpty { return n }
        if m.serverId == ServerContext.local.id.uuidString { return "Local" }
        return String(m.serverId.prefix(8))
    }

    private func fieldDetail(_ field: FleetApplyField) -> String {
        switch field {
        case .modelPreset:
            return "Bind the same model preset (overwrites the target's binding)."
        case .board:
            return "Set the board on hosts that don't have one yet (existing boards are kept)."
        case .cron:
            return "Recreate this project's cron jobs on each host (paused, paths rewritten)."
        }
    }

    private func statusIcon(_ status: FleetApplyExecutor.FieldResult.Status) -> String {
        switch status {
        case .applied: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed:  return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: FleetApplyExecutor.FieldResult.Status) -> Color {
        switch status {
        case .applied: return ScarfColor.success
        case .skipped: return ScarfColor.foregroundMuted
        case .failed:  return ScarfColor.danger
        }
    }
}

