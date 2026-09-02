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
                Text(kind.allowedHeading)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
                Text(verbatim: itemsCountLabel)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }

            if items.isEmpty {
                Text(kind.noRestrictionsNote)
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
                            label: kind.allowedHeading,
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
                    Label(kind.addEntryLabel, systemImage: "plus.circle")
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
        return kind.countSummary(nonEmpty)
    }
}

/// `GatewayAllowlistKind.noun` / `.pluralNoun` are ENGLISH TOKENS that also
/// feed YAML and prose assembly in ScarfCore, which has no string catalog of
/// its own. Interpolating them into a sentence produced keys like
/// `"Allowed %@"` — grammatically unusable in any language that inflects the
/// adjective. So the UI vocabulary lives here, app-side, one whole extractable
/// sentence per case (the same shape `BotPresence` uses).
extension GatewayAllowlistKind {
    var allowedHeading: LocalizedStringKey {
        switch self {
        case .channels: return "Allowed channels"
        case .chats:    return "Allowed chats"
        case .rooms:    return "Allowed rooms"
        }
    }

    var noRestrictionsNote: LocalizedStringKey {
        switch self {
        case .channels: return "No restrictions — agent responds in any channel."
        case .chats:    return "No restrictions — agent responds in any chat."
        case .rooms:    return "No restrictions — agent responds in any room."
        }
    }

    var addEntryLabel: LocalizedStringKey {
        switch self {
        case .channels: return "Add channel"
        case .chats:    return "Add chat"
        case .rooms:    return "Add room"
        }
    }

    /// Count pill. Automatic grammar agreement handles the number instead of
    /// the old `0 channels` / `1 chat` hand-branching.
    func countSummary(_ count: Int) -> String {
        switch self {
        case .channels: return String(localized: "^[\(count) channel](inflect: true)")
        case .chats:    return String(localized: "^[\(count) chat](inflect: true)")
        case .rooms:    return String(localized: "^[\(count) room](inflect: true)")
        }
    }
}

private struct AllowlistRow: View {
    @Binding var value: String
    let label: LocalizedStringKey
    let placeholder: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: ScarfSpace.s2) {
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(ScarfFont.monoSmall)
                .accessibilityLabel(Text(label))
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
