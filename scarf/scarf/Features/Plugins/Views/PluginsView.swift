import SwiftUI

struct PluginsView: View {
    @State private var viewModel: PluginsViewModel
    @State private var installIdentifier = ""
    @State private var showInstall = false
    @State private var pendingRemove: HermesPlugin?

    init(context: ServerContext) {
        _viewModel = State(initialValue: PluginsViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isLoading && viewModel.plugins.isEmpty {
                ProgressView().padding()
            } else if viewModel.plugins.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Plugins")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading plugins…",
            isEmpty: viewModel.plugins.isEmpty
        )
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showInstall) { installSheet }
        .confirmationDialog(
            pendingRemove.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let plugin = pendingRemove { viewModel.remove(plugin) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
    }

    private var header: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                installIdentifier = ""
                showInstall = true
            } label: {
                Label("Install", systemImage: "plus")
            }
            .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No plugins installed")
                .foregroundStyle(.secondary)
            Text("Plugins extend hermes with custom tools, providers, or memory backends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Install a Plugin") {
                installIdentifier = ""
                showInstall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.plugins) { plugin in
                    row(plugin)
                }
            }
            .padding()
        }
    }

    private func row(_ plugin: HermesPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: plugin.enabled ? "app.badge.checkmark.fill" : "app.badge")
                .foregroundStyle(plugin.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                    if !plugin.version.isEmpty {
                        Text(plugin.version)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !plugin.source.isEmpty {
                    Text(plugin.source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button(plugin.enabled ? "Disable" : "Enable") {
                if plugin.enabled { viewModel.disable(plugin) } else { viewModel.enable(plugin) }
            }
            .controlSize(.small)
            Button("Update") { viewModel.update(plugin) }
                .controlSize(.small)
            Button("Remove", role: .destructive) { pendingRemove = plugin }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Plugin")
                .font(.headline)
            Text("Provide a Git URL (https://github.com/...) or a shorthand like `owner/repo`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("github.com/owner/plugin-repo  or  owner/repo", text: $installIdentifier)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { showInstall = false }
                Button("Install") {
                    viewModel.install(installIdentifier)
                    showInstall = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 200)
    }
}
