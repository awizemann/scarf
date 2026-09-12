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
    /// Job ids whose INCIDENTS disclosure is open. Per-job, not a single
    /// shared flag: one `Bool` made expanding on job A silently expand the
    /// panel for every other job the user then selected.
    @State private var expandedIncidentJobIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// v0.19.0 — durable per-job execution history (`hermes cron runs`).
    /// Pre-0.19.0 hosts render the detail pane byte-identically: no RUN
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

    /// v0.21.0 — `_is_recoverable_error_job`: a recurring job in
    /// `state = "error"` is exempt from the terminal block and plain
    /// `cron resume` recovers it.
    private var hasCronRecoverableErrorResume: Bool {
        capabilitiesStore?.capabilities.hasCronRecoverableErrorResume ?? false
    }

    /// v0.18.1 — `resume_job`'s "one-shot time … is in the past" refusal.
    /// Gates the offer's third door so a pre-0.18.1 host, which resumes such
    /// a job happily, still gets a Resume button.
    private var hasCronPastOneShotResumeRefusal: Bool {
        capabilitiesStore?.capabilities.hasCronPastOneShotResumeRefusal ?? false
    }

    /// v0.20.6 — `--deliver bot-chat[:profile]`. Placeholder/hint only;
    /// the strip happens in `supportsCronDeliver`.
    private var hasCronBotChatDelivery: Bool {
        capabilitiesStore?.capabilities.hasCronBotChatDelivery ?? false
    }
    /// v0.21.1 — `--failure-deliver` on create/edit plus the `failure_deliver`
    /// job field. Unlike the deliver hints above this one is NOT cosmetic:
    /// the flag is unknown to older argparse, so the field is hidden AND the
    /// form value is stripped before it can reach the CLI.
    private var hasCronFailureDeliver: Bool {
        capabilitiesStore?.capabilities.hasCronFailureDeliver ?? false
    }
    /// v0.21.1 — `last_dispatch` / `last_delivery_unverified` read-only
    /// diagnostics. Field-presence decides what renders; this only decides
    /// whether to look, so a pre-v0.21.1 host is byte-identical to today.
    private var hasCronDispatchDiagnostics: Bool {
        capabilitiesStore?.capabilities.hasCronDispatchDiagnostics ?? false
    }
    /// v0.21.1 — `cron create --paused`, which also gates the past-one-shot
    /// pre-check (only a v0.21.1 host refuses such a create).
    private var hasCronCreatePaused: Bool {
        capabilitiesStore?.capabilities.hasCronCreatePaused ?? false
    }

    /// The past-one-shot pre-check is gated on the RELEASE, not on any one
    /// flag: only a v0.21.1 host rejects a one-shot whose timestamp is
    /// already past, and refusing locally on an older host would deny a
    /// write that host accepts. Reading `hasCronCreatePaused` for it worked
    /// only by having the same floor today.
    private var isV0211OrLater: Bool {
        capabilitiesStore?.capabilities.isV0211OrLater ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            // Shared resizable-column mechanism (Bots, Chat) instead of
            // HSplitView. HSplitView's two minWidths ADD UP (320 + 400):
            // in a detail column narrower than their sum it does not
            // shrink, it overflows — and the overflowing detail pane is
            // clipped, which takes its whole subtree out of the
            // accessibility tree (no `cron.detail.*`, not even the
            // "Select a cron job" placeholder), for VoiceOver exactly as
            // much as for XCUITest. A fixed-width list + a flexible
            // detail can never overflow, and the divider position now
            // persists across relaunches. 360 is the mockup's list width
            // (HSplitView had drifted to an even 50/50 split).
            HStack(spacing: 0) {
                jobsList
                    .resizableColumn(
                        key: "scarf.cron.listWidth",
                        defaultWidth: 360,
                        minWidth: 320,
                        maxWidth: 480
                    )
                jobDetail
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Cron Jobs")
        .loadingOverlay(viewModel.isLoading, label: "Loading cron jobs…", isEmpty: viewModel.jobs.isEmpty)
        .onAppear {
            viewModel.load(changeToken: fileWatcher.lastChangeDate)
            viewModel.isV0206OrLater = hasCronResumeRunNow
            viewModel.isV021OrLater = hasCronRecoverableErrorResume
            viewModel.isV0181OrLater = hasCronPastOneShotResumeRefusal
            viewModel.isV0211OrLater = isV0211OrLater
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
        .onChange(of: hasCronResumeRunNow) { _, newValue in viewModel.isV0206OrLater = newValue }
        .onChange(of: hasCronRecoverableErrorResume) { _, newValue in viewModel.isV021OrLater = newValue }
        .onChange(of: hasCronPastOneShotResumeRefusal) { _, newValue in viewModel.isV0181OrLater = newValue }
        .onChange(of: isV0211OrLater) { _, newValue in viewModel.isV0211OrLater = newValue }
        .onChange(of: hasCronIncidents) { _, newValue in if newValue { viewModel.loadIncidents() } }
        .onChange(of: hasCronDoctor) { _, newValue in if newValue { viewModel.loadDoctor() } }
        .sheet(isPresented: $viewModel.showCreateSheet) {
            CronJobEditor(mode: .create, availableSkills: viewModel.availableSkills, supportsWorkdir: hasCronWorkdir, supportsNoAgent: hasCronNoAgent, supportsDeliverAll: hasCronDeliverAll, supportsBotChatDelivery: hasCronBotChatDelivery, supportsFailureDeliver: hasCronFailureDeliver) { form in
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
                    noAgent: hasCronNoAgent ? form.noAgent : false,
                    failureDeliver: hasCronFailureDeliver ? form.failureDeliver : ""
                )
                viewModel.showCreateSheet = false
            } onCancel: {
                viewModel.showCreateSheet = false
            }
        }
        .sheet(item: $viewModel.editingJob) { job in
            CronJobEditor(mode: .edit(job), availableSkills: viewModel.availableSkills, supportsWorkdir: hasCronWorkdir, supportsNoAgent: hasCronNoAgent, supportsDeliverAll: hasCronDeliverAll, supportsBotChatDelivery: hasCronBotChatDelivery, supportsFailureDeliver: hasCronFailureDeliver) { form in
                viewModel.updateJob(
                    id: job.id,
                    // Untouched schedule → omit `--schedule` entirely. Re-sending
                    // a one-shot's own `run_at` would be rejected once that
                    // instant has passed (`cron/jobs.py` refuses a run_at outside
                    // the grace window), so a rename of a fired one-shot must not
                    // drag its spent timestamp along.
                    schedule: form.schedule == job.schedule.editValue ? nil : form.schedule,
                    prompt: form.prompt,
                    // The value the editor was SEEDED with, so `updateJob`
                    // can tell "user emptied the field" (a real clear
                    // gesture Hermes can express) from "field was always
                    // blank" — the same distinction `existingSkills` draws.
                    existingPrompt: job.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    repeatCount: form.repeatCount,
                    existingRepeatCount: job.repeatEditValue,
                    // The job's STORED skills, so the edit can be sent as a
                    // diff — `cron edit` treats "no --skill flags" as
                    // "untouched", not "clear" (see `skillEditArguments`).
                    existingSkills: job.skills ?? [],
                    newSkills: form.skills,
                    clearSkills: form.clearSkills,
                    script: form.script,
                    workdir: hasCronWorkdir ? form.workdir : nil,
                    noAgent: hasCronNoAgent ? form.noAgent : nil,
                    // `""` on edit is Hermes's clear-the-override gesture, so an
                    // emptied field is forwarded; `nil` (older host) omits it.
                    failureDeliver: hasCronFailureDeliver ? form.failureDeliver : nil
                )
                viewModel.editingJob = nil
            } onCancel: {
                viewModel.editingJob = nil
            }
        }
        // Round-4 decision 5. The hint on a job Hermes will not re-activate
        // says "duplicate it", and this is the button that sentence names —
        // an ORDINARY `cron create` pre-filled from the record, which is the
        // only door left open: `_reject_terminal_activation` guards
        // `update_job` (`cron/jobs.py:1941`, `:1965` @ `v2026.9.7`) and
        // `rearm_oneshot` refuses anything but `once` (`:2065-2066`), but
        // nothing guards a create.
        .sheet(item: $viewModel.duplicatingJob) { job in
            CronJobEditor(mode: .duplicate(job), availableSkills: viewModel.availableSkills, existingNames: viewModel.jobs.map(\.name), supportsWorkdir: hasCronWorkdir, supportsNoAgent: hasCronNoAgent, supportsDeliverAll: hasCronDeliverAll, supportsBotChatDelivery: hasCronBotChatDelivery, supportsFailureDeliver: hasCronFailureDeliver) { form in
                viewModel.createJob(
                    schedule: form.schedule,
                    prompt: form.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    skills: form.skills,
                    script: form.script,
                    repeatCount: form.repeatCount,
                    workdir: hasCronWorkdir ? form.workdir : "",
                    noAgent: hasCronNoAgent ? form.noAgent : false,
                    failureDeliver: hasCronFailureDeliver ? form.failureDeliver : ""
                )
                viewModel.duplicatingJob = nil
            } onCancel: {
                viewModel.duplicatingJob = nil
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
                // Failures no longer auto-clear (see CronViewModel.post), so
                // they get a colour and an explicit dismiss.
                let failed = viewModel.messageOutcome == .failure
                HStack(spacing: ScarfSpace.s1) {
                    Text(msg)
                        .scarfStyle(.caption)
                        .foregroundStyle(failed ? ScarfColor.danger : ScarfColor.foregroundMuted)
                        // UI gate: the ONLY place a failed `hermes cron …`
                        // is reported to the user, so a journey that sees a
                        // mutation not happen can say WHY.
                        .accessibilityIdentifier("cron.message")
                    if failed {
                        Button {
                            viewModel.dismissMessage()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .accessibilityLabel("Dismiss this cron error")
                    }
                }
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
                // UI gate (CronKanbanJourneyUITests): the only entry to
                // the create sheet.
                .accessibilityIdentifier("cron.newJob")
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
                            .accessibilityLabel("^[\(finding.issues.count) health issue](inflect: true)")
                    }
                    // v0.20.6 open failure incidents for this job.
                    if hasCronIncidents {
                        let open = viewModel.openIncidentCount(jobID: job.id)
                        if open > 0 {
                            ScarfBadge("^[\(open) incident](inflect: true)", kind: .danger)
                        }
                    }
                    if !job.enabled {
                        ScarfBadge("paused", kind: .neutral)
                    }
                    // Colour + an indefinite pulse were the ONLY rendering
                    // of run state. The pulse now stops under Reduce Motion
                    // (an endlessly repeating animation is exactly what that
                    // setting exists to suppress), and the state is spoken
                    // rather than left to hue.
                    Circle()
                        .fill(statusDotColor(job))
                        .frame(width: 7, height: 7)
                        .opacity(job.effectiveState == "running" && !reduceMotion ? 0.55 : 1.0)
                        .animation(
                            job.effectiveState == "running" && !reduceMotion
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: job.effectiveState
                        )
                        // The dot's meaning now rides in the ROW's own
                        // label (name + state), so a second stop that
                        // says only "Status: Paused" would be a repeat.
                        .accessibilityHidden(true)
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
            // THE row-selection bug: a `.plain` Button's hit area is its
            // label's OPAQUE content, and an unselected row's background
            // is `Color.clear` — so only the glyphs took clicks. A click
            // (or right-click) anywhere in the row's empty middle — which
            // is exactly where a synthesized click lands, and where a
            // mouse user aims — fell through to the ScrollView: no
            // selection, no context menu, and therefore a detail pane
            // that never had a job to show.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // UI gate: one row per job, keyed by the SAME id the CLI and
        // `cron/jobs.json` use, so a test can create a job, read its id
        // back from the file, and address exactly that row.
        .accessibilityIdentifier("cron.row.\(job.id)")
        // Name first, state after (list-row convention). The schedule and
        // next-run line stay reachable as the row's VALUE rather than
        // being swallowed by the explicit label.
        .accessibilityLabel(Text(rowAccessibilityLabel(job)))
        .accessibilityValue(Text(rowAccessibilityValue(job)))
        // Selection is conveyed visually by the tint alone.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            // The FOURTH offer site. It used to read `job.enabled` raw, which
            // made it the one place that still offered plain Resume for a
            // terminal or past-deadline job — a guaranteed exit 1 that the
            // detail pane and the Bots routines list had already stopped
            // offering. Same shared offer as `actionBar`, same conditions.
            let offer = viewModel.recoveryOffer(for: job)
            if job.enabled, !job.isTerminal {
                Button("Pause") { viewModel.pauseJob(job) }
                    // UI gate: addressed by identifier, not title — the Edit
                    // menu also has a "Delete" item, so a title lookup
                    // matches two elements.
                    .accessibilityIdentifier("cron.contextMenu.pauseToggle")
            } else if offer.canResume {
                Button("Resume") { viewModel.resumeJob(job) }
                    .accessibilityIdentifier("cron.contextMenu.pauseToggle")
            }
            if offer.canRearm {
                Button("Resume & Run Now") { viewModel.resumeAndRunNow(job) }
                    .accessibilityIdentifier("cron.contextMenu.resumeRunNow")
            }
            Button("Run Now") { viewModel.runNow(job) }
                // `trigger_job` uses the BARE `is_terminal_job`
                // (`cron/jobs.py:2012` @ v2026.9.7) with no
                // recoverable-error exemption, so a terminal job can never be
                // run — disabled exactly as `BotRoutinesView` disables it.
                .disabled(viewModel.refusesTerminalJobLocally(job))
            Button("Edit") { viewModel.editingJob = job }
            // Round-4 decision 5: the row menu offers the same remedy the
            // detail pane's hint names, unconditionally — a `cron create`
            // pre-filled from the record is accepted for ANY job, terminal
            // or not, so this one needs no gate.
            Button("Duplicate…") { viewModel.duplicatingJob = job }
                .accessibilityIdentifier("cron.contextMenu.duplicate")
            Divider()
            Button("Delete", role: .destructive) { pendingDelete = job }
                .accessibilityIdentifier("cron.contextMenu.delete")
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

    /// The state the row's coloured dot conveys, in words. Same
    /// precedence as `statusDotColor`, so the two can never disagree.
    /// Fragments are localized HERE (a `String` passed to
    /// `.accessibilityLabel` is never extracted).
    private func rowStateWord(_ job: HermesCronJob) -> String {
        if !job.enabled { return String(localized: "paused") }
        if job.effectiveState == "running" { return String(localized: "running") }
        if job.lastError != nil { return String(localized: "last run failed") }
        return String(localized: "scheduled")
    }

    /// Name first, state after — the list-row convention.
    private func rowAccessibilityLabel(_ job: HermesCronJob) -> String {
        "\(job.name), \(rowStateWord(job))"
    }

    /// What the explicit label would otherwise swallow: the schedule and
    /// the next-run line the row shows underneath the name.
    private func rowAccessibilityValue(_ job: HermesCronJob) -> String {
        var parts: [String] = []
        if let schedule = job.schedule.expression ?? job.schedule.display, !schedule.isEmpty {
            parts.append(schedule)
        }
        if let next = job.nextRunAt {
            parts.append(String(localized: "next \(CronScheduleFormatter.formatNextRun(iso: next))"))
        }
        // The badge and the warning icon are the row's only rendering of
        // these; an explicit row label would otherwise bury both.
        if hasCronDoctor, let finding = viewModel.doctorFindings[job.id] {
            parts.append(String(localized: "^[\(finding.issues.count) health issue](inflect: true)"))
        }
        if hasCronIncidents {
            let open = viewModel.openIncidentCount(jobID: job.id)
            if open > 0 { parts.append(String(localized: "^[\(open) open incident](inflect: true)")) }
        }
        return parts.joined(separator: ", ")
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

    /// The one cron state → badge colour mapping, shared with
    /// `BotRoutinesView` so the same job's state never renders in two colours
    /// in two panes. The keys are `effective_job_state`'s own vocabulary
    /// (`cron/jobs.py:488-503` @ `v2026.9.7`), plus `failed` as an alias the
    /// routines list already carried.
    static func badgeKind(for state: String) -> ScarfBadgeKind {
        switch state {
        case "scheduled": return .info
        case "running": return .brand
        case "completed": return .success
        case "error", "failed": return .danger
        case "paused": return .warning
        default: return .neutral
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
                    // `stateDisplay` (= `effectiveState`), never the raw
                    // `enabled` flag. The raw flag calls a `completed` or
                    // `error` job "paused" — a state Hermes's own
                    // `effective_job_state` deliberately refuses to claim
                    // (`cron/jobs.py:488-503` @ `v2026.9.7`: a terminal state
                    // is preserved regardless of `enabled`, and an `enabled`
                    // job is NEVER reported paused). Every other cron surface
                    // — the list row, the Bots routines list — already reads
                    // `stateDisplay`; this pane was the last raw read, so it
                    // was the one place a finished job looked merely paused
                    // and the Resume button looked like it would work.
                    ScarfBadge(verbatim: job.stateDisplay, kind: Self.badgeKind(for: job.stateDisplay))
                        // UI gate: the detail pane's rendering of
                        // enabled/paused — the thing a pause journey has
                        // to see change.
                        .accessibilityIdentifier("cron.detail.state")
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
            // `trigger_job` uses the BARE `is_terminal_job`
            // (`cron/jobs.py:2012` @ `v2026.9.7`) — no
            // `_is_recoverable_error_job` exemption, unlike the resume door —
            // so Run Now on a terminal job is a guaranteed exit 1. The row
            // context menu (`:494`) and `BotRoutinesView` (`:201-203`) already
            // disabled it; this pane's PRIMARY button was the one left live,
            // which is the loudest place to offer a refusal.
            .disabled(viewModel.refusesTerminalJobLocally(job))

            // The offer is computed once, from the two Hermes predicates —
            // `_is_recoverable_error_job` and `rearm_oneshot`'s
            // one-shot-only guard — so this pane, `BotRoutinesView` and iOS
            // all show the same buttons for the same job.
            let offer = viewModel.recoveryOffer(for: job)

            if job.enabled, !job.isTerminal {
                Button {
                    viewModel.pauseJob(job)
                } label: {
                    Image(systemName: "pause")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help("Pause")
                .accessibilityIdentifier("cron.detail.pauseToggle")
            } else if offer.canResume {
                Button {
                    viewModel.resumeJob(job)
                } label: {
                    Image(systemName: "play")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help("Resume")
                .accessibilityIdentifier("cron.detail.pauseToggle")
            }

            // v0.20.6 `cron resume --run-now` — re-arm. ONE-SHOT ONLY:
            // `rearm_oneshot` raises `_REARM_RECURRING_ERROR` for any other
            // schedule (`cron/jobs.py:2065-2066` @ v2026.9.7), so offering
            // it for a recurring job was a guaranteed exit 1.
            if offer.canRearm {
                Button {
                    viewModel.resumeAndRunNow(job)
                } label: {
                    Label("Resume & Run Now", systemImage: "forward.end.fill")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help(job.isTerminal
                      ? "This one-shot is \(job.effectiveState) — re-arm it for the next scheduler tick."
                      : "Resume and fire at the next scheduler tick instead of at its scheduled time.")
            }

            // Nothing Hermes would accept. Say so instead of offering a
            // dead end (round-3 product decision 1).
            if let hint = offer.hint {
                Text(hint)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cron.detail.recoveryHint")
            }
            // Every hint this offer can produce names duplicating as the
            // remedy (`CronRecoveryOffer.noFutureOccurrencesHint`,
            // `pastDeadlineOneShotHint`, `errorNeedsNewerHermesHint`), and a
            // hint that names a remedy has to be walked like a button — so
            // here is the button. Shown for the dead end, and for the
            // re-armable one-shot too: `noFutureOccurrencesHint` is not the
            // only sentence a user can act on, and a duplicate is always
            // accepted where a re-arm may not be.
            if offer.isDeadEnd || offer.canRearm {
                Button {
                    viewModel.duplicatingJob = job
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(ScarfSecondaryButton())
                .help("Create a new job pre-filled from this one — the only thing Hermes accepts for a job it won't re-activate.")
                .accessibilityIdentifier("cron.detail.duplicate")
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
            .accessibilityIdentifier("cron.detail.delete")
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

    private func statCard(label: LocalizedStringKey, value: String, sub: String?) -> some View {
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

        if hasCronFailureDeliver, let failureDeliver = job.failureDeliver {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(failureDeliver == "local"
                     ? String(localized: "Failures: suppressed (local)")
                     : String(localized: "Failures: \(failureDeliver)"))
                    .scarfStyle(.caption)
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
        }

        if hasCronDispatchDiagnostics {
            dispatchRow(job: job)
            deliveryUnverifiedBanner(job: job)
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

    /// v0.21.1 `last_dispatch` — scheduled-vs-actual timing for the last
    /// fire. Mirrors `hermes_cli/cron.py::_dispatch_display`: an on-time
    /// dispatch reads quietly, a late / catch-up one reads loudly, because a
    /// run that fired long after gateway downtime must not look like an
    /// ordinary success. Renders nothing when the stamp is absent or
    /// incomplete — presence, not version, decides (charter C4).
    @ViewBuilder
    private func dispatchRow(job: HermesCronJob) -> some View {
        if let dispatch = job.lastDispatch {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: dispatch.isLate ? "clock.badge.exclamationmark" : "clock")
                    .font(.system(size: 11))
                Text(Self.dispatchSummary(dispatch))
                    .scarfStyle(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(dispatch.isLate ? ScarfColor.warning : ScarfColor.foregroundMuted)
            .accessibilityIdentifier("cron.detail.dispatch")
        }
    }

    /// One line, matching `_dispatch_display`'s three shapes. The wording
    /// lives on `CronDispatchStamp` in ScarfCore so the parity suite can
    /// assert it against the CLI's own text.
    static func dispatchSummary(_ dispatch: CronDispatchStamp) -> String { dispatch.summary }

    /// v0.21.1 `last_delivery_unverified` — a live adapter acked the send but
    /// returned no `message_id`/`raw_response` (the Slack/Matrix/Mattermost
    /// shape). Accepted as delivered, so this is a note, not a failure.
    @ViewBuilder
    private func deliveryUnverifiedBanner(job: HermesCronJob) -> some View {
        if let note = job.deliveryUnverifiedNote {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                Text(note)
                    .scarfStyle(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(ScarfColor.warning)
            .accessibilityIdentifier("cron.detail.deliveryUnverified")
        }
    }

    /// Tooltip text for the list-row `cron doctor` warning icon.
    private func doctorTooltip(_ finding: HermesCronDoctorFinding) -> String {
        String(localized: "Health check: \(finding.issues.joined(separator: " · "))")
    }

    /// Inline `cron doctor` findings for the selected job — a warning
    /// card in the detail flow, not a separate health pane.
    private func doctorBanner(_ finding: HermesCronDoctorFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundStyle(ScarfColor.warning)
            VStack(alignment: .leading, spacing: 3) {
                // v0.21.1 split the delivery story: `delivery_failed` no
                // longer also emits `last run failed:`, and a new
                // "unverified" issue reports an ack with no receipt. That
                // last one is NOT a fault, so it is counted and rendered
                // apart — headlining it as an issue would have every
                // Slack-delivering job permanently badged broken.
                Text(finding.problemIssues.isEmpty
                     ? String(localized: "Health check: delivery unverified")
                     : String(localized: "Health check found ^[\(finding.problemIssues.count) issue](inflect: true)"))
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                ForEach(finding.problemIssues, id: \.self) { issue in
                    Text("• \(issue)")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(finding.unverifiedIssues, id: \.self) { issue in
                    Label(issue, systemImage: "questionmark.circle")
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
            let isExpanded = expandedIncidentJobIDs.contains(job.id)
            Button {
                if isExpanded { expandedIncidentJobIDs.remove(job.id) }
                else { expandedIncidentJobIDs.insert(job.id) }
            } label: {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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

            if isExpanded {
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

    /// Per-job durable run-history disclosure (v0.19.0+; gated on
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
    private func sectionBlock<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
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
        /// Round-4 decision 5. An ORDINARY create, pre-filled from an
        /// existing record — the only door Hermes leaves open for a job it
        /// refuses to re-activate. Not an edit: it runs `cron create`, so
        /// none of `_reject_terminal_activation`'s guards
        /// (`cron/jobs.py:1865-1878`, armed at `:1941`/`:1965` @ `v2026.9.7`)
        /// are on its path, and every flag it fills was walked at
        /// `hermes_cli/subcommands/cron.py:25-65` for `cron create`.
        case duplicate(HermesCronJob)

        /// The record this mode is seeded from, if any.
        var seed: HermesCronJob? {
            switch self {
            case .create: return nil
            case .edit(let job), .duplicate(let job): return job
            }
        }
    }

    struct FormState {
        var name: String = ""
        var schedule: String = ""
        var prompt: String = ""
        var deliver: String = ""
        /// v0.21.1 `--failure-deliver` — same grammar as Deliver, applied to
        /// FAILURE notices only. Empty = failures follow Deliver.
        var failureDeliver: String = ""
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
    /// Every job name currently on the host, used ONLY to seed a
    /// `.duplicate`'s name uniquely (``HermesCronDuplicateName``). Default
    /// empty so `.create` / `.edit` call sites need not pass it.
    var existingNames: [String] = []
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
    /// Pass `true` on v0.21.1+ hosts. Unlike the two hints above this hides
    /// the whole row: `--failure-deliver` is an unknown flag to older
    /// argparse and would fail the entire create/edit.
    var supportsFailureDeliver: Bool = false
    let onSave: (FormState) -> Void
    let onCancel: () -> Void

    @State private var form = FormState()
    @State private var isEditMode = false

    /// The TARGET host's capabilities, for the duplicate gaps line only.
    /// Read from the environment rather than plumbed through the three
    /// `supports…` flags above because the gaps list needs the FLOORS, not
    /// just "is the field visible" — and because `.empty` (no store) is
    /// exactly the state in which the parent's own `?? false` gates blank all
    /// three values, so naming all three is the correct answer there.
    @Environment(\.hermesCapabilities) private var duplicateGapCapabilitiesStore
    private var duplicateGapCapabilities: HermesCapabilities {
        duplicateGapCapabilitiesStore?.capabilities ?? .empty
    }

    /// The host roster plus any skill already on the job that the roster
    /// doesn't list, in roster order then job order. Keeps the block (and
    /// "Clear all skills on save") reachable on a host with an empty roster.
    private var skillRows: [String] {
        availableSkills + form.skills.filter { !availableSkills.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            headerText
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            formField("Name", text: $form.name, placeholder: "Friendly label")
                .accessibilityIdentifier("cron.editor.name")
            formField("Schedule", text: $form.schedule, placeholder: "0 9 * * *  or  30m  or  every 2h", mono: true)
                .accessibilityIdentifier("cron.editor.schedule")
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                TextEditor(text: $form.prompt)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("cron.editor.prompt")
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
                verbatimPlaceholder: deliverPlaceholder,
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
            if supportsFailureDeliver {
                formField(
                    "Failure deliver",
                    text: $form.failureDeliver,
                    verbatimPlaceholder: deliverPlaceholder,
                    mono: true
                )
                .accessibilityIdentifier("cron.editor.failureDeliver")
                Text("Where FAILURE notices go instead of Deliver — `local` suppresses them entirely (run state still shows in the list). Empty = failures follow Deliver. v0.21.1+ only.")
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
            // Rows = the host's roster PLUS any skill this job already
            // carries that the roster doesn't list (an uninstalled skill, or
            // a host whose roster read failed). Without that union the whole
            // block vanished on an empty roster, so a job's existing skills
            // could be neither edited nor cleared — see `skillRows`.
            if !skillRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(skillRows, id: \.self) { skill in
                                Toggle(skill, isOn: Binding(
                                    get: { form.skills.contains(skill) },
                                    set: { on in
                                        if on {
                                            if !form.skills.contains(skill) { form.skills.append(skill) }
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
                    // `--clear-skills` wins over `--add-skill` in
                    // `cron_edit` (hermes_cli/cron.py:612-618), so the two
                    // controls are mutually exclusive in the UI rather than
                    // silently discarding the checkboxes at save time.
                    .opacity(form.clearSkills ? 0.4 : 1.0)
                    .disabled(form.clearSkills)
                    if isEditMode {
                        Toggle("Clear all skills on save", isOn: $form.clearSkills)
                            .scarfStyle(.caption)
                            .tint(ScarfColor.accent)
                        if form.clearSkills {
                            Text("Every skill is removed from this job on save. Turn this off to pick skills individually.")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                    }
                }
                .opacity(form.noAgent ? 0.4 : 1.0)
                .disabled(form.noAgent)
            }
            // What a duplicate CANNOT carry. This form has no field for
            // `--model`/`--provider`/`--reasoning-effort`/`--monitor-script`/
            // `--monitor-url`/`--continuity`, so a record holding any of them
            // produces a copy that behaves differently — most sharply a
            // monitor job, which without its source runs the agent on every
            // tick. Naming them is the honest alternative to widening the
            // form; see `HermesCronJob.settingsACreateFormCannotCarry`.
            if case .duplicate(let job) = mode {
                let dropped = job.settingsACreateFormCannotCarry(caps: duplicateGapCapabilities)
                if !dropped.isEmpty {
                    Text("This copy won't carry: \(dropped.joined(separator: ", ")). Set those with `hermes cron edit` on the host.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cron.editor.duplicateGaps")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(ScarfGhostButton())
                Button("Save") { onSave(form) }
                    .buttonStyle(ScarfPrimaryButton())
                    .accessibilityIdentifier("cron.editor.save")
                    .disabled(form.schedule.isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(minWidth: 580, minHeight: 580)
        .background(ScarfColor.backgroundPrimary)
        .onAppear {
            // `.duplicate` seeds the SAME fields as `.edit` — that is what
            // "pre-filled from the record" means — but stays a create, so
            // `isEditMode` (which only gates the edit-only "Clear all skills
            // on save" toggle) stays false.
            if let job = mode.seed {
                if case .edit = mode { isEditMode = true }
                // A duplicate may NOT reuse the name: `resolve_job_ref`
                // matches on a case-folded name and raises
                // `AmbiguousJobReference` for both jobs as soon as two share
                // one (`cron/jobs.py:1840-1845` @ `v2026.9.7`), which breaks
                // `hermes cron run <name>` for the ORIGINAL too.
                if case .duplicate = mode {
                    form.name = HermesCronDuplicateName.next(for: job.name, existing: existingNames)
                } else {
                    form.name = job.name
                }
                // `editValue`, never `display`: a one-shot's display label
                // ("once at 2026-02-03 14:00") is not a schedule Hermes can
                // parse back, so seeding the field from it made every
                // one-shot edit fail at `parse_schedule`. See
                // `CronSchedule.editValue`.
                // `.duplicate` of a SPENT one-shot seeds the schedule field
                // EMPTY, not from the record: `cron create` refuses a
                // past-grace one-shot outright
                // (`_next_run_or_reject_past_oneshot`, `cron/jobs.py:1758`
                // → `:1663-1666` @ `v2026.9.7`), so pre-filling the dead time
                // built an argv guaranteed to exit 1 while the Duplicate hint
                // was already telling the user "with a new time". Save is
                // `.disabled(form.schedule.isEmpty)`, so an empty field IS the
                // ask. `.edit` keeps `editValue` — editing a past one-shot's
                // OTHER fields is a different verb with a different refusal.
                form.schedule = {
                    if case .duplicate = mode { return job.duplicateSeedSchedule() }
                    return job.schedule.editValue
                }()
                form.prompt = job.prompt
                form.deliver = job.deliver ?? ""
                form.failureDeliver = job.failureDeliver ?? ""
                form.skills = job.skills ?? []
                // `repeat` is unmodeled and rides in `extra`; `repeatSpec`
                // is the read side (a port of `cron/jobs.py::
                // normalize_repeat_value`, v2026.9.7 :591). Without this the
                // field opened blank on every edit, so saving an unrelated
                // change omitted `--repeat` and Hermes kept the old count —
                // but the user had just been shown "Optional count" and had
                // every reason to think the job repeated forever.
                // `nil` times = run forever, which IS the empty field.
                form.repeatCount = job.repeatEditValue
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

    private var headerText: Text {
        switch mode {
        case .create: return Text("Create Cron Job")
        case .edit(let job): return Text("Edit \(job.name)")
        case .duplicate(let job): return Text("Duplicate \(job.name)")
        }
    }

    @ViewBuilder
    private func formField(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        placeholder: LocalizedStringKey,
        mono: Bool = false
    ) -> some View {
        formField(label, text: text, placeholderText: Text(placeholder), mono: mono)
    }

    /// Escape hatch for the Deliver row, whose placeholder is assembled at
    /// runtime from the host's capability set.
    @ViewBuilder
    private func formField(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        verbatimPlaceholder: String,
        mono: Bool = false
    ) -> some View {
        formField(label, text: text, placeholderText: Text(verbatim: verbatimPlaceholder), mono: mono)
    }

    @ViewBuilder
    private func formField(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        placeholderText: Text,
        mono: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            TextField(text: text, prompt: placeholderText) { Text(label) }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(mono ? ScarfFont.monoSmall : ScarfFont.body)
                .accessibilityLabel(Text(label))
        }
    }
}
