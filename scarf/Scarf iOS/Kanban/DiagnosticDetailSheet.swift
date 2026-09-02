import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS substitute for the Mac inspector's `.help()` tooltip on a Kanban
/// diagnostic chip. iOS doesn't have hover, so each diagnostic chip in
/// the detail sheet is tappable; tap presents this sheet with the kind,
/// severity, server-supplied message, and detection timestamp.
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
                        ScarfBadge(severityLabel, kind: severityBadgeKind)
                    }
                    if let detectedAt = diagnostic.detectedAt, !detectedAt.isEmpty {
                        LabeledContent("Detected at") {
                            Text(detectedAt)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Diagnostic")
                }

                if let message = diagnostic.message, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.body)
                            .textSelection(.enabled)
                    } header: {
                        Text("Message")
                    }
                }

                Section {
                    Label("Recovery actions live on the Mac app — open this task there to verify, reject, or unblock.", systemImage: "info.circle")
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

    private var severityLabel: LocalizedStringKey {
        let kind = KanbanDiagnosticKind.from(diagnostic.kind)
        switch kind.severity {
        case .danger:  return "danger"
        case .warning: return "warning"
        case .neutral: return "neutral"
        }
    }

    private var severityBadgeKind: ScarfBadgeKind {
        let kind = KanbanDiagnosticKind.from(diagnostic.kind)
        switch kind.severity {
        case .danger:  return .danger
        case .warning: return .warning
        case .neutral: return .neutral
        }
    }
}
