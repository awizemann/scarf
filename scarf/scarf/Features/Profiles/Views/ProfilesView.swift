import SwiftUI
import ScarfCore
import AppKit
import UniformTypeIdentifiers

struct ProfilesView: View {
    @State private var viewModel: ProfilesViewModel
    @State private var selected: HermesProfile?
    @State private var showCreate = false
    @State private var createName = ""
    @State private var createCloneConfig = true
    @State private var createCloneAll = false
    @State private var showRename = false

    init(context: ServerContext) {
        _viewModel = State(initialValue: ProfilesViewModel(context: context))
    }

    @State private var renameTarget: HermesProfile?
    @State private var renameNewName = ""
    @State private var pendingDelete: HermesProfile?

    var body: some View {
        HSplitView {
            listSection
                .frame(minWidth: 260, idealWidth: 300)
            detailSection
                .frame(minWidth: 400)
        }
        .navigationTitle("Profiles")
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showCreate) { createSheet }
        .sheet(isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            renameSheet
        }
        .confirmationDialog(
            pendingDelete.map { "Delete profile '\($0.name)'?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete { viewModel.delete(profile) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the profile directory and all data within it. This cannot be undone.")
        }
    }

    private var listSection: some View {
        VStack(spacing: 0) {
            HStack {
                if let msg = viewModel.message {
                    Label(msg, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    createName = ""; createCloneConfig = true; createCloneAll = false
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .controlSize(.small)
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.zip]
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.import(from: url.path)
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()
            List(selection: Binding(
                get: { selected?.id },
                set: { id in
                    if let id, let profile = viewModel.profiles.first(where: { $0.id == id }) {
                        selected = profile
                        viewModel.showDetail(profile)
                    }
                }
            )) {
                ForEach(viewModel.profiles) { profile in
                    HStack {
                        Image(systemName: profile.isActive ? "checkmark.circle.fill" : "person.crop.square")
                            .foregroundStyle(profile.isActive ? .green : .secondary)
                        Text(profile.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if profile.isActive {
                            Text("active")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Use") { viewModel.switchTo(profile) }
                            .disabled(profile.isActive)
                        Button("Rename") {
                            renameTarget = profile
                            renameNewName = profile.name
                        }
                        Button("Export…") {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.zip]
                            panel.nameFieldStringValue = "\(profile.name)-profile.zip"
                            if panel.runModal() == .OK, let url = panel.url {
                                viewModel.export(profile, to: url.path)
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { pendingDelete = profile }
                            .disabled(profile.isActive)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if viewModel.profiles.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView("No Profiles", systemImage: "person.2.crop.square.stack", description: Text("Create a profile to isolate config and skills."))
                }
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        if let profile = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.square.filled.and.at.rectangle")
                            .font(.title)
                        VStack(alignment: .leading) {
                            Text(profile.name).font(.title2.bold())
                            (profile.isActive ? Text("Active profile") : Text("Inactive"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !profile.isActive {
                            Button {
                                viewModel.switchTo(profile)
                            } label: {
                                Label("Switch to This Profile", systemImage: "arrow.triangle.swap")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    if !profile.isActive {
                        profileSwitchWarning
                    }
                    SettingsSection(title: "Details", icon: "info.circle") {
                        if !profile.path.isEmpty {
                            ReadOnlyRow(label: "Path", value: profile.path)
                        }
                    }
                    if !viewModel.detailOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("hermes profile show")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(viewModel.detailOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView("Select a Profile", systemImage: "person.2.crop.square.stack", description: Text("Choose a profile to inspect."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var profileSwitchWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Switching the active profile changes the `~/.hermes` directory hermes uses. Restart Scarf after switching so it re-reads from the new profile's files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Profile").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. experimental", text: $createName)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Clone config, .env, SOUL.md from active profile", isOn: $createCloneConfig)
                .disabled(createCloneAll)
            Toggle("Full copy of active profile (all state)", isOn: $createCloneAll)
            HStack {
                Spacer()
                Button("Cancel") { showCreate = false }
                Button("Create") {
                    viewModel.create(name: createName, cloneConfig: createCloneConfig, cloneAll: createCloneAll)
                    showCreate = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(createName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 240)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Profile").font(.headline)
            if let target = renameTarget {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New name for '\(target.name)'").font(.caption).foregroundStyle(.secondary)
                    TextField("new-name", text: $renameNewName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") {
                    if let target = renameTarget {
                        viewModel.rename(target, to: renameNewName)
                    }
                    renameTarget = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameNewName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 180)
    }
}
