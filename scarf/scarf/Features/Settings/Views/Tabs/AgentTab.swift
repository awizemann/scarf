import SwiftUI
import ScarfCore
import ScarfDesign

/// Agent tab — turns, reasoning effort, tool use enforcement, approvals, gateway timing, service tier.
struct AgentTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    var body: some View {
        SettingsSection(title: "Turns & Reasoning", icon: "arrow.2.circlepath") {
            // When `agent.max_turns` is absent (sentinel 0) show the host's
            // effective default — unlimited on v0.20.5+, 500 on v0.20.0–
            // v0.20.4, 60 before — without writing it back. Only a user step
            // writes a value.
            //
            // v0.20.5 flipped the default to unlimited and its
            // `resolve_turn_limit` accepts 0 as unlimited, so the stepper's
            // low end opens up to 0 ("Unlimited") on those hosts only; older
            // hosts have no unlimited semantics and keep the 1 floor.
            StepperRow(
                label: "Max Turns",
                value: viewModel.config.displayMaxTurns(capabilities: capabilities),
                range: capabilities.isV0205OrLater ? 0...1000 : 1...1000,
                valueLabel: { $0 == HermesConfig.maxTurnsUnlimited ? "Unlimited" : "\($0)" }
            ) { viewModel.setMaxTurns($0) }
            // v0.20 added the `max` and `ultra` tiers (hermes_constants.py
            // VALID_REASONING_EFFORTS); older hosts keep the shorter list.
            PickerRow(label: "Reasoning Effort", selection: viewModel.config.reasoningEffort, options: HermesReasoningEffort.levels(capabilities: capabilitiesStore?.capabilities ?? .empty)) { viewModel.setReasoningEffort($0) }
            PickerRow(label: "Tool Use Enforcement", selection: viewModel.config.toolUseEnforcement, options: ["auto", "true", "false"]) { viewModel.setToolUseEnforcement($0) }
        }

        // v0.20: per-model reasoning overrides (`agent.reasoning_overrides`).
        // Hidden pre-v0.20 so the tab renders exactly as before.
        if let capabilities = capabilitiesStore?.capabilities, capabilities.isV020OrLater {
            ReasoningOverridesSection(viewModel: viewModel, capabilities: capabilities)
        }

        SettingsSection(title: "Approvals", icon: "checkmark.shield") {
            PickerRow(label: "Approval Mode", selection: viewModel.config.approvalMode, options: ["auto", "manual", "smart", "off"]) { viewModel.setApprovalMode($0) }
            StepperRow(label: "Approval Timeout (s)", value: viewModel.config.approvalTimeout, range: 5...600, step: 5) { viewModel.setApprovalTimeout($0) }
        }

        SettingsSection(title: "Messaging Gateway", icon: "antenna.radiowaves.left.and.right") {
            ToggleRow(label: "Fast Mode", isOn: viewModel.config.serviceTier == "fast") { on in
                viewModel.setServiceTier(on ? "fast" : "normal")
            }
            StepperRow(label: "Gateway Timeout (s)", value: viewModel.config.gatewayTimeout, range: 60...7200, step: 60) { viewModel.setGatewayTimeout($0) }
            StepperRow(label: "Notify Interval (s)", value: viewModel.config.gatewayNotifyInterval, range: 0...3600, step: 30) { viewModel.setGatewayNotifyInterval($0) }
            // v0.20.4+ (isV0204OrLater).
            if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
                StepperRow(label: "Cron Drain Timeout (s)", value: viewModel.config.cronDrainTimeout, range: 0...600, step: 5) { viewModel.setCronDrainTimeout($0) }
                    .help("Cron-only floor under gateway stop/restart drain. Distinct from Restart Drain Timeout. Default 30.")
                // The upstream default flipped 1800 → 5 at v0.21.0, so the
                // shown value, the range and the step are all host-aware.
                // On v0.21+ the floor drops to 5 and the step to 5, so the
                // host's own default is expressible and round-trips instead
                // of snapping to 60 the first time the stepper is touched
                // (a 60-second lease is 12x the intended wait). Pre-v0.21
                // hosts keep the original 60/60 pair verbatim — their
                // default is still 1800 and 5 is not a value they'd want.
                let leaseCaps = capabilitiesStore?.capabilities ?? .empty
                let leaseFloor = leaseCaps.isV021OrLater
                    ? HermesConfig.gatewayTurnLeaseTimeoutMinimum : 60
                StepperRow(
                    label: "Gateway Turn Lease Timeout (s)",
                    value: viewModel.config.displayGatewayTurnLeaseTimeout(capabilities: leaseCaps),
                    range: leaseFloor...7200,
                    step: leaseFloor
                ) { viewModel.setGatewayTurnLeaseTimeout($0) }
                    .help(leaseCaps.isV021OrLater
                          ? "Max time an alias routing key waits for an active turn holding the same session lease. Keep it short — Telegram dispatches updates sequentially, so a waiter also delays unrelated topics. Non-positive values fall back to 5."
                          : "Max time an alias routing key waits for an active turn holding the same session lease. Non-positive values fall back to 1800.")
            }
        }

        // v0.19+: `profile_routes` — route inbound gateway messages to
        // different profiles by platform/server/channel/thread. Older than
        // the rest of this tab's gated surface (first tag v2026.7.20 =
        // Hermes 0.19.0), hence its own floor.
        if let capabilities = capabilitiesStore?.capabilities, capabilities.hasGatewayProfileRoutes {
            ProfileRoutesSection(viewModel: viewModel, capabilities: capabilities)
        }
    }
}

/// Compact editor for `agent.reasoning_overrides` — rows of
/// (model pattern → effort), matched spelling-tolerantly by Hermes against
/// the active model and winning over the global Reasoning Effort. Writes go
/// through the direct-YAML path (dicts are inexpressible via
/// `hermes config set`); the whole dict is rewritten on each change,
/// removing the key entirely when the last row is deleted.
private struct ReasoningOverridesSection: View {
    @Bindable var viewModel: SettingsViewModel
    let capabilities: HermesCapabilities
    @State private var newPattern = ""
    @State private var newEffort = "high"

    /// Sorted for a stable row order (the YAML dict is unordered on read).
    private var sortedOverrides: [(key: String, value: String)] {
        viewModel.config.reasoningOverrides
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (key: $0.key, value: $0.value) }
    }

    var body: some View {
        SettingsSection(title: "Per-Model Reasoning", icon: "brain") {
            ForEach(sortedOverrides, id: \.key) { pair in
                OverrideRow(
                    pattern: pair.key,
                    effort: pair.value,
                    options: effortOptions(current: pair.value),
                    onEffortChange: { newEffort in
                        changeEffort(pattern: pair.key, to: newEffort)
                    },
                    onRemove: {
                        save(sortedOverrides.filter { $0.key != pair.key })
                    }
                )
            }
            HStack {
                TextField("Model name or spelling (e.g. claude-opus-4.5)", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(ScarfFont.monoSmall)
                Picker("", selection: $newEffort) {
                    ForEach(HermesReasoningEffort.levels(capabilities: capabilities), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Add") { addNew() }
                    .controlSize(.small)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
            .help("Overrides the global Reasoning Effort when the active model matches the pattern (exact or common spelling variants — dots/dashes, with/without provider prefix). First match wins.")
        }
    }

    /// Existing rows may carry a value outside the picker vocabulary (a
    /// hand-edited alias like "disabled") — keep it selectable so the picker
    /// doesn't silently rewrite it.
    private func effortOptions(current: String) -> [String] {
        let base = HermesReasoningEffort.levels(capabilities: capabilities)
        return base.contains(current) ? base : [current] + base
    }

    private func changeEffort(pattern: String, to newEffort: String) {
        var pairs = sortedOverrides
        for i in pairs.indices where pairs[i].key == pattern {
            pairs[i].value = newEffort
        }
        save(pairs)
    }

    private func addNew() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        // Case-insensitive replace-on-add so "Claude-Opus" doesn't sit
        // alongside an existing "claude-opus" row.
        var pairs = sortedOverrides.filter { $0.key.caseInsensitiveCompare(pattern) != .orderedSame }
        pairs.append((key: pattern, value: newEffort))
        save(pairs)
        newPattern = ""
    }

    private func save(_ pairs: [(key: String, value: String)]) {
        viewModel.saveReasoningOverrides(pairs, capabilities: capabilities)
    }
}

/// One (model pattern → effort) row — split out so the type-checker deals
/// with small, plain closures instead of an inline nested-binding pyramid.
private struct OverrideRow: View {
    let pattern: String
    let effort: String
    let options: [String]
    let onEffortChange: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(pattern)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Picker("", selection: Binding(get: { effort }, set: onEffortChange)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .buttonStyle(.plain)
            .help("Remove this override")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}
