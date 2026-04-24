import SwiftUI
import ScarfCore

/// iOS Cron screen. M6 gained: toggle-enabled, swipe-to-delete,
/// "+" toolbar → editor sheet, and row-tap → edit existing job.
struct CronListView: View {
    let config: IOSServerConfig

    @State private var vm: IOSCronViewModel
    @State private var editingJob: HermesCronJob?
    @State private var showingNewJob = false

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
                        .foregroundStyle(.orange)
                }
            }

            if vm.jobs.isEmpty, !vm.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No cron jobs yet.")
                            .font(.headline)
                        Text("Tap \(Image(systemName: "plus.circle.fill")) to create one, or manage them from the Mac app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        }
                    }
                }
            }
        }
        .scarfGoListDensity()
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
        .task { await vm.load() }
        .sheet(item: $editingJob) { job in
            CronEditorView(initial: job, title: "Edit cron job") { edited in
                Task { await vm.upsert(edited) }
            }
            // Cron editor is a Form with ~6 fields; .large gives room
            // without cramping. No peek detent — editing cron jobs is
            // a focused task, not something users want to half-see.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingNewJob) {
            CronEditorView(initial: nil, title: "New cron job") { created in
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
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(.secondarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(CronScheduleFormatter.humanReadable(from: job.schedule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    let title: String
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

    init(
        initial: HermesCronJob?,
        title: String,
        onSave: @escaping (HermesCronJob) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        self.existing = initial
        _id = State(initialValue: initial?.id ?? "job_\(UUID().uuidString.prefix(8))")
        _name = State(initialValue: initial?.name ?? "")
        _prompt = State(initialValue: initial?.prompt ?? "")
        _model = State(initialValue: initial?.model ?? "")
        _skills = State(initialValue: (initial?.skills ?? []).joined(separator: ", "))
        _deliver = State(initialValue: initial?.deliver ?? "")
        _enabled = State(initialValue: initial?.enabled ?? true)
        _scheduleKind = State(initialValue: initial?.schedule.kind ?? "cron")
        _scheduleDisplay = State(initialValue: initial?.schedule.display ?? "")
        _scheduleRunAt = State(initialValue: initial?.schedule.runAt ?? "")
        _scheduleExpression = State(initialValue: initial?.schedule.expression ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    Toggle("Enabled", isOn: $enabled)
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
            .navigationTitle(title)
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

    private var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && !p.isEmpty
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
        let schedule = CronSchedule(
            kind: scheduleKind,
            runAt: emptyToNil(scheduleRunAt),
            display: emptyToNil(scheduleDisplay),
            expression: emptyToNil(scheduleExpression)
        )
        return HermesCronJob(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            skills: skillList.isEmpty ? nil : skillList,
            model: emptyToNil(model),
            schedule: schedule,
            enabled: enabled,
            state: existing?.state ?? "scheduled",
            deliver: emptyToNil(deliver),
            // Preserve runtime state fields from the existing job so
            // an edit doesn't reset last_run_at, failure counts, etc.
            nextRunAt: existing?.nextRunAt,
            lastRunAt: existing?.lastRunAt,
            lastError: existing?.lastError,
            preRunScript: existing?.preRunScript,
            deliveryFailures: existing?.deliveryFailures,
            lastDeliveryError: existing?.lastDeliveryError,
            timeoutType: existing?.timeoutType,
            timeoutSeconds: existing?.timeoutSeconds,
            silent: existing?.silent
        )
    }
}
