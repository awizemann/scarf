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

    /// Content types for profile archives. `hermes profile export` writes
    /// gzipped tars only, so the panels must offer those — `.zip` made the
    /// save panel promise a file the CLI never wrote.
    ///
    /// `.gzip` covers `.gz`; the explicit `tar.gz` / `tgz` types are added
    /// when the system can resolve them so the panel accepts the double
    /// extension without the user fighting it.
    static let profileArchiveContentTypes: [UTType] = {
        var types: [UTType] = [.gzip]
        for identifier in ["org.gnu.gnu-zip-tar-archive"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        for ext in HermesProfileArchive.recognizedExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

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
    /// inline; remote imports route through `RemoteProfilePathSheet`
    /// because the zip the user wants to import lives on the remote
    /// host (that's where `hermes profile export` produced it), and
    /// `NSOpenPanel` can only browse the local Mac.
    @State private var showRemoteImportSheet = false

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
            RemoteProfilePathSheet(
                context: viewModel.context,
                title: "Import profile",
                prompt: "Enter the path to a profile `.tar.gz` on \(viewModel.context.displayName).",
                placeholder: "e.g. ~/profiles/my-profile.tar.gz",
                confirmLabel: "Import",
                onCancel: { showRemoteImportSheet = false },
                onConfirm: { path in
                    showRemoteImportSheet = false
                    viewModel.import(from: path)
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
                        // The archive lives on the remote (where `hermes
                        // profile export` produced it). NSOpenPanel can only
                        // browse the user's Mac, so route through a
                        // remote-path input sheet instead.
                        showRemoteImportSheet = true
                    } else {
                        let panel = NSOpenPanel()
                        // `import_profile` opens the path with `tarfile` —
                        // .zip was never a shape Hermes could read.
                        panel.allowedContentTypes = Self.profileArchiveContentTypes
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
                        // Redundant with the "viewing"/"active" badge on
                        // the same row.
                        Image(systemName: viewing ? "eye.fill" : (profile.isActive ? "checkmark.circle.fill" : "person.crop.square"))
                            .foregroundStyle(viewing ? Color.accentColor : (profile.isActive ? .green : .secondary))
                            .accessibilityHidden(true)
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
                    // Name plus state badge as one announcement.
                    .accessibilityElement(children: .combine)
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
                            // The export lands on this Mac whichever host
                            // Hermes runs on (gh#132) — remote contexts
                            // stream the archive down from a host-side
                            // scratch path. See RemoteProfileExport.
                            //
                            // `.tar.gz`, not `.zip`: `export_profile` always
                            // writes a gzipped tar and appends `.tar.gz` to
                            // whatever base it is given, so a `.zip`
                            // destination silently produced `….zip.tar.gz`.
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = Self.profileArchiveContentTypes
                            panel.nameFieldStringValue = HermesProfileArchive.suggestedFilename(for: profile.name)
                            if panel.runModal() == .OK, let url = panel.url {
                                viewModel.export(profile, to: url)
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
                    .accessibilityLabel("Name")
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
                        .accessibilityLabel("New name for '\(target.name)'")
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

/// Remote-path picker for profile **import**. Used when the active
/// `ServerContext` is `.ssh` — the zip the user wants to import lives on
/// the remote host, and `NSOpenPanel` can only browse the user's Mac. The
/// sheet takes a remote path string and verifies it (exists, is a file,
/// looks like a zip) via the active transport before handing it back.
/// Export stopped using this sheet in gh#132 — exports now stream down to
/// a local `NSSavePanel` destination (see `RemoteProfileExport`), which
/// also retired the write-path Verify and its gh#131 bug class.
private struct RemoteProfilePathSheet: View {
    let context: ServerContext
    let title: String
    let prompt: String
    let placeholder: String
    let confirmLabel: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var path: String = ""
    @State private var verification: Verification = .idle

    private enum Verification: Equatable {
        case idle
        case verifying
        case ok(String)
        case warn(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: path) { _, _ in
                        if verification != .idle { verification = .idle }
                    }
                Button("Verify") { Task { await verify() } }
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty
                              || verification == .verifying)
            }
            verificationBadge
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmLabel) {
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on \(context.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok(let detail):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(detail).font(.caption)
            }
        case .warn(let detail):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(detail).font(.caption)
            }
        }
    }

    private func verify() async {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        verification = .verifying
        let snapshot = context
        let result: Verification = await Task.detached {
            let transport = snapshot.makeTransport()
            guard transport.fileExists(trimmed) else {
                return .warn("Path doesn't exist on \(snapshot.displayName).")
            }
            guard let stat = transport.stat(trimmed) else {
                return .warn("Found, but couldn't stat — check permissions.")
            }
            if stat.isDirectory {
                return .warn("Path is a directory, not a file.")
            }
            if HermesProfileArchive.validateImportPath(trimmed) != .ok {
                return .warn("File found, but the extension isn't `.tar.gz` or `.tgz`. `hermes profile import` reads the archive with `tarfile`.")
            }
            return .ok("File found on \(snapshot.displayName).")
        }.value
        verification = result
    }
}
