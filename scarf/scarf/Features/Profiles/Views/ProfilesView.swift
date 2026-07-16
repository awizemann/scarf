import SwiftUI
import ScarfCore
import ScarfDesign
import AppKit
import UniformTypeIdentifiers

struct ProfilesView: View {
    @State private var viewModel: ProfilesViewModel
    @State private var selected: HermesProfile?
    @State private var showCreate = false
    @State private var createName = ""
    @State private var createCloneConfig = true
    @State private var createCloneAll = false
    /// v0.13+ `--no-skills` toggle. Mutually exclusive with `--clone-all`
    /// at the UX layer (Decision H from the WS-7 plan): a full clone
    /// copies skills wholesale — `--no-skills` would be a contradiction.
    @State private var createNoSkills = false
    @State private var showRename = false
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// This window's client-side "viewing profile" (#126). Present for every
    /// window; only meaningful on remote windows, where selecting a profile
    /// re-points the window's `HERMES_HOME` without touching the server's
    /// `active_profile`. Optional so previews/tests without the environment
    /// don't trap.
    @Environment(WindowProfileScope.self) private var profileScope: WindowProfileScope?

    init(context: ServerContext) {
        _viewModel = State(initialValue: ProfilesViewModel(context: context))
    }

    /// Whether this window is currently *viewing* `profile` (remote only —
    /// distinct from `profile.isActive`, which is the server's active profile).
    private func isViewing(_ profile: HermesProfile) -> Bool {
        viewModel.context.isRemote && (profileScope?.isViewing(profile.name) ?? false)
    }

    @State private var renameTarget: HermesProfile?
    @State private var renameNewName = ""
    @State private var pendingDelete: HermesProfile?
    /// Profile the user has clicked "Switch & Relaunch" on, awaiting
    /// confirmation before we run `hermes profile use` and exit. The
    /// confirmation step is load-bearing — relaunching closes every
    /// open Scarf window in the process, so the user needs an explicit
    /// agreement.
    @State private var pendingSwitch: HermesProfile?
    /// Remote-import sheet visibility. Local imports use `NSOpenPanel`
    /// inline; remote imports route through `RemotePathSheet`
    /// because the zip the user wants to import lives on the remote
    /// host (that's where `hermes profile export` produced it), and
    /// `NSOpenPanel` can only browse the local Mac.
    @State private var showRemoteImportSheet = false
    /// When non-nil, the export button on the named profile presents
    /// `RemotePathSheet` to ask for an output path on the
    /// remote host. Local exports continue to use `NSSavePanel`.
    @State private var pendingRemoteExport: HermesProfile?

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Profiles",
                subtitle: "Named config bundles you can swap between."
            )
            HSplitView {
                listSection
                    .frame(minWidth: 260, idealWidth: 300)
                detailSection
                    .frame(minWidth: 400)
            }
        }
        .background(ScarfColor.backgroundPrimary)
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
        .confirmationDialog(
            pendingSwitch.map { "Switch to '\($0.name)' and relaunch Scarf?" } ?? "",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })
        ) {
            Button("Switch & Relaunch") {
                if let profile = pendingSwitch { viewModel.switchAndRelaunch(profile) }
                pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        } message: {
            Text("All Scarf windows will close and reopen. Unsaved chat input may be lost.")
        }
        .sheet(isPresented: $showRemoteImportSheet) {
            RemotePathSheet(
                context: viewModel.context,
                title: "Import profile",
                prompt: "Enter the path to a profile `.zip` on \(viewModel.context.displayName).",
                placeholder: "e.g. ~/profiles/my-profile.zip",
                confirmLabel: "Import",
                mode: .existingFile,
                expectedExtension: "zip",
                extensionNote: "Profile import expects a zip archive.",
                onCancel: { showRemoteImportSheet = false },
                onConfirm: { path in
                    showRemoteImportSheet = false
                    viewModel.import(from: path)
                }
            )
        }
        .sheet(item: $pendingRemoteExport) { profile in
            RemotePathSheet(
                context: viewModel.context,
                title: "Export profile '\(profile.name)'",
                prompt: "Enter the destination path on \(viewModel.context.displayName) where the `.zip` should be written.",
                placeholder: "e.g. ~/\(profile.name)-profile.zip",
                confirmLabel: "Export",
                mode: .writableFile(initialName: "\(profile.name)-profile.zip"),
                expectedExtension: "zip",
                extensionNote: "The export command writes a zip archive.",
                onCancel: { pendingRemoteExport = nil },
                onConfirm: { path in
                    pendingRemoteExport = nil
                    viewModel.export(profile, to: path)
                }
            )
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
                    createName = ""; createCloneConfig = true; createCloneAll = false; createNoSkills = false
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .controlSize(.small)
                Button {
                    if viewModel.context.isRemote {
                        // The zip lives on the remote (where `hermes profile
                        // export` produced it). NSOpenPanel can only browse
                        // the user's Mac, so route through a remote-path
                        // input sheet instead.
                        showRemoteImportSheet = true
                    } else {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.zip]
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.import(from: url.path)
                        }
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
                    let viewing = isViewing(profile)
                    HStack {
                        Image(systemName: viewing ? "eye.fill" : (profile.isActive ? "checkmark.circle.fill" : "person.crop.square"))
                            .foregroundStyle(viewing ? Color.accentColor : (profile.isActive ? .green : .secondary))
                        Text(profile.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        // On remote windows "viewing" (this window's scope) is
                        // the primary badge; "active" (the server's own active
                        // profile) is shown when it differs. Local windows only
                        // have the "active" concept.
                        if viewing {
                            Text("viewing")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                        } else if profile.isActive {
                            Text("active")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(profile.id)
                    .contextMenu {
                        if viewModel.context.isRemote {
                            Button("View this profile") { profileScope?.select(profile.name) }
                                .disabled(viewing)
                            Button("Set as server's active profile") { viewModel.switchTo(profile) }
                                .disabled(profile.isActive)
                        } else {
                            Button("Switch & Relaunch") { pendingSwitch = profile }
                                .disabled(profile.isActive)
                            Button("Set Active (no relaunch)") { viewModel.switchTo(profile) }
                                .disabled(profile.isActive)
                        }
                        Divider()
                        Button("Rename") {
                            renameTarget = profile
                            renameNewName = profile.name
                        }
                        Button("Export…") {
                            if viewModel.context.isRemote {
                                // Exporting a remote profile must write to a
                                // remote path — NSSavePanel would write to
                                // the user's Mac, leaving the remote
                                // profile zip nowhere on the host where
                                // anyone can use it.
                                pendingRemoteExport = profile
                            } else {
                                let panel = NSSavePanel()
                                panel.allowedContentTypes = [.zip]
                                panel.nameFieldStringValue = "\(profile.name)-profile.zip"
                                if panel.runModal() == .OK, let url = panel.url {
                                    viewModel.export(profile, to: url.path)
                                }
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
                            detailSubtitle(profile)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        detailPrimaryAction(profile)
                    }
                    detailInfoBanner(profile)
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

    @ViewBuilder
    private func detailSubtitle(_ profile: HermesProfile) -> some View {
        if viewModel.context.isRemote {
            if isViewing(profile) {
                Text("Viewing in this window")
            } else if profile.isActive {
                Text("Server's active profile")
            } else {
                Text("Not viewing")
            }
        } else {
            Text(profile.isActive ? "Active profile" : "Inactive")
        }
    }

    @ViewBuilder
    private func detailPrimaryAction(_ profile: HermesProfile) -> some View {
        if viewModel.context.isRemote {
            if isViewing(profile) {
                Label("Viewing", systemImage: "eye.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    profileScope?.select(profile.name)
                } label: {
                    Label("View this profile", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Show this profile's sessions, memory, cron, and chat in this window — without changing the server's active profile.")
            }
        } else if !profile.isActive {
            Button {
                pendingSwitch = profile
            } label: {
                Label("Switch & Relaunch", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Set as active profile and relaunch Scarf so every tab loads from \(profile.name)")
        }
    }

    @ViewBuilder
    private func detailInfoBanner(_ profile: HermesProfile) -> some View {
        if viewModel.context.isRemote {
            if !isViewing(profile) { profileViewInfo }
        } else if !profile.isActive {
            profileSwitchInfo
        }
    }

    private var profileViewInfo: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("**View this profile** re-points this window at the profile's `~/.hermes/profiles/<name>/` data — Sessions, Memory, Cron, and Chat all reload — without changing the server's active profile (what the agent, cron, and terminal use). To change the server's active profile instead, use **Set as server's active profile** from the list's context menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var profileSwitchInfo: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("**Switch & Relaunch** sets this as the active profile (writes `~/.hermes/active_profile`) and relaunches Scarf so every tab — Webhooks, Sessions, SOUL.md, Memory — reloads from the new profile's `~/.hermes/profiles/<name>/` directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(ScarfColor.backgroundSecondary)
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
            if capabilitiesStore?.capabilities.hasProfileNoSkills ?? false {
                Toggle("Empty profile (no skills)", isOn: $createNoSkills)
                    .disabled(createCloneAll)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCreate = false }
                Button("Create") {
                    viewModel.create(
                        name: createName,
                        cloneConfig: createCloneConfig,
                        cloneAll: createCloneAll,
                        // Defensive: if the toggle isn't visible (pre-v0.13)
                        // the state is always `false`, but read it through
                        // the capability gate anyway so a stale state value
                        // can't sneak `--no-skills` to a CLI that doesn't
                        // know it.
                        noSkills: (capabilitiesStore?.capabilities.hasProfileNoSkills ?? false) ? createNoSkills : false
                    )
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
