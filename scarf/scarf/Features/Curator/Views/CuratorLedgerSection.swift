import SwiftUI
import ScarfCore
import ScarfDesign

/// Mac sub-view rendering the curator's per-mutation audit ledger
/// (`hermes curator ledger`, v0.20.4+). Every row is one curator/agent/user
/// action; rows carrying an `absorbed into` or `rollback of` suffix show
/// that context inline. Each row offers "Roll back this entry" — gated
/// upstream on `hasCuratorEntryRollback` (older 0.20.4-line hosts that
/// somehow lack it would still show the ledger read-only).
struct CuratorLedgerSection: View {
    let entries: [HermesCuratorLedgerEntry]
    let isLoading: Bool
    let rollbackAvailable: Bool
    let pendingRollbackEntryID: String?
    let onRollback: (HermesCuratorLedgerEntry) -> Void

    @State private var confirmingEntry: HermesCuratorLedgerEntry?

    var body: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                header
                if isLoading && entries.isEmpty {
                    loadingRow
                } else if entries.isEmpty {
                    emptyState
                } else {
                    rows
                }
            }
        }
        .alert(
            "Roll back this entry?",
            isPresented: Binding(
                get: { confirmingEntry != nil },
                set: { isShown in if !isShown { confirmingEntry = nil } }
            ),
            presenting: confirmingEntry
        ) { entry in
            Button("Roll Back", role: .destructive) {
                onRollback(entry)
                confirmingEntry = nil
            }
            Button("Cancel", role: .cancel) { confirmingEntry = nil }
        } message: { entry in
            Text("Restores \(entry.skill) to its state before the \(entry.action) mutation (\(entry.whenLabel)). This adds a new ledger entry — it doesn't erase this one.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            ScarfSectionHeader("Ledger")
            Spacer()
            Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: ScarfSpace.s2) {
            ProgressView().controlSize(.small)
            Text("Loading ledger…")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            Text("Ledger is empty.")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Every curator/agent/user mutation to a skill (archive, absorb, rollback, purge…) is recorded here as it happens.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            ForEach(entries) { entry in
                LedgerRow(
                    entry: entry,
                    rollbackAvailable: rollbackAvailable,
                    isPending: pendingRollbackEntryID == entry.id,
                    disabled: pendingRollbackEntryID != nil,
                    onRollback: { confirmingEntry = entry }
                )
            }
        }
    }
}

private struct LedgerRow: View {
    let entry: HermesCuratorLedgerEntry
    let rollbackAvailable: Bool
    let isPending: Bool
    let disabled: Bool
    let onRollback: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: ScarfSpace.s2) {
            Text(entry.whenLabel)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .frame(width: 92, alignment: .leading)
            ScarfBadge(entry.actor, kind: actorBadgeKind)
                .frame(width: 64, alignment: .leading)
            Text(entry.action)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.skill)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .lineLimit(1)
                if let absorbedInto = entry.absorbedInto {
                    Text("→ absorbed into '\(absorbedInto)'")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                } else if let rollbackTarget = entry.rollbackTarget {
                    Text("→ rollback of \(rollbackTarget)")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if rollbackAvailable {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Button {
                        onRollback()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled || !entry.isRollbackable)
                    .help("Roll back this entry")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var actorBadgeKind: ScarfBadgeKind {
        switch entry.actor {
        case "curator": return .info
        case "agent": return .neutral
        case "user": return .success
        default: return .neutral
        }
    }
}
