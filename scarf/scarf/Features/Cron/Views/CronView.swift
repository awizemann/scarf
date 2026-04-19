import SwiftUI

struct CronView: View {
    @State private var viewModel: CronViewModel
    @State private var pendingDelete: HermesCronJob?

    init(context: ServerContext) {
        _viewModel = State(initialValue: CronViewModel(context: context))
    }


    var body: some View {
        HSplitView {
            jobsList
                .frame(minWidth: 320, idealWidth: 360)
            jobDetail
                .frame(minWidth: 400)
        }
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

    private var jobsList: some View {
        VStack(spacing: 0) {
            HStack {
                if let msg = viewModel.message {
                    Label(msg, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
                Button("Reload") { viewModel.load() }
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()
            List(selection: Binding(
                get: { viewModel.selectedJob?.id },
                set: { id in
                    if let id, let job = viewModel.jobs.first(where: { $0.id == id }) {
                        viewModel.selectJob(job)
                    } else {
                        viewModel.selectedJob = nil
                        viewModel.jobOutput = nil
                    }
                }
            )) {
                ForEach(viewModel.jobs) { job in
                    HStack {
                        Image(systemName: job.stateIcon)
                            .foregroundStyle(job.enabled ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name)
                                .lineLimit(1)
                            Text(job.schedule.display ?? job.schedule.kind)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if job.silent == true {
                            Text("SILENT")
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                        }
                        if !job.enabled {
                            Text("Disabled")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(job.id)
                    .contextMenu {
                        Button(job.enabled ? "Pause" : "Resume") {
                            if job.enabled {
                                viewModel.pauseJob(job)
                            } else {
                                viewModel.resumeJob(job)
                            }
                        }
                        Button("Run Now") { viewModel.runNow(job) }
                        Button("Edit") { viewModel.editingJob = job }
                        Divider()
                        Button("Delete", role: .destructive) { pendingDelete = job }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if viewModel.jobs.isEmpty {
                    ContentUnavailableView("No Cron Jobs", systemImage: "clock.arrow.2.circlepath", description: Text("No scheduled jobs configured"))
                }
            }
        }
    }

    @ViewBuilder
    private var jobDetail: some View {
        if let job = viewModel.selectedJob {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(job)
                    actionBar(job)
                    Divider()
                    detailBody(job)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView("Select a Job", systemImage: "clock.arrow.2.circlepath", description: Text("Choose a cron job from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ job: HermesCronJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.name)
                .font(.title2.bold())
            HStack(spacing: 16) {
                Label(job.state, systemImage: job.stateIcon)
                Label(job.schedule.display ?? job.schedule.kind, systemImage: "clock")
                Label(job.enabled ? "Enabled" : "Disabled", systemImage: job.enabled ? "checkmark.circle" : "xmark.circle")
                if let deliver = job.deliveryDisplay {
                    Label("Deliver: \(deliver)", systemImage: "paperplane")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func actionBar(_ job: HermesCronJob) -> some View {
        HStack(spacing: 8) {
            Button {
                if job.enabled { viewModel.pauseJob(job) } else { viewModel.resumeJob(job) }
            } label: {
                Label(job.enabled ? "Pause" : "Resume", systemImage: job.enabled ? "pause" : "play")
            }
            Button {
                viewModel.runNow(job)
            } label: {
                Label("Run Now", systemImage: "bolt")
            }
            Button {
                viewModel.editingJob = job
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Spacer()
            Button(role: .destructive) {
                pendingDelete = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func detailBody(_ job: HermesCronJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(job.prompt)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if let script = job.preRunScript, !script.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pre-Run Script")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        if let skills = job.skills, !skills.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(skills, id: \.self) { skill in
                        Text(skill)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        if let nextRun = job.nextRunAt {
            Label("Next run: \(nextRun)", systemImage: "arrow.forward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let lastRun = job.lastRunAt {
            Label("Last run: \(lastRun)", systemImage: "arrow.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = job.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let timeout = job.timeoutSeconds {
            Label("Timeout: \(timeout)s (\(job.timeoutType ?? "wall_clock"))", systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let failures = job.deliveryFailures, failures > 0 {
            Label("\(failures) delivery failure\(failures == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let deliveryError = job.lastDeliveryError {
            Label(deliveryError, systemImage: "paperplane.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let output = viewModel.jobOutput {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Output")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(headerText)
                .font(.headline)
            formField("Name", text: $form.name, placeholder: "Friendly label")
            formField("Schedule", text: $form.schedule, placeholder: "0 9 * * *  or  30m  or  every 2h", mono: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $form.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(4)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            formField("Deliver", text: $form.deliver, placeholder: "origin | local | discord:CHANNEL | telegram:CHAT", mono: true)
            formField("Repeat", text: $form.repeatCount, placeholder: "Optional count")
            formField("Script path", text: $form.script, placeholder: "Python script whose stdout is injected", mono: true)
            if !availableSkills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills")
                        .font(.caption).foregroundStyle(.secondary)
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
                                .font(.caption.monospaced())
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    if isEditMode {
                        Toggle("Clear all skills on save", isOn: $form.clearSkills)
                            .font(.caption)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { onSave(form) }
                    .buttonStyle(.borderedProminent)
                    .disabled(form.schedule.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 560)
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
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
        }
    }
}
