import SwiftUI
import ScarfCore

struct MCPServerAddCustomView: View {
    let viewModel: MCPServersViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var transport: MCPTransport = .stdio
    @State private var command: String = "npx"
    @State private var argsText: String = ""
    @State private var url: String = ""
    @State private var auth: String = "none"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Custom MCP Server")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionBox(title: "Identity") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name").font(.caption.bold())
                            TextField("my_server", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Text("Becomes the key under mcp_servers: in config.yaml.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    sectionBox(title: "Transport") {
                        Picker("", selection: $transport) {
                            ForEach(MCPTransport.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if transport == .stdio {
                        stdioSection
                    } else {
                        httpSection
                    }
                    Text("Env vars, headers, and tool filters can be edited after the server is added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private var stdioSection: some View {
        sectionBox(title: "Command") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command").font(.caption.bold())
                    TextField("npx", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Args (one per line)").font(.caption.bold())
                    TextEditor(text: $argsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
                        )
                }
            }
        }
    }

    private var httpSection: some View {
        sectionBox(title: "Endpoint") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(.caption.bold())
                    TextField("https://...", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auth").font(.caption.bold())
                    Picker("", selection: $auth) {
                        Text("None").tag("none")
                        Text("OAuth 2.1").tag("oauth")
                        Text("Header").tag("header")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var canSubmit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        switch transport {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let args = argsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resolvedAuth: String? = (auth == "none") ? nil : auth
        viewModel.addCustom(
            name: trimmedName,
            transport: transport,
            command: command.trimmingCharacters(in: .whitespaces),
            args: args,
            url: url.trimmingCharacters(in: .whitespaces),
            auth: resolvedAuth
        )
        dismiss()
    }

    @ViewBuilder
    private func sectionBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
