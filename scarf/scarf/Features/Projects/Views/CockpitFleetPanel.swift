import SwiftUI
import ScarfCore
import ScarfDesign

/// Cockpit **Fleet** panel — the per-project view of the fleet/portfolio
/// dimension (Phase-1 item #4). Shows where the project is materialized
/// across the user's registered servers (grouped by stable
/// `ScarfProject.id`) and the per-host config drift between those hosts.
///
/// Read surface. The "Apply to Fleet…" action (config-as-policy) hangs
/// off the same loaded `FleetProject`.
struct CockpitFleetPanel: View {
    /// The cockpit's loaded record — the source config for apply-to-fleet
    /// and the id we group on. `nil` while the cockpit VM is still loading.
    let sourceProject: ScarfProject?
    let currentContext: ServerContext
    let contexts: [ServerContext]

    @State private var viewModel: FleetPanelViewModel?
    @State private var showingApplySheet = false

    var body: some View {
        Group {
            if let sourceProject {
                content(sourceProject)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Presented on the panel ROOT, not inside `content`'s loaded branch:
        // that branch is torn down whenever the gather goes back to loading
        // (the `onApplied` reload does exactly that), which takes the sheet's
        // presenter out of the hierarchy and dismisses the results the user
        // is reading — or drops the sheet before it ever appears.
        .sheet(isPresented: $showingApplySheet) {
            if let vm = viewModel, let sourceMaterialization = vm.sourceMaterialization {
                FleetApplySheet(
                    source: sourceMaterialization,
                    candidates: vm.otherMaterializations,
                    contexts: contexts,
                    onApplied: { Task { await vm.load(force: true) } }
                )
            }
        }
        .task(id: sourceProject?.id) {
            // Drop the prior project's VM first so a project switch never
            // renders stale materializations under the new header during
            // the (async) rebuild — content falls back to the spinner via
            // `viewModel?.isLoading ?? true`.
            viewModel = nil
            guard let sourceProject else { return }
            let vm = FleetPanelViewModel(
                projectID: sourceProject.id,
                currentServerId: currentContext.id.uuidString,
                contexts: contexts
            )
            viewModel = vm
            await vm.load()
        }
    }

    @ViewBuilder
    private func content(_ source: ScarfProject) -> some View {
        if let fleet = viewModel?.fleetProject {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryRow(fleet, source: source)
                    if !fleet.drift.isEmpty {
                        driftCallout(fleet.drift)
                    }
                    ForEach(fleet.materializations) { m in
                        materializationCard(m, drift: fleet.drift)
                    }
                    if !fleet.isMultiHost {
                        singleHostHint
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else if viewModel?.isLoading ?? true {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CockpitEmptyState(
                icon: "square.stack.3d.up.slash",
                text: "This project isn't materialized on any registered server yet."
            )
        }
    }

    // MARK: - Summary

    private func summaryRow(_ fleet: FleetProject, source: ScarfProject) -> some View {
        HStack(spacing: 10) {
            Label(
                "Materialized on ^[\(fleet.materializations.count) host](inflect: true)",
                systemImage: "square.stack.3d.up"
            )
            .font(.subheadline.weight(.medium))
            Spacer()
            statusChip(fleet)
            if fleet.isMultiHost {
                applyButton(source)
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ fleet: FleetProject) -> some View {
        if fleet.drift.isEmpty {
            if fleet.isMultiHost {
                Label("In sync", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ScarfColor.success)
            }
        } else {
            Label(
                "\(fleet.drift.fields.count) field\(fleet.drift.fields.count == 1 ? "" : "s") drifted",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(ScarfColor.warning)
        }
    }

    @ViewBuilder
    private func applyButton(_ source: ScarfProject) -> some View {
        let pushable = !FleetApplyPlan.applicableFields(source: source).isEmpty
        let haveSource = viewModel?.sourceMaterialization != nil
        Button {
            showingApplySheet = true
        } label: {
            Label("Apply to Fleet…", systemImage: "arrow.up.forward.app")
        }
        .controlSize(.small)
        .disabled(!pushable || !haveSource)
        .help(pushable
            ? "Push this host's model preset, board, and cron jobs onto other hosts."
            : "This host has no model preset, board, or cron config to push.")
    }

    /// Which config fields disagree across hosts.
    private func driftCallout(_ drift: FleetDrift) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Config drift across hosts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScarfColor.warning)
            FlowChips(labels: drift.sortedFields.map(Self.driftLabel))
            Text("These fields hold different values on different hosts. Apply this host's config to bring them in line.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    // MARK: - Materialization card

    private func materializationCard(_ m: FleetMaterialization, drift: FleetDrift) -> some View {
        let isCurrent = m.serverId == currentContext.id.uuidString
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(hostLabel(m), systemImage: "server.rack")
                    .font(.callout.weight(.medium))
                if isCurrent {
                    Text("this host")
                        .font(.caption2)
                        .foregroundStyle(ScarfColor.accentActive)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ScarfColor.accentTint)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(m.project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Project record last updated \(m.project.updatedAt.formatted())")
            }

            Text(m.project.rootPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            // Per-host config readout; drifted fields are tinted.
            VStack(alignment: .leading, spacing: 3) {
                configRow("cpu", "Model", modelLabel(m.project), drifted: drift.has(.modelPreset))
                configRow("rectangle.split.3x1", "Board", m.project.board ?? "none", drifted: drift.has(.board))
                configRow("clock", "Cron jobs", "\(m.project.cronJobIds.count)", drifted: drift.has(.cron))
                if !m.project.miniApps.isEmpty || drift.has(.miniApps) {
                    configRow("square.grid.2x2", "Mini-apps", "\(m.project.miniApps.count)", drifted: drift.has(.miniApps))
                }
                if m.project.memoryNamespace != nil || drift.has(.memoryNamespace) {
                    configRow("brain", "Memory", m.project.memoryNamespace ?? "none", drifted: drift.has(.memoryNamespace))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md)
                .strokeBorder(isCurrent ? ScarfColor.accentActive.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func configRow(_ icon: String, _ label: String, _ value: String, drifted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(drifted ? ScarfColor.warning : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if drifted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.warning)
                    .help("Differs across hosts.")
            }
        }
    }

    private var singleHostHint: some View {
        Text("This project is live on a single host. Materialize it on another server (clone the repo there and add it) to unlock fleet config-as-policy.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: - Labels

    /// "Local" / a known server display name / a short id prefix for a
    /// host that's in the record but no longer in the registry.
    private func hostLabel(_ m: FleetMaterialization) -> String {
        if let name = m.serverDisplayName, !name.isEmpty { return name }
        if m.serverId == ServerContext.local.id.uuidString { return "Local" }
        return String(m.serverId.prefix(8))
    }

    /// Model presets are per-host UUIDs we don't resolve to names here
    /// (that needs a per-host `ModelPresetService` hop); show bound-vs-
    /// default + a short id so drift is legible without the lookup.
    private func modelLabel(_ project: ScarfProject) -> String {
        guard let id = project.modelPresetId, !id.isEmpty else { return "default" }
        return String(id.prefix(8))
    }

    nonisolated static func driftLabel(_ field: FleetDrift.Field) -> String {
        switch field {
        case .name:            return "Name"
        case .modelPreset:     return "Model preset"
        case .board:           return "Board"
        case .cron:            return "Cron jobs"
        case .memoryNamespace: return "Memory namespace"
        case .miniApps:        return "Mini-apps"
        }
    }
}

// MARK: - Chip flow

/// A simple wrapping row of pill chips for the drift field list. Kept
/// local to the Fleet panel — small enough not to warrant a shared
/// component, and the cockpit has no other chip-flow need yet.
private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        // A handful of short labels (≤6 drift fields) — a plain HStack
        // wraps acceptably inside the panel width via `.fixedSize`-free
        // layout; use an adaptive grid so long names don't clip.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90, maximum: 160), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ScarfColor.warning.opacity(0.18))
                    .foregroundStyle(ScarfColor.warning)
                    .clipShape(Capsule())
            }
        }
    }
}
