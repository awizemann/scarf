import SwiftUI
import AppKit

/// Shared form-row components used across the Settings tabs. Extracting these keeps
/// individual tab views small and avoids triggering SwiftUI's type-checker timeout
/// on large view bodies (per project guidance in CLAUDE.md).

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(spacing: 1) {
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            if isEditing {
                TextField(label, text: $text, onCommit: {
                    if text != value { onCommit(text) }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button("Cancel") { isEditing = false }
                    .controlSize(.mini)
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Edit") {
                    text = value
                    isEditing = true
                }
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            if isEditing {
                TextField(label, text: $text, onCommit: {
                    if text != value { onCommit(text) }
                    isEditing = false
                    isRevealed = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button("Cancel") {
                    isEditing = false
                    isRevealed = false
                }
                .controlSize(.mini)
            } else {
                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct ToggleRow: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text("\(value)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .leading)
            Stepper("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
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
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .leading)
            Stepper("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct ReadOnlyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct PathRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}
