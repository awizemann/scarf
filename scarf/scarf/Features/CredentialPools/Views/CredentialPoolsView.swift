import SwiftUI
import ScarfCore
import ScarfDesign

struct CredentialPoolsView: View {
    @State private var viewModel: CredentialPoolsViewModel
    @State private var showAddSheet = false
    @State private var pendingRemove: HermesCredential?
    /// Mirrors `pendingRemove` for OAuth providers — different model
    /// type, separate confirmation. Non-nil while the dialog is up.
    @State private var pendingOAuthRemove: HermesOAuthProvider?
    /// When non-nil, `AddCredentialSheet` opens pre-seeded with this
    /// provider name + OAuth type — driven by the chat banner's
    /// "Re-authenticate" button via `AppCoordinator.pendingOAuthReauth`,
    /// or by clicking the per-row "Re-authenticate" button in this
    /// view. Reset to nil when the sheet dismisses so the next plain
    /// "Add Credential" press doesn't accidentally inherit it.
    @State private var reauthInitialProvider: String?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    /// Mirror of `OAuthKeepaliveCronService.isEnabled()` so the
    /// toggle reads from local @State (instant) instead of hitting
    /// disk on every render. `nil` while the initial probe is in
    /// flight; reloaded on appear and after every enable/disable.
    @State private var keepaliveEnabled: Bool?
    @State private var keepaliveBusy: Bool = false
    @State private var keepaliveError: String?
    /// Cached Nous subscription state. Used by `keepaliveSection` to
    /// surface a contextual nudge when the auth record hasn't been
    /// refreshed in ≥14 days — that's exactly when enabling the
    /// keepalive cron is highest-value. Loaded async on appear; the
    /// section renders without the nudge while this is `.absent`.
    @State private var nousSubscription: NousSubscriptionState = .absent

    private let keepalive: OAuthKeepaliveCronService
    private let nousService: NousSubscriptionService

    init(context: ServerContext) {
        _viewModel = State(initialValue: CredentialPoolsViewModel(context: context))
        self.keepalive = OAuthKeepaliveCronService(context: context)
        self.nousService = NousSubscriptionService(context: context)
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    safetyNotice
                    if viewModel.isLoading {
                        ProgressView().padding()
                    } else if viewModel.pools.isEmpty && viewModel.oauthProviders.isEmpty {
                        emptyState
                    } else {
                        if !viewModel.oauthProviders.isEmpty {
                            keepaliveSection
                            oauthProvidersSection
                        }
                        ForEach(viewModel.pools) { pool in
                            poolSection(pool)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Credential Pools")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading credentials…",
            isEmpty: viewModel.pools.isEmpty && viewModel.oauthProviders.isEmpty
        )
        .onAppear {
            viewModel.load()
            consumePendingReauth()
            probeKeepalive()
        }
        .onChange(of: coordinator.pendingOAuthReauth) { _, _ in
            consumePendingReauth()
        }
        // Pick up external changes to auth.json — terminal
        // `hermes auth logout`, OAuth flows from another window,
        // OAuth keepalive cron rewriting tokens. Without this the
        // pool only refreshes on appear / sheet-dismiss, so users
        // who removed a provider via CLI saw stale rows after
        // Reload (the file watcher already polls auth.json on the
        // remote SSH path; here we just subscribe to its tick).
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
            probeKeepalive()
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            // Refresh after every dismiss — the OAuth flow rewrites
            // `auth.json` on success, but the sheet self-closes
            // before SwiftUI re-renders the parent. Without this,
            // users had to hit Reload manually after a successful
            // re-auth to see the expiry badge clear and the new
            // `tokenTail` populate.
            reauthInitialProvider = nil
            viewModel.load()
            probeKeepalive()
        }) {
            AddCredentialSheet(viewModel: viewModel, initialProvider: reauthInitialProvider) {
                showAddSheet = false
            }
        }
        .confirmationDialog(
            pendingRemove.map { "Remove credential for \($0.provider)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let target = pendingRemove {
                    viewModel.removeCredential(provider: target.provider, index: target.index)
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("This removes the credential from hermes. The upstream provider key is not revoked.")
        }
        .confirmationDialog(
            pendingOAuthRemove.map { "Remove OAuth provider \($0.provider.capitalized)?" } ?? "",
            isPresented: Binding(get: { pendingOAuthRemove != nil }, set: { if !$0 { pendingOAuthRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let target = pendingOAuthRemove {
                    viewModel.removeOAuthProvider(target.provider)
                }
                pendingOAuthRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingOAuthRemove = nil }
        } message: {
            Text("Removes this OAuth provider from auth.json. You'll need to re-authenticate before Hermes can use it again. The upstream provider account is not revoked.")
        }
    }

    /// Drain any pending re-auth hand-off from the chat banner: the
    /// banner's "Re-authenticate" button writes to
    /// `coordinator.pendingOAuthReauth` and switches to this view; we
    /// pick the value up here, seed the sheet's initial provider, and
    /// clear the slot so navigating back to this view doesn't re-open
    /// the sheet.
    private func consumePendingReauth() {
        guard let pending = coordinator.pendingOAuthReauth else { return }
        reauthInitialProvider = pending
        showAddSheet = true
        coordinator.pendingOAuthReauth = nil
    }

    /// Read the current keepalive cron job state off the main
    /// thread. Disk reads on remote contexts can take 100–300ms
    /// (one SFTP round-trip for `~/.hermes/cron/jobs.json`) so this
    /// hops to a detached task and only flips `keepaliveEnabled` on
    /// MainActor when the result lands. Concurrently loads the Nous
    /// subscription record so the staleness nudge is computed off
    /// the same probe.
    private func probeKeepalive() {
        let svc = keepalive
        let nous = nousService
        Task.detached {
            let enabled = svc.isEnabled()
            let state = nous.loadState()
            await MainActor.run {
                keepaliveEnabled = enabled
                nousSubscription = state
            }
        }
    }

    /// Section above the OAuth providers list with a single toggle
    /// that registers / removes a Scarf-owned daily cron job. The
    /// job's only purpose is to boot a Hermes session, which is what
    /// causes Hermes to refresh OAuth access tokens (no standalone
    /// CLI verb for refresh exists today). Hidden until we know the
    /// current state — flickering the toggle off→on on view appear
    /// would be confusing.
    @ViewBuilder
    private var keepaliveSection: some View {
        let isOn = keepaliveEnabled ?? false
        let stale = nousSubscription.hasStaleRefresh && keepaliveEnabled == false
        SettingsSection(title: LocalizedStringKey("Keep tokens fresh"), icon: "arrow.clockwise") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { isOn },
                        set: { newValue in toggleKeepalive(to: newValue) }
                    )) {
                        Text("Auto-refresh OAuth tokens daily")
                            .font(.system(.body, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .disabled(keepaliveEnabled == nil || keepaliveBusy)
                    Text("Registers a `\(OAuthKeepaliveCronService.jobName)` cron job that runs at 4am daily. Booting a Hermes session is what triggers token refresh — without this, refresh tokens silently expire if you go ~30 days without using Scarf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if stale, let days = nousSubscription.daysSinceLastRefresh() {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Your Nous subscription was last refreshed \(days) days ago. Enable the toggle above to prevent the refresh token from expiring.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                    if let err = keepaliveError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if keepaliveBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    private func toggleKeepalive(to newValue: Bool) {
        guard !keepaliveBusy else { return }
        keepaliveBusy = true
        keepaliveError = nil
        let svc = keepalive
        Task.detached {
            let ok = newValue ? await svc.enable() : await svc.disable()
            let actualState = svc.isEnabled()
            await MainActor.run {
                keepaliveBusy = false
                keepaliveEnabled = actualState
                if !ok {
                    keepaliveError = newValue
                        ? "Couldn't register the keepalive cron job. Check `hermes cron` works in a terminal."
                        : "Couldn't remove the keepalive cron job. Check `hermes cron remove` works in a terminal."
                }
            }
        }
    }

    private var header: some View {
        ScarfPageHeader(
            "Credential Pools",
            subtitle: "Shared OAuth + token pools rotated across runs."
        ) {
            HStack(spacing: ScarfSpace.s2) {
                if let msg = viewModel.message {
                    Label(msg, systemImage: "info.circle.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Button("Reload") { viewModel.load() }
                    .buttonStyle(ScarfGhostButton())
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Credential", systemImage: "plus")
                }
                .buttonStyle(ScarfPrimaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var safetyNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("API keys are never displayed in full. Scarf only shows the last 4 characters for identification. Full key values are stored by hermes in ~/.hermes/auth.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No credential pools configured")
                .foregroundStyle(.secondary)
            Text("Add rotation credentials so hermes can failover between keys when one hits rate limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Render OAuth-authed providers (`auth.json.providers.<name>`) as a
    /// single section above the rotation pools. Read-only — Hermes owns
    /// the write path via `hermes auth add <name>`. Rendered only when
    /// `viewModel.oauthProviders` is non-empty so users without any
    /// OAuth-authed providers don't see an empty header.
    @ViewBuilder
    private var oauthProvidersSection: some View {
        SettingsSection(title: LocalizedStringKey("OAuth providers"), icon: "person.badge.key") {
            ForEach(viewModel.oauthProviders) { provider in
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.provider.capitalized)
                                .font(.system(.body, weight: .medium))
                            Text("oauth")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(Capsule())
                            if !provider.hasAccessToken && provider.hasRefreshToken {
                                Text("refresh-only")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            oauthExpiryBadge(provider)
                        }
                        HStack(spacing: 8) {
                            Text(provider.tokenTail.isEmpty ? "—" : provider.tokenTail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let updated = provider.updatedAt {
                                Text("authed · \(Self.relativeAge(updated))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let url = provider.portalURL, !url.isEmpty {
                                Text(url)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Spacer()
                    Button("Re-authenticate") {
                        reauthInitialProvider = provider.provider
                        showAddSheet = true
                    }
                    .controlSize(.small)
                    // `Text(verbatim:)` skips the LocalizedStringKey
                    // overload that would interpret the backticks as
                    // markdown inline-code styling — `.help(_:)` rejects
                    // styled Text. Plain string preserves the backticks
                    // literally.
                    .help(Text(verbatim: "Run `hermes auth add \(provider.provider) --type oauth` again to refresh this provider's tokens."))
                    Button(role: .destructive) {
                        pendingOAuthRemove = provider
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help(Text(verbatim: "Remove this OAuth provider from auth.json. Hermes will need to be re-authenticated to use it again."))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.3))
            }
            HStack {
                Text("Re-authenticate refreshes tokens; the trash icon removes the provider from auth.json.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    @ViewBuilder
    private func oauthExpiryBadge(_ provider: HermesOAuthProvider) -> some View {
        if let expiresAt = provider.expiresAt {
            let secondsRemaining = expiresAt.timeIntervalSinceNow
            if secondsRemaining <= 0 {
                Text("expired")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red)
                    .clipShape(Capsule())
            } else if secondsRemaining < 7 * 86_400 {
                let days = max(1, Int(secondsRemaining / 86_400))
                Text("expires in \(days)d")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func poolSection(_ pool: HermesCredentialPool) -> some View {
        SettingsSection(title: LocalizedStringKey(pool.provider), icon: "key.horizontal") {
            PickerRow(label: "Rotation", selection: pool.strategy, options: viewModel.strategyOptions) { strategy in
                viewModel.setStrategy(strategy, for: pool.provider)
            }
            ForEach(pool.credentials) { cred in
                HStack(spacing: 12) {
                    Image(systemName: cred.authType == "oauth" ? "person.badge.key" : "key.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("#\(cred.index + 1)")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                            if !cred.label.isEmpty {
                                Text(cred.label).font(.caption)
                            }
                            if !cred.authType.isEmpty {
                                Text(cred.authType)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            if !cred.lastStatus.isEmpty {
                                Text(cred.lastStatus)
                                    .font(.caption2)
                                    .foregroundStyle(statusColor(cred.lastStatus))
                            }
                            expiryBadge(cred)
                        }
                        HStack(spacing: 8) {
                            Text(cred.tokenTail.isEmpty ? "—" : cred.tokenTail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if !cred.source.isEmpty {
                                Text(cred.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if cred.requestCount > 0 {
                                Text("\(cred.requestCount) req")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let rotated = cred.agentKeyObtainedAt {
                                Text("agent key · \(Self.relativeAge(rotated))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { pendingRemove = cred }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Reset Cooldowns") { viewModel.resetProvider(pool.provider) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok", "active": return .green
        case "cooldown": return .orange
        case "exhausted": return .red
        default: return .secondary
        }
    }

    /// Red "expired" / orange "expires in Nd" pill shown inline with the
    /// credential's auth-type chip. Hidden when the credential has no
    /// expiry or is more than 7 days out — no point pulling attention to a
    /// token the user doesn't need to think about yet.
    @ViewBuilder
    private func expiryBadge(_ cred: HermesCredential) -> some View {
        if let badge = cred.expiryBadge() {
            switch badge {
            case .expired:
                Text("expired")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red)
                    .clipShape(Capsule())
            case .expiringSoon(let days):
                Text("expires in \(days)d")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    /// "2h ago" / "3d ago" / "just now". Kept terse for the one-line
    /// credential row. `RelativeDateTimeFormatter` isn't used because its
    /// output ("2 hours ago") is too long for the slot.
    private static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Two-step sheet for adding a credential:
/// 1. Provider picker (populated from the models catalog, falls back to free text)
///    + type selector (API Key vs OAuth) + optional label
/// 2. Either an immediate save (API key) or an embedded terminal running the
///    OAuth flow so the user can paste the authorization code back.
private struct AddCredentialSheet: View {
    @Bindable var viewModel: CredentialPoolsViewModel
    /// Optional pre-fill from the re-auth path. When non-nil, the sheet
    /// opens with this provider name + OAuth selected, mirroring the
    /// state the user would otherwise have to type. Plain "Add
    /// Credential" presses leave it nil.
    let initialProvider: String?
    let onDismiss: () -> Void

    init(
        viewModel: CredentialPoolsViewModel,
        initialProvider: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.initialProvider = initialProvider
        self.onDismiss = onDismiss
        _providerID = State(initialValue: initialProvider ?? "")
        _authType = State(initialValue: initialProvider == nil ? .apiKey : .oauth)
    }

    enum AuthType: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case oauth = "OAuth"
        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .apiKey: return "API Key"
            case .oauth: return "OAuth"
            }
        }
    }

    @State private var providerID: String
    @State private var authType: AuthType
    @State private var apiKey: String = ""
    @State private var label: String = ""
    @State private var providers: [HermesProviderInfo] = []
    /// True while the initial models.dev catalog read is in flight.
    /// Drives the loading-overlay placeholder. Pre-fix this work ran
    /// synchronously inside `.onAppear` and froze the sheet for 1–2
    /// minutes on remote contexts (issue #59).
    @State private var isLoadingProviders: Bool = true
    @State private var oauthStarted: Bool = false
    @State private var authCode: String = ""
    /// Drives presentation of the dedicated Nous sign-in sheet from inside
    /// this add-credential sheet. Nous uses device-code, not PKCE — the
    /// regular `OAuthFlowController` silently stalls, so we route Nous
    /// through ``NousSignInSheet`` instead.
    @State private var showNousSignIn: Bool = false
    /// Provider/model swap prompt presented after a successful OAuth.
    /// Captures the just-authed provider and the active config so the
    /// confirm sheet can show the user what's about to change. Nil
    /// when no swap is offered (already aligned, or user dismissed).
    @State private var pendingProviderSwap: PendingProviderSwap?

    /// Snapshot of the post-OAuth state used to render the
    /// "Switch active provider?" sheet. Frozen at the moment OAuth
    /// succeeded so the sheet stays consistent if config.yaml is
    /// edited concurrently.
    private struct PendingProviderSwap: Identifiable {
        let id = UUID()
        let newProvider: String
        let currentProvider: String
        let currentModelDefault: String
    }

    private var catalog: ModelCatalogService { ModelCatalogService(context: viewModel.context) }

    private func oauthGate(for rawID: String) -> CredentialPoolsOAuthGate {
        CredentialPoolsOAuthGate.resolve(providerID: rawID, catalog: catalog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Credential")
                .font(.headline)
            if !oauthStarted {
                configSection
            } else {
                oauthSection
            }
            Divider()
            footer
        }
        .padding()
        .frame(minWidth: 600, minHeight: 460)
        .overlay {
            if isLoadingProviders {
                ProgressView("Loading providers…")
                    .progressViewStyle(.circular)
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            // Off-MainActor read of the multi-megabyte models.dev cache
            // (via SSHTransport on remote contexts). Pre-fix this ran
            // sync inside `.onAppear` and froze the Add Credential sheet
            // for 1–2 minutes on remote contexts (issue #59).
            isLoadingProviders = true
            providers = await catalog.loadProvidersAsync()
            isLoadingProviders = false
        }
        // Auto-close the sheet once a credential is actually saved. We key
        // off `succeeded` which the controller sets only when hermes exited
        // zero AND the output has no failure markers. The 0.8s delay lets the
        // user see the success banner before the sheet disappears.
        //
        // v2.8 — before auto-dismissing, check whether the just-authed
        // provider matches `model.provider` in config.yaml. If they
        // disagree, surface the "Switch active provider?" sheet so the
        // user doesn't have to dig into Settings to make the new
        // credentials actually drive chats. Detected entirely on the
        // detached read; only the present-sheet branch keeps the user
        // from auto-dismissing.
        .onChange(of: viewModel.oauthFlow.succeeded) { _, newValue in
            guard newValue else { return }
            let trimmedProvider = providerID.trimmingCharacters(in: .whitespaces)
            let ctx = viewModel.context
            Task.detached {
                let svc = HermesFileService(context: ctx)
                let config = svc.loadConfig()
                let activeProvider = config.provider.trimmingCharacters(in: .whitespaces)
                let modelDefault = config.model.trimmingCharacters(in: .whitespaces)
                let needsSwap = !trimmedProvider.isEmpty
                    && !activeProvider.isEmpty
                    && trimmedProvider.caseInsensitiveCompare(activeProvider) != .orderedSame
                await MainActor.run {
                    if needsSwap {
                        pendingProviderSwap = PendingProviderSwap(
                            newProvider: trimmedProvider,
                            currentProvider: activeProvider,
                            currentModelDefault: modelDefault
                        )
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            onDismiss()
                        }
                    }
                }
            }
        }
        .sheet(item: $pendingProviderSwap) { swap in
            providerSwapSheet(swap: swap)
        }
        // Nous sign-in is a parallel flow that bypasses OAuthFlowController.
        // When it completes, the parent list refreshes from auth.json just
        // like it does after a regular OAuth add — so we dismiss the
        // AddCredentialSheet after a short delay.
        .sheet(isPresented: $showNousSignIn) {
            NousSignInSheet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Step 1: provider + type + label + optional API key

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Free-text first so providers missing from the catalog
                    // (e.g. "nous") are still addable.
                    TextField("e.g. anthropic", text: $providerID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Menu("Browse") {
                        ForEach(providers) { provider in
                            Button(provider.providerName + " (\(provider.providerID))") {
                                providerID = provider.providerID
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Credential Type").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $authType) {
                    ForEach(AuthType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. team-prod", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            if authType == .apiKey {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                oauthGuidance
            }
        }
    }

    /// Renders either the standard PKCE preamble, the Nous-specific
    /// "sign in with the dedicated sheet" affordance, or a CLI fallback —
    /// whichever matches the provider the user has typed.
    @ViewBuilder
    private var oauthGuidance: some View {
        switch oauthGate(for: providerID) {
        case .ok, .providerEmpty:
            oauthPreamble
        case .useNousSignIn:
            nousSignInPreamble
        case .useCLI(let provider):
            cliFallbackPreamble(for: provider)
        }
    }

    private var nousSignInPreamble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Nous Portal uses a dedicated sign-in flow.")
                    .font(.caption)
            }
            Text("We'll open the Nous Portal approval page in your browser and show the device code here. No code-paste step.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cliFallbackPreamble(for provider: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("`\(provider)` uses a different sign-in flow.")
                    .font(.caption)
            }
            Text("Run `hermes auth add \(provider)` in a terminal to finish sign-in. In-app support for this provider is coming in a follow-up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Brief explanation shown before the user clicks "Start OAuth". Sets
    /// expectations about the embedded-terminal flow so the browser window
    /// and code-paste step aren't surprises.
    private var oauthPreamble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clicking Start OAuth opens the provider's authorization page in your browser. After you approve, copy the code the provider displays and paste it back into the terminal that appears next.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The terminal is a real TTY — paste with ⌘V, press Return, and wait for the process to exit with \"login succeeded\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Step 2: OAuth — URL button, code field, live output log

    private var oauthSection: some View {
        // Pull the observable controller into a local so the view redraws
        // when its @Observable properties change.
        let flow = viewModel.oauthFlow
        return VStack(alignment: .leading, spacing: 10) {
            oauthHeader(flow: flow)
            urlBlock(flow: flow)
            codeEntryBlock(flow: flow)
            outputLogBlock(flow: flow)
        }
    }

    @ViewBuilder
    private func oauthHeader(flow: OAuthFlowController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
            Text("OAuth login for \(viewModel.oauthProvider)")
                .font(.headline)
            Spacer()
            if flow.isRunning {
                ProgressView().controlSize(.small)
            } else if flow.succeeded {
                Label("Succeeded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let err = flow.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    /// Authorization URL block. Hermes prints the URL on startup; we detect
    /// it via regex and expose a prominent Open + Copy pair. The URL keeps
    /// showing even after the browser is opened so users can paste it into
    /// a different browser profile if needed.
    @ViewBuilder
    private func urlBlock(flow: OAuthFlowController) -> some View {
        if let url = flow.authorizationURL {
            VStack(alignment: .leading, spacing: 6) {
                Label("Authorization URL", systemImage: "link")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        flow.openURLInBrowser()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if flow.isRunning {
            // Still waiting for hermes to print the URL — usually <1s.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization URL…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Authorization code input. Only active once hermes has printed its
    /// "Authorization code:" prompt so users can't submit before hermes is
    /// ready to receive input.
    @ViewBuilder
    private func codeEntryBlock(flow: OAuthFlowController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Authorization Code", systemImage: "keyboard")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("After approving in your browser, the provider shows a code. Paste it below and submit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Paste code here…", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(!flow.awaitingCode)
                    .onSubmit { submitCode(flow: flow) }
                Button("Submit") { submitCode(flow: flow) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.awaitingCode || authCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !flow.awaitingCode && flow.isRunning {
                Text("Waiting for hermes to prompt for the code…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Live output log — useful for diagnostics if the flow stalls or errors.
    @ViewBuilder
    private func outputLogBlock(flow: OAuthFlowController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Output", systemImage: "text.alignleft")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                Text(flow.output.isEmpty ? "(no output yet)" : flow.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func submitCode(flow: OAuthFlowController) {
        let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.submitOAuthCode(trimmed)
        authCode = ""
    }

    // MARK: - Footer (buttons)

    private var footer: some View {
        HStack {
            Spacer()
            if oauthStarted {
                Button("Close") {
                    // Closing mid-flow terminates hermes so we don't leave a
                    // zombie process waiting for stdin forever.
                    viewModel.cancelOAuth()
                    onDismiss()
                }
            } else {
                Button("Cancel") { onDismiss() }
                if authType == .apiKey {
                    Button("Add") {
                        viewModel.addAPIKey(provider: providerID, apiKey: apiKey, label: label)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerID.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    oauthActionButton
                }
            }
        }
    }

    /// "Switch active provider?" sheet shown after a successful OAuth
    /// when the just-authed provider doesn't match `model.provider` in
    /// config.yaml. Without this, the user has to remember to open
    /// Settings and swap the provider manually — they'd otherwise hit
    /// the v2.8 mismatch banner on the very next chat. v2.8.
    private func providerSwapSheet(swap: PendingProviderSwap) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch active provider to \(swap.newProvider)?")
                        .font(.headline)
                    Text("`\(swap.newProvider)` is now authenticated, but `model.provider` in config.yaml is still `\(swap.currentProvider)`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !swap.currentModelDefault.isEmpty {
                // Honest promise (t-9657430b audit): the switch CLEARS
                // model.default, and the chat preflight then asks the
                // user to pick a model for the new provider — Hermes
                // itself only self-defaults for subscription overlays,
                // and Scarf's ModelPreflight gates chat start first
                // either way.
                Text("Current `model.default`: `\(swap.currentModelDefault)` — switching clears it, and you'll pick a model for `\(swap.newProvider)` when you next start a chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Keep \(swap.currentProvider)") {
                    pendingProviderSwap = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onDismiss() }
                }
                Spacer()
                Button("Switch to \(swap.newProvider)") {
                    let target = swap.newProvider
                    let ctx = viewModel.context
                    pendingProviderSwap = nil
                    Task.detached {
                        let svc = HermesFileService(context: ctx)
                        // Empty model lets Hermes pick its own default
                        // for the new provider — matches the Nous Portal
                        // path and avoids re-introducing a stale prefix.
                        //
                        // Routed through the write plan (t-9657430b):
                        // this IS a provider switch (the sheet only
                        // shows on a mismatch), so stale local-managed
                        // keys (model.base_url/api_key/api_mode/
                        // context_length) are scrubbed — skipped when
                        // the just-read config shows them already unset
                        // — and the old model.default is CLEARED, which
                        // is what the sheet's "Hermes will pick a
                        // default" copy promises (setModelAndProvider
                        // left it pinned).
                        let ops = LocalModelConfigPlan.operations(
                            selectingRemoteModel: "",
                            provider: target,
                            current: svc.loadConfig()
                        )
                        _ = !ops.isEmpty && svc.applyModelConfigPlan(ops)
                        await MainActor.run {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onDismiss() }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    /// Gate-aware OAuth primary action. For PKCE providers it's the
    /// unchanged "Start OAuth" button; for Nous it's "Sign in to Nous
    /// Portal" (opens ``NousSignInSheet``); for other device-code /
    /// external providers it's a disabled button with a CLI hint inline.
    @ViewBuilder
    private var oauthActionButton: some View {
        switch oauthGate(for: providerID) {
        case .providerEmpty:
            Button("Start OAuth") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .ok:
            Button("Start OAuth") {
                viewModel.startOAuth(provider: providerID, label: label)
                oauthStarted = true
            }
            .buttonStyle(.borderedProminent)
        case .useNousSignIn:
            Button("Sign in to Nous Portal") {
                showNousSignIn = true
            }
            .buttonStyle(.borderedProminent)
        case .useCLI:
            Button("Start OAuth") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }
}
