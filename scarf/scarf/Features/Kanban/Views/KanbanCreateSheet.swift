import SwiftUI
import ScarfCore
import ScarfDesign

/// New Task sheet — creates a Kanban task via `hermes kanban create`.
/// Workspace defaults to the project directory when shown from a per-
/// project board (locked); on the global board defaults to scratch.
struct KanbanCreateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let assignees: [HermesKanbanAssignee]
    /// Pre-filled tenant on per-project boards. Empty on global board.
    let tenantPrefill: String?
    /// Pre-filled project workspace path on per-project boards. When
    /// non-nil, the workspace picker is locked to "Project Dir".
    let projectWorkspacePath: String?
    /// True when the connected Hermes is on v0.13+ — gates the
    /// `--max-retries` field and decides whether to strip newlines from
    /// the title at submit time. Pre-v0.13 hosts may truncate at the
    /// first `\n`; we keep the multi-line input rendering on either way
    /// since a taller `TextField` is harmless on v0.12.
    let supportsKanbanDiagnostics: Bool
    /// Closure invoked when the user submits — VM owner constructs the
    /// `KanbanService.create` call.
    let onSubmit: (KanbanCreateRequest) async throws -> Void

    @State private var title: String = ""
    @State private var bodyText: String = ""
    /// Default assignee on first appearance. Hermes's dispatcher
    /// silently skips unassigned tasks (`skipped_unassigned` field on
    /// `kanban dispatch --json` output) so leaving this empty produces
    /// tasks that never run. We preselect the active Hermes profile
    /// and let the user opt out if they really want unassigned (which
    /// is rarely useful — typically only when they plan to assign
    /// later via CLI or another flow).
    @State private var assignee: String = HermesProfileResolver.activeProfileName()
    @State private var workspaceKind: WorkspaceKind = .scratch
    @State private var priority: Double = 50
    @State private var skillsInput: String = ""
    @State private var tenant: String = ""
    @State private var sendToTriage: Bool = false
    /// v0.13: per-task retry budget. Toggle-gated so the user can opt
    /// into "send the flag" vs. "let Hermes pick its default" (the
    /// release notes default to 3 — see TODO in KanbanCreateRequest).
    @State private var maxRetriesEnabled: Bool = false
    @State private var maxRetries: Int = 3
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    @FocusState private var titleFocused: Bool

    enum WorkspaceKind: String, CaseIterable, Identifiable {
        case scratch
        case worktree
        case projectDir
        var id: String { rawValue }
        var label: String {
            switch self {
            case .scratch:    return "Scratch"
            case .worktree:   return "Worktree"
            case .projectDir: return "Project Dir"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            header
            ScarfDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    titleField
                    descriptionField
                    assigneePicker
                    workspaceField
                    priorityField
                    if supportsKanbanDiagnostics {
                        maxRetriesField
                    }
                    skillsField
                    if projectWorkspacePath == nil {
                        tenantField
                    }
                    triageToggle
                }
                .padding(.vertical, ScarfSpace.s2)
            }
            if let error = submitError {
                errorBanner(error)
            }
            ScarfDivider()
            footerButtons
        }
        .padding(ScarfSpace.s5)
        .frame(width: 540, height: 660)
        .onAppear {
            if let path = projectWorkspacePath, !path.isEmpty {
                workspaceKind = .projectDir
            }
            if let prefill = tenantPrefill, !prefill.isEmpty {
                tenant = prefill
            }
            titleFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New task")
                    .scarfStyle(.title3)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                if let prefill = tenantPrefill, !prefill.isEmpty {
                    Text("Tenant: `\(prefill)`")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else {
                    Text("Adds to the global Kanban board")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
        }
    }

    // MARK: - Fields

    private var titleField: some View {
        // v0.13 server tolerates multi-line titles. We keep the
        // multi-line input rendering on for ALL versions of Hermes —
        // visually a taller TextField is harmless on v0.12 — and decide
        // at submit time whether to strip newlines (see `makeRequest`).
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Title")
            TextField(
                "What needs doing?",
                text: $title,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .scarfStyle(.body)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
            )
            .focused($titleFocused)
            .accessibilityLabel("Title")
        }
    }

    /// v0.13: per-task retry budget. Toggle gates whether `--max-retries`
    /// is sent at all so the user can preserve "let Hermes pick the
    /// default" semantics by leaving the toggle off.
    private var maxRetriesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader(
                "Max retries",
                subtitle: "0 = no retries. Defaults to 3."
            )
            HStack(spacing: ScarfSpace.s3) {
                Toggle("Override default", isOn: $maxRetriesEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Stepper(value: $maxRetries, in: 0...20) {
                    Text("\(maxRetries)")
                        .scarfStyle(.bodyEmph)
                        .frame(minWidth: 24, alignment: .trailing)
                        .foregroundStyle(
                            maxRetriesEnabled
                                ? ScarfColor.foregroundPrimary
                                : ScarfColor.foregroundFaint
                        )
                }
                .disabled(!maxRetriesEnabled)
                Spacer()
            }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Description", subtitle: "Markdown supported")
            TextEditor(text: $bodyText)
                .scrollContentBackground(.hidden)
                .padding(ScarfSpace.s2)
                .frame(minHeight: 120, maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                )
                .scarfStyle(.body)
        }
    }

    private var assigneePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Assignee")
            Menu {
                Button("Unassigned") { assignee = "" }
                if !assignees.isEmpty {
                    Divider()
                    ForEach(assignees) { profile in
                        Button(profile.profile) { assignee = profile.profile }
                    }
                }
            } label: {
                HStack {
                    Text(assignee.isEmpty ? "Unassigned" : assignee)
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.vertical, ScarfSpace.s2)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Workspace")
            Picker("", selection: $workspaceKind) {
                ForEach(allowedWorkspaces) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(projectWorkspacePath != nil)
            if projectWorkspacePath != nil {
                Text("Locked to project directory.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    private var allowedWorkspaces: [WorkspaceKind] {
        // Project Dir is only meaningful when we have a path.
        if projectWorkspacePath == nil {
            return [.scratch, .worktree]
        }
        return WorkspaceKind.allCases
    }

    private var priorityField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Priority", subtitle: "0–100; higher runs first")
            HStack(spacing: ScarfSpace.s3) {
                Slider(value: $priority, in: 0...100, step: 1)
                Text("\(Int(priority))")
                    .scarfStyle(.bodyEmph)
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
            }
            HStack {
                Text("low").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
                Text("normal").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
                Text("high").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    private var skillsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Skills", subtitle: "Comma-separated names from ~/.hermes/skills/")
            ScarfTextField("e.g. translation, github-code-review", text: $skillsInput)
                .accessibilityLabel("Skills")
        }
    }

    private var tenantField: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfSectionHeader("Tenant", subtitle: "Optional namespace")
            ScarfTextField("(none)", text: $tenant)
                .accessibilityLabel("Tenant")
        }
    }

    private var triageToggle: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Toggle("Send to triage", isOn: $sendToTriage)
                .toggleStyle(.switch)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            Text(message)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.12))
        )
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ScarfSecondaryButton())
            Button {
                submit()
            } label: {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Create task")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(ScarfPrimaryButton())
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
    }

    // MARK: - Submit

    private func submit() {
        let request = makeRequest()
        isSubmitting = true
        submitError = nil
        Task {
            do {
                try await onSubmit(request)
                isSubmitting = false
                dismiss()
            } catch let err as KanbanError {
                isSubmitting = false
                submitError = err.errorDescription
            } catch {
                isSubmitting = false
                submitError = error.localizedDescription
            }
        }
    }

    private func makeRequest() -> KanbanCreateRequest {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pre-v0.13 hosts may truncate titles at the first `\n`. Strip
        // newlines client-side when we know the connected Hermes hasn't
        // shipped multi-line title support — replace with a space to
        // keep the user's intent visible. v0.13+ keeps newlines verbatim.
        if !supportsKanbanDiagnostics {
            trimmedTitle = trimmedTitle.replacingOccurrences(of: "\n", with: " ")
        }
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSkills = skillsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let workspace: KanbanWorkspaceSpec?
        switch workspaceKind {
        case .scratch:
            workspace = .scratch
        case .worktree:
            workspace = .worktree
        case .projectDir:
            if let path = projectWorkspacePath, !path.isEmpty {
                workspace = .directory(path)
            } else {
                workspace = .scratch
            }
        }

        // Belt-and-suspenders: the `maxRetriesField` is only rendered
        // when `supportsKanbanDiagnostics` is true, but gate again here
        // so a programmatic state change can't smuggle the flag onto a
        // pre-v0.13 host (where the verb would error).
        let resolvedMaxRetries: Int? = (supportsKanbanDiagnostics && maxRetriesEnabled)
            ? maxRetries
            : nil

        return KanbanCreateRequest(
            title: trimmedTitle,
            body: trimmedBody.isEmpty ? nil : trimmedBody,
            assignee: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            parentIds: [],
            workspace: workspace,
            tenant: trimmedTenant.isEmpty ? nil : trimmedTenant,
            priority: Int(priority),
            triage: sendToTriage,
            idempotencyKey: nil,
            maxRuntimeSeconds: nil,
            createdBy: nil,
            skills: parsedSkills,
            maxRetries: resolvedMaxRetries
        )
    }
}
