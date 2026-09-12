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
                valueLabel: { $0 == HermesConfig.maxTurnsUnlimited ? String(localized: "Unlimited") : $0.formatted() }
            ) { viewModel.setMaxTurns($0) }
            // `max` and `ultra` are NOT v0.20 — they arrived a release apart
            // and both well before it. Walked: `VALID_REASONING_EFFORTS`
            // gains `"max"` at v2026.7.7 (0.18.1, `hermes_constants.py:794`)
            // and `"ultra"` at v2026.7.20 (0.19.0, `:835-837`), so the two
            // floors are `hasReasoningEffortMax` (0.18.1) and
            // `hasReasoningEffortUltra` (0.19.0) — NOT "v0.20 for both",
            // which is what this comment used to claim. Those are the floors
            // `HermesReasoningEffort.levels(capabilities:)` uses; older hosts
            // keep the shorter list.
            //
            // Round-4 decision 13: the list is WIDENED to include whatever is
            // already on disk, because a `Picker` whose selection matches no
            // tag renders blank — a 0.18.x host with `ultra` in config.yaml
            // showed an empty control. Widening is not an endorsement, so the
            // row carries `unsupportedLevelNotice` beneath it.
            //
            // The leading empty row is the ABSENT key. It is not a level
            // the picker may assert — `agent.reasoning_effort` is in no
            // schema layer at any supported tag, so stamping `medium` into
            // the control would claim a value Hermes never wrote, and the
            // first unrelated save on that tab would write it. What the
            // absent key RESOLVES to is Hermes's own `medium`, not the model
            // provider's default: the chat-completions transport substitutes
            // it EXPLICITLY (`agent/transports/chat_completions.py:420-422` @
            // `v2026.9.7`), and only the Anthropic adapter leaves the choice
            // to the model (`agent/anthropic_adapter.py:570`). Hence the row
            // reads "Hermes default", P45's wording on all four surfaces.
            PickerRow(
                label: "Reasoning Effort",
                // P46b: the SELECTION, not just the options. `levels(…)`
                // treats a whitespace-only stored value as the sentinel and
                // widens nothing, but this binding handed the picker the raw
                // `"  "`, which matches neither the sentinel row's `""` tag
                // nor any level — so the control rendered blank, the exact
                // failure decision 13 exists to prevent.
                selection: HermesReasoningEffort.pickerSelection(
                    for: viewModel.config.reasoningEffort
                ),
                options: [""] + HermesReasoningEffort.levels(
                    capabilities: capabilities,
                    selected: viewModel.config.reasoningEffort
                ),
                optionLabel: { $0.isEmpty ? String(localized: "Hermes default") : $0 }
            ) { viewModel.setReasoningEffort($0) }
            UnsupportedEffortNote(
                selected: viewModel.config.reasoningEffort,
                capabilities: capabilities
            )
            PickerRow(label: "Tool Use Enforcement", selection: viewModel.config.toolUseEnforcement, options: ["auto", "true", "false"]) { viewModel.setToolUseEnforcement($0) }
        }

        // v0.20: per-model reasoning overrides (`agent.reasoning_overrides`).
        // Hidden pre-v0.20 so the tab renders exactly as before.
        if let capabilities = capabilitiesStore?.capabilities, capabilities.isV020OrLater {
            ReasoningOverridesSection(viewModel: viewModel, capabilities: capabilities)
        }

        SettingsSection(title: "Approvals", icon: "checkmark.shield") {
            // `auto` was never a valid `approvals.mode` at ANY tag — Hermes
            // warns and falls back to `manual` (`tools/approval_context.py`
            // `_VALID_MODES = ("manual", "smart", "off")` @ v2026.9.7; the same
            // three-member set back to v0.3). The selection is normalised the
            // way Hermes reads it, so a config still carrying `auto` shows the
            // `manual` the host is actually enforcing instead of a blank
            // picker. See `HermesApprovalMode`.
            //
            // The leading empty row is the ABSENT key, rendered as the mode
            // the connected host would run — "Host default (smart)" on
            // v0.19.0+, "Host default (manual)" below it, "Host default
            // (unknown)" when the version could not be detected. Reading the
            // absent key as a flat `manual` told every stock v0.19+ user that
            // Scarf would ask before each guarded command while the guardian
            // model was actually deciding. Selecting any explicit mode writes
            // it; selecting the host-default row CLEARS the key with
            // `hermes config unset approvals.mode` on a v0.19+ host
            // (round-3 decision 10) and, below that floor, stays inert with
            // a hint — it never writes an empty scalar, which Hermes reads
            // as `manual`.
            PickerRow(
                label: "Approval Mode",
                selection: viewModel.config.storedApprovalMode?.rawValue ?? "",
                options: [""] + HermesApprovalMode.options,
                optionLabel: {
                    $0.isEmpty
                        ? viewModel.config.approvalModeHostDefaultLabel(capabilities: capabilities)
                        : $0
                }
            ) { viewModel.setApprovalMode($0, capabilities: capabilities) }
            // Absent key (sentinel 0) shows the host's own default — 300 on
            // v0.19.1+, 60 before — without writing it back, so the first
            // stepper tap steps from the resolved default rather than from 0.
            // The 5-second floor stays: Hermes accepts any positive value and
            // 300 is expressible, so nothing snaps.
            StepperRow(
                label: "Approval Timeout (s)",
                value: viewModel.config.displayApprovalTimeout(capabilities: capabilities),
                range: 5...600,
                step: 5
            ) { viewModel.setApprovalTimeout($0) }
        }

        SettingsSection(title: "Messaging Gateway", icon: "antenna.radiowaves.left.and.right") {
            // `agent.service_tier`. Was a Bool toggle through v0.21.0; a
            // toggle can only express two of the four values the v0.21.1
            // parser accepts, and it showed OFF for `auto`/`cold` then
            // overwrote them on the first tap. On a pre-v0.21.1 host the
            // picker offers exactly the two values the toggle wrote, so
            // nothing about that host's behaviour changes.
            fastModeRows
            StepperRow(label: "Gateway Timeout (s)", value: viewModel.config.gatewayTimeout, range: 60...7200, step: 60) { viewModel.setGatewayTimeout($0) }
            // Absent key shows the host's own default — 180 on v0.11.0+, 600
            // before — without writing it back. An explicit `0` on disk is a
            // real setting ("no still-working notices"), which is why the
            // parse carries a true optional rather than a 0 sentinel here.
            // The 30-second step keeps 180 expressible; 600 was already.
            StepperRow(
                label: "Notify Interval (s)",
                value: viewModel.config.displayGatewayNotifyInterval(capabilities: capabilities),
                range: 0...3600,
                step: 30
            ) { viewModel.setGatewayNotifyInterval($0) }
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

    /// Fast-mode selection plus the window length the bounded modes use.
    ///
    /// The selection is normalized through `HermesServiceTier` rather than
    /// compared literally: Hermes accepts six spellings of "off" and three
    /// of "always" (`cli.py` `_parse_service_tier_config`), and a
    /// hand-edited `priority` must render as Always, not as a blank row.
    /// `HermesServiceTier.options(capabilities:current:)` keeps a value the
    /// host can't use visible instead of silently rewriting it.
    @ViewBuilder
    private var fastModeRows: some View {
        // `current:` matters: when the probe failed (`capabilities` is
        // `.empty`, every floor false) but the config already holds a bounded
        // `auto`/`cold`, the toggle would render it as "off" and overwrite it
        // with `normal` on the first tap. Pass the stored value so that one
        // state falls through to the picker instead.
        let storedTier = HermesServiceTier.normalize(viewModel.config.serviceTier)
        if HermesServiceTier.editorStyle(capabilities: capabilities, current: storedTier) == .picker {
            boundedFastModeRows
        } else {
            // C1: a pre-target host (and an undetected one) renders exactly
            // what it rendered before this cycle — the Bool toggle, which is
            // lossless there because the two values it writes are the only
            // two such a host's parser accepts.
            ToggleRow(label: "Fast Mode", isOn: viewModel.config.serviceTier == "fast") { on in
                viewModel.setServiceTier(on ? "fast" : "normal")
            }
        }
    }

    /// v0.21.1+: the four-way picker, plus the window the bounded modes use.
    @ViewBuilder
    private var boundedFastModeRows: some View {
        let tier = HermesServiceTier.normalize(viewModel.config.serviceTier)
        let options = HermesServiceTier.options(capabilities: capabilities, current: tier)
        PickerRow(
            label: "Fast Mode",
            selection: tier.rawValue,
            options: options.map(\.rawValue),
            optionLabel: { Self.fastModeLabel(for: $0) }
        ) { raw in
            viewModel.setServiceTier(HermesServiceTier(rawValue: raw)?.configValue ?? raw)
        }
        .help("Priority service tier for provider requests. Always = every request; Auto = the first seconds of every turn; Cold = a session's first turn only.")
        // The window length only means anything while a bounded mode is
        // actually selected.
        if tier.isBounded {
            StepperRow(
                label: "Fast Window (s)",
                value: viewModel.config.agentFastAutoSeconds,
                range: 5...3600,
                step: 5
            ) { viewModel.setAgentFastAutoSeconds($0) }
                .help("How long the fast window stays open once a turn opens it. Hermes default: 60.")
        }
    }

    /// User-facing name for a `HermesServiceTier` raw value. Every option
    /// the picker offers comes from `HermesServiceTier.options`, which
    /// only ever yields enum cases — `normalize` maps every spelling
    /// Hermes accepts, and everything else, onto one of them — so there is
    /// no non-enum raw value to fall back to.
    private static func fastModeLabel(for raw: String) -> String {
        switch HermesServiceTier(rawValue: raw) ?? .off {
        case .off:    String(localized: "Off")
        case .always: String(localized: "Always")
        case .auto:   String(localized: "Auto (bounded window)")
        case .cold:   String(localized: "Cold (first turn only)")
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
                    capabilities: capabilities,
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
                    ForEach(
                        HermesReasoningEffort.levels(capabilities: capabilities, selected: newEffort),
                        id: \.self
                    ) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Add") { addNew() }
                    .controlSize(.small)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty
                              || controlCharacterFieldLabel != nil
                              || oversizedKeyFieldLabel != nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
            .help("Overrides the global Reasoning Effort when the active model matches the pattern (exact or common spelling variants — dots/dashes, with/without provider prefix). First match wins.")
            // Round-4 decision 9: a dead Add button always says what it
            // wants, in the same shape `BotEditorSheet.cannotSaveReason` uses.
            if let field = controlCharacterFieldLabel {
                Text("“\(field)” contains a tab or a control character. Remove it, then add.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityLabel(
                        Text("Validation error: \(field) contains a tab or a control character. Remove it, then add.")
                    )
            }
            // P41b: the other way this field can make Hermes discard the
            // whole config.yaml — a map key past PyYAML's simple-key limit.
            // The copy does not name 1024, because the budget the user
            // would have to count against is the EMITTED token: quoting
            // spends two of it, and a combining mark or an emoji ZWJ
            // sequence spends more scalars than it shows Characters (P41c).
            if let field = oversizedKeyFieldLabel {
                Text("“\(field)” is too long for Hermes to read as a config.yaml key once Scarf quotes it. Hermes ignores the whole file. Shorten it, then add.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityLabel(
                        Text("Validation error: \(field) is too long to use as a config.yaml key. Shorten it, then add.")
                    )
            }
        }
    }

    /// Round-4 decision 9 — the reasoning-override pattern is the other
    /// free-text field that reaches config.yaml with no control-character
    /// refusal, alongside the MCP entry editor. Same shape as round-3
    /// decision 6 gave `BotsViewModel` / `HermesProfileRoute`: refuse
    /// visibly rather than reshape, because a pasted ESC that round-trips as
    /// the literal `a\x1bb` is a pattern the user cannot see and which will
    /// never match a model name.
    ///
    /// Checked on the pattern as ``addNew`` WRITES it — trimmed, matching
    /// `PowerSettingsWriter.setReasoningOverrides`, which trims the key for
    /// both the emptiness test and the write since P41.
    ///
    /// Deliberately NOT applied to the EXISTING rows, which a re-save
    /// rewrites: `YAMLScalar.quoteIfNeeded` represents a control character
    /// losslessly (`YAMLScalar.doubleQuoted` escapes it `\xNN`/`\uNNNN`)
    /// and `YAMLScalar.unquote` reads it back, so a hand-edited pattern
    /// survives a save intact — refusing it would make the whole section
    /// uneditable to fix the very row that carries it, which is the
    /// over-refusal P19 warned about.
    private var controlCharacterFieldLabel: String? {
        PowerSettingsWriter.controlCharacterFieldLabel(pattern: newPattern)
    }

    /// Round-4, P41b — the pattern is a config.yaml map KEY and PyYAML
    /// refuses a simple key past 1024 emitted unicode scalars, which makes
    /// `load_config` discard the whole file. See
    /// ``PowerSettingsWriter/oversizedKeyFieldLabel(pattern:)``.
    private var oversizedKeyFieldLabel: String? {
        PowerSettingsWriter.oversizedKeyFieldLabel(pattern: newPattern)
    }

    /// Existing rows may carry a value outside the picker vocabulary (a
    /// hand-edited alias like "disabled") — keep it selectable so the picker
    /// doesn't silently rewrite it.
    /// The picker's options for an EXISTING override row, widened to
    /// whatever is on disk. This is where round-4 decision 13's widening was
    /// first written; it now lives in `HermesReasoningEffort` so the two
    /// top-level pickers share it instead of re-deriving it.
    /// P46b: the empty row is CONDITIONAL — it exists only when the stored
    /// value is empty (or whitespace-only, Hermes's same absent-key case),
    /// because a `Picker` whose selection matches no tag renders blank and
    /// an override row has no sentinel of its own the way the two top-level
    /// pickers do.
    ///
    /// It is not offered as a choice on a row that has a real level, and
    /// that is deliberate: `HermesReasoningEffort.isValid("")` is false, so
    /// `PowerSettingsWriter.setReasoningOverrides` REFUSES a batch carrying
    /// an empty value — an always-present "Default" row would be a control
    /// the user can move and the save then silently declines. Clearing an
    /// override is the minus button, which is also what selecting this row
    /// does (`changeEffort`).
    ///
    /// What an empty override means is walked rather than assumed:
    /// `resolve_per_model_reasoning_effort` runs the value through
    /// `parse_reasoning_effort`, which returns `None` for it, and
    /// `resolve_reasoning_config` then falls through to the global
    /// `agent.reasoning_effort` (`hermes_constants.py:935-941`, `:970-976` @
    /// `v2026.9.7`) — i.e. to the row above this section. "Default" is that
    /// row's own word for "not set here", which is why it is reused rather
    /// than "Hermes default" (the global row's claim, which this one does
    /// not make).
    private func effortOptions(current: String) -> [String] {
        let levels = HermesReasoningEffort.levels(capabilities: capabilities, selected: current)
        return HermesReasoningEffort.pickerSelection(for: current).isEmpty
            ? [""] + levels
            : levels
    }

    private func changeEffort(pattern: String, to newEffort: String) {
        // The sentinel row (P46b) means "no override here", and the only way
        // to say that in `agent.reasoning_overrides` is to not have the
        // entry: an empty value fails `HermesReasoningEffort.isValid` and
        // the writer would refuse the whole save.
        guard !HermesReasoningEffort.pickerSelection(for: newEffort).isEmpty else {
            save(sortedOverrides.filter { $0.key != pattern })
            return
        }
        var pairs = sortedOverrides
        for i in pairs.indices where pairs[i].key == pattern {
            pairs[i].value = newEffort
        }
        save(pairs)
    }

    private func addNew() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        // EXACT replace-on-add. Round-5 decision 16.
        //
        // The case-insensitive filter that used to stand here DELETED a live
        // override: Hermes's lookup is a plain dict membership test,
        // `variant in overrides` inside `resolve_per_model_reasoning_effort`
        // (`hermes_constants.py:929-941` @ `v2026.9.7`), over the variants
        // `_canonical_model_variants` derives (`:892-926`) — which recover
        // dots↔dashes and add/strip provider prefixes but NEVER change case.
        // So `Claude-Opus` and `claude-opus` are two distinct entries, each
        // live for the model whose id it actually spells, and adding one was
        // silently removing the other from the file (`setReasoningOverrides`
        // rewrites the block from what the editor holds).
        // The rule itself lives in `HermesReasoningEffort
        // .overridesAfterAdding` so a test can exercise the code this view
        // runs (P51b): the inline copy that used to stand here left
        // decision 16 pinned only by a source grep.
        save(HermesReasoningEffort.overridesAfterAdding(
            pattern: pattern, effort: newEffort, to: sortedOverrides
        ))
        newPattern = ""
    }

    private func save(_ pairs: [(key: String, value: String)]) {
        Task { await viewModel.saveReasoningOverrides(pairs, capabilities: capabilities) }
    }
}

/// One (model pattern → effort) row — split out so the type-checker deals
/// with small, plain closures instead of an inline nested-binding pyramid.
private struct OverrideRow: View {
    let pattern: String
    let effort: String
    let options: [String]
    let capabilities: HermesCapabilities
    let onEffortChange: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            // Round-4 decision 13. `options` is widened to `effort`, so a
            // level above this host's floor is selectable here rather than
            // blank — this is what stops the widening from reading as
            // support.
            UnsupportedEffortNote(selected: effort, capabilities: capabilities)
        }
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }

    private var row: some View {
        HStack {
            Text(pattern)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Picker("", selection: Binding(
                get: { HermesReasoningEffort.pickerSelection(for: effort) },
                set: onEffortChange
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? String(localized: "Default") : option).tag(option)
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
    }
}
