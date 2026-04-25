import SwiftUI
import ScarfCore
import ScarfDesign

/// Full-canvas webview wrapper for the Site sub-tab. Reuses the
/// `WebviewWidgetView` representable in its `fullCanvas: true` mode so
/// rendering, error handling, and the non-persistent data store all
/// stay in one place.
struct ProjectSiteView: View {
    let widget: DashboardWidget

    var body: some View {
        WebviewWidgetView(widget: widget, fullCanvas: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScarfColor.backgroundPrimary)
    }
}
