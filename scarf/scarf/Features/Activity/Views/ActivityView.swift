import SwiftUI
import ScarfCore
import ScarfDesign

/// Activity — chronological feed of tool calls per
/// `design/static-site/ui-kit/Activity.jsx`. Day-grouped, full-width,
/// each day rendered as a bordered card containing its rows. Tap a row
/// to open the existing detail in a sheet.
struct ActivityView: View {
    @State private var viewModel: ActivityViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: ActivityViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            filterStrip
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    ForEach(groupedByDay) { group in
                        dayGroup(group)
                    }
                    if viewModel.filteredActivity.isEmpty && !viewModel.isLoading {
                        emptyState
                    }
                }
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Activity")
        .task { await viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
        .onDisappear { Task { await viewModel.cleanup() } }
        .sheet(isPresented: detailSheetBinding) { detailSheet }
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Everything Scarf has done recently — sessions, tools, approvals.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        HStack(spacing: ScarfSpace.s2) {
            FilterChip(label: "All", isSelected: viewModel.filterKind == nil) {
                viewModel.filterKind = nil
            }
            ForEach(ToolKind.allCases, id: \.rawValue) { kind in
                FilterChip(label: kind.rawValue.capitalized, isSelected: viewModel.filterKind == kind) {
                    viewModel.filterKind = kind
                }
            }
            Rectangle()
                .fill(ScarfColor.border)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 4)
            Picker(selection: $viewModel.filterSessionId) {
                Text("All sessions").tag(String?.none)
                Divider()
                ForEach(viewModel.availableSessions, id: \.id) { session in
                    Text(session.label)
                        .lineLimit(1)
                        .tag(String?.some(session.id))
                }
            } label: {
                EmptyView()
            }
            .frame(maxWidth: 250)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
    }

    // MARK: - Day grouping

    private struct DayGroup: Identifiable {
        let label: String
        let entries: [ActivityEntry]
        var id: String { label }
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)
        let entries = viewModel.filteredActivity
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        let bucketed = Dictionary(grouping: entries) { entry -> Date in
            cal.startOfDay(for: entry.timestamp ?? .distantPast)
        }
        let sortedKeys = bucketed.keys.sorted(by: >)
        return sortedKeys.map { key in
            let label: String
            if key == today {
                label = "Today"
            } else if let y = yesterday, key == y {
                label = "Yesterday"
            } else if cal.isDate(key, equalTo: today, toGranularity: .weekOfYear) {
                label = key.formatted(.dateTime.weekday(.wide))
            } else {
                label = key.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            return DayGroup(label: label, entries: bucketed[key] ?? [])
        }
    }

    private func dayGroup(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text(group.label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { idx, entry in
                    ActivityRow(entry: entry) {
                        Task { await viewModel.selectEntry(entry) }
                    }
                    if idx < group.entries.count - 1 {
                        Rectangle().fill(ScarfColor.border).frame(height: 1)
                    }
                }
            }
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

    // MARK: - Empty / detail

    private var emptyState: some View {
        VStack(spacing: ScarfSpace.s2) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 28))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No activity yet")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(ScarfSpace.s10)
    }

    private var detailSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.selectedEntry != nil },
            set: { if !$0 { Task { await viewModel.selectEntry(nil) } } }
        )
    }

    @ViewBuilder
    private var detailSheet: some View {
        if let entry = viewModel.selectedEntry {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: entry.kind.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(colorForKind(entry.kind))
                        Text(entry.toolName)
                            .scarfStyle(.bodyEmph)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                    }
                    Spacer()
                    Button("Done") {
                        Task { await viewModel.selectEntry(nil) }
                    }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, ScarfSpace.s4)
                .padding(.vertical, ScarfSpace.s2)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                        HStack(spacing: ScarfSpace.s3) {
                            if let time = entry.timestamp {
                                Label(time.formatted(.dateTime.month().day().hour().minute().second()),
                                      systemImage: "clock")
                            }
                            Button {
                                coordinator.selectedSessionId = entry.sessionId
                                coordinator.selectedSection = .sessions
                                Task { await viewModel.selectEntry(nil) }
                            } label: {
                                Label(String(entry.sessionId.prefix(20)),
                                      systemImage: "bubble.left.and.bubble.right")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ScarfColor.accent)
                        }
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)

                        sectionLabel("ARGUMENTS")
                        Text(entry.prettyArguments)
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .textSelection(.enabled)
                            .padding(ScarfSpace.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(ScarfColor.backgroundSecondary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(ScarfColor.border, lineWidth: 1)
                                    )
                            )

                        if let result = viewModel.toolResult, !result.isEmpty {
                            sectionLabel("OUTPUT")
                            Text(result)
                                .font(ScarfFont.monoSmall)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .textSelection(.enabled)
                                .lineLimit(80)
                                .padding(ScarfSpace.s2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(ScarfColor.backgroundSecondary)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                                        )
                                )
                        }

                        if !entry.messageContent.isEmpty {
                            sectionLabel("ASSISTANT MESSAGE")
                            MarkdownContentView(content: entry.messageContent)
                                .padding(ScarfSpace.s2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(ScarfColor.backgroundSecondary)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                                        )
                                )
                        }
                    }
                    .padding(ScarfSpace.s5)
                }
            }
            .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 600)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scarfStyle(.captionUppercase)
            .foregroundStyle(ScarfColor.foregroundMuted)
    }

    private func colorForKind(_ kind: ToolKind) -> Color {
        switch kind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }
}

// MARK: - Activity row

private struct ActivityRow: View {
    let entry: ActivityEntry
    let onTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: ScarfSpace.s3) {
                Text(timeLabel)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .frame(width: 44, alignment: .leading)

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(toneBackground)
                    Image(systemName: entry.kind.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(toneForeground)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.toolName)
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                    Group {
                        if entry.summary.isEmpty {
                            Text(entry.kind.displayName)
                        } else {
                            Text(entry.summary)
                        }
                    }
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s3 - 2)
            .background(hover ? ScarfColor.backgroundTertiary.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var timeLabel: String {
        guard let t = entry.timestamp else { return "—" }
        return t.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private var toneBackground: Color {
        switch entry.kind {
        case .read:    return ScarfColor.success.opacity(0.16)
        case .edit:    return ScarfColor.info.opacity(0.16)
        case .execute: return ScarfColor.warning.opacity(0.18)
        case .fetch:   return ScarfColor.Tool.web.opacity(0.16)
        case .browser: return ScarfColor.Tool.search.opacity(0.16)
        case .other:   return ScarfColor.backgroundTertiary
        }
    }

    private var toneForeground: Color {
        switch entry.kind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(isSelected ? ScarfColor.onAccent : ScarfColor.foregroundPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? ScarfColor.accent : ScarfColor.backgroundTertiary)
                )
        }
        .buttonStyle(.plain)
    }
}
