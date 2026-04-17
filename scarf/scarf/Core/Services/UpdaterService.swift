import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle reads `SUFeedURL`, `SUPublicEDKey`, and check-interval defaults from Info.plist.
/// This service exposes the bits the UI needs: a "check now" trigger, a toggle for automatic
/// checks, and observable state for the Settings screen.
@MainActor
@Observable
final class UpdaterService: NSObject {
    private let controller: SPUStandardUpdaterController

    /// User-facing toggle. Mirrors `updater.automaticallyChecksForUpdates`.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Last time Sparkle checked the appcast (nil before the first check).
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    override init() {
        // startingUpdater: true → Sparkle scans for updates on launch per Info.plist schedule.
        // Default delegates are sufficient for a non-sandboxed app.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Triggers a user-initiated update check. Sparkle handles the UI (alert, progress, install).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
