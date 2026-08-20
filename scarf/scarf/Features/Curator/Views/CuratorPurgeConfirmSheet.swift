import SwiftUI
import ScarfCore
import ScarfDesign

/// Confirm sheet for `hermes curator purge` — **permanently deletes**
/// archived skills past the TTL, unlike `prune` (which only *archives*,
/// reversibly). Deliberately styled as a destructive-delete gate: red
/// "Permanently Delete" action, explicit "cannot be undone" copy, and a
/// spelled-out list of exactly what disappears — never let this read like
/// the Prune sheet above it. Cancel keeps the keyboard default so an
/// accidental Enter never deletes anything.
struct CuratorPurgeConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CuratorPurgeSummary
    let isPurging: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, ScarfSpace.s2)
            ScarfDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    if let reason = summary.disabledReason {
                        Text(reason)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(.vertical, ScarfSpace.s2)
                    } else {
                        ForEach(summary.candidates) { candidate in
                            row(candidate: candidate)
                        }
                        if summary.candidates.isEmpty {
                            Text("No archived skills are older than \(daysLabel). Nothing to purge.")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .padding(.vertical, ScarfSpace.s2)
                        }
                    }
                }
                .padding(.vertical, ScarfSpace.s2)
            }
            ScarfDivider()
            footer
                .padding(.top, ScarfSpace.s2)
        }
        .frame(minWidth: 520, minHeight: 380)
        .padding(ScarfSpace.s4)
    }

    private var daysLabel: String {
        summary.days.map { "\($0) days" } ?? "the configured TTL"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(alignment: .firstTextBaseline) {
                Label("Permanently delete archived skills", systemImage: "exclamationmark.triangle.fill")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.danger)
                Spacer()
                if summary.count > 0 {
                    ScarfBadge("\(summary.count)", kind: .danger)
                }
            }
            Text("This deletes each skill's files from disk. It is NOT the same as archiving — deleted skills cannot be restored from the Archived list, and this action cannot be undone. Each deletion is still recorded in the ledger for audit purposes.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(candidate: CuratorPurgeCandidate) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "trash")
                .foregroundStyle(ScarfColor.danger)
                .font(.caption)
            Text(candidate.name)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .buttonStyle(ScarfGhostButton())
            // Cancel owns .defaultAction — an accidental Enter must never
            // trigger a permanent, unrecoverable delete.
            .keyboardShortcut(.defaultAction)
            .disabled(isPurging)
            Spacer()
            if isPurging {
                ProgressView().controlSize(.small)
            }
            Button(deleteLabel) {
                onConfirm()
            }
            .buttonStyle(ScarfDestructiveButton())
            // `canPurge` is the model-owned contract (no candidates or a
            // disabled verb ⇒ never armed); this view adds only the
            // in-flight guard.
            .disabled(isPurging || !summary.canPurge)
            .accessibilityIdentifier("curatorPurge.confirm")
        }
    }

    private var deleteLabel: String {
        summary.count == 1 ? "Permanently Delete 1 Skill" : "Permanently Delete \(summary.count) Skills"
    }
}
