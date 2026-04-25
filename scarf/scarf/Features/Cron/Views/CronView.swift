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
    @State private var viewModel: CronViewModel
    @State private var pendingDelete: HermesCronJob?

    init(context: ServerContext) {
        _viewModel = State(initialValue: CronViewModel(context: context))
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
        .onAppear { viewModel.load() }
        .sheet(isPresented: $viewModel.showCreateSheet) {
            CronJobEditor(mode: .create, availableSkills: viewModel.availableSkills) { form in
                viewModel.createJob(
                    schedule: form.schedule,
                    prompt: form.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    skills: form.skills,
                    script: form.script,
                    repeatCount: form.repeatCount
                )
                viewModel.showCreateSheet = false
            } onCancel: {
                viewModel.showCreateSheet = false
            }
        }
        .sheet(item: $viewModel.editingJob) { job in
            CronJobEditor(mode: .edit(job), availableSkills: viewModel.availableSkills) { form in
                viewModel.updateJob(
                    id: job.id,
                    schedule: form.schedule,
                    prompt: form.prompt,
                    name: form.name,
                    deliver: form.deliver,
                    repeatCount: form.repeatCount,
                    newSkills: form.skills,
                    clearSkills: form.clearSkills,
                    script: form.script
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
                    viewModel.load()
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
                    if !job.enabled {
                        ScarfBadge("paused", kind: .neutral)
                    }
                    Circle()
                        .fill(statusDotColor(job))
                        .frame(width: 7, height: 7)
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
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 24))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No cron jobs yet")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(ScarfSpace.s8)
    }

    private func statusDotColor(_ job: HermesCronJob) -> Color {
        if !job.enabled { return ScarfColor.foregroundFaint }
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

        if let error = job.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .scarfStyle(.caption)
            }
            .foregroundStyle(ScarfColor.danger)
        }

        if let output = viewModel.jobOutput {
            sectionBlock("LAST OUTPUT") {
                Text(output)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(ScarfSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
    }

    let mode: Mode
    let availableSkills: [String]
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
            formField("Deliver", text: $form.deliver, placeholder: "origin | local | discord:CHANNEL | telegram:CHAT", mono: true)
            formField("Repeat", text: $form.repeatCount, placeholder: "Optional count")
            formField("Script path", text: $form.script, placeholder: "Python script whose stdout is injected", mono: true)
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
            }
        }
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
        }
    }
}
