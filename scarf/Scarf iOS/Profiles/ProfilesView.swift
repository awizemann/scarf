import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS Profiles switcher (#120, Design B).
///
/// Selecting a profile re-scopes everything THIS phone shows — dashboard,
/// memory, cron, sessions, gateway, skills, and chat — to that profile's
/// `HERMES_HOME`, WITHOUT changing the server's own active profile (what the
/// Mac app and terminal use). The switch is applied by `ScarfGoCoordinator`
/// and takes effect when `ScarfGoTabRoot` rebuilds the tab tree.
///
/// Creating, renaming, deleting, and import/export stay on the Mac app —
/// those touch enough state that we keep them off the phone.
struct ProfilesView: View {
    let config: IOSServerConfig

    @Environment(\.serverContext) private var contextFromEnv
    @Environment(\.scarfGoCoordinator) private var coordinator

    @State private var namedProfiles: [String] = []
    /// The server's OWN active profile (its `active_profile` file). Distinct
    /// from what this phone is viewing — shown only to surface divergence.
    @State private var hostActiveProfile: String?
    @State private var isLoading = true
    @State private var lastError: String?
    @State private var pendingChoice: ProfileChoice?

    private var context: ServerContext {
        config.toServerContext(id: contextFromEnv.id)
    }

    /// What this phone is currently viewing — `nil` means the default
    /// (root) profile.
    private var selected: String? { coordinator?.selectedProfile }

    var body: some View {
        List {
            if let err = lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                }
            }

            Section {
                choiceRow(.defaultProfile)
                ForEach(namedProfiles, id: \.self) { name in
                    choiceRow(.named(name))
                }
            } header: {
                Text("Viewing: \(selected ?? "Default")")
            } footer: {
                footer
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            pendingChoice.map { "Switch to \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingChoice != nil },
                set: { if !$0 { pendingChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let choice = pendingChoice {
                Button("Switch to \(choice.displayName)") {
                    // The coordinator persists + flips the selection;
                    // ScarfGoTabRoot's `.id` then rebuilds every tab
                    // (incl. this view) against the new profile. Keep this
                    // action fire-and-forget: this view sits below that
                    // `.id` boundary, so it may be torn down mid-action —
                    // don't add awaits/animations after the switch.
                    // Clear first so a no-op switch (already-selected) still
                    // dismisses the dialog cleanly rather than re-presenting.
                    pendingChoice = nil
                    coordinator?.setSelectedProfile(choice.profileName)
                }
                Button("Cancel", role: .cancel) { pendingChoice = nil }
            }
        } message: {
            Text("ScarfGo will reload to show this profile. The server's own active profile — what the Mac app and terminal use — won't change.")
        }
    }

    @ViewBuilder
    private func choiceRow(_ choice: ProfileChoice) -> some View {
        let isSelected = choice.profileName == selected
        Button {
            if !isSelected { pendingChoice = choice }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ScarfColor.accent : ScarfColor.foregroundMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.displayName)
                        .font(.body)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    // Surface the server's own active profile only when it
                    // diverges from what you're viewing — the informative case.
                    if choice.profileName == hostActiveProfile, !isSelected {
                        Text("Server's active profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    ScarfBadge("Viewing", kind: .success)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: choice, isSelected: isSelected))
        .accessibilityHint(isSelected ? "" : "Switches ScarfGo to this profile")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// VoiceOver label that folds in the divergence subtitle (the one cue a
    /// sighted user gets) so it isn't lost to assistive tech.
    private func accessibilityLabel(for choice: ProfileChoice, isSelected: Bool) -> String {
        var parts = [choice.displayName]
        if isSelected { parts.append("viewing") }
        if choice.profileName == hostActiveProfile, !isSelected {
            parts.append("server's active profile")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switching changes only what this phone shows — it points ScarfGo at the selected profile's data and chat. The server's active profile is unchanged.")
            if namedProfiles.isEmpty && !isLoading {
                Text("No named profiles yet. Create one with `hermes profile create <name>` from the Mac app. Renaming, deleting, and import/export also live there.")
            } else {
                Text("Create, rename, delete, and import/export live in the Mac app.")
            }
        }
        .font(.caption)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = context
        // `active_profile` is a root-home concept — read it from the root
        // even while the context is scoped to a named profile (#120).
        let rootHome = HermesProfileScope.rootHome(
            forHome: config.remoteHome ?? HermesPathSet.defaultRemoteHome
        )
        let result = await Task.detached { () -> (output: String?, active: String?) in
            // `profile list` enumerates ALL profiles regardless of the
            // HERMES_HOME scope the transport injects — Hermes resolves it
            // against the root via get_default_hermes_root() (verified
            // v0.16; see memory note "Hermes profile / HERMES_HOME
            // resolution"). So running it through the profile-scoped
            // transport still returns the full list.
            let listOut = Self.runHermes(context: ctx, args: ["profile", "list"])
            let activeRaw = ctx.readText(rootHome + "/active_profile")
            let active = activeRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (listOut, active)
        }.value
        self.hostActiveProfile = result.active.flatMap {
            ($0.isEmpty || $0 == "default") ? nil : $0
        }
        if let output = result.output {
            // The explicit "Default" row covers the root profile, so drop a
            // parsed "default" entry to avoid a duplicate. Empty output is a
            // legitimate zero-named-profiles host, NOT an error — the footer
            // handles that case.
            self.namedProfiles = Self.parse(output).filter { $0 != "default" }
            self.lastError = nil
        } else {
            // Transport threw — keep any last-known list and surface the error.
            self.lastError = "Couldn't reach `hermes profile list` on this server."
        }
    }

    /// Run a hermes command, returning combined stdout+stderr, or `nil`
    /// when the transport itself failed (so callers can tell "couldn't
    /// reach the host" apart from "ran fine, printed nothing").
    nonisolated private static func runHermes(context: ServerContext, args: [String]) -> String? {
        let transport = context.makeTransport()
        do {
            let r = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: args,
                stdin: nil,
                timeout: 30
            )
            return r.stdoutString + r.stderrString
        } catch {
            return nil
        }
    }

    /// Tolerant parser for `hermes profile list`. The CLI prints a
    /// table-like format with the profile name in the leading column. We
    /// surface the names (an active marker like `◆`/`*` is stripped).
    nonisolated private static func parse(_ output: String) -> [String] {
        var results: [String] = []
        for raw in output.components(separatedBy: "\n") {
            var trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Strip leading active markers.
            for marker in ["◆", "*"] where trimmed.hasPrefix(marker) {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Box-drawing / rule lines: extract the leading column if any.
            if trimmed.hasPrefix("┃") || trimmed.hasPrefix("┏") || trimmed.hasPrefix("┡")
                || trimmed.hasPrefix("┗") || trimmed.hasPrefix("━") || trimmed.hasPrefix("│") {
                let body = trimmed
                    .replacingOccurrences(of: "│", with: "|")
                    .replacingOccurrences(of: "┃", with: "|")
                guard body.contains("|") else { continue }
                let cols = body.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = cols.first, isProfileName(name) {
                    results.append(name)
                }
                continue
            }
            // Plain-text fallback: first whitespace-delimited token is the name.
            if let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
               isProfileName(String(token)) {
                results.append(String(token))
            }
        }
        // Dedupe (table-row + plain-text passes can overlap), preserving order.
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    /// A token is a profile name if it matches Hermes' id grammar — keeps
    /// table headers ("Profile", "Gateway", "Tip:") out of the list.
    nonisolated private static func isProfileName(_ s: String) -> Bool {
        // \A…\z, not ^…$: ICU's $ matches before a trailing line terminator
        // (SEC-L1) — a token carrying a stray \r would otherwise validate and
        // then travel into the profile selection.
        s.range(of: "\\A[a-z0-9][a-z0-9_-]{0,63}\\z", options: .regularExpression) != nil
    }

    /// A selectable profile: the default (root) profile or a named one.
    private enum ProfileChoice: Equatable, Identifiable {
        case defaultProfile
        case named(String)

        var id: String { profileName ?? "·default" }

        /// The value handed to `setSelectedProfile` — `nil` for default.
        var profileName: String? {
            switch self {
            case .defaultProfile: return nil
            case .named(let name): return name
            }
        }

        var displayName: String {
            switch self {
            case .defaultProfile: return "Default"
            case .named(let name): return name
            }
        }
    }
}
