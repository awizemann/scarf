import SwiftUI
import ScarfCore
import ScarfDesign
import Stats

/// Display tab — streaming, reasoning, cost, skin, compact mode, inline diffs, bell, etc.
struct DisplayTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    /// Scarf-local chat density preferences (issues #47 / #48).
    /// Independent of the Hermes config flags rendered in the
    /// "Output" section below — those control what Hermes EMITS,
    /// these control how Scarf RENDERS what was emitted.
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyle: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyle: String = ReasoningStyle.disclosure.rawValue
    @AppStorage(ChatDensityKeys.fontScale)
    private var fontScale: Double = ChatFontScale.default
    /// Side-pane visibility (issue #58). Mirrors the toolbar buttons in
    /// ChatView; this is the canonical preferences home.
    @AppStorage(ChatDensityKeys.showSessionsList)
    private var showSessionsList: Bool = true
    @AppStorage(ChatDensityKeys.showInspector)
    private var showInspector: Bool = true
    /// Background-completion notifications (issue #64). Default on so
    /// users new to Scarf get the async-aware UX out of the box.
    @AppStorage(ChatNotificationService.toggleKey)
    private var notifyOnComplete: Bool = true
    /// v2.8 — opt-in tool-result content load when resuming past
    /// chats. Default off so slow remotes don't blow past the SSH
    /// timeout on chats with multi-page tool output. Tool call cards
    /// still render either way; only the inspector's "Output"
    /// section is empty until the user opens a card (lazy-fetched
    /// per-call).
    @AppStorage(ChatDensityKeys.loadHistoricalToolResults)
    private var loadHistoricalToolResults: Bool = false

    /// `display.busy_input_mode` picker options: `interrupt` / `queue`
    /// always, `steer` when the host reads it (v0.12.0+,
    /// `HermesCapabilities.hasBusyInputSteerMode`). A stored value outside
    /// that set is APPENDED rather than dropped, so the picker never renders
    /// a blank selection over a config.yaml Scarf did not expect — the same
    /// rule `HermesApprovalMode.normalize` enforces on the Approvals picker.
    static func busyInputModeOptions(
        current: String, capabilities: HermesCapabilities
    ) -> [String] {
        var options = ["interrupt", "queue"]
        if capabilities.hasBusyInputSteerMode { options.append("steer") }
        if !current.isEmpty, !options.contains(current) { options.append(current) }
        return options
    }

    var body: some View {
        SettingsSection(title: "Chat density", icon: "rectangle.compress.vertical") {
            DensityPickerRow(
                label: "Tool calls",
                selection: $toolCardStyle,
                options: ToolCardStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            DensityPickerRow(
                label: "Reasoning",
                selection: $reasoningStyle,
                options: ReasoningStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            FontScaleRow(scale: $fontScale)
            ToggleRow(label: "Sessions list", isOn: showSessionsList) { showSessionsList = $0 }
            ToggleRow(label: "Tool inspector", isOn: showInspector) { showInspector = $0 }
            ToggleRow(
                label: "Load tool results in past chats",
                isOn: loadHistoricalToolResults
            ) { loadHistoricalToolResults = $0 }
            Text("Off (default) keeps past chat resumes fast on slow remotes — tool call cards still render, but the inspector lazy-loads each result when you open it.")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.leading, 168)
            DensityFootnote()
        }

        SettingsSection(title: "Output", icon: "doc.plaintext") {
            ToggleRow(label: "Streaming", isOn: viewModel.config.streaming) { viewModel.setStreaming($0) }
            // Absent key resolves against the host: `display.show_reasoning`
            // flipped false → true at v0.18.1, so a flat `false` rendered the
            // toggle off on every stock v0.18.1+ host that streams reasoning.
            ToggleRow(
                label: "Show Reasoning",
                isOn: viewModel.config.displayShowReasoning(capabilities: capabilities)
            ) { viewModel.setShowReasoning($0) }
            ToggleRow(label: "Show Cost", isOn: viewModel.config.showCost) { viewModel.setShowCost($0) }
            ToggleRow(label: "Interim Messages", isOn: viewModel.config.interimAssistantMessages) { viewModel.setInterimAssistantMessages($0) }
            // No "Verbose" row: `agent.verbose` is not a config key.
            // Re-verified at v2026.9.7 (v0.21.1) — absent from the `"agent"`
            // block in `hermes_cli/config_defaults.py`, and the only thing
            // that sets the runtime flag is argparse:
            // `hermes_cli/_parser.py:224` declares `-v/--verbose`,
            // `hermes_cli/main.py:2867` defaults it for unparsed chat,
            // `cli.py:2596` stores it (`bool(verbose) if verbose is not None
            // else False` — no config lookup at all), and
            // `hermes_cli/cli_agent_setup_mixin.py:524` hands it to the agent
            // as `verbose_logging`. (go/no-go blocking condition 8, A5.)
            ToggleRow(label: "Inline Diffs", isOn: viewModel.config.display.inlineDiffs) { viewModel.setInlineDiffs($0) }
            // v0.14 — per-message timestamps in TUI output. ACP chat
            // renders timestamps independently (the streaming chip
            // shows wall-clock turn duration); this toggle only
            // affects the CLI TUI.
            if capabilitiesStore?.capabilities.hasDisplayTimestamps == true {
                ToggleRow(label: "Show Timestamps", isOn: viewModel.config.display.timestamps) { viewModel.setDisplayTimestamps($0) }
            }
            // v0.21.1 — `model.streaming`. Sits beside "Streaming"
            // (`display.streaming`) deliberately: they are easy to confuse
            // and the pair only reads correctly together. This one is a
            // PROVIDER-request property (whole session, subagents included),
            // not a rendering one, and its default is ON.
            if capabilitiesStore?.capabilities.isV0211OrLater ?? false {
                ToggleRow(label: "Provider Request Streaming", isOn: viewModel.config.modelStreaming) { viewModel.setModelStreaming($0) }
                    .help("Streams the model's own API requests (parent and subagents). Turn OFF only for self-hosted OpenAI-compatible servers whose streaming tool-call path is broken — non-streaming loses liveness. Separate from Streaming above, which only affects terminal rendering.")
            }
        }

        SettingsSection(title: "Layout", icon: "rectangle.3.group") {
            EditableTextField(label: "Skin", value: viewModel.config.display.skin) { viewModel.setSkin($0) }
            ToggleRow(label: "Compact", isOn: viewModel.config.display.compact) { viewModel.setDisplayCompact($0) }
            PickerRow(label: "Resume Display", selection: viewModel.config.display.resumeDisplay, options: ["full", "minimal"]) { viewModel.setResumeDisplay($0) }
            // `steer` (Enter injects the typed text into the RUNNING turn) is
            // the third member Hermes has read since v0.12.0 — `cli.py:2592`
            // @ v2026.9.7 reads `_bim if _bim in ("queue", "steer") else
            // "interrupt"`. Gated so a pre-v0.12 host can't be given a mode it
            // silently downgrades to `interrupt`.
            PickerRow(
                label: "Busy Input Mode",
                selection: viewModel.config.display.busyInputMode,
                options: Self.busyInputModeOptions(
                    current: viewModel.config.display.busyInputMode,
                    capabilities: capabilitiesStore?.capabilities ?? .empty)
            ) { viewModel.setBusyInputMode($0) }
            // v0.21.1 — Hermes Desktop's own cold-start restore. Default ON
            // upstream. Scarf's chat pane restores nothing across launches,
            // so this row is purely the host's preference.
            if capabilitiesStore?.capabilities.isV0211OrLater ?? false {
                ToggleRow(label: "Resume Last Session", isOn: viewModel.config.display.resumeLastSession) { viewModel.setResumeLastSession($0) }
                    .help("Hermes Desktop reopens the last chat or page on cold start. Does not affect Scarf, which always opens on a fresh view.")
            }
        }

        SettingsSection(title: "Tool Progress", icon: "gauge") {
            ToggleRow(label: "Tool Progress Command", isOn: viewModel.config.display.toolProgressCommand) { viewModel.setToolProgressCommand($0) }
            StepperRow(label: "Preview Length", value: viewModel.config.display.toolPreviewLength, range: 0...500, step: 10) { viewModel.setToolPreviewLength($0) }
        }

        SettingsSection(title: "Feedback", icon: "bell") {
            ToggleRow(label: "Bell on Complete", isOn: viewModel.config.display.bellOnComplete) { viewModel.setBellOnComplete($0) }
            // v0.21.1 — the other half of the bell pair: fires when Hermes
            // BLOCKS on a prompt rather than when a turn finishes.
            if capabilitiesStore?.capabilities.isV0211OrLater ?? false {
                ToggleRow(label: "Bell on Prompt", isOn: viewModel.config.display.bellOnPrompt) { viewModel.setBellOnPrompt($0) }
                    .help("Terminal bell when a blocking prompt opens — clarify, approval or sudo.")
            }
            ToggleRow(label: "Notify when Hermes finishes", isOn: notifyOnComplete) {
                notifyOnComplete = $0
                Analytics.record(.notificationToggled(enabled: $0))
            }
        }
    }
}

// MARK: - Density-section primitives

/// Segmented picker over (rawValue, displayName) tuples — keeps the
/// existing `PickerRow` simple-string contract while still letting us
/// render distinct user-facing labels for each density enum case.
/// Cannot reuse the generic `PickerRow` in `SettingsComponents.swift`:
/// that one is `.menu` style and doesn't accept a separate display
/// name per option.
private struct DensityPickerRow: View {
    let label: String
    @Binding var selection: String
    let options: [(rawValue: String, displayName: String)]

    var body: some View {
        HStack {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 160, alignment: .trailing)
            Picker("", selection: $selection) {
                ForEach(options, id: \.rawValue) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}

private struct FontScaleRow: View {
    @Binding var scale: Double

    var body: some View {
        HStack {
            Text("Chat font size")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 160, alignment: .trailing)
            Slider(
                value: $scale,
                in: ChatFontScale.min...ChatFontScale.max,
                step: ChatFontScale.step
            )
            .frame(maxWidth: 240)
            Text(ChatFontScale.percentLabel(for: scale))
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 48, alignment: .leading)
            Button("Reset") {
                scale = ChatFontScale.default
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(abs(scale - ChatFontScale.default) < 0.001)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}

private struct DensityFootnote: View {
    var body: some View {
        Text("Controls how Scarf renders the chat. Use Output → Show Reasoning to control what Hermes sends.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 6)
    }
}
