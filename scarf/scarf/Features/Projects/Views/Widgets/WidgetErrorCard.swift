import SwiftUI
import ScarfDesign

/// Replacement for the legacy "Unknown widget" placeholder. Surfaces the
/// widget's own title plus a structured reason so dashboard authors can see
/// at a glance what's wrong (unknown type, missing file, parse error, …).
///
/// Used by the `WidgetView` dispatcher's default branch and (in v2.7+) by
/// file-reading widgets that can't load their underlying data.
struct WidgetErrorCard: View {
    /// Always runtime data (the dashboard author's own widget title), so it
    /// renders verbatim and is never extracted.
    private let title: String
    private let reason: Text
    private let hint: Text?

    init(title: String, reason: LocalizedStringKey, hint: LocalizedStringKey? = nil) {
        self.title = title
        self.reason = Text(reason)
        self.hint = hint.map { Text($0) }
    }

    /// Escape hatch for reasons that are already-localized runtime text
    /// (e.g. `WidgetPathError.userMessage`).
    init(verbatimReason: String, title: String, hint: LocalizedStringKey? = nil) {
        self.title = title
        self.reason = Text(verbatim: verbatimReason)
        self.hint = hint.map { Text($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                    .font(.caption)
                (title.isEmpty ? Text("Widget error") : Text(verbatim: title))
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            reason
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                hint
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.warning.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg)
                .strokeBorder(ScarfColor.warning.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }
}
