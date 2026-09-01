import SwiftUI
import ScarfCore
import ScarfDesign

/// Cron — visual layer follows `design/static-site/ui-kit/Cron.jsx`:
/// page header (title + subtitle + New cron job action), 360 px job
/// list pane on the left with rust-active rows + status dots, detail
/// pane on the right with avatar header + active/paused pill + action
/// row + sectioned settings cards. The HSplitView master-detail
/// architecture is preserved (matches the mockup's 360 px list + flex
/// detail).
struct CronView: View {
    // Coordinator-cached (t-aud24) so it survives section switches.
    // `@Bindable` (not `let`) because the view needs `$viewModel` bindings
    // (e.g. `$viewModel.showCreateSheet`); the instance is still coordinator-
    // owned, not view-owned.
    @Bindable var viewModel: CronViewModel
    @State private var pendingDelete: HermesCronJob?
    @State private var showOutputPanel: Bool = false
    @State private var showRunHistory: Bool = false
    @State private var showIncidents: Bool = false
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(viewModel: CronViewModel) {
        self.viewModel = viewModel
    }

    private var hasCronWorkdir: Bool {
        capabilitiesStore?.capabilities.hasCronWorkdir ?? false
    }

    private var hasCronNoAgent: Bool {
        capabilitiesStore?.capabilities.hasCronNoAgent ?? false
    }
    /// v0.14 — `deliver=all` cron routing intent. Capability-gated so
    /// pre-v0.14 hosts don't see the placeholder hint and don't get
    /// the helper line under the field.
    private var hasCronDeliverAll: Bool {
        capabilitiesStore?.capabilities.hasCronDeliverAll ?? false
    }

    /// v0.20 — durable per-job execution history (`hermes cron runs`).
    /// Pre-0.20 hosts render the detail pane byte-identically: no RUN
    /// HISTORY disclosure and no CLI probe.
    private var hasCronRuns: Bool {
        capabilitiesStore?.capabilities.hasCronRuns ?? false
    }

    /// v0.20.6 — durable failure incidents (`hermes cron incidents`).
    /// Pre-0.20.6 hosts get no INCIDENTS disclosure, no row badge and
    /// no CLI probe.
    private var hasCronIncidents: Bool {
        capabilitiesStore?.capabilities.hasCronIncidents ?? false
    }

    /// v0.21 — `hermes cron doctor`. Drives the inline per-job warning
    /// affordance; absent everywhere below v0.21.
    private var hasCronDoctor: Bool {
        capabilitiesStore?.capabilities.hasCronDoctor ?? false
    }

    /// v0.20.6 — `hermes cron resume <id> --run-now`, the documented way
    /// to re-arm a completed/error (terminal) job.
    private var hasCronResumeRunNow: Bool {
        capabilitiesStore?.capabilities.hasCronResumeRunNow ?? false
    }

    /// v0.20.6 — `--deliver bot-chat[:profile]`. Placeholder/hint only;
    /// the strip happens in `supportsCronDeliver`.
    private var hasCronBotChatDelivery: Bool {
        capabilitiesStore?.capabilities.hasCronBotChatDelivery ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            HSplitView {
                jobsList
                    .frame(minWidth: 320, idealWidth: 360)
                jobDetail
                    .frame(minWidth: 400)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Cron Jobs")
        .loadingOverlay(viewModel.isLoading, label: "Loading cron jobs…", isEmpty: viewModel.jobs.isEmpty)
        .onAppear {
            viewModel.load(changeToken: fileWatcher.lastChangeDate)
            viewModel.supportsResumeRunNow = hasCronResumeRunNow
            // Both probes are one cheap read-only CLI call each, and both
            // feed always-visible affordances (row badge / warning icon),
            // so they can't be deferred behind a disclosure the way RUN
            // HISTORY is. Gated: a pre-0.20.6 / pre-0.21 host issues neither.
            if hasCronIncidents { viewModel.loadIncidents() }
            if hasCronDoctor { viewModel.loadDoctor() }
        }
        // Reload on Hermes file mutations — Hermes flips `state` between
        // "scheduled" and "running" inside `~/.hermes/cron/jobs.json`
        // when a job starts/finishes, and writes a new run-output file
        // under `~/.hermes/cron/output/`. The watcher gives us the
        // running indicator + log tail refresh "for free" without a
        // polling timer. Same wiring ActivityView uses.
        .onChange(of: fileWatcher.lastChangeDate) { _, newValue in viewModel.load(changeToken: newValue) }
        // The capability store probes `hermes --version` asynchronously,
        // so `onAppear` can run before the answer lands. Re-run the gated
        // work when it does — otherwise a cold launch shows no incidents,
        // no doctor findings, and the wrong terminal-refusal wording.
        .onChange(of: hasCronResumeRunNow) { _, newValue in viewModel.supportsResumeRunNow = newValue }
        .onChange(of: hasCronIncidents) { _, newValue in if newValue { viewModel.loadIncidents() } }
        .onChange(of: hasCronDoctor) { _, newValue in if newValue { viewModel.loadDoctor() } }
        .sheet(isPresented: $viewModel.showCreateSheet) {
            CronJobEditor(mode: .create, availableSkills: viewModel.availableSkills, supportsWorkdir: hasCronWorkdir, supportsNoAgent: hasCronNoAgent, supportsDeliverAll: hasCronDeliverAll, supportsBotChatDelivery: hasCronBotChatDelivery) { form in
                viewModel.createJob(
                    schedule: form.schedule,
                    prompt: form.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    skills: form.skills,
                    script: form.script,
                    repeatCount: form.repeatCount,
                    workdir: hasCronWorkdir ? form.workdir : "",
                    // Mirrors the workdir strip-on-pre-version pattern: pre-v0.13
                    // hosts get a hard `false`, so a stale form value (or a
                    // hand-edited jobs.json round-tripped through edit-mode)
                    // can't sneak `--no-agent` into a CLI that doesn't grok it.
                    noAgent: hasCronNoAgent ? form.noAgent : false
                )
                viewModel.showCreateSheet = false
            } onCancel: {
                viewModel.showCreateSheet = false
            }
        }
        .sheet(item: $viewModel.editingJob) { job in
            CronJobEditor(mode: .edit(job), availableSkills: viewModel.availableSkills, supportsWorkdir: hasCronWorkdir, supportsNoAgent: hasCronNoAgent, supportsDeliverAll: hasCronDeliverAll, supportsBotChatDelivery: hasCronBotChatDelivery) { form in
                viewModel.updateJob(
                    id: job.id,
                    schedule: form.schedule,
                    prompt: form.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    repeatCount: form.repeatCount,
                    newSkills: form.skills,
                    clearSkills: form.clearSkills,
                    script: form.script,
                    workdir: hasCronWorkdir ? form.workdir : nil,
                    noAgent: hasCronNoAgent ? form.noAgent : nil
                )
                viewModel.editingJob = nil
            } onCancel: {
                viewModel.editingJob = nil
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let job = pendingDelete { viewModel.deleteJob(job) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the scheduled job permanently.")
        }
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cron")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Scheduled agent runs. Each job invokes Hermes with a fixed prompt.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            if let msg = viewModel.message {
                Text(msg)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            HStack(spacing: ScarfSpace.s2) {
                Button {
                    viewModel.load(force: true)
                    if hasCronIncidents { viewModel.loadIncidents(force: true) }
                    if hasCronDoctor { viewModel.loadDoctor(force: true) }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ScarfGhostButton())
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Label("New cron job", systemImage: "plus")
                }
                .buttonStyle(ScarfPrimaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Jobs list

    private var jobsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if viewModel.jobs.isEmpty {
                    emptyJobs
                } else {
                    ForEach(viewModel.jobs) { job in
                        cronRow(job)
                    }
                }
            }
            .padding(ScarfSpace.s2)
        }
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(width: 1),
            alignment: .trailing
        )
    }

    private func cronRow(_ job: HermesCronJob) -> some View {
        let isActive = viewModel.selectedJob?.id == job.id
        return Button {
            viewModel.selectJob(job)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text(job.name)
                        .scarfStyle(isActive ? .bodyEmph : .body)
                        .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // v0.21 `cron doctor` finding for this job — a single
                    // icon with the issues in its tooltip, so the health
                    // check never costs a pane or a row of its own.
                    if hasCronDoctor, let finding = viewModel.doctorFindings[job.id] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(ScarfColor.warning)
                            .help(doctorTooltip(finding))
                            .accessibilityLabel("\(finding.issues.count) health issue\(finding.issues.count == 1 ? "" : "s")")
                    }
                    // v0.20.6 open failure incidents for this job.
                    if hasCronIncidents {
                        let open = viewModel.openIncidentCount(jobID: job.id)
                        if open > 0 {
                            ScarfBadge("\(open) incident\(open == 1 ? "" : "s")", kind: .danger)
                        }
                    }
                    if !job.enabled {
                        ScarfBadge("paused", kind: .neutral)
                    }
                    Circle()
                        .fill(statusDotColor(job))
                        .frame(width: 7, height: 7)
                        .opacity(job.effectiveState == "running" ? 0.55 : 1.0)
                        .animation(
                            job.effectiveState == "running"
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: job.effectiveState
                        )
                }
                HStack(spacing: 10) {
                    Text(job.schedule.expression ?? job.schedule.display ?? "—")
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let next = job.nextRunAt {
                        Text("· next \(CronScheduleFormatter.formatNextRun(iso: next))")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? ScarfColor.accentTint : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(job.enabled ? "Pause" : "Resume") {
                if job.enabled { viewModel.pauseJob(job) } else { viewModel.resumeJob(job) }
            }
            Button("Run Now") { viewModel.runNow(job) }
            Button("Edit") { viewModel.editingJob = job }
            Divider()
            Button("Delete", role: .destructive) { pendingDelete = job }
        }
    }

    private var emptyJobs: some View {
        VStack(spacing: ScarfSpace.s2) {
            Image(systemName: viewModel.loadDecodeFailed ? "exclamationmark.triangle" : "clock.arrow.2.circlepath")
                .font(.system(size: 24))
                .foregroundStyle(viewModel.loadDecodeFailed ? ScarfColor.warning : ScarfColor.foregroundFaint)
            Text(viewModel.loadDecodeFailed ? "Couldn't read cron jobs" : "No cron jobs yet")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
            if viewModel.loadDecodeFailed {
                // t-aud09: corrupt jobs.json used to render as a silent
                // empty board — surface it so the user knows jobs exist
                // but couldn't be parsed.
                Text("Its `jobs.json` couldn't be parsed and may be corrupt.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ScarfSpace.s8)
    }

    private func statusDotColor(_ job: HermesCronJob) -> Color {
        // Order matters: a currently-running job overrides a stale
        // lastError so the user sees "yes, retrying right now" rather
        // than "still showing the old failure." Disabled wins over
        // everything else — a paused job isn't running, regardless
        // of state-field churn.
        if !job.enabled { return ScarfColor.foregroundFaint }
        if job.effectiveState == "running" { return ScarfColor.info }
        if job.lastError != nil { return ScarfColor.danger }
        return ScarfColor.success
    }

    // MARK: - Job detail

    @ViewBuilder
    private var jobDetail: some View {
        if let job = viewModel.selectedJob {
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    detailHeader(job)
                    actionBar(job)
                    statsGrid(job)
                    detailBody(job)
                }
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(spacing: ScarfSpace.s2) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Text("Select a cron job")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ job: HermesCronJob) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ScarfColor.accentTint)
                Image(systemName: "clock")
                    .font(.system(size: 22))
                    .foregroundStyle(ScarfColor.accent)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.name)
                        .scarfStyle(.title2)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    ScarfBadge(job.enabled ? "active" : "paused",
                               kind: job.enabled ? .success : .neutral)
                    if job.effectiveState == "running" {
                        ScarfBadge("running…", kind: .info)
                    }
                }
                Text(CronScheduleFormatter.humanReadable(from: job.schedule))
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
        }
    }

    private func actionBar(_ job: HermesCronJob) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Button {
                viewModel.runNow(job)
            } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .buttonStyle(ScarfPrimaryButton())

            Button {
                if job.enabled { viewModel.pauseJob(job) } else { viewModel.resumeJob(job) }
            } label: {
                Image(systemName: job.enabled ? "pause" : "play")
            }
            .buttonStyle(ScarfSecondaryButton())
            .help(job.enabled ? "Pause" : "Resume")

            // v0.20.6 `cron resume --run-now`. Offered next to Resume
            // whenever plain Resume isn't the whole story: a paused job
            // the user wants fired immediately, and — the case Hermes
            // actually refuses — a terminal (completed/error) job, whose
            // ONLY re-arm path this is.
            if hasCronResumeRunNow, !job.enabled || job.isTerminal {
                Button {
                    viewModel.resumeAndRunNow(job)
                } label: {
                    Label("Resume & Run Now", systemImage: "forward.end.fill")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help(job.isTerminal
                      ? "This job is \(job.effectiveState) — re-arm it to fire immediately."
                      : "Resume and fire immediately instead of at the next scheduled time.")
            }

            Button {
                viewModel.editingJob = job
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(ScarfGhostButton())
            .help("Edit")

            Spacer()

            Button {
                pendingDelete = job
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ScarfDestructiveButton())
            .help("Delete")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statsGrid(_ job: HermesCronJob) -> some View {
        HStack(spacing: ScarfSpace.s3) {
            statCard(label: "Schedule",
                     value: CronScheduleFormatter.humanReadable(from: job.schedule),
                     sub: job.schedule.expression ?? job.schedule.display)
            statCard(label: "Last run",
                     value: job.lastRunAt.map { CronScheduleFormatter.formatNextRun(iso: $0) } ?? "—",
                     sub: job.lastError != nil ? "failed" : "ok")
            statCard(label: "Timeout",
                     value: job.timeoutSeconds.map { "\($0)s" } ?? "—",
                     sub: job.timeoutType)
            statCard(label: "Next run",
                     value: job.nextRunAt.map { CronScheduleFormatter.formatNextRun(iso: $0) } ?? (job.enabled ? "—" : "paused"),
                     sub: nil)
        }
    }

    private func statCard(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(value)
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailBody(_ job: HermesCronJob) -> some View {
        sectionBlock("PROMPT") {
            Text(job.prompt)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
                .padding(ScarfSpace.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let script = job.preRunScript, !script.isEmpty {
            sectionBlock("PRE-RUN SCRIPT") {
                Text(script)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(ScarfSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if let skills = job.skills, !skills.isEmpty {
            sectionBlock("SKILLS") {
                HStack {
                    ForEach(skills, id: \.self) { skill in
                        Text(skill)
                            .font(ScarfFont.monoSmall)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(ScarfColor.accentTint, in: Capsule())
                            .foregroundStyle(ScarfColor.accentActive)
                    }
                    Spacer(minLength: 0)
                }
                .padding(ScarfSpace.s3)
            }
        }

        if let deliver = job.deliveryDisplay {
            HStack(spacing: 6) {
                Image(systemName: "paperplane")
                    .font(.system(size: 11))
                Text("Deliver: \(deliver)")
                    .scarfStyle(.caption)
                if let failures = job.deliveryFailures, failures > 0 {
                    Text("· \(failures) failure\(failures == 1 ? "" : "s")")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
        }

        if hasCronDoctor, let finding = viewModel.doctorFindings[job.id] {
            doctorBanner(finding)
        }

        if let error = job.lastError {
            errorBanner(job: job, error: error)
        }

        outputPanel(job: job)

        if hasCronRuns {
            runHistoryPanel(job: job)
        }

        if hasCronIncidents {
            incidentsPanel(job: job)
        }
    }

    /// Tooltip text for the list-row `cron doctor` warning icon.
    private func doctorTooltip(_ finding: HermesCronDoctorFinding) -> String {
        "Health check: " + finding.issues.joined(separator: " · ")
    }

    /// Inline `cron doctor` findings for the selected job — a warning
    /// card in the detail flow, not a separate health pane.
    private func doctorBanner(_ finding: HermesCronDoctorFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundStyle(ScarfColor.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Health check found \(finding.issues.count) issue\(finding.issues.count == 1 ? "" : "s")")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                ForEach(finding.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.warning.opacity(0.25), lineWidth: 1)
        )
    }

    /// Per-job durable failure-incident disclosure (v0.20.6+; gated on
    /// `hasCronIncidents`). Mirrors the RUN HISTORY chrome. The listing
    /// is fetched once for all jobs (the CLI has no per-job filter), so
    /// expanding costs nothing beyond the initial probe.
    @ViewBuilder
    private func incidentsPanel(job: HermesCronJob) -> some View {
        let jobIncidents = viewModel.incidents.filter { $0.jobID == job.id }
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Button {
                showIncidents.toggle()
            } label: {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: showIncidents ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text("INCIDENTS")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    let open = jobIncidents.filter(\.isOpen).count
                    Text(jobIncidents.isEmpty
                         ? "none"
                         : "\(jobIncidents.count) total · \(open) open")
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(open > 0 ? ScarfColor.danger : ScarfColor.foregroundFaint)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showIncidents {
                Group {
                    if viewModel.isLoadingIncidents && viewModel.incidents.isEmpty {
                        Text("Loading incidents…")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(ScarfSpace.s3)
                    } else if jobIncidents.isEmpty {
                        Text("No failure incidents recorded for this job.")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(ScarfSpace.s3)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(jobIncidents) { incident in
                                incidentRow(incident)
                                if incident.id != jobIncidents.last?.id {
                                    Rectangle().fill(ScarfColor.border).frame(height: 1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
            }
        }
    }

    private func incidentRow(_ incident: HermesCronIncident) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(incidentStateColor(incident.state))
                    .frame(width: 7, height: 7)
                Text(incident.state)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(incident.failureType)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text(CronScheduleFormatter.formatNextRun(iso: incident.lastSeenAt))
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer(minLength: 4)
                if incident.isOpen {
                    Button("Ack") { viewModel.ackIncident(incident) }
                        .buttonStyle(ScarfGhostButton())
                        .help("Acknowledge — silences this failure signature until the error changes.")
                }
            }
            if !incident.error.isEmpty {
                Text(incident.error)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.danger)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 7)
    }

    private func incidentStateColor(_ state: String) -> Color {
        switch state {
        case "detected": return ScarfColor.danger
        case "alerted": return ScarfColor.warning
        case "closed": return ScarfColor.success
        default: return ScarfColor.foregroundFaint
        }
    }

    /// Per-job durable run-history disclosure (v0.20+; gated on
    /// `hasCronRuns`). Collapsed by default and lazy — `hermes cron runs
    /// <id>` only fires when the user expands it, and re-fires when the
    /// selection changes while expanded. Mirrors the LAST RUN OUTPUT
    /// panel's collapsed-chevron chrome so the detail pane stays uniform.
    @ViewBuilder
    private func runHistoryPanel(job: HermesCronJob) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Button {
                showRunHistory.toggle()
                if showRunHistory { viewModel.loadRunHistory(jobID: job.id) }
            } label: {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: showRunHistory ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text("RUN HISTORY")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showRunHistory {
                Group {
                    if viewModel.isLoadingRunHistory && viewModel.runHistory.isEmpty {
                        Text("Loading run history…")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(ScarfSpace.s3)
                    } else if viewModel.runHistory.isEmpty {
                        Text("No execution attempts recorded for this job yet.")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(ScarfSpace.s3)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.runHistory) { run in
                                runHistoryRow(run)
                                if run.id != viewModel.runHistory.last?.id {
                                    Rectangle().fill(ScarfColor.border).frame(height: 1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
            }
        }
        // Selection changed while expanded → load the new job's history.
        .onChange(of: job.id) { _, newID in
            if showRunHistory { viewModel.loadRunHistory(jobID: newID) }
        }
    }

    private func runHistoryRow(_ run: HermesCronRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runStatusColor(run.status))
                    .frame(width: 7, height: 7)
                Text(run.status)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(CronScheduleFormatter.formatNextRun(iso: run.claimedAt))
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer(minLength: 4)
                Text(run.source)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            if let error = run.error {
                Text(error)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.danger)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 7)
    }

    private func runStatusColor(_ status: String) -> Color {
        switch status {
        case "completed": return ScarfColor.success
        case "failed": return ScarfColor.danger
        case "running", "claimed": return ScarfColor.info
        default: return ScarfColor.foregroundFaint  // "unknown" + future values
        }
    }

    /// Last-error surface. When `ACPErrorHint` recognizes the message
    /// (OAuth refresh-revoked, missing credentials, SSH failure, etc.),
    /// it renders the human hint + raw error + a re-auth button when
    /// applicable. Otherwise falls back to the legacy single-line
    /// red text — same chrome the view used pre-PR for unrecognized
    /// errors. Mirrors `ChatView.errorBanner` so the recovery flow is
    /// identical between cron and chat.
    @ViewBuilder
    private func errorBanner(job: HermesCronJob, error: String) -> some View {
        if let classification = viewModel.selectedErrorClassification {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(classification.hint)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .textSelection(.enabled)
                        Text(error)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Spacer(minLength: ScarfSpace.s2)
                    if let provider = classification.oauthProvider {
                        Button("Re-authenticate") {
                            coordinator.pendingOAuthReauth = provider
                            coordinator.selectedSection = .credentialPools
                        }
                        .buttonStyle(ScarfPrimaryButton())
                        .help("Open Credential Pools and re-authenticate \(provider).")
                    }
                }
            }
            .padding(ScarfSpace.s3)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .fill(ScarfColor.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .strokeBorder(ScarfColor.warning.opacity(0.25), lineWidth: 1)
            )
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .scarfStyle(.caption)
                    .textSelection(.enabled)
            }
            .foregroundStyle(ScarfColor.danger)
        }
    }

    /// Per-job run-output panel. Always visible; collapsed by default
    /// with a one-line summary so the detail pane stays scannable when
    /// the user has dozens of cron jobs. Expanded body mirrors the
    /// dark monospaced tail layout `LogsView` uses, fed by
    /// `HermesFileService.loadCronOutput` (Hermes writes per-run files
    /// under `~/.hermes/cron/output/<jobId>-*`). Reload happens via the
    /// outer `HermesFileWatcher` `.onChange` — when a fresh run lands a
    /// new output file, the VM re-reads on the next mtime tick.
    @ViewBuilder
    private func outputPanel(job: HermesCronJob) -> some View {
        let summary = outputSummary(job)
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Button {
                showOutputPanel.toggle()
            } label: {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: showOutputPanel ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text("LAST RUN OUTPUT")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text(summary)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showOutputPanel {
                if let output = viewModel.jobOutput, !output.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(output)
                                .font(ScarfFont.monoSmall)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(ScarfSpace.s3)
                                .id("cron-output-bottom")
                        }
                        .frame(maxHeight: 320)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .fill(Color(red: 0.07, green: 0.06, blue: 0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                        )
                        // Auto-scroll to the latest line whenever the
                        // output content changes (a new run lands).
                        .onChange(of: output) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("cron-output-bottom", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            proxy.scrollTo("cron-output-bottom", anchor: .bottom)
                        }
                    }
                } else {
                    Text("No output yet — this job hasn't run, or its output file is gone.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ScarfSpace.s3)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .fill(ScarfColor.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                        )
                }
            }
        }
    }

    /// One-line summary rendered next to the LAST RUN OUTPUT chevron
    /// when the panel is collapsed. Gives a quick "yes there's content"
    /// (or "no output yet") read without expanding.
    private func outputSummary(_ job: HermesCronJob) -> String {
        let timestamp = job.lastRunAt.map { CronScheduleFormatter.formatNextRun(iso: $0) } ?? "never"
        let status: String = {
            if job.effectiveState == "running" { return "running…" }
            if job.lastError != nil { return "error" }
            if job.lastRunAt != nil { return "ok" }
            return "no runs yet"
        }()
        return "\(timestamp) — \(status)"
    }

    @ViewBuilder
    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text(title)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            content()
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
        }
    }
}

/// Create/edit sheet. Form fields mirror `hermes cron create|edit` flags.
struct CronJobEditor: View {
    enum Mode {
        case create
        case edit(HermesCronJob)
    }

    struct FormState {
        var name: String = ""
        var schedule: String = ""
        var prompt: String = ""
        var deliver: String = ""
        var repeatCount: String = ""
        var skills: [String] = []
        var clearSkills: Bool = false
        var script: String = ""
        /// v0.12+ workdir flag — fills `--workdir <path>`. Empty string
        /// preserves the v0.11 behaviour of running with no cwd hint.
        var workdir: String = ""
        /// v0.13+ `--no-agent` flag — script-only watchdog mode. Hermes
        /// runs the pre-run script and skips the AI turn.
        var noAgent: Bool = false
    }

    let mode: Mode
    let availableSkills: [String]
    /// Pass `false` on pre-v0.12 hosts; the `--workdir` field is hidden and
    /// the form's value is dropped when the parent calls `createJob`/`updateJob`.
    let supportsWorkdir: Bool
    /// Pass `false` on pre-v0.13 hosts; the `--no-agent` toggle is hidden
    /// and the parent strips the form's value before calling
    /// `createJob`/`updateJob`. Mirrors the `supportsWorkdir` pattern.
    let supportsNoAgent: Bool
    /// Pass `true` on v0.14+ hosts so the Deliver placeholder mentions
    /// the new `all` fan-out value. The field itself is free-form so
    /// the user can always type `all` on any host; the placeholder is
    /// the only behavior change.
    var supportsDeliverAll: Bool = false
    /// Pass `true` on v0.20.6+ hosts so `bot-chat[:profile]` shows up as
    /// a delivery target. Same placeholder/hint-only treatment as
    /// `supportsDeliverAll`: a pre-0.20.6 host would fail the whole
    /// `cron create` at argparse, which `supportsCronDeliver` guards for
    /// the copy/fleet paths.
    var supportsBotChatDelivery: Bool = false
    let onSave: (FormState) -> Void
    let onCancel: () -> Void

    @State private var form = FormState()
    @State private var isEditMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text(headerText)
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            formField("Name", text: $form.name, placeholder: "Friendly label")
            formField("Schedule", text: $form.schedule, placeholder: "0 9 * * *  or  30m  or  every 2h", mono: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                TextEditor(text: $form.prompt)
                    .font(ScarfFont.mono)
                    .frame(minHeight: 100)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                                    .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                            )
                    )
                    .scrollContentBackground(.hidden)
            }
            .opacity(form.noAgent ? 0.4 : 1.0)
            .disabled(form.noAgent)
            formField(
                "Deliver",
                text: $form.deliver,
                placeholder: deliverPlaceholder,
                mono: true
            )
            if supportsDeliverAll {
                Text("`all` fans out to every connected channel — v0.14+ only.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            if supportsBotChatDelivery {
                Text("`bot-chat[:profile]` injects the output into a local profile's Bot Chat as a message the bot responds to — v0.20.6+ only.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            formField("Repeat", text: $form.repeatCount, placeholder: "Optional count")
            formField("Script path", text: $form.script, placeholder: "Python script whose stdout is injected", mono: true)
            if supportsWorkdir {
                formField("Workdir", text: $form.workdir, placeholder: "Absolute path; pulls AGENTS.md/CLAUDE.md context", mono: true)
            }
            if supportsNoAgent {
                Toggle("Run script only (no agent call)", isOn: $form.noAgent)
                    .scarfStyle(.body)
                    .tint(ScarfColor.accent)
                if form.noAgent {
                    Text("Watchdog mode — Hermes runs the pre-run script and skips the AI turn. Prompt + skills are ignored.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(.leading, ScarfSpace.s3)
                }
            }
            if !availableSkills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableSkills, id: \.self) { skill in
                                Toggle(skill, isOn: Binding(
                                    get: { form.skills.contains(skill) },
                                    set: { on in
                                        if on {
                                            form.skills.append(skill)
                                        } else {
                                            form.skills.removeAll { $0 == skill }
                                        }
                                    }
                                ))
                                .font(ScarfFont.monoSmall)
                                .toggleStyle(.checkbox)
                                .tint(ScarfColor.accent)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                    )
                    if isEditMode {
                        Toggle("Clear all skills on save", isOn: $form.clearSkills)
                            .scarfStyle(.caption)
                            .tint(ScarfColor.accent)
                    }
                }
                .opacity(form.noAgent ? 0.4 : 1.0)
                .disabled(form.noAgent)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(ScarfGhostButton())
                Button("Save") { onSave(form) }
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(form.schedule.isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(minWidth: 580, minHeight: 580)
        .background(ScarfColor.backgroundPrimary)
        .onAppear {
            if case .edit(let job) = mode {
                isEditMode = true
                form.name = job.name
                form.schedule = job.schedule.expression ?? job.schedule.display ?? ""
                form.prompt = job.prompt
                form.deliver = job.deliver ?? ""
                form.skills = job.skills ?? []
                form.script = job.preRunScript ?? ""
                form.workdir = job.workdir ?? ""
                form.noAgent = job.noAgent ?? false
            }
        }
    }

    /// Free-form field; the placeholder is the only capability-driven
    /// difference (the user can always type any value on any host).
    private var deliverPlaceholder: String {
        var options = ["origin", "local"]
        if supportsDeliverAll { options.append("all") }
        if supportsBotChatDelivery { options.append("bot-chat[:profile]") }
        options += ["discord:CHANNEL", "telegram:CHAT"]
        return options.joined(separator: " | ")
    }

    private var headerText: String {
        switch mode {
        case .create: return "Create Cron Job"
        case .edit(let job): return "Edit \(job.name)"
        }
    }

    @ViewBuilder
    private func formField(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? ScarfFont.monoSmall : ScarfFont.body)
                .accessibilityLabel(label)
        }
    }
}
