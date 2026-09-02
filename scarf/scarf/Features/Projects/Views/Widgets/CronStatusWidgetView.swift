import SwiftUI
import ScarfCore
import ScarfDesign

/// Surfaces last-run / next-run / state for a single Hermes cron job by id,
/// plus a short tail of its most recent output. Read-only — Run / Pause /
/// Resume controls remain on the main Cron tab to keep this widget non-
/// destructive (the dashboard shouldn't be a place where the user
/// accidentally fires a job).
///
/// Refreshes whenever `HermesFileWatcher.lastChangeDate` ticks, which
/// covers both `cron/jobs.json` mutations and the project-wide `.scarf/`
/// watch installed in v2.7. Reads happen detached — never on the main
/// actor.
struct CronStatusWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(HermesFileWatcher.self) private var fileWatcher

    @State private var job: HermesCronJob?
    @State private var outputTail: String?
    @State private var loadError: String?
    @State private var isLoading = false

    private var jobId: String? { widget.jobId }
    private var lineCount: Int { max(1, min(40, widget.lines ?? 5)) }

    var body: some View {
        Group {
            if let jobId, !jobId.isEmpty {
                content(jobId: jobId)
            } else {
                WidgetErrorCard(
                    title: widget.title,
                    reason: "Missing required `jobId` field.",
                    hint: "Set `jobId` to a Hermes cron job's id (visible in the Cron tab)."
                )
            }
        }
        .task(id: "\(jobId ?? "")|\(lineCount)|\(fileWatcher.lastChangeDate.timeIntervalSince1970)") {
            await reload()
        }
    }

    @ViewBuilder
    private func content(jobId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading && job == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            if let job {
                jobRow(job)
                if let tail = outputTail, !tail.isEmpty {
                    tailView(tail)
                }
            } else if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !isLoading {
                Text("No cron job with id `\(jobId)`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private func jobRow(_ job: HermesCronJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(job.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                stateBadge(for: job)
            }
            HStack(spacing: 12) {
                if let last = job.lastRunAt, !last.isEmpty {
                    Label(last, systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if let next = job.nextRunAt, !next.isEmpty {
                    Label(next, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            if let lastError = job.lastError, !lastError.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.danger)
                    Text(lastError)
                        .lineLimit(2)
                }
                .font(.caption2)
                .foregroundStyle(ScarfColor.danger)
            }
        }
    }

    private func stateBadge(for job: HermesCronJob) -> some View {
        let (label, status): (String, ListItemStatus) = {
            if !job.enabled { return ("DISABLED", .neutral) }
            switch job.state.lowercased() {
            case "active", "running":   return (job.state.uppercased(), .info)
            case "paused":              return ("PAUSED", .warning)
            case "error", "failed":     return (job.state.uppercased(), .danger)
            default:                    return (job.state.uppercased(), .success)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.15))
            .foregroundStyle(status.tint)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func tailView(_ tail: String) -> some View {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).suffix(lineCount)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
    }

    private func reload() async {
        guard let jobId, !jobId.isEmpty else { return }
        let context = serverContext
        let lines = lineCount
        isLoading = true
        defer { isLoading = false }
        let result: (HermesCronJob?, String?, String?) = await Task.detached {
            let fs = HermesFileService(context: context)
            // Measures time to load cron jobs + output from disk/transport.
            let (jobs, outputRaw): ([HermesCronJob], String?) = ScarfMon.measure(.diskIO, "widget.cron_status.load") {
                (fs.loadCronJobs(), fs.loadCronOutput(jobId: jobId))
            }
            guard let match = jobs.first(where: { $0.id == jobId }) else {
                return (nil, nil, "No cron job with id `\(jobId)`.")
            }
            let trimmed: String? = {
                guard let outputRaw else { return nil }
                let stripped = AnsiStripper.strip(outputRaw)
                let allLines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
                let kept = allLines.suffix(lines)
                return kept.joined(separator: "\n")
            }()
            return (match, trimmed, nil)
        }.value
        // GENERATION GUARD. `.task(id:)` cancels this body when the widget's
        // refresh key changes, but cancellation does NOT stop a suspended
        // `await` from resuming — and the detached read above does not
        // inherit cancellation at all. Without this check a slow read from an
        // earlier watcher tick resumed AFTER the newer one had already
        // committed, and overwrote it with older content.
        guard !Task.isCancelled else { return }
        self.job = result.0
        self.outputTail = result.1
        self.loadError = result.2
    }
}
