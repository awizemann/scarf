import SwiftUI
import ScarfCore
import ScarfDesign

/// Security tab — redaction, command allowlist (read-only), Tirith sandbox, website blocklist, human delay.
struct SecurityTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// v0.20+ `hermes approvals suggest`. Pre-0.20 hosts render the tab
    /// byte-identically — no section, no CLI probe.
    private var hasApprovalsSuggest: Bool {
        capabilitiesStore?.capabilities.hasApprovalsSuggest ?? false
    }

    var body: some View {
        SettingsSection(title: "Redaction", icon: "eye.slash") {
            ToggleRow(label: "Redact Secrets", isOn: viewModel.config.security.redactSecrets) { viewModel.setRedactSecrets($0) }
            ToggleRow(label: "Redact PII", isOn: viewModel.config.security.redactPII) { viewModel.setRedactPII($0) }
        }

        SettingsSection(title: "Tirith Sandbox", icon: "shield.checkerboard") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.security.tirithEnabled) { viewModel.setTirithEnabled($0) }
            EditableTextField(label: "Binary Path", value: viewModel.config.security.tirithPath) { viewModel.setTirithPath($0) }
            StepperRow(label: "Timeout (s)", value: viewModel.config.security.tirithTimeout, range: 1...60) { viewModel.setTirithTimeout($0) }
            ToggleRow(label: "Fail Open", isOn: viewModel.config.security.tirithFailOpen) { viewModel.setTirithFailOpen($0) }
        }

        SettingsSection(title: "Website Blocklist", icon: "xmark.shield") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.security.blocklistEnabled) { viewModel.setBlocklistEnabled($0) }
            if !viewModel.config.security.blocklistDomains.isEmpty {
                ReadOnlyRow(label: "Domains", value: viewModel.config.security.blocklistDomains.joined(separator: ", "))
            }
        }

        if !viewModel.config.commandAllowlist.isEmpty {
            SettingsSection(title: "Command Allowlist", icon: "checkmark.shield") {
                ReadOnlyRow(label: "Commands", value: viewModel.config.commandAllowlist.joined(separator: ", "))
            }
        }

        if hasApprovalsSuggest {
            allowlistSuggestionsSection
        }

        SettingsSection(title: "Human Delay", icon: "hourglass.tophalf.filled") {
            PickerRow(label: "Mode", selection: viewModel.config.humanDelay.mode, options: ["off", "natural", "custom"]) { viewModel.setHumanDelayMode($0) }
            StepperRow(label: "Min (ms)", value: viewModel.config.humanDelay.minMS, range: 0...10_000, step: 50) { viewModel.setHumanDelayMinMS($0) }
            StepperRow(label: "Max (ms)", value: viewModel.config.humanDelay.maxMS, range: 0...10_000, step: 50) { viewModel.setHumanDelayMaxMS($0) }
        }
    }

    // MARK: - Allowlist suggestions (v0.20+, `hermes approvals suggest`)

    /// Proposals mined from approval history. Each row carries its own
    /// Add button — applying writes to `command_allowlist`, so it always
    /// takes an explicit per-proposal click; there is deliberately no
    /// "apply all".
    private var allowlistSuggestionsSection: some View {
        SettingsSection(title: "Allowlist Suggestions", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Text("Recurring commands you've approved before, mined from session history. Adding one writes it to the command allowlist so it stops prompting.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let msg = viewModel.approvalSuggestMessage {
                    Text(msg)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                }

                if viewModel.isLoadingApprovalSuggestions && viewModel.approvalProposals.isEmpty {
                    Text("Mining approval history…")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                } else if viewModel.approvalProposals.isEmpty {
                    Text("No suggestions right now — nothing recurring has needed approval.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                } else {
                    ForEach(viewModel.approvalProposals) { proposal in
                        proposalRow(proposal)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ScarfSpace.s3)
        }
        .onAppear { viewModel.loadApprovalSuggestions() }
    }

    private func proposalRow(_ proposal: HermesApprovalProposal) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proposal.pattern)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .textSelection(.enabled)
                    Text(proposal.kind)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                Text("approved \(proposal.count)× · \(proposal.classes.joined(separator: ", "))")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
                if let example = proposal.examples.first {
                    Text("e.g. \(example)")
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: ScarfSpace.s2)
            Button {
                viewModel.applyApprovalProposal(proposal)
            } label: {
                if viewModel.applyingProposalN == proposal.n {
                    Text("Adding…")
                } else {
                    Label("Add", systemImage: "plus")
                }
            }
            .disabled(viewModel.applyingProposalN != nil)
            .help("Add \(proposal.pattern) to command_allowlist in config.yaml")
        }
        .padding(.vertical, 4)
    }
}
