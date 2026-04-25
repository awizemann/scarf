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
        case .enumPicker(let options):
            Picker(spec.displayName, selection: $enumValue) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.segmented)
        case .number(let range):
            Stepper(value: $numberValue, in: range, step: 1) {
                Text("\(numberValue)")
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
        case .toggle, .enumPicker, .number: return true
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

    private func primeFromCurrent() {
        switch spec.kind {
        case .toggle:
            boolValue = (currentValue.lowercased() == "true" || currentValue.lowercased() == "yes")
        case .enumPicker(let options):
            enumValue = options.contains(currentValue) ? currentValue : (options.first ?? "")
        case .number:
            numberValue = Int(currentValue) ?? 0
        case .text:
            textValue = currentValue
        }
    }

    @MainActor
    private func save() async {
        saveError = nil
        do {
            try await vm.saveValue(key: spec.key, value: stringValue)
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
        case enumPicker(options: [String])
        case number(range: ClosedRange<Int>)
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
            helpText: "How agents handle risky tool calls. Manual prompts you; auto approves reads; yolo approves writes too.",
            kind: .enumPicker(options: ["manual", "auto", "yolo"])
        ),
        SettingSpec(
            key: "agent.max_turns",
            displayName: "Max turns",
            helpText: "Ceiling on assistant replies per prompt. Higher = agent can chain more tool calls before stopping.",
            kind: .number(range: 1...500)
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
