import SwiftUI
import ScarfDesign

/// Translucent loading overlay used by feature views while their VM's
/// `load()` runs in the background. Shows a centered ProgressView with
/// optional label; the underlying content stays visible (just dimmed)
/// when it's already populated, or the overlay fully covers an empty
/// section so the user sees activity instead of "nothing here yet".
///
/// Usage:
/// ```swift
/// SomeContent()
///     .loadingOverlay(viewModel.isLoading, label: "Loading credentials…", isEmpty: viewModel.pools.isEmpty)
/// ```
///
/// The `isEmpty` flag controls whether the overlay covers the full view
/// (when there's no stale content to show under it) or just dims it
/// (when refreshing existing data).
struct LoadingOverlay: ViewModifier {
    let isLoading: Bool
    let label: String
    let isEmpty: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isLoading {
                    if isEmpty {
                        // Full cover: empty state. User has no data to look at,
                        // so own the whole pane with the spinner.
                        VStack(spacing: ScarfSpace.s3) {
                            ProgressView()
                                .controlSize(.large)
                            Text(label)
                                .scarfStyle(.callout)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ScarfColor.backgroundPrimary)
                    } else {
                        // Stale-content refresh: top-trailing pill so the
                        // user sees data is being refreshed without losing
                        // their place.
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(label)
                                        .scarfStyle(.caption)
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                                .padding(ScarfSpace.s2)
                            }
                            Spacer()
                        }
                    }
                }
            }
    }
}

extension View {
    /// Show a loading indicator while `isLoading` is true. If `isEmpty` is
    /// also true, the indicator covers the full view; otherwise it shows
    /// as a small refresh pill in the top-trailing corner so existing
    /// content stays visible.
    func loadingOverlay(_ isLoading: Bool, label: String = "Loading…", isEmpty: Bool = false) -> some View {
        modifier(LoadingOverlay(isLoading: isLoading, label: label, isEmpty: isEmpty))
    }
}
