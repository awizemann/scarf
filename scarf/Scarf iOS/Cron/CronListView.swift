import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS Cron screen. M6 gained: toggle-enabled, swipe-to-delete,
/// "+" toolbar → editor sheet, and row-tap → edit existing job.
struct CronListView: View {
    let config: IOSServerConfig

    @State private var vm: IOSCronViewModel
    @State private var editingJob: HermesCronJob?
    @State private var showingNewJob = false
    /// Round-4 decision 5 — the pre-filled create the recovery hint names.
    /// A separate slot from `editingJob`, because it seeds a NEW record
    /// (`HermesCronJob.duplicatedAsNewJob`) rather than editing this one.
    @State private var duplicatingJob: HermesCronJob?

    /// Same mirror the Mac's `CronView` performs onto `CronViewModel`: the
    /// two recovery floors that decide what a wedged job may be offered
    /// (`hasCronResumeRunNow` = v0.20.6, `hasCronRecoverableErrorResume` =
    /// v0.21.0). Without them iOS and the Mac made different offers for the
    /// same job — the P30 finding.
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private var hasCronResumeRunNow: Bool {
        capabilitiesStore?.capabilities.hasCronResumeRunNow ?? false
    }

    private var hasCronRecoverableErrorResume: Bool {
        capabilitiesStore?.capabilities.hasCronRecoverableErrorResume ?? false
    }

    /// v0.18.1 — `resume_job`'s past-one-shot refusal. iOS used to apply this
    /// rule unflagged and BEFORE the offer; it is now the offer's third door,
    /// so the Mac inherits it too and both platforms gate it on the floor.
    private var hasCronPastOneShotResumeRefusal: Bool {
        capabilitiesStore?.capabilities.hasCronPastOneShotResumeRefusal ?? false
    }

    private func mirrorCapabilities() {
        vm.isV0206OrLater = hasCronResumeRunNow
        vm.isV021OrLater = hasCronRecoverableErrorResume
        vm.isV0181OrLater = hasCronPastOneShotResumeRefusal
    }

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(config: IOSServerConfig) {
        self.config = config
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _vm = State(initialValue: IOSCronViewModel(context: ctx))
    }

    var body: some View {
        List {
            if let err = vm.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                }
            }

            if vm.jobs.isEmpty, !vm.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No cron jobs yet.")
                            .font(.headline)
                        Text("Tap \(Image(systemName: "plus.circle.fill")) to create one, or manage them from the Mac app.")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(vm.jobs) { job in
                        CronRow(job: job) {
                            Task { await vm.toggleEnabled(id: job.id) }
                        } onTap: {
                            editingJob = job
                        }
                        .scarfGoCompactListRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await vm.delete(id: job.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            // Round-5 review (P50b). Every refusal sentence
                            // this screen shows in its top banner names
                            // Duplicate as the remedy
                            // (`IOSCronViewModel.resumeRefusalMessage` →
                            // "Duplicate it to schedule a new run."), and the
                            // only way to reach it was a long press. A hint
                            // that names a gesture must put that gesture
                            // within reach of the row it is about. Same
                            // action as the context menu's, no new logic.
                            Button {
                                duplicatingJob = job
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(ScarfColor.accent)
                        }
                        .contextMenu {
                            // The SAME shared offer the Mac's detail pane and
                            // the Bots routines list render, so all three make
                            // one offer for one job
                            // (`HermesCronJob.recoveryOffer`).
                            let offer = vm.recoveryOffer(for: job)
                            // Round-4 decision 6: iOS has the re-arm door now
                            // rather than pointing at the Mac.
                            if offer.canRearm {
                                Button {
                                    Task { await vm.resumeAndRunNow(id: job.id) }
                                } label: {
                                    Label("Resume & Run Now", systemImage: "forward.end.fill")
                                }
                            }
                            // Round-4 decision 5: the remedy every hint names.
                            // Unconditional — a create is accepted for any
                            // record, terminal or not.
                            Button {
                                duplicatingJob = job
                            } label: {
                                Label("Duplicate…", systemImage: "plus.square.on.square")
                            }
                        }
                    }
                }
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Cron jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewJob = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(vm.isSaving)
            }
        }
        .overlay {
            if vm.isLoading && vm.jobs.isEmpty {
                ProgressView("Loading jobs…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .refreshable { await vm.load() }
        .task {
            mirrorCapabilities()
            await vm.load()
        }
        // The store probes `hermes --version` asynchronously, so `.task`
        // can run before the answer lands (same reasoning as `CronView`).
        .onChange(of: hasCronResumeRunNow) { _, _ in mirrorCapabilities() }
        .onChange(of: hasCronRecoverableErrorResume) { _, _ in mirrorCapabilities() }
        .onChange(of: hasCronPastOneShotResumeRefusal) { _, _ in mirrorCapabilities() }
        .sheet(item: $editingJob) { job in
            CronEditorView(
                initial: job, title: "Edit cron job",
                // The edit sheet is the one arm with a real record behind it,
                // so it is the one arm that can refuse Enabled.
                recoveryOffer: vm.recoveryOffer(for: job)
            ) { edited in
                Task { await vm.upsert(edited) }
            }
            // Cron editor is a Form with ~6 fields; .large gives room
            // without cramping. No peek detent — editing cron jobs is
            // a focused task, not something users want to half-see.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $duplicatingJob) { job in
            // An ordinary create, pre-filled: on iOS a create IS a rewrite of
            // `cron/jobs.json` (see `IOSCronViewModel.saveJobs`), so the seed
            // is a fresh record rather than a `cron create` argv — and it can
            // carry every field, including the ones the Mac's create FORM has
            // no widget for.
            CronEditorView(
                initial: job.duplicatedAsNewJob(
                        id: "job_\(UUID().uuidString.prefix(8))",
                        existingNames: vm.jobs.map(\.name)),
                title: "Duplicate cron job",
                // A duplicate's seed is `enabled: true, state: "scheduled"`
                // — a fresh record refuses nothing.
                recoveryOffer: .none
            ) { created in
                Task { await vm.upsert(created) }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingNewJob) {
            CronEditorView(
                initial: nil, title: "New cron job", recoveryOffer: .none
            ) { created in
                Task { await vm.upsert(created) }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct CronRow: View {
    let job: HermesCronJob
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: job.enabled
                    ? "checkmark.circle.fill"
                    : "circle")
                    .font(.title3)
                    .foregroundStyle(job.enabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        if !job.enabled {
                            Text("DISABLED")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(.secondarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(CronScheduleFormatter.humanReadable(from: job.schedule))
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text("Next: \(CronScheduleFormatter.formatNextRun(iso: job.nextRunAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

/// Sheet for creating or editing a single `HermesCronJob`. Scoped
/// to the fields a user typically sets; runtime state fields
/// (delivery_failures, last_run_at, etc.) pass through untouched
/// when editing an existing job.
struct CronEditorView: View {
    /// P60: a `LocalizedStringResource`, not a `String`.
    ///
    /// `.navigationTitle(_:)` has a `StringProtocol` overload that renders
    /// its argument VERBATIM, and a `String` parameter selected it — so the
    /// three call sites' literals ("Edit cron job", "New cron job",
    /// "Duplicate cron job") reached the bar untranslated even though all
    /// three already have rows in `Localizable.xcstrings` in six locales.
    /// A `LocalizedStringResource` makes the literals resource literals at
    /// the call site and forces the resolving path through `Text`.
    let title: LocalizedStringResource
    let onSave: (HermesCronJob) -> Void
    @Environment(\.dismiss) private var dismiss

    // Form-backing state.
    @State private var id: String
    @State private var name: String
    @State private var prompt: String
    @State private var model: String
    @State private var skills: String  // comma-separated
    @State private var deliver: String
    @State private var enabled: Bool

    @State private var scheduleKind: String
    @State private var scheduleDisplay: String
    @State private var scheduleRunAt: String
    @State private var scheduleExpression: String

    private let existing: HermesCronJob?

    /// The SAME shared offer the row toggle gates on
    /// (`IOSCronViewModel.recoveryOffer(for:)` → `HermesCronJob.recoveryOffer`),
    /// handed in because this sheet has no view model. Round-5 review (P50b):
    /// no default, because this parameter IS the fix — a caller that forgets
    /// it must not silently get the ungated editor back.
    private let recoveryOffer: CronRecoveryOffer

    init(
        initial: HermesCronJob?,
        title: LocalizedStringResource,
        recoveryOffer: CronRecoveryOffer,
        onSave: @escaping (HermesCronJob) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        self.existing = initial
        self.recoveryOffer = recoveryOffer
        _id = State(initialValue: initial?.id ?? "job_\(UUID().uuidString.prefix(8))")
        _name = State(initialValue: initial?.name ?? "")
        _prompt = State(initialValue: initial?.prompt ?? "")
        _model = State(initialValue: initial?.model ?? "")
        _skills = State(initialValue: (initial?.skills ?? []).joined(separator: ", "))
        _deliver = State(initialValue: initial?.deliver ?? "")
        _enabled = State(initialValue: initial?.enabled ?? true)
        // NOT the F5 seed-from-display bug. F5 fixed a Mac editor that
        // collapsed a schedule into ONE free-text field seeded from
        // `schedule.display` and then posted it to `hermes cron edit
        // --schedule`, where `parse_schedule` cannot read "once at 2026-02-03
        // 14:00" back. This editor has separate `run_at` / `expr` fields —
        // already exactly what `CronSchedule.editValue` would select — and
        // iOS persists by rewriting `jobs.json` directly (see
        // `IOSCronViewModel.saveJobs`), so `parse_schedule` is never invoked
        // and `display` round-trips as the label it is. Verified before
        // changing anything; `editValue` would be a no-op here.
        _scheduleKind = State(initialValue: initial?.schedule.kind ?? "cron")
        _scheduleDisplay = State(initialValue: initial?.schedule.display ?? "")
        _scheduleRunAt = State(initialValue: initial?.schedule.runAt ?? "")
        _scheduleExpression = State(initialValue: initial?.schedule.expression ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    Toggle("Enabled", isOn: $enabled)
                        .disabled(enabledIsLocked)
                } header: {
                    Text("Job")
                } footer: {
                    if enabledIsLocked, let existing {
                        // The same REASON the row toggle gives, worded for a
                        // modal: `resumeRefusalMessage`'s two remedies name
                        // "Resume & Run Now" and "duplicate it", and neither
                        // is reachable from inside this sheet — both live on
                        // the list row the sheet is covering (round-6 P53).
                        Text(IOSCronViewModel.editorEnabledLockNote(
                            existing, offer: recoveryOffer))
                    }
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                        .font(.body)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Schedule") {
                    Picker("Kind", selection: $scheduleKind) {
                        Text("cron").tag("cron")
                        Text("interval").tag("interval")
                        Text("once").tag("once")
                    }
                    TextField("Display (e.g. \"9am weekdays\")", text: $scheduleDisplay)
                        .autocorrectionDisabled()
                    if scheduleKind == "cron" {
                        TextField("Expression (e.g. \"0 9 * * 1-5\")", text: $scheduleExpression)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if scheduleKind == "once" {
                        TextField("Run at (ISO8601)", text: $scheduleRunAt)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if oneShotTimeIsUnusable {
                            Text("Pick a future time — a one-shot more than \(Int(HermesCronJob.oneShotGraceSeconds)) s in the past can never fire.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("cron.editor.pastOneShot")
                        }
                    }
                    // Save is already grey; without this the user has no way
                    // to learn WHICH field is refused, and the failure this
                    // stops is invisible — Hermes takes the record and the
                    // job simply never fires.
                    if let refusal = scheduleRefusal {
                        Text(refusal.message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("cron.editor.scheduleRefusal")
                    }
                }

                Section("Optional") {
                    TextField("Model (leave blank to use default)", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Skills (comma-separated)", text: $skills)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Deliver (e.g. discord:channel)", text: $deliver)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(buildJob())
                        dismiss()
                    }
                    .disabled(!isValid)
                    .bold()
                }
            }
        }
    }

    /// A `once` job whose `run_at` is already past Hermes's grace window, as
    /// the FORM currently reads — i.e. what pressing Save would write.
    ///
    /// iOS persists by rewriting `cron/jobs.json` (`IOSCronViewModel.saveJobs`)
    /// with no `cron create` in the path, so nothing downstream refuses it:
    /// the record lands `scheduled`, and the misfire backstop then declines to
    /// resurrect a one-shot more than `ONESHOT_GRACE_SECONDS` overdue
    /// (`cron/scheduler_provider.py:274-279` @ `v2026.9.7`). A "scheduled" job
    /// that can never fire is exactly the ghost
    /// `_next_run_or_reject_past_oneshot` (`cron/jobs.py:1669-1680`) exists to
    /// stop the CLI writing, so this form is where iOS has to stop it. Reuses
    /// the Mac's own predicate, `HermesCronJob.oneShotScheduleIsPastGrace` —
    /// including its conservative +12h window for a naive timestamp: a value
    /// still future in SOME zone is accepted, because Scarf cannot know the
    /// host's. An EMPTY time is unusable for the same reason (a `once` with no
    /// `run_at` has no `next_run_at` to compute) and that string-level helper
    /// answers `false` for one, so it is checked here.
    /// **Scoped to a create or a duplicate — round-5 decision 13.** It used
    /// to fire on an edit too, which blocked a user from fixing the PROMPT of
    /// a record whose one-shot time had already passed: the schedule field
    /// was never touched, yet Save stayed grey with nothing on screen naming
    /// the reason. The axis is the SCHEDULE, not the sheet: a spent time is
    /// refused unless it is the record's OWN already-stored value, unedited.
    /// That admits the prompt-only edit and still refuses every write that
    /// puts a spent time somewhere it was not — a create (no `existing`), a
    /// duplicate (whose seed is blanked by `duplicateSeedSchedule`, so a
    /// spent value there is one the user just typed), a kind switch, and a
    /// re-typed dead timestamp.
    ///
    /// Hermes agrees for the case this admits. `cron edit <id> --prompt …` on
    /// a one-shot that actually RAN is accepted at `v2026.9.7`: the record is
    /// `enabled=False, state="completed", next_run_at=None`
    /// (`_complete_job_record`, `cron/jobs.py:1463-1465`), so
    /// `_reject_terminal_activation` (`:1865-1878`) sees `state` in the
    /// terminal set, `enabled` not `True` and `next_run_at` nil and does not
    /// raise, `_apply_schedule_update` never runs without `--schedule`, and
    /// `_fill_missing_next_run` (`:1912-1927`) returns on the first line
    /// because the record is disabled. The one shape Hermes would still
    /// refuse is a never-run GHOST (`state="scheduled", enabled=True`, no
    /// `next_run_at`), where `_fill_missing_next_run` raises "Requested
    /// one-shot time … is in the past" — but that record can only exist
    /// because an older Scarf wrote it, this gate is what stops a new one,
    /// and re-saving its prompt writes back the ghost that is already there
    /// rather than creating a second. iOS never shells `cron edit` anyway
    /// (`IOSCronViewModel.saveJobs` rewrites `cron/jobs.json`), so this form
    /// is the only validation either way.
    private var oneShotTimeIsUnusable: Bool {
        guard scheduleKind == "once" else { return false }
        let raw = scheduleRunAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return true }
        // The record's own stored time, unchanged: this write re-states what
        // `jobs.json` already holds, so it cannot create a ghost that is not
        // already there.
        if existing?.schedule.kind == "once",
           let stored = existing?.schedule.runAt?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored == raw {
            return false
        }
        return HermesCronJob.oneShotScheduleIsPastGrace(raw)
    }

    /// Round-5 review (P50b). Decision 13 widened `isValid` so a spent
    /// one-shot's PROMPT can be saved — which newly put Save within reach of
    /// a record whose `Enabled` toggle was never gated. Flipping it on a
    /// `completed` one-shot would write `enabled: true, state: "completed"`
    /// into `cron/jobs.json`: exactly the shape
    /// `_reject_terminal_activation` refuses (`cron/jobs.py:1865-1878` @
    /// `v2026.9.7` — `state` in the terminal set AND `enabled is True`), and
    /// the shape the list row's own toggle already declines via
    /// `IOSCronViewModel.setEnabled`'s `offer.refusesResume` gate. iOS
    /// persists by rewriting `jobs.json` (`IOSCronViewModel.saveJobs`), so
    /// no CLI stands behind this form to refuse it — the two doors into the
    /// same write must agree, and this is the second one.
    ///
    /// Only an EDIT is gated: a new job has no record and a duplicate's seed
    /// is `enabled: true, state: "scheduled"`
    /// (`HermesCronJob.duplicatedAsNewJob`), so neither refuses anything.
    private var enabledIsLocked: Bool {
        existing != nil && recoveryOffer.refusesResume
    }

    /// The schedule-shape validations `hermes cron edit` performs and this
    /// form is the only place to perform — the full `update_job` gate table,
    /// and why each of these three lands here, is on
    /// `HermesCronJob.scheduleFormRefusal`. P56, addendum lesson 14.
    ///
    /// `carriedIntervalMinutes` is what `buildJob` would WRITE, not what the
    /// record holds: the sheet has no minutes field, and `buildJob` keeps the
    /// stored `minutes` only while the kind is unchanged, so a kind switch
    /// into `interval` has none to carry.
    private var scheduleRefusal: CronScheduleFormRefusal? {
        HermesCronJob.scheduleFormRefusal(
            kind: scheduleKind,
            expression: scheduleExpression,
            runAt: scheduleRunAt,
            carriedIntervalMinutes: existing?.schedule.kind == scheduleKind
                ? existing?.schedule.minutes
                : nil
        )
    }

    private var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && !p.isEmpty && !oneShotTimeIsUnusable
            && scheduleRefusal == nil
    }

    private func buildJob() -> HermesCronJob {
        let skillList = skills
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let emptyToNil: (String) -> String? = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // Carry the existing schedule's unedited machine fields (interval
        // minutes, unmodeled keys) only while the kind is unchanged — after
        // a kind switch they describe a schedule that no longer exists.
        // The REAL defect here, found while checking the reported one: the
        // `sameKind` guard covered `minutes` and `extra` but not the three
        // fields above them. `run_at` and `expr` are hidden by the form once
        // the kind changes, yet their `@State` keeps the old value and was
        // written unconditionally — so switching a job from "once" to "cron"
        // saved the new expression alongside the dead one-shot timestamp and
        // a `display` label reading "once at …". Every field that describes
        // the OLD schedule must go when the kind changes, not just the two
        // that happened to be guarded.
        let sameKind = existing?.schedule.kind == scheduleKind
        let schedule = CronSchedule(
            kind: scheduleKind,
            runAt: scheduleKind == "once" ? emptyToNil(scheduleRunAt) : nil,
            display: sameKind ? emptyToNil(scheduleDisplay) : nil,
            expression: scheduleKind == "cron" ? emptyToNil(scheduleExpression) : nil,
            minutes: sameKind ? existing?.schedule.minutes : nil,
            extra: sameKind ? (existing?.schedule.extra ?? [:]) : [:]
        )
        // The UNMODELED top-level `schedule_display`, which `extra` carries
        // verbatim and `HermesCronJob.encode` re-emits, is the label of the
        // schedule the record USED to be on. Hermes's
        // `_schedule_display_for_job` PREFERS it over everything inside
        // `schedule` whenever it is non-empty (`cron/jobs.py:438-446` @
        // `v2026.9.7`) and `_normalize_job_record` stamps the result onto
        // every record it reads (`:470`) — so forwarding it across a
        // schedule change does not merely look stale, it SHADOWS the new
        // time for every reader of the job. Drop it whenever the schedule
        // moved and let Hermes re-derive from the fields that did.
        //
        // This bit ORDINARY edits, not just duplicates: `buildJob` is the
        // one writer behind both, and it forwarded `existing?.extra`
        // unconditionally, so re-timing a live job from the iOS editor left
        // the old label in front of the new time.
        let scheduleMoved = existing?.schedule != schedule
        let carriedExtra = scheduleMoved
            ? HermesCronJob.droppingDerivedScheduleDisplay(existing?.extra ?? [:])
            : (existing?.extra ?? [:])
        return HermesCronJob(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            skills: skillList.isEmpty ? nil : skillList,
            model: emptyToNil(model),
            schedule: schedule,
            // A locked toggle keeps the value it HELD, and what it holds is
            // whatever `jobs.json` already says — the P47 lesson that a
            // `.disabled` control still reports its binding, applied by
            // writing the record's own stored flag rather than the sheet's.
            // Forcing `false` would be its own bug: a recurring job in
            // `error` is terminal AND enabled, and a prompt-only save must
            // not quietly disable it.
            enabled: enabledIsLocked ? (existing?.enabled ?? enabled) : enabled,
            state: existing?.state ?? "scheduled",
            deliver: emptyToNil(deliver),
            // Preserve runtime state fields from the existing job so
            // an edit doesn't reset last_run_at, failure counts, etc.
            // Every field the editor doesn't own must be forwarded, or
            // a save silently strips it from jobs.json.
            //
            // `next_run_at` is the ONE runtime field a schedule change
            // invalidates, so it is forwarded only while the schedule stands
            // still. The due scan fires on the STORED instant —
            // `_evaluate_due_job` reads `job.get("next_run_at")` and
            // recomputes only when it is absent (`cron/jobs.py:2910`,
            // `:2925` @ `v2026.9.7`) — so a re-timed job carrying the old
            // value keeps the old appointment. What happens next depends on
            // the kind, and only ONE kind repairs itself: `_reanchor_stale_cron`
            // (`:2801-2819`) re-anchors a `cron` instant that no longer sits
            // on its expression's lattice, and nothing does that for an
            // `interval` (it fires once early) or a `once` — where
            // `_retire_expired_oneshot` (`:2853-2865`) RETIRES the record
            // past the grace window without ever running it. A job the user
            // moved to next Tuesday is deleted for missing last Tuesday.
            //
            // Clearing it hands the recomputation to Hermes, which is exactly
            // what `clearingNextRunAt()` documents for the `setEnabled`
            // fallback (`IOSCronViewModel:218-219`): `_recover_missing_next_run`
            // (`:2690-2710`) recomputes from the CURRENT schedule and
            // persists. The same helper is not reused here because `buildJob`
            // assembles the record field-by-field and has no instance to
            // transform; the value it would produce is the same `nil`.
            nextRunAt: scheduleMoved ? nil : existing?.nextRunAt,
            lastRunAt: existing?.lastRunAt,
            lastError: existing?.lastError,
            preRunScript: existing?.preRunScript,
            deliveryFailures: existing?.deliveryFailures,
            lastDeliveryError: existing?.lastDeliveryError,
            timeoutType: existing?.timeoutType,
            timeoutSeconds: existing?.timeoutSeconds,
            silent: existing?.silent,
            workdir: existing?.workdir,
            contextFrom: existing?.contextFrom,
            noAgent: existing?.noAgent,
            attachToSession: existing?.attachToSession,
            extra: carriedExtra
        )
    }
}
