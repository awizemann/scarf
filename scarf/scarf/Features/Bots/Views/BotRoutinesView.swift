import SwiftUI
import ScarfCore
import ScarfDesign

/// B4's `automation` slot: the cron jobs Hermes Desktop's Routines pane
/// scopes to this bot via the `[bot:<name>] ` name prefix (verified against
/// `hermes-bots/cron.tsx`), plus a minimal create sheet. Power users who
/// want the rest of `hermes cron` (skills, workdir, run history, incidents,
/// doctor) go to the full Cron section — this pane deliberately stays small.
struct BotRoutinesView: View {
    @Bindable var viewModel: BotRoutinesViewModel
    let hasCronBotChatDelivery: Bool

    @State private var showCreate = false
    @State private var pendingDelete: HermesCronJob?
    /// Round-4 decision 5 — the routine the Duplicate sheet is pre-filled
    /// from. The sheet is the full `CronJobEditor` in `.duplicate` mode, not
    /// the minimal `CreateRoutineSheet`: a duplicate must round-trip the
    /// record's STORED prompt (already carrying the delegation wrapper) and
    /// its `[bot:<name>] ` prefix verbatim, and the minimal sheet's fields are
    /// the pre-wrapper title/instruction.
    @State private var duplicating: HermesCronJob?

    /// Same flags `CronView` mirrors onto the shared editor, read from the
    /// same store — otherwise a duplicate raised from this pane could emit a
    /// flag the host's argparse doesn't know and fail the whole create (C1).
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private var hasCronWorkdir: Bool { capabilitiesStore?.capabilities.hasCronWorkdir ?? false }
    private var hasCronNoAgent: Bool { capabilitiesStore?.capabilities.hasCronNoAgent ?? false }
    private var hasCronDeliverAll: Bool { capabilitiesStore?.capabilities.hasCronDeliverAll ?? false }
    private var hasCronFailureDeliver: Bool { capabilitiesStore?.capabilities.hasCronFailureDeliver ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                ScarfSectionHeader("Routines", subtitle: "Cron jobs namespaced for this bot")
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Button {
                    showCreate = true
                } label: {
                    Label("New Routine", systemImage: "plus")
                }
                .buttonStyle(ScarfGhostButton())
                .accessibilityLabel("Create a routine for this bot")
            }
            if let message = viewModel.message {
                // Colour by the view model's typed outcome, never by the
                // string: the same channel carries "Resumed" and
                // "Failed: …". A failure also stays put until dismissed
                // instead of auto-clearing after three seconds.
                HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                    if viewModel.messageIsFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ScarfColor.danger)
                            .accessibilityHidden(true)
                    }
                    Text(message)
                        .scarfStyle(.caption)
                        .foregroundStyle(viewModel.messageIsFailure ? ScarfColor.danger : ScarfColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if viewModel.messageIsFailure {
                        Spacer(minLength: 0)
                        Button {
                            viewModel.dismissMessage()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .accessibilityLabel("Dismiss this routine error")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if viewModel.routines.isEmpty {
                ScarfCard(padding: ScarfSpace.s3) {
                    HStack(alignment: .top, spacing: ScarfSpace.s3) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .foregroundStyle(ScarfColor.foregroundFaint)
                        Text("No routines yet. Name a cron job \"[bot:\(viewModel.botName)] …\" to scope it to this bot, or create one below.")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ScarfCard(padding: ScarfSpace.s3) {
                    VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                        ForEach(viewModel.routines) { job in
                            routineRow(job)
                            if job.id != viewModel.routines.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .onAppear { viewModel.load() }
        .sheet(item: $duplicating) { job in
            CronJobEditor(
                mode: .duplicate(job),
                availableSkills: [],
                // ALL the host's jobs, not just this bot's routines: the
                // collision `resolve_job_ref` raises on is over every job in
                // `jobs.json`, and the `[bot:…] ` prefix is part of the name
                // it folds (`cron/jobs.py:1840-1845` @ `v2026.9.7`).
                existingNames: viewModel.allJobNames,
                supportsWorkdir: hasCronWorkdir,
                supportsNoAgent: hasCronNoAgent,
                supportsDeliverAll: hasCronDeliverAll,
                supportsBotChatDelivery: hasCronBotChatDelivery,
                supportsFailureDeliver: hasCronFailureDeliver
            ) { form in
                viewModel.duplicate(
                    schedule: form.schedule, prompt: form.prompt, name: form.name,
                    deliver: form.deliver, skills: form.skills, script: form.script,
                    repeatCount: form.repeatCount,
                    workdir: hasCronWorkdir ? form.workdir : "",
                    noAgent: hasCronNoAgent ? form.noAgent : false,
                    failureDeliver: hasCronFailureDeliver ? form.failureDeliver : ""
                )
                duplicating = nil
            } onCancel: {
                duplicating = nil
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateRoutineSheet(
                botName: viewModel.botName,
                hasCronBotChatDelivery: hasCronBotChatDelivery,
                onCreate: { title, schedule, prompt in
                    viewModel.createRoutine(
                        title: title,
                        schedule: schedule,
                        prompt: prompt,
                        hasCronBotChatDelivery: hasCronBotChatDelivery
                    )
                    showCreate = false
                },
                onCancel: { showCreate = false }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \(routineTitle($0))?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let job = pendingDelete { viewModel.delete(job) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func routineRow(_ job: HermesCronJob) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            Image(systemName: job.stateIcon)
                .foregroundStyle(ScarfColor.foregroundMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(routineTitle(job))
                    .scarfStyle(.bodyEmph)
                    .lineLimit(1)
                Text(job.schedule.display ?? job.schedule.expression ?? job.schedule.kind)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                ScarfBadge(verbatim: job.stateDisplay, kind: badgeKind(for: job.stateDisplay))
            }
            Spacer(minLength: 0)
            HStack(spacing: ScarfSpace.s2) {
                // One shared offer, same as `CronView`'s detail pane: plain
                // Resume for a paused job and for a recoverable-error
                // recurring one, "Resume & Run Now" only where
                // `rearm_oneshot` accepts it (`schedule.kind == "once"`),
                // and a hint where Hermes has no door at all.
                let offer = viewModel.recoveryOffer(for: job)
                if !job.isTerminal, job.enabled {
                    Button("Pause") { viewModel.pause(job) }
                        .buttonStyle(ScarfGhostButton())
                } else if offer.canResume {
                    Button("Resume") { viewModel.resume(job) }
                        .buttonStyle(ScarfGhostButton())
                }
                if offer.canRearm {
                    Button("Resume & Run Now") { viewModel.resumeAndRunNow(job) }
                        .buttonStyle(ScarfGhostButton())
                }
                if let hint = offer.hint {
                    Text(hint)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(maxWidth: 200, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The hint says "duplicate it"; this is that button. Same
                // condition as `CronView`'s detail pane, so the two panes
                // cannot offer a routine different remedies.
                if offer.isDeadEnd || offer.canRearm {
                    Button("Duplicate") { duplicating = job }
                        .buttonStyle(ScarfGhostButton())
                        .accessibilityLabel("Duplicate \(routineTitle(job))")
                }
                Button("Run Now") { viewModel.runNow(job) }
                    .buttonStyle(ScarfGhostButton())
                    .disabled(viewModel.refusesTerminalJobLocally(job))
                Button {
                    pendingDelete = job
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ScarfDestructiveButton())
                .help("Delete this routine")
                .accessibilityLabel("Delete \(routineTitle(job))")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(routineTitle(job)), \(job.stateDisplay)")
    }

    /// Strip the `[bot:<name>] ` prefix for display — the user already
    /// knows which bot this pane belongs to.
    private func routineTitle(_ job: HermesCronJob) -> String {
        if let tagged = BotRoutinePrefix.taggedBot(inJobName: job.name), !tagged.isEmpty {
            let stripped = job.name.drop { $0 != "]" }.dropFirst()
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? job.name : trimmed
        }
        return job.name
    }

    /// Delegated, not re-derived: `CronView` renders the same states in the
    /// detail pane and the list, and two copies of a colour map drift.
    private func badgeKind(for state: String) -> ScarfBadgeKind {
        CronView.badgeKind(for: state)
    }
}

/// Minimal create sheet — schedule, prompt, title only. Composes
/// `[bot:<name>] <title>` as the job's `--name` and, when the host supports
/// it, routes output to this bot's own Bot Chat.
struct CreateRoutineSheet: View {
    let botName: String
    let hasCronBotChatDelivery: Bool
    let onCreate: (_ title: String, _ schedule: String, _ prompt: String) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var schedule = ""
    @State private var prompt = ""

    /// `nil` when the sheet's fields are ready to submit; otherwise a copy
    /// naming the offending field. Composes the base required-fields check
    /// with `BotRoutinesViewModel.routineInputError` (empty-prompt + Hermes
    /// Desktop's NUL guard) so Create disables instead of failing at submit
    /// (A1-L7).
    private var validationError: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Title can't be empty."
        }
        if schedule.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Schedule can't be empty."
        }
        return BotRoutinesViewModel.routineInputError(title: title, instruction: prompt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                Text("New routine for \(botName)")
                    .scarfStyle(.title3)
                Text("Saved as a cron job named \"[bot:\(botName)] \(title.isEmpty ? "…" : title)\". For skills, workdir or run history, use the Cron section instead.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Title").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundMuted)
                    ScarfTextField("Morning digest", text: $title)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedule").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundMuted)
                    ScarfTextField("0 9 * * *  or  30m  or  every 2h", text: $schedule)
                        .font(ScarfFont.mono)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundMuted)
                    TextEditor(text: $prompt)
                        .accessibilityLabel("Prompt")
                        .font(ScarfFont.mono)
                        .frame(minHeight: 90)
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
                if hasCronBotChatDelivery {
                    Text("Output is delivered to \(botName)'s Bot Chat as a message it responds to.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else {
                    Text("This host is older than v0.20.6, so output isn't routed anywhere automatically. Check results in the Cron section.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(ScarfGhostButton())
                    Button("Create") {
                        onCreate(title, schedule, prompt)
                    }
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(validationError != nil)
                }
            }
            .padding(ScarfSpace.s5)
        }
        .frame(width: 460)
    }
}
