import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS substitute for the Mac inspector's `.help()` tooltip on a Kanban
/// diagnostic chip. iOS doesn't have hover, so each diagnostic chip in
/// the detail sheet is tappable; tap presents this sheet with the kind,
/// severity, Hermes's summary + detail, and when it was last seen.
///
/// Read-only — there are no recovery actions on iOS in v2.8.0. The
/// surface is deliberately small (one screen, no scroll padding) so it
/// reads as a fast peek rather than a full editor.
struct DiagnosticDetailSheet: View {
    let diagnostic: HermesKanbanDiagnostic

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Kind") {
                        Text(diagnostic.kind)
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                    }
                    LabeledContent("Severity") {
                        ScarfBadge(verbatim: severityLabel, kind: severityBadgeKind)
                    }
                    if let lastSeenAt = diagnostic.lastSeenAt, !lastSeenAt.isEmpty {
                        LabeledContent("Last seen") {
                            Text(lastSeenAt)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if diagnostic.count > 1 {
                        LabeledContent("Occurrences") {
                            Text("\(diagnostic.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Diagnostic")
                }

                if !diagnostic.title.isEmpty {
                    Section {
                        Text(diagnostic.title)
                            .font(.body)
                            .textSelection(.enabled)
                    } header: {
                        Text("Summary")
                    }
                }

                if !diagnostic.detail.isEmpty {
                    Section {
                        Text(diagnostic.detail)
                            .font(.body)
                            .textSelection(.enabled)
                    } header: {
                        Text("Detail")
                    }
                }

                Section {
                    Label("Recovery actions live on the Mac app — open this task there to unblock, complete, or archive it.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ScarfColor.backgroundPrimary)
            .navigationTitle("Diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Hermes's own severity string — rendered verbatim so a tier Scarf
    /// doesn't know still reads correctly.
    private var severityLabel: String {
        diagnostic.severity
    }

    private var severityBadgeKind: ScarfBadgeKind {
        switch KanbanDiagnosticSeverity.from(diagnostic.severity) {
        case .critical, .error: return .danger
        case .warning:          return .warning
        }
    }
}
