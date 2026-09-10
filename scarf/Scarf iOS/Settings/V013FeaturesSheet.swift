import SwiftUI
import ScarfDesign

/// "Learn more" sheet behind the v0.13 features-active badge in
/// `SettingsView`. Text-only summary of what shipped in Hermes v0.13
/// (Persistent Goals, ACP /queue, Kanban diagnostics, Curator archive,
/// Google Chat platform). Every row spells out
/// where the editing lives — Mac for v2.8.0; iOS write surfaces are
/// deferred to v2.8.x.
///
/// No deep-linking from rows in v2.8.0 — that's a v2.8.x polish.
struct V013FeaturesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    featureRow(
                        icon: "scope",
                        title: "Persistent goals",
                        description: "Type /goal <text> in chat to lock the agent on a target across turns. Send and clear from the Mac app in v2.8."
                    )
                    featureRow(
                        icon: "tray.full",
                        title: "ACP /queue",
                        description: "Queue prompts to run after the current turn finishes. Send and manage from the Mac app in v2.8."
                    )
                    featureRow(
                        icon: "stethoscope",
                        title: "Kanban diagnostics",
                        description: "Worker distress signals (repeated failures, crashes, stuck cards) surface on the task detail."
                    )
                    featureRow(
                        icon: "archivebox",
                        title: "Curator archive",
                        description: "Stale skills move to an Archived list. Restore them, or archive idle ones, from the Mac app."
                    )
                    featureRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Google Chat platform",
                        description: "New messaging-gateway target. Configure on the Mac app."
                    )
                } header: {
                    Text("What's new in v0.13")
                } footer: {
                    Text("This iOS release surfaces v0.13 features read-only. Editing lives in the Mac app for v2.8.")
                        .font(.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ScarfColor.backgroundPrimary)
            .navigationTitle("v0.13 features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
