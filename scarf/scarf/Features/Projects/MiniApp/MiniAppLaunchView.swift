import SwiftUI
import ScarfCore
import ScarfDesign
import os

/// Cockpit "Mini-apps" panel — lists the project's mini-apps and launches
/// one through the permission gate into the sandboxed host.
struct CockpitMiniAppsPanel: View {
    let project: ScarfProject?
    let manifests: [MiniAppManifest]
    let serverContext: ServerContext
    /// Open a mini-app — routes up to the cockpit, which presents it in the
    /// slide-in inspector (via `AppCoordinator.presentedMiniApp`).
    let onOpen: (MiniAppManifest) -> Void

    var body: some View {
        Group {
            if let project, !manifests.isEmpty {
                List(manifests) { manifest in
                    row(manifest, project: project)
                }
                .listStyle(.plain)
            } else if project == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CockpitEmptyState(
                    icon: "square.grid.2x2",
                    text: "No mini-apps in this project yet. Drop one in `.scarf/miniapps/<id>/` or have the agent build one."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ manifest: MiniAppManifest, project: ScarfProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: manifest.generated ? "wand.and.stars" : "square.grid.2x2")
                .foregroundStyle(manifest.generated ? ScarfColor.warning : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(manifest.name).font(.callout)
                    if manifest.generated {
                        Text("agent-generated").font(.caption2)
                            .foregroundStyle(ScarfColor.warning)
                    }
                }
                Text(permissionSummary(manifest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Every row's button reads "Open"; without the mini-app's name
            // a list of them is unusable to Voice Control and gives
            // VoiceOver nothing to distinguish one row's button from the
            // next. The visible title stays "Open".
            Button("Open") { onOpen(manifest) }
                .buttonStyle(ScarfSecondaryButton())
                .accessibilityLabel(Text("Open \(manifest.name)"))
        }
        .padding(.vertical, 2)
    }

    private func permissionSummary(_ manifest: MiniAppManifest) -> String {
        manifest.permissions.isEmpty
            ? "v\(manifest.version) · no permissions requested"
            : "v\(manifest.version) · \(manifest.permissions.count) permission\(manifest.permissions.count == 1 ? "" : "s") requested"
    }
}

// MARK: - Launch flow (permission gate → runner)

/// Hosts one mini-app launch in the cockpit's slide-in inspector: shows the
/// permission preview when there's no prior decision, then the sandboxed
/// runner. The inspector isn't a sheet, so closing routes through the
/// injected `onClose` (clears `AppCoordinator.presentedMiniApp`) rather than
/// `@Environment(\.dismiss)`.
struct MiniAppLaunchHost: View {
    let project: ScarfProject
    let manifest: MiniAppManifest
    let serverContext: ServerContext
    let onClose: () -> Void

    @State private var phase: Phase = .loading
    @State private var granted: Set<MiniAppPermission> = []
    /// Seeds the preview's checkboxes on RE-review (nil = first decision →
    /// default policy). Without this, re-reviewing reset to defaults and
    /// silently discarded the user's prior customization on approve.
    @State private var reviewSeed: Set<MiniAppPermission>? = nil
    /// Approve is in flight (the grant write is off-main and can block on
    /// the registry lock + an SSH round-trip). Disables the button and shows
    /// progress rather than freezing the sheet under the press.
    @State private var isSaving = false
    /// A failed save, shown in the sheet. The failure direction is safe
    /// (nothing recorded → asked again next launch), but silently running
    /// after a refused write told the user their decision had stuck.
    @State private var saveError: String? = nil

    private enum Phase { case loading, incompatible, review, run }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .incompatible:
                // The runner + review phases carry their own close; the
                // incompatible empty state needs one so the inspector is
                // always dismissable.
                VStack(spacing: 16) {
                    CockpitEmptyState(
                        icon: "exclamationmark.triangle",
                        text: "“\(manifest.name)” needs a newer mini-app bridge (requires \(manifest.minBridgeVersion); this Scarf provides \(miniAppBridgeVersion)). Update Scarf to run it."
                    )
                    Button("Close") { onClose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review:
                MiniAppPermissionPreview(
                    manifest: manifest,
                    seed: reviewSeed,
                    isSaving: isSaving,
                    saveError: saveError,
                    onApprove: { approved in
                        guard !isSaving else { return }
                        isSaving = true
                        saveError = nil
                        Task {
                            let failure = await save(approved)
                            isSaving = false
                            if let failure {
                                saveError = failure
                            } else {
                                granted = approved
                                phase = .run
                            }
                        }
                    },
                    onCancel: { onClose() }
                )
            case .run:
                MiniAppRunner(
                    project: project,
                    manifest: manifest,
                    serverContext: serverContext,
                    granted: granted,
                    onReviewPermissions: { reviewSeed = granted; phase = .review },
                    onClose: { onClose() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: manifest.id) {
            // Version gate first: refuse a mini-app built against a newer
            // bridge contract rather than silently half-running it.
            guard MiniAppBridge.satisfiesMinBridgeVersion(manifest.minBridgeVersion) else {
                phase = .incompatible
                return
            }
            // OFF-MAIN (charter C10). These are up to three transport reads
            // of the grants file — each one a guarded read that may retry,
            // and on a cold start with a corrupt file a quarantine write too
            // — and they used to run on the MainActor just to decide which
            // sheet to show. On a remote context that is the whole window
            // frozen before anything is drawn. One detached hop answers all
            // three questions together.
            let context = serverContext
            let pid = project.id.uuidString
            let miniAppId = manifest.id
            let fingerprint = manifest.securityFingerprint
            let permissions = manifest.permissions
            let decision = await Task.detached { () -> (matched: Bool, granted: Set<MiniAppPermission>, seed: Set<MiniAppPermission>?) in
                let store = MiniAppGrantStore(context: context)
                if store.hasDecision(projectId: pid, miniAppId: miniAppId, matching: fingerprint) {
                    return (
                        true,
                        store.grantedPermissions(projectId: pid, miniAppId: miniAppId),
                        nil
                    )
                }
                let seed = store.hasDecision(projectId: pid, miniAppId: miniAppId)
                    ? store.grantedPermissions(projectId: pid, miniAppId: miniAppId)
                        .intersection(permissions)
                    : nil
                return (false, [], seed)
            }.value
            // CANCELLATION GUARD. `.task(id:)` cancellation does not stop a
            // suspended `await` from resuming, and a detached child doesn't
            // inherit cancellation at all — so without this, a switch to
            // another mini-app could be followed by the PREVIOUS one's read
            // landing and driving this view into `.run` with the wrong
            // grant set.
            guard !Task.isCancelled else { return }
            // TOFU is bound to CONTENT, not just identity: the stored grant
            // is reused only when it was made about this exact manifest
            // fingerprint (permissions + entry + minBridgeVersion). A
            // mini-app that rewrites its own `miniapp.json` to ask for more
            // — trivial for an agent-generated app in an agent-writable
            // directory — lands back on the sheet instead of inheriting the
            // old grant. A stale/pre-fingerprint decision still seeds the
            // sheet, so re-review shows the user's previous answer rather
            // than resetting to policy defaults.
            if decision.matched {
                granted = decision.granted
                phase = .run
            } else {
                reviewSeed = decision.seed
                phase = .review
            }
        }
    }

    /// Persist the user's decision, OFF THE MAIN ACTOR. Returns a
    /// user-facing reason on failure, `nil` on success.
    ///
    /// **Why detached** (charter C10). `MiniAppGrantStore.mutate` takes
    /// `RegistryWriteLock` — which waits, with a `Thread.sleep`, for up to
    /// 60s on a contended remote lock — and then does a guarded
    /// read-modify-write over SSH. Running that synchronously inside the
    /// button's action beachballed the whole window on the one press the
    /// user makes at a security prompt. Same `Task.detached`-and-await shape
    /// as `ProjectsViewModel.save`.
    ///
    /// A failure here is not silent-but-fine: since G2 the store REFUSES
    /// the write when its signing key is unavailable (rather than purging
    /// every other grant on the machine). The failure direction is still
    /// safe — nothing is recorded, so the sheet reappears on the next launch
    /// — but the user pressed Approve and is entitled to know it didn't
    /// take, rather than watching the app re-ask forever.
    private func save(_ permissions: Set<MiniAppPermission>) async -> String? {
        let context = serverContext
        let projectId = project.id.uuidString
        let miniAppId = manifest.id
        let fingerprint = manifest.securityFingerprint
        return await Task.detached { () -> String? in
            do {
                try MiniAppGrantStore(context: context).setGrant(
                    projectId: projectId,
                    miniAppId: miniAppId,
                    permissions: permissions,
                    manifestFingerprint: fingerprint
                )
                return nil
            } catch {
                Logger(subsystem: "com.scarf", category: "MiniAppLaunch").error(
                    "couldn't record the mini-app permission decision for \(miniAppId, privacy: .public): \(error.localizedDescription, privacy: .public); it will be asked again next launch"
                )
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }.value
    }
}

/// The trust-boundary sheet: every declared surface, sensitive ones
/// highlighted, default-off for agent-generated apps. Approve grants
/// exactly the checked set; unknown permissions can never be granted.
struct MiniAppPermissionPreview: View {
    let manifest: MiniAppManifest
    /// Existing grant to pre-select when re-reviewing; `nil` on a first
    /// decision (use the default policy instead of clobbering prior choices).
    var seed: Set<MiniAppPermission>? = nil
    /// The decision is being written; Approve is disabled and progress shows.
    var isSaving: Bool = false
    /// Why the last Approve didn't stick, if it didn't.
    var saveError: String? = nil
    let onApprove: (Set<MiniAppPermission>) -> Void
    let onCancel: () -> Void

    @State private var checked: Set<MiniAppPermission> = []

    /// Permissions that can actually be toggled (unknowns are shown but
    /// never grantable).
    private var grantable: [MiniAppPermission] {
        Self.deduped(manifest.permissions.filter { if case .unknown = $0 { return false }; return true })
    }
    private var unknowns: [MiniAppPermission] {
        Self.deduped(manifest.permissions.filter { if case .unknown = $0 { return true }; return false })
    }

    /// First occurrence wins, order preserved.
    ///
    /// `manifest.permissions` is parsed from an agent-written `miniapp.json`
    /// and nothing upstream promises the list is unique — `["store",
    /// "store"]` parses to two equal elements. `ForEach(_, id: \.self)` over
    /// duplicate ids is undefined behaviour in SwiftUI (rows that render
    /// twice, toggle state that lands on the wrong row, animation glitches),
    /// and this is the sheet where a row's toggle state IS the security
    /// decision — the one list in the app where "usually renders fine" is
    /// not good enough.
    private static func deduped(_ permissions: [MiniAppPermission]) -> [MiniAppPermission] {
        var seen: Set<MiniAppPermission> = []
        return permissions.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(manifest.name) wants permission")
                    .font(.headline)
                // One caption for every app. The old version promised a
                // weaker review for apps that declared `generated: false` —
                // a claim the app itself makes in a file the agent can
                // write. Sensitive permissions are now off for everyone, so
                // the sentence that describes the sheet is the same sentence
                // for everyone.
                Text("Mini-apps run in the project's folder, which the agent can write to. Sensitive permissions are off by default — turn on only what you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            Divider()

            if manifest.permissions.isEmpty {
                CockpitEmptyState(icon: "checkmark.shield", text: "This mini-app requests no permissions.")
            } else {
                List {
                    ForEach(grantable, id: \.self) { perm in
                        Toggle(isOn: Binding(
                            get: { checked.contains(perm) },
                            set: { if $0 { checked.insert(perm) } else { checked.remove(perm) } }
                        )) {
                            permissionRow(perm)
                        }
                    }
                    ForEach(unknowns, id: \.self) { perm in
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(ScarfColor.warning)
                                .accessibilityHidden(true)
                            Text(verbatim: perm.localizedSummary).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text("denied").font(.caption2).foregroundStyle(.secondary)
                        }
                        // Unknown-permission row reads as one stop ("<name>,
                        // denied") instead of a bare "question mark" glyph
                        // ahead of the text.
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            if let saveError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                        .accessibilityHidden(true)
                    Text("Couldn't save this decision: \(saveError)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving your decision")
                }
                Button("Approve & Run") { onApprove(checked) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .accessibilityHint("Grants only the checked permissions")
            }
            .padding()
        }
        .task { checked = seed ?? defaultChecked() }
    }

    private func permissionRow(_ perm: MiniAppPermission) -> some View {
        HStack(spacing: 8) {
            // Sensitivity is already spoken via the "sensitive" text below
            // (and, for the plain case, by the absence of it) — the glyph
            // is redundant and would otherwise read as "warning" or
            // "checkmark" ahead of the permission's own name.
            Image(systemName: perm.isSensitive ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(perm.isSensitive ? ScarfColor.warning : .secondary)
                .accessibilityHidden(true)
            Text(verbatim: perm.localizedSummary).font(.callout)
            if perm.isSensitive {
                Text("sensitive").font(.caption2).foregroundStyle(ScarfColor.warning)
            }
        }
    }

    /// Default selection: non-sensitive on, **sensitive always off** —
    /// user-overridable, as before.
    ///
    /// This used to read `!manifest.generated`, pre-checking sensitive
    /// permissions for apps that declared themselves hand-authored. But
    /// `generated` is a plain boolean in `miniapp.json`, which lives in the
    /// project's mini-app directory, which is agent-writable — and it
    /// DEFAULTS TO FALSE when absent. So the flag said "trust me" and the
    /// party asking to be trusted was the only one who set it: an agent
    /// writing an app that wants `file:read` and `prompt` simply omits the
    /// key, and the sheet opens with the dangerous boxes already ticked,
    /// one default-action Return away from granted.
    ///
    /// A self-declared attribute cannot key a security default. There is no
    /// provenance signal to derive a real one from (Scarf does not sign
    /// mini-apps, and a template's app is copied into the same writable
    /// directory), so the honest resolution is to stop asking: sensitive
    /// permissions are off for everyone and the user ticks the ones they
    /// mean. The flag survives as a LABEL — the badge and the caption still
    /// show it — where a false claim can only make the app look safer than
    /// the sheet is treating it, which costs nothing.
    private func defaultChecked() -> Set<MiniAppPermission> {
        Set(grantable.filter { !$0.isSensitive })
    }
}

/// Hosts the running mini-app with a slim chrome (close + re-review perms).
private struct MiniAppRunner: View {
    let project: ScarfProject
    let manifest: MiniAppManifest
    let serverContext: ServerContext
    let granted: Set<MiniAppPermission>
    let onReviewPermissions: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(manifest.name).font(.headline)
                Spacer()
                Button {
                    onReviewPermissions()
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .buttonStyle(.borderless)
                .help("Review or change what this mini-app can access")
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            MiniAppHostView(
                project: project,
                manifest: manifest,
                serverContext: serverContext,
                grantedPermissions: granted,
                onUIAction: { action in
                    // Honor the mini-app's own "done" affordance
                    // (`scarf.ui.requestClose()`) — close the slide-in surface,
                    // same as the chrome Close button. (toast/setTitle/resize
                    // stay host-logged only for now.)
                    if case .requestClose = action { onClose() }
                }
            )
            // Recreate the web host (fresh dispatcher) whenever the granted
            // set changes — so re-reviewing to a NARROWER set actually
            // revokes access on the live instance, not just on next launch.
            .id(manifest.id + "|" + granted.map(\.rawValue).sorted().joined(separator: ","))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


/// `MiniAppPermission.summary` is an untranslated English token from ScarfCore
/// (no string catalog there), and this sheet is a SECURITY consent surface —
/// a user who cannot read the permission cannot meaningfully grant it. One
/// extractable sentence per case, mirroring the ScarfCore wording.
extension MiniAppPermission {
    var localizedSummary: String {
        switch self {
        case .prompt: return String(localized: "Send prompts to this chat's agent")
        case .events: return String(localized: "Read this chat's streamed agent output")
        case .query(let kind):
            return kind.isEmpty
                ? String(localized: "Read data (read-only)")
                : String(localized: "Read \(kind) (read-only)")
        case .kanbanWrite: return String(localized: "Create and move kanban tasks")
        case .fileRead: return String(localized: "Read any file inside the project")
        case .fileWrite: return String(localized: "Write files inside the project")
        case .store: return String(localized: "Save its own settings")
        case .net: return String(localized: "Make outbound network requests")
        // Deliberately says what the user will still get to decide: this
        // row grants the right to ask, and every new site is confirmed by
        // name before anything opens.
        case .openURL: return String(localized: "Open links in your browser (you confirm each new site)")
        case .unknown(let raw):
            // Sanitized, never verbatim: this is the consent sheet, and the
            // string comes from an agent-written manifest (P8 SEC-L4).
            return String(localized: "Unknown permission \"\(MiniAppPermission.displaySafe(raw))\" (will be denied)")
        }
    }
}
