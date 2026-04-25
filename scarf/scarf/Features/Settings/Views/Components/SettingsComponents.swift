import SwiftUI
import AppKit
import ScarfDesign

/// Shared form-row components used across the Settings tabs. Tokens come
/// from ScarfDesign so light/dark resolves automatically and the rust
/// accent flows through any controls that reach for `Color.accentColor`.

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(ScarfColor.accent)
                Text(title)
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
            }
            VStack(spacing: 1) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .strokeBorder(ScarfColor.border, lineWidth: 1)
            )
        }
    }
}

private let settingsRowLabelWidth: CGFloat = 160

private struct SettingsRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 6)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}

private extension View {
    func settingsRowChrome() -> some View { modifier(SettingsRowChrome()) }
}

private struct SettingsRowLabel: View {
    let label: String
    var body: some View {
        Text(label)
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .frame(width: settingsRowLabelWidth, alignment: .trailing)
    }
}

struct EditableTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            if isEditing {
                TextField(label, text: $text, onCommit: {
                    if text != value { onCommit(text) }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .font(ScarfFont.monoSmall)
                Button("Cancel") { isEditing = false }
                    .controlSize(.mini)
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(value.isEmpty ? ScarfColor.foregroundFaint : ScarfColor.foregroundPrimary)
                Spacer()
                Button("Edit") {
                    text = value
                    isEditing = true
                }
                .controlSize(.mini)
            }
        }
        .settingsRowChrome()
    }
}

/// Masked text field for API keys, tokens, etc. Shows ••• until the user taps reveal.
struct SecretTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String = ""
    @State private var isEditing = false
    @State private var isRevealed = false

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            if isEditing {
                TextField(label, text: $text, onCommit: {
                    if text != value { onCommit(text) }
                    isEditing = false
                    isRevealed = false
                })
                .textFieldStyle(.roundedBorder)
                .font(ScarfFont.monoSmall)
                Button("Cancel") {
                    isEditing = false
                    isRevealed = false
                }
                .controlSize(.mini)
            } else {
                Text(displayValue)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(value.isEmpty ? ScarfColor.foregroundFaint : ScarfColor.foregroundPrimary)
                Spacer()
                if !value.isEmpty {
                    Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                        .controlSize(.mini)
                }
                Button("Edit") {
                    text = value
                    isEditing = true
                }
                .controlSize(.mini)
            }
        }
        .settingsRowChrome()
    }

    private var displayValue: String {
        if value.isEmpty { return "—" }
        if isRevealed { return value }
        let tail = value.suffix(4)
        return String(repeating: "•", count: max(0, min(12, value.count - 4))) + tail
    }
}

struct PickerRow: View {
    let label: String
    let selection: String
    let options: [String]
    let onChange: (String) -> Void

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Picker("", selection: Binding(
                get: { selection },
                set: { onChange($0) }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? "(none)" : option).tag(option)
                }
            }
            .frame(maxWidth: 250)
            Spacer()
        }
        .settingsRowChrome()
    }
}

struct ToggleRow: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(ScarfColor.accent)
            Spacer()
        }
        .settingsRowChrome()
    }
}

struct StepperRow: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let onChange: (Int) -> Void

    init(label: String, value: Int, range: ClosedRange<Int>, step: Int = 1, onChange: @escaping (Int) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.step = step
        self.onChange = onChange
    }

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Text("\(value)")
                .font(ScarfFont.monoSmall)
                .frame(width: 70, alignment: .leading)
            Stepper("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
            .labelsHidden()
            Spacer()
        }
        .settingsRowChrome()
    }
}

/// Double stepper that increments by a fractional step (e.g. 0.05 for thresholds).
struct DoubleStepperRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(ScarfFont.monoSmall)
                .frame(width: 70, alignment: .leading)
            Stepper("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
            .labelsHidden()
            Spacer()
        }
        .settingsRowChrome()
    }
}

struct ReadOnlyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Text(value.isEmpty ? "—" : value)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(value.isEmpty ? ScarfColor.foregroundFaint : ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .settingsRowChrome()
    }
}

struct PathRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack {
            SettingsRowLabel(label: label)
            Text(path)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .buttonStyle(.plain)
        }
        .settingsRowChrome()
    }
}
