import SwiftUI
import ScarfCore
import ScarfDesign

/// Reusable list-of-strings editor for v0.13 cross-platform allowlists.
/// Shape: a vertical stack of rows, each with a delete glyph; an "Add row"
/// button at the bottom appends an empty entry.
///
/// Stateless — binds to the parent VM's `items` array. The VM owns
/// persistence and change tracking; this view is pure presentation.
struct AllowlistEditor: View {
    @Binding var items: [String]
    let kind: GatewayAllowlistKind

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Allowed \(kind.pluralNoun)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
                Text(itemsCountLabel)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }

            if items.isEmpty {
                Text("No restrictions — agent responds in any \(kind.noun).")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .padding(.vertical, ScarfSpace.s2)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, _ in
                        AllowlistRow(
                            value: Binding(
                                get: { items[safe: idx] ?? "" },
                                set: { newValue in
                                    guard idx < items.count else { return }
                                    items[idx] = newValue
                                }
                            ),
                            label: "Allowed \(kind.pluralNoun)",
                            placeholder: kind.inputPlaceholder,
                            onDelete: {
                                guard idx < items.count else { return }
                                items.remove(at: idx)
                            }
                        )
                    }
                }
            }

            HStack {
                Button {
                    items.append("")
                } label: {
                    Label("Add \(kind.noun)", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
    }

    private var itemsCountLabel: String {
        let nonEmpty = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if nonEmpty == 0 { return "0 \(kind.pluralNoun)" }
        if nonEmpty == 1 { return "1 \(kind.noun)" }
        return "\(nonEmpty) \(kind.pluralNoun)"
    }
}

private struct AllowlistRow: View {
    @Binding var value: String
    let label: String
    let placeholder: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: ScarfSpace.s2) {
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(ScarfFont.monoSmall)
                .accessibilityLabel(label)
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(ScarfColor.danger)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
