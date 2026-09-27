import SwiftUI
import ScarfCore
import ScarfDesign

/// "Can't read Hermes state" banner for any page whose data comes from
/// `state.db`. An empty list or a row of zeros looks exactly like a
/// fresh install, so a page that failed to read must say so rather than
/// render the empty state as fact.
///
/// Lifted out of `DashboardView` so the Sessions tab, Insights and Project
/// Sessions show the same banner, with the same Run Diagnostics escape.
struct StateReadErrorBanner: View {
    let context: ServerContext
    let message: String
    @State private var showDiagnostics = false

    var body: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't read Hermes state on \(context.displayName)")
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(message)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showDiagnostics = true
            } label: {
                Label("Run Diagnostics…", systemImage: "stethoscope")
            }
            .buttonStyle(ScarfSecondaryButton())
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1)
                )
        )
        // Sweep contract: the section sweep (SectionSweepUITests) asserts
        // no `error.banner` is on screen after switching to a section.
        .accessibilityIdentifier("error.banner")
        .sheet(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(context: context)
        }
    }
}
