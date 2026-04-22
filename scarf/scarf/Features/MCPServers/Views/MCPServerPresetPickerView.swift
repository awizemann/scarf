import SwiftUI
import ScarfCore

struct MCPServerPresetPickerView: View {
    let viewModel: MCPServersViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: MCPServerPreset?
    @State private var nameOverride: String = ""
    @State private var pathArg: String = ""
    @State private var envValues: [String: String] = [:]
    @State private var showSecrets: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let preset = selectedPreset {
                configureStep(preset: preset)
            } else {
                galleryStep
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack {
            if selectedPreset != nil {
                Button {
                    selectedPreset = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                (selectedPreset.map { Text(verbatim: $0.displayName) } ?? Text("Add from Preset"))
                    .font(.headline)
                (selectedPreset.map { Text(verbatim: $0.description) } ?? Text("Pick an MCP server to add."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var galleryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(MCPServerPreset.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category)
                            .font(.subheadline.bold())
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 200), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(MCPServerPreset.byCategory(category)) { preset in
                                presetCard(preset)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func presetCard(_ preset: MCPServerPreset) -> some View {
        Button {
            selectedPreset = preset
            nameOverride = preset.id
            pathArg = ""
            envValues = Dictionary(uniqueKeysWithValues: preset.requiredEnvKeys.map { ($0, "") })
            for key in preset.optionalEnvKeys {
                envValues[key] = ""
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.iconSystemName)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: preset.displayName)
                        .font(.body.bold())
                    Spacer()
                    Image(systemName: preset.transport == .http ? "network" : "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: preset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !preset.requiredEnvKeys.isEmpty {
                    Text("Requires: \(preset.requiredEnvKeys.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func configureStep(preset: MCPServerPreset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nameField
                if let prompt = preset.pathArgPrompt {
                    pathArgField(prompt: prompt)
                }
                if !preset.requiredEnvKeys.isEmpty || !preset.optionalEnvKeys.isEmpty {
                    envFields(preset: preset)
                }
                if !preset.docsURL.isEmpty {
                    Link(destination: URL(string: preset.docsURL) ?? URL(string: "https://modelcontextprotocol.io")!) {
                        Label("Docs", systemImage: "book")
                            .font(.caption)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Server") {
                        submit(preset: preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit(preset: preset))
                }
            }
            .padding()
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Server name")
                .font(.caption.bold())
            TextField("e.g. github", text: $nameOverride)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("Used as the YAML key. Lowercase, no spaces.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func pathArgField(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prompt)
                .font(.caption.bold())
            TextField(prompt, text: $pathArg)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func envFields(preset: MCPServerPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment Variables")
                    .font(.caption.bold())
                Spacer()
                Toggle("Show values", isOn: $showSecrets)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            ForEach(preset.requiredEnvKeys, id: \.self) { key in
                envRow(key: key, required: true)
            }
            ForEach(preset.optionalEnvKeys, id: \.self) { key in
                envRow(key: key, required: false)
            }
        }
    }

    private func envRow(key: String, required: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                if required {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 240, alignment: .leading)
            if showSecrets {
                TextField("value", text: bindingForEnv(key))
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField("value", text: bindingForEnv(key))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func bindingForEnv(_ key: String) -> Binding<String> {
        Binding(
            get: { envValues[key] ?? "" },
            set: { envValues[key] = $0 }
        )
    }

    private func canSubmit(preset: MCPServerPreset) -> Bool {
        let trimmedName = nameOverride.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        if preset.pathArgPrompt != nil && pathArg.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        for key in preset.requiredEnvKeys {
            if (envValues[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    private func submit(preset: MCPServerPreset) {
        let finalName = nameOverride.trimmingCharacters(in: .whitespaces)
        let finalPath = pathArg.trimmingCharacters(in: .whitespaces)
        let trimmedEnv = envValues.reduce(into: [String: String]()) { acc, pair in
            let trimmedValue = pair.value.trimmingCharacters(in: .whitespaces)
            if !trimmedValue.isEmpty { acc[pair.key] = pair.value }
        }
        viewModel.addFromPreset(
            preset: preset,
            name: finalName,
            pathArg: preset.pathArgPrompt != nil ? finalPath : nil,
            envValues: trimmedEnv
        )
        dismiss()
    }
}
