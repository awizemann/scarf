import SwiftUI
import ScarfCore
import ScarfDesign

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
            Button("Open") { onOpen(manifest) }
                .buttonStyle(ScarfSecondaryButton())
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
                    onApprove: { approved in
                        save(approved)
                        granted = approved
                        phase = .run
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
            let store = MiniAppGrantStore(context: serverContext)
            let pid = project.id.uuidString
            // TOFU is bound to CONTENT, not just identity: the stored grant
            // is reused only when it was made about this exact manifest
            // fingerprint (permissions + entry + minBridgeVersion). A
            // mini-app that rewrites its own `miniapp.json` to ask for more
            // — trivial for an agent-generated app in an agent-writable
            // directory — lands back on the sheet instead of inheriting the
            // old grant. A stale/pre-fingerprint decision still seeds the
            // sheet, so re-review shows the user's previous answer rather
            // than resetting to policy defaults.
            if store.hasDecision(projectId: pid, miniAppId: manifest.id, matching: manifest.securityFingerprint) {
                granted = store.grantedPermissions(projectId: pid, miniAppId: manifest.id)
                phase = .run
            } else {
                if store.hasDecision(projectId: pid, miniAppId: manifest.id) {
                    reviewSeed = store.grantedPermissions(projectId: pid, miniAppId: manifest.id)
                        .intersection(manifest.permissions)
                }
                phase = .review
            }
        }
    }

    private func save(_ permissions: Set<MiniAppPermission>) {
        try? MiniAppGrantStore(context: serverContext).setGrant(
            projectId: project.id.uuidString,
            miniAppId: manifest.id,
            permissions: permissions,
            manifestFingerprint: manifest.securityFingerprint
        )
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
    let onApprove: (Set<MiniAppPermission>) -> Void
    let onCancel: () -> Void

    @State private var checked: Set<MiniAppPermission> = []

    /// Permissions that can actually be toggled (unknowns are shown but
    /// never grantable).
    private var grantable: [MiniAppPermission] {
        manifest.permissions.filter { if case .unknown = $0 { return false }; return true }
    }
    private var unknowns: [MiniAppPermission] {
        manifest.permissions.filter { if case .unknown = $0 { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(manifest.name) wants permission")
                    .font(.headline)
                Text(manifest.generated
                     ? "This mini-app was generated by the agent. Sensitive permissions are off by default — turn on only what you trust."
                     : "Review what this mini-app can access before running it.")
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
                            Image(systemName: "questionmark.circle").foregroundStyle(ScarfColor.warning)
                            Text(perm.summary).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text("denied").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve & Run") { onApprove(checked) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .task { checked = seed ?? defaultChecked() }
    }

    private func permissionRow(_ perm: MiniAppPermission) -> some View {
        HStack(spacing: 8) {
            Image(systemName: perm.isSensitive ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(perm.isSensitive ? ScarfColor.warning : .secondary)
            Text(perm.summary).font(.callout)
            if perm.isSensitive {
                Text("sensitive").font(.caption2).foregroundStyle(ScarfColor.warning)
            }
        }
    }

    /// Default selection: non-sensitive on; sensitive off for
    /// agent-generated apps, on for hand-authored/template ones (still
    /// user-overridable).
    private func defaultChecked() -> Set<MiniAppPermission> {
        Set(grantable.filter { !$0.isSensitive || !manifest.generated })
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
