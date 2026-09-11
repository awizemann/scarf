import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet for editing a single Hermes config value. Renders the
/// appropriate control for each supported key:
/// - `.toggle` → SwiftUI Toggle (display.show_cost, show_reasoning,
///   streaming, agent.verbose).
/// - `.enumPicker(options)` → SwiftUI Picker (agent.approval_mode).
/// - `.number` → Stepper (agent.max_turns).
/// - `.text` → TextField (model.default, model.provider, timezone).
///
/// The save path calls `IOSSettingsViewModel.saveValue(key:value:)`
/// which shells out to `hermes config set` remotely. Hermes owns the
/// YAML round-trip (preserves comments, key order). Scarf just picks
/// the value.
struct SettingEditorSheet: View {
    let spec: SettingSpec
    let currentValue: String
    let vm: IOSSettingsViewModel
    let onDismiss: () -> Void

    @State private var textValue: String = ""
    @State private var boolValue: Bool = false
    @State private var numberValue: Int = 0
    @State private var enumValue: String = ""
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    control
                } header: {
                    Text(spec.displayName)
                } footer: {
                    Text(spec.helpText)
                        .font(.caption)
                }

                if let err = saveError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Edit \(spec.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(vm.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if vm.isSaving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(vm.isSaving || !hasValidValue)
                }
            }
            .task { primeFromCurrent() }
        }
        .presentationDetents([.height(260), .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .toggle:
            Toggle(spec.displayName, isOn: $boolValue)
        case .enumPicker(let options, let labels):
            Picker(spec.displayName, selection: $enumValue) {
                ForEach(options, id: \.self) { opt in
                    Text(verbatim: labels[opt] ?? opt).tag(opt)
                }
            }
            // `.menu`, not `.segmented`: the sentinel row's label is a
            // sentence ("Host default (smart)"), which a segmented control
            // truncates to nothing useful.
            .pickerStyle(.menu)
        case .number(let range, let zeroLabel):
            Stepper(value: $numberValue, in: range, step: 1) {
                Text(numberValue == 0 ? (zeroLabel ?? "0") : "\(numberValue)")
                    .monospacedDigit()
            }
        case .text:
            TextField(spec.displayName, text: $textValue)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var hasValidValue: Bool {
        switch spec.kind {
        case .toggle, .number: return true
        case .enumPicker(let options, _):
            // `""` is only selectable when it is the sentinel row; otherwise
            // an empty selection means priming found nothing and there is
            // nothing to save.
            return !enumValue.isEmpty || options.contains("")
        case .text: return !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var stringValue: String {
        switch spec.kind {
        case .toggle: return boolValue ? "true" : "false"
        case .enumPicker: return enumValue
        case .number: return String(numberValue)
        case .text: return textValue.trimmingCharacters(in: .whitespaces)
        }
    }

    /// What `primeFromCurrent` put in the control, so `save()` can tell an
    /// untouched sheet from a real edit.
    ///
    /// Several keys prime a RESOLVED host default rather than a stored value
    /// — `approvals.mode`'s sentinel row, `agent.max_turns`'s "Unlimited"/500,
    /// `display.show_reasoning`'s v0.18.1+ `true`. Writing one of those back
    /// because the user opened the sheet and tapped Save PINS a default they
    /// never chose, which is the whole point of reading those keys as
    /// absence sentinels in the first place. So Save on an unchanged sheet
    /// writes nothing.
    @State private var primedValue: String?

    private func primeFromCurrent() {
        // ONE priming rule, in `Kind.primedScalar`, so the value Save compares
        // against cannot drift from the value the control was given.
        let primed = spec.kind.primedScalar(currentValue: currentValue)
        switch spec.kind {
        case .toggle: boolValue = primed == "true"
        case .enumPicker: enumValue = primed
        case .number: numberValue = Int(primed) ?? 0
        case .text: textValue = primed
        }
        primedValue = primed
    }

    /// The scalar Save must hand `saveValue`, or `nil` for "write nothing".
    ///
    /// The whole of Save's write/no-write policy lives here rather than inline
    /// in `save()`, because `save()` is a `private func` on a SwiftUI `View`
    /// whose inputs are `@State` — unreachable from a test — and this rule is
    /// the part that has been wrong twice.
    ///
    /// Two reasons to write nothing:
    ///
    /// 1. **Unchanged.** `stringValue == primedValue`. Several keys prime a
    ///    RESOLVED host default rather than a stored value, so writing an
    ///    untouched sheet back PINS a default the user never chose.
    /// 2. **The host-default sentinel row is selected.** Picking the empty
    ///    `enumPicker` row IS a real edit (it differs from `primedValue`
    ///    whenever the key had a stored value), but what it means is "unset
    ///    this key" — and `hermes config set <key> ''` does not unset
    ///    anything. For a str-typed key `_coerce_config_set_value` returns the
    ///    string verbatim (`hermes_cli/config.py:3306-3312` @ v2026.9.7), so
    ///    an empty scalar lands on disk, and `_normalize_approval_mode("")`
    ///    falls through `if normalized:` and resolves to `"manual"`
    ///    (`tools/approval_context.py:197-214`). Scarf's own reader is
    ///    `raw.isEmpty ? nil : …` (`HermesConfig.swift`), so the row would go
    ///    back to rendering "Host default (smart)" while the host enforced
    ///    `manual` — silently wrong, and worse than the bug the sentinel row
    ///    was added to fix.
    ///
    /// So the host-default row writes nothing, mirroring
    /// `SettingsViewModel.setApprovalMode`'s `guard !value.isEmpty` on the
    /// Mac. Clearing a key that is already set needs `config unset`, which
    /// this sheet does not drive.
    static func valueToWrite(
        kind: SettingSpec.Kind,
        stringValue: String,
        primedValue: String?
    ) -> String? {
        if stringValue == primedValue { return nil }
        if case .enumPicker(let options, _) = kind,
           stringValue.isEmpty, options.contains("") {
            return nil
        }
        return stringValue
    }

    /// What selecting the host-default sentinel row over a STORED value means
    /// — the half `valueToWrite` deliberately answers `nil` for.
    ///
    /// Round-3 decision 10: that row clears the key with
    /// `hermes config unset <key>` on a host that has the verb, and below the
    /// `hasConfigUnset` floor (v0.19.0) it stays inert with a hint, because
    /// Scarf never shells a verb the host lacks (charter C5). `nil` means
    /// "not a clear gesture" and Save proceeds to `valueToWrite` unchanged.
    ///
    /// Pure and `static` for the same reason `valueToWrite` is: `save()` is a
    /// `private func` on a SwiftUI `View` over `@State` and cannot be reached
    /// from a test, and this rule is the part that has been wrong twice.
    enum ClearAction: Equatable { case unset, belowFloor }

    static func clearAction(
        kind: SettingSpec.Kind,
        stringValue: String,
        primedValue: String?,
        capabilities: HermesCapabilities
    ) -> ClearAction? {
        guard case .enumPicker(let options, _) = kind, options.contains("") else { return nil }
        // The sentinel row selected...
        guard stringValue.isEmpty else { return nil }
        // ...over a key that actually HAS a stored value. An untouched sheet
        // on an absent key has nothing to clear, and `primedValue == nil`
        // means priming never ran.
        guard let primed = primedValue, !primed.isEmpty else { return nil }
        return capabilities.hasConfigUnset ? .unset : .belowFloor
    }

    @MainActor
    private func save() async {
        saveError = nil
        // The clear gesture comes FIRST and returns: `valueToWrite` answers
        // `nil` for it, which would otherwise dismiss the sheet having done
        // nothing (the P28/P29 sentinel rule — it must never write `''`).
        if let clear = Self.clearAction(
            kind: spec.kind,
            stringValue: stringValue,
            primedValue: primedValue,
            capabilities: capabilities
        ) {
            switch clear {
            case .belowFloor:
                saveError = HermesConfigUnset.belowFloorHint(key: spec.key)
            case .unset:
                do {
                    try await vm.unsetValue(key: spec.key)
                    onDismiss()
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
            return
        }
        guard let value = Self.valueToWrite(
            kind: spec.kind,
            stringValue: stringValue,
            primedValue: primedValue
        ) else {
            onDismiss()
            dismiss()
            return
        }
        do {
            try await vm.saveValue(key: spec.key, value: value)
            onDismiss()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Describes a single editable Hermes config key. Centralized so the
/// SettingsView can iterate a curated list rather than hard-coding
/// one row per field. Add new entries here when a field graduates to
/// on-the-go-editable.
struct SettingSpec: Identifiable, Hashable {
    let key: String              // "model.default", "agent.approval_mode", ...
    let displayName: String      // "Default model", "Approval mode", ...
    let helpText: String         // Sentence for the sheet footer.
    let kind: Kind

    var id: String { key }

    enum Kind: Hashable {
        case text
        case toggle
        /// `labels` renders an option as prose without changing the scalar
        /// that gets written — used by the ABSENT-key sentinel (`""`), whose
        /// label names the mode the connected host would run.
        case enumPicker(options: [String], labels: [String: String] = [:])
        /// `zeroLabel` renders 0 as a word instead of the digit — used by
        /// `agent.max_turns`, where Hermes v0.20.5's `resolve_turn_limit`
        /// reads 0 as "unlimited".
        case number(range: ClosedRange<Int>, zeroLabel: String? = nil)

        /// The scalar an UNTOUCHED sheet holds after priming from
        /// `currentValue` — i.e. the value Save must NOT write, because the
        /// user did not choose it.
        ///
        /// Several of these keys are read as ABSENCE SENTINELS: an empty
        /// `approvals.mode` means "no key, the host decides" (`smart` on
        /// v0.19+), and `agent.max_turns` reports the RESOLVED host default
        /// ("Unlimited" / 500 / 60) rather than a stored number. Priming a
        /// concrete option over an absent value and then writing it pins a
        /// default the user never picked — the bug P20 fixed on the Mac and
        /// left live here. So an absent value primes the sentinel row when
        /// there is one, and never `options.first`.
        func primedScalar(currentValue: String) -> String {
            switch self {
            case .toggle:
                // One boolish helper, as everywhere else (P18) — `currentValue`
                // is normally a rendered `Bool`, but accepting the YAML
                // spellings costs nothing and cannot read one as OFF.
                return (HermesYAML.boolishValue(currentValue) ?? false) ? "true" : "false"
            case .enumPicker(let options, _):
                if options.contains(currentValue) { return currentValue }
                return currentValue.isEmpty ? "" : (options.first ?? "")
            case .number:
                return String(Int(currentValue) ?? 0)
            case .text:
                return currentValue
            }
        }
    }

    /// Capability-adjusted copy of this spec.
    ///
    /// `agent.max_turns`: v0.20.5 flipped the default from 500 to unlimited
    /// and accepts 0 as unlimited, so the stepper's low end opens to 0 on
    /// those hosts. Pre-v0.20.5 hosts have no unlimited semantics, so the
    /// floor stays 1 there and Scarf never writes a 0 they cannot resolve.
    /// The old 500 ceiling was the *default*, not a limit; it is raised to
    /// 1000 to match the macOS stepper.
    func resolved(capabilities: HermesCapabilities) -> SettingSpec {
        // `approvals.mode`: the leading empty row is the ABSENT key, rendered
        // as the mode the connected host would run — the same sentinel the
        // Mac picker carries (`AgentTab.swift`). Without it the sheet has no
        // way to represent "no key", so Save pins one.
        if key == "approvals.mode" {
            let hostDefault = HermesConfig.approvalModeHostDefaultLabel(capabilities: capabilities)
            return SettingSpec(
                key: key,
                displayName: displayName,
                helpText: helpText,
                kind: .enumPicker(
                    options: [""] + HermesApprovalMode.options,
                    labels: ["": hostDefault]
                )
            )
        }
        guard key == "agent.max_turns" else { return self }
        return SettingSpec(
            key: key,
            displayName: displayName,
            helpText: capabilities.isV0205OrLater
                ? "Ceiling on assistant replies per prompt. Higher = agent can chain more tool calls before stopping. 0 = Unlimited, which is the Hermes default from v0.20.5."
                : helpText,
            kind: .number(
                range: capabilities.isV0205OrLater ? 0...1000 : 1...1000,
                zeroLabel: "Unlimited"
            )
        )
    }

    /// Curated v1 list. Ordered as it should appear in Settings.
    static let v1Editable: [SettingSpec] = [
        SettingSpec(
            key: "model.default",
            displayName: "Default model",
            helpText: "Used by every new chat unless overridden. Needs to be a model the selected provider actually serves.",
            kind: .text
        ),
        SettingSpec(
            key: "model.provider",
            displayName: "Provider",
            helpText: "Which backend Hermes routes prompts to. Switch to a provider you're authenticated against.",
            kind: .text
        ),
        SettingSpec(
            key: "approvals.mode",
            displayName: "Approval mode",
            // `auto` and `yolo` were never `approvals.mode` members at ANY
            // tag — `_VALID_MODES = ("manual", "smart", "off")`
            // (`tools/approval_context.py:197` @ v2026.9.7), and `auto` is
            // the docstring's own example of a value that warns and falls
            // back to `manual`. The set comes from `HermesApprovalMode` so
            // this sheet and the Mac picker cannot drift.
            helpText: "How agents handle risky tool calls. Manual prompts you; smart lets a guardian model decide; off never asks.",
            kind: .enumPicker(options: HermesApprovalMode.options)
        ),
        SettingSpec(
            key: "agent.max_turns",
            displayName: "Max turns",
            helpText: "Ceiling on assistant replies per prompt. Higher = agent can chain more tool calls before stopping.",
            kind: .number(range: 1...1000, zeroLabel: "Unlimited")
        ),
        SettingSpec(
            key: "display.show_cost",
            displayName: "Show cost",
            helpText: "Render per-prompt cost totals in the chat window.",
            kind: .toggle
        ),
        SettingSpec(
            key: "display.show_reasoning",
            displayName: "Show reasoning",
            helpText: "Expand the thinking-block above each assistant reply.",
            kind: .toggle
        ),
        SettingSpec(
            key: "display.streaming",
            displayName: "Stream replies",
            helpText: "Show the assistant's reply token-by-token as it comes in.",
            kind: .toggle
        ),
    ]
}
