import SwiftUI

/// The configure form rendered for template install + post-install
/// editing. One row per schema field; controls dispatch by field type.
/// Commit button returns the finalized values via `onCommit` — in
/// install mode the caller stashes them in the install plan; in edit
/// mode the caller writes them straight to `<project>/.scarf/config.json`.
struct TemplateConfigSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var viewModel: TemplateConfigViewModel
    let title: LocalizedStringKey
    let commitLabel: LocalizedStringKey
    /// In install mode the caller passes the planned `ProjectEntry`
    /// (project dir path is the unique key for the Keychain secret).
    /// In edit mode the VM already holds the project; pass `nil` here.
    let project: ProjectEntry?
    let onCommit: ([String: TemplateConfigValue]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                // `.frame(maxWidth: .infinity, alignment: .leading)` is
                // load-bearing: without it, SwiftUI resolves width
                // bottom-up and an unbreakable token in a child (e.g. a
                // raw URL inside a field description rendered via
                // AttributedString markdown) sets the whole VStack's
                // ideal width to that token's length. ScrollView's
                // content then exceeds the sheet's viewport, the outer
                // `.frame(minWidth: 560)` grows to content width, and
                // the window clips the result with labels cut off on
                // the left + URL spilling off the right. With the
                // explicit maxWidth, the ScrollView's offered width
                // propagates down and the description Text's
                // `.fixedSize(horizontal: false, vertical: true)`
                // wraps at whitespace boundaries as intended.
                VStack(alignment: .leading, spacing: 18) {
                    if viewModel.schema.fields.isEmpty {
                        ContentUnavailableView(
                            "No fields",
                            systemImage: "slider.horizontal.3",
                            description: Text("This template has no configuration fields.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(viewModel.schema.fields) { field in
                            fieldRow(field)
                        }
                    }
                    if let rec = viewModel.schema.modelRecommendation {
                        modelRecommendation(rec)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Header / footer

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(viewModel.templateId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") {
                // Caller owns dismissal — this view is used both as a
                // standalone sheet (ConfigEditorSheet, where the caller
                // wants dismissal) AND inlined inside the install sheet
                // (TemplateInstallSheet.configureView, where calling
                // .dismiss here would tear down the OUTER install sheet
                // and abort the flow before .planned is reached).
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button(commitLabel) {
                if let finalized = viewModel.commit(project: project) {
                    onCommit(finalized)
                }
                // Same dismissal-is-caller's-responsibility rule as
                // Cancel — inside the install sheet, onCommit transitions
                // stage to .planned and the outer view re-renders to
                // show the preview. In the edit sheet, onCommit
                // transitions the editor VM and its state machine
                // handles dismissal via the success view's Done button.
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: - Field rows

    @ViewBuilder
    private func fieldRow(_ field: TemplateConfigField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(field.label).font(.headline)
                if field.required {
                    Text("*")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(field.type.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let description = field.description, !description.isEmpty {
                // Inline markdown so descriptions can include
                // `[Create one](https://…)`-style links to token
                // generation pages, **bold** emphasis on important
                // prerequisites, etc. Raw URLs (not wrapped in
                // markdown link syntax) will still render but can't
                // word-break mid-token — keep the parent maxWidth
                // constraint below so a rogue raw URL wraps cleanly
                // instead of expanding the entire sheet.
                TemplateMarkdown.inlineText(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control(for: field)
            if let err = viewModel.errors[field.key] {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        // maxWidth: .infinity forces this row to span the column's
        // full width so its internal description Text wraps instead
        // of expanding the outer VStack when a description contains
        // a long unbreakable token (raw URL, path, etc.). See the
        // comment on the parent ScrollView's inner VStack.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.secondary)
        )
    }

    @ViewBuilder
    private func control(for field: TemplateConfigField) -> some View {
        switch field.type {
        case .string:
            StringControl(
                value: stringBinding(for: field),
                placeholder: field.placeholder
            )
        case .text:
            TextControl(value: stringBinding(for: field))
        case .number:
            NumberControl(value: numberBinding(for: field))
        case .bool:
            BoolControl(label: field.label, value: boolBinding(for: field))
        case .enum:
            EnumControl(
                options: field.options ?? [],
                value: stringBinding(for: field)
            )
        case .list:
            ListControl(items: listBinding(for: field))
        case .secret:
            SecretControl(
                fieldKey: field.key,
                placeholder: field.placeholder,
                viewModel: viewModel
            )
        }
    }

    // MARK: - Model recommendation panel

    private func modelRecommendation(_ rec: TemplateModelRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recommended model", systemImage: "lightbulb")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(rec.preferred).font(.body.monospaced())
            if let rationale = rec.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alts = rec.alternatives, !alts.isEmpty {
                Text("Also works: \(alts.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Scarf doesn't auto-switch your active model. Change it in Settings if you'd like.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    // MARK: - Binding helpers (threading the VM through typed lenses)

    private func stringBinding(for field: TemplateConfigField) -> Binding<String> {
        Binding(
            get: {
                if case .string(let s) = viewModel.values[field.key] { return s }
                return ""
            },
            set: { viewModel.setString(field.key, $0) }
        )
    }

    private func numberBinding(for field: TemplateConfigField) -> Binding<Double> {
        Binding(
            get: {
                if case .number(let n) = viewModel.values[field.key] { return n }
                return 0
            },
            set: { viewModel.setNumber(field.key, $0) }
        )
    }

    private func boolBinding(for field: TemplateConfigField) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let b) = viewModel.values[field.key] { return b }
                return false
            },
            set: { viewModel.setBool(field.key, $0) }
        )
    }

    private func listBinding(for field: TemplateConfigField) -> Binding<[String]> {
        Binding(
            get: {
                if case .list(let items) = viewModel.values[field.key] { return items }
                return []
            },
            set: { viewModel.setList(field.key, $0) }
        )
    }
}

// MARK: - Field controls

private struct StringControl: View {
    @Binding var value: String
    let placeholder: String?
    var body: some View {
        TextField(placeholder ?? "", text: $value)
            .textFieldStyle(.roundedBorder)
    }
}

private struct TextControl: View {
    @Binding var value: String
    var body: some View {
        TextEditor(text: $value)
            .font(.body.monospaced())
            .frame(minHeight: 80, maxHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.3))
            )
    }
}

private struct NumberControl: View {
    @Binding var value: Double
    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
    }
}

private struct BoolControl: View {
    let label: String
    @Binding var value: Bool
    var body: some View {
        Toggle(isOn: $value) {
            Text(value ? "Enabled" : "Disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EnumControl: View {
    let options: [TemplateConfigField.EnumOption]
    @Binding var value: String
    var body: some View {
        // Segmented for ≤ 4 options, dropdown otherwise — fits Scarf's
        // existing settings UI.
        if options.count <= 4 {
            Picker("", selection: $value) {
                ForEach(options) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Picker("", selection: $value) {
                ForEach(options) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
        }
    }
}

/// Variable-length list of string values. Each row is a text field
/// with an inline remove button; a + button adds a trailing row.
private struct ListControl: View {
    @Binding var items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("", text: Binding(
                        get: { i < items.count ? items[i] : "" },
                        set: { newValue in
                            guard i < items.count else { return }
                            items[i] = newValue
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        guard i < items.count else { return }
                        items.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(items.count <= 1)
                }
            }
            Button {
                items.append("")
            } label: {
                Label("Add", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Secret fields never echo the previously-stored value back. Instead
/// we render "(unchanged)" when a Keychain ref already exists and let
/// the user type over it if they want to replace. Empty input in edit
/// mode signals "remove this secret entirely."
private struct SecretControl: View {
    let fieldKey: String
    let placeholder: String?
    @Bindable var viewModel: TemplateConfigViewModel

    @State private var typedValue: String = ""
    @State private var isRevealed: Bool = false

    private var hasStoredRef: Bool {
        if case .keychainRef = viewModel.values[fieldKey] { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField(placeholder ?? "", text: $typedValue)
                    } else {
                        SecureField(placeholder ?? "", text: $typedValue)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onChange(of: typedValue) { _, new in
                    viewModel.setSecret(fieldKey, new)
                }
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide" : "Show while typing")
            }
            if hasStoredRef && typedValue.isEmpty {
                Text("Saved in Keychain — leave empty to keep the stored value.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !typedValue.isEmpty {
                Text("Will be saved to the Keychain on commit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
