import SwiftUI
import ScarfCore

/// iOS Cron screen. Read-only list of scheduled jobs pulled from
/// `~/.hermes/cron/jobs.json`. Editing is deferred to a later phase —
/// see `IOSCronViewModel`'s header for the scope rationale.
struct CronListView: View {
    let config: IOSServerConfig

    @State private var vm: IOSCronViewModel

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
                        Text("Create cron jobs from the Mac app or by editing `~/.hermes/cron/jobs.json` directly. iOS will display them here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(vm.jobs) { job in
                        CronRow(job: job)
                    }
                }
            }
        }
        .navigationTitle("Cron jobs")
        .navigationBarTitleDisplayMode(.inline)
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
    }
}

private struct CronRow: View {
    let job: HermesCronJob

    var body: some View {
        NavigationLink {
            CronDetailView(job: job)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack {
                    Image(systemName: job.stateIcon)
                        .foregroundStyle(stateColor)
                        .font(.body)
                }
                .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.name)
                            .font(.body)
                            .fontWeight(.medium)
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
                    if let schedule = job.schedule.display, !schedule.isEmpty {
                        Text(schedule)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !job.schedule.kind.isEmpty {
                        Text(job.schedule.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let nextRun = job.nextRunAt {
                        Text("Next: \(nextRun)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var stateColor: Color {
        switch job.state {
        case "running":   return .blue
        case "completed": return .green
        case "failed":    return .red
        default:          return .secondary
        }
    }
}

private struct CronDetailView: View {
    let job: HermesCronJob

    var body: some View {
        Form {
            Section("Prompt") {
                Text(job.prompt)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Section("Schedule") {
                LabeledContent("Kind", value: job.schedule.kind)
                if let display = job.schedule.display {
                    LabeledContent("When", value: display)
                }
                if let expr = job.schedule.expression {
                    LabeledContent("Expression", value: expr)
                }
            }

            Section("State") {
                LabeledContent("Enabled", value: job.enabled ? "yes" : "no")
                LabeledContent("State", value: job.state)
                if let last = job.lastRunAt {
                    LabeledContent("Last run", value: last)
                }
                if let next = job.nextRunAt {
                    LabeledContent("Next run", value: next)
                }
                if let err = job.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last error")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            if let delivery = job.deliveryDisplay {
                Section("Delivery") {
                    LabeledContent("Route", value: delivery)
                }
            }

            if let skills = job.skills, !skills.isEmpty {
                Section("Skills") {
                    ForEach(skills, id: \.self) { s in
                        Text(s)
                            .font(.caption.monospaced())
                    }
                }
            }

            if let model = job.model {
                Section("Model") {
                    Text(model).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
