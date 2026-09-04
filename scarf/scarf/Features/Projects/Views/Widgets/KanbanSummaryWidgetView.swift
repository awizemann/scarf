import SwiftUI
import ScarfCore
import ScarfDesign

/// `kanban_summary` dashboard widget. Renders a compact 3-row list of
/// the most-pressing tasks (running + blocked + todo, by priority)
/// for the active project's tenant, plus a glance string footer.
///
/// Looks up the project's tenant from `<project>/.scarf/manifest.json`
/// at first render (cheap; cached). Falls back to "no tasks" copy when
/// no tenant is minted yet (i.e. the user hasn't opened the Kanban
/// tab yet).
struct KanbanSummaryWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(\.selectedProjectRoot) private var projectRoot

    // The 9pt initials badge was a hardcoded point size in a fixed 16x16
    // frame — defeats Dynamic Type. Scale both together.
    @ScaledMetric(relativeTo: .caption2) private var initialsSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var badgeDiameter: CGFloat = 16

    @State private var tenant: String?
    @State private var tenantProbe: TenantProbe?
    @State private var tasks: [HermesKanbanTask] = []
    @State private var stats: HermesKanbanStats = .empty
    @State private var isLoading = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    private var maxRows: Int {
        if case .number(let n) = widget.value { return max(1, Int(n)) }
        return 3
    }

    var body: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                header
                if let error {
                    errorRow(error)
                } else if tasks.isEmpty && !isLoading {
                    emptyRow
                } else {
                    ForEach(tasks.prefix(maxRows)) { task in
                        taskRow(task)
                    }
                }
                if !stats.glanceString.isEmpty {
                    Text(stats.glanceString)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .padding(.top, 4)
                }
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Text(widget.title.isEmpty ? "Kanban" : widget.title)
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer()
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(ScarfColor.foregroundMuted)
                .accessibilityHidden(true)
        }
    }

    private func taskRow(_ task: HermesKanbanTask) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            statusDot(for: task.status)
            Text(task.title)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let assignee = task.assignee, !assignee.isEmpty {
                Text(initials(of: assignee))
                    .font(.system(size: initialsSize, weight: .semibold))
                    .foregroundStyle(ScarfColor.accentActive)
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .background(ScarfColor.accentTint)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        // Status was an 8pt dot in color alone — invisible to VoiceOver and
        // indistinguishable to anyone colorblind. Speak it as a value on the
        // row instead of only on the dot glyph.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(statusLabel(for: task.status)))
    }

    private func statusDot(for status: String) -> some View {
        let color: Color
        let symbol: String
        switch KanbanStatus.from(status) {
        case .running:  color = ScarfColor.info;          symbol = "circle.fill"
        case .blocked:  color = ScarfColor.warning;        symbol = "exclamationmark.circle.fill"
        case .done:     color = ScarfColor.success;        symbol = "checkmark.circle.fill"
        default:        color = ScarfColor.foregroundMuted; symbol = "circle"
        }
        // Shape, not just hue, distinguishes status — running/blocked/done/
        // other now each draw a different glyph in addition to the color.
        return Image(systemName: symbol)
            .resizable()
            .frame(width: 8, height: 8)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func statusLabel(for status: String) -> String {
        switch KanbanStatus.from(status) {
        case .running:  return String(localized: "Running")
        case .blocked:  return String(localized: "Blocked")
        case .done:     return String(localized: "Done")
        case .ready:    return String(localized: "Ready")
        case .todo:     return String(localized: "To do")
        default:        return status
        }
    }

    private var emptyRow: some View {
        Text("No active tasks for this project.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundFaint)
            .padding(.vertical, ScarfSpace.s2)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
                .font(.caption)
            Text(message)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .lineLimit(2)
        }
    }

    // MARK: - Loading

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await loadOnce()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func loadOnce() async {
        guard let projectRoot, !projectRoot.isEmpty else { return }
        await refreshTenant(projectRoot: projectRoot)
        guard let tenant, !tenant.isEmpty else {
            tasks = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let svc = KanbanService(context: serverContext)
        let filter = KanbanListFilter(tenant: tenant)
        do {
            let polled = try await svc.list(filter)
            // Sort by priority DESC, status preference (running > blocked > todo).
            tasks = polled
                .filter {
                    let status = KanbanStatus.from($0.status)
                    return status != .done && status != .archived
                }
                .sorted { lhs, rhs in
                    let lp = lhs.priority ?? 0
                    let rp = rhs.priority ?? 0
                    if lp != rp { return lp > rp }
                    return statusRank(lhs.status) < statusRank(rhs.status)
                }
            stats = (try? await svc.stats()) ?? .empty
            error = nil
        } catch let err as KanbanError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private nonisolated func statusRank(_ status: String) -> Int {
        switch KanbanStatus.from(status) {
        case .running:  return 0
        case .blocked:  return 1
        case .ready:    return 2
        case .todo:     return 3
        default:        return 4
        }
    }

    /// Resolve the project's kanban tenant, OFF THE MAIN ACTOR and at
    /// most once per manifest change.
    ///
    /// Two things were wrong here (PERF M1, charter C10). It ran on the
    /// main actor: `readTenant` is `nonisolated`, but calling it from this
    /// `@MainActor` view ran it on the main thread anyway, and on a remote
    /// context it is two blocking SSH round-trips with a 60s timeout each
    /// — a beachball behind a dashboard widget. And a nil answer was never
    /// cached, so a project without a tenant (the common case before the
    /// user has opened the Kanban tab) re-paid that every 10 seconds
    /// forever.
    ///
    /// The negative result is cached against the manifest's SIGNATURE, so
    /// minting a tenant is picked up on the next poll: the signature is
    /// what invalidates it, and the file changing is exactly the event
    /// that can change the answer. The signature probe is one batched
    /// `stat`; the read + decode happen only when it moves.
    private func refreshTenant(projectRoot: String) async {
        let ctx = serverContext
        let manifestPath = projectRoot + "/.scarf/manifest.json"
        let previous = tenantProbe
        let probe = await Task.detached(priority: .utility) { () -> TenantProbe? in
            let transport = ctx.makeTransport()
            // `nil` from statAll is "don't trust this" — keep whatever we
            // already resolved rather than re-reading over a sick link.
            guard let stats = transport.statAll([manifestPath]) else { return nil }
            let signature = stats[manifestPath].map {
                "\(Int($0.mtime.timeIntervalSince1970)):\($0.size)"
            } ?? "-"
            if let previous, previous.path == manifestPath, previous.signature == signature {
                return nil
            }
            let tenant: String? = {
                guard signature != "-",
                      let data = try? transport.readFile(manifestPath),
                      let manifest = try? JSONDecoder().decode(
                        ProjectTemplateManifest.self, from: data)
                else { return nil }
                return manifest.kanbanTenant
            }()
            return TenantProbe(path: manifestPath, signature: signature, tenant: tenant)
        }.value
        guard let probe, projectRoot == self.projectRoot else { return }
        tenantProbe = probe
        tenant = probe.tenant
    }

    /// What the manifest said, and the signature it said it at.
    private struct TenantProbe: Sendable {
        var path: String
        var signature: String
        var tenant: String?
    }

    private func initials(of name: String) -> String {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
