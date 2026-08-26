import Foundation
import ScarfCore
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
    // `SPUUpdater` only accepts a delegate at construction time (no settable
    // property post-init — see `SPUUpdater.h`), and it holds it *weakly*, so
    // this reference is what keeps the delegate alive for the app's
    // lifetime; `self` can't be that delegate directly because `self` isn't
    // available yet when `controller` (a `let`) is being initialized.
    private let updateCheckDelegate: UpdateCheckAnalyticsDelegate

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
        // Under `--scarf-test-mode` we keep Sparkle inert so XCUITest runs
        // never see a "an update is available" sheet pop on top of the
        // window the test is trying to drive. The controller still
        // initializes — `automaticallyChecksForUpdates` reads/writes
        // continue to work — it just doesn't fire the on-launch check
        // or surface UI.
        let startUpdater = !TestModeFlags.shared.isTestMode
        let updateCheckDelegate = UpdateCheckAnalyticsDelegate()
        self.updateCheckDelegate = updateCheckDelegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: startUpdater,
            updaterDelegate: updateCheckDelegate,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Triggers a user-initiated update check. Sparkle handles the UI (alert, progress, install).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - update_check_completed

/// Stateless `SPUUpdaterDelegate` whose only job is reporting
/// `update_check_completed`. A separate `NSObject` rather than
/// `UpdaterService` itself conforming: Sparkle wants the delegate at
/// `SPUStandardUpdaterController` *construction* time and holds it weakly,
/// but `self` isn't available yet while `UpdaterService.controller` (a
/// `let`) is being built — see the property comment on
/// `UpdaterService.updateCheckDelegate`.
final class UpdateCheckAnalyticsDelegate: NSObject, SPUUpdaterDelegate {
    /// Sparkle found a newer version than the one running.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Analytics.record(.updateCheckCompleted(result: .available))
    }

    /// Sparkle checked the appcast and the running version is current.
    /// This is the one outcome Sparkle reports via a plain `Error`
    /// (`SUNoUpdateError`) rather than a distinct success callback, so it's
    /// routed here rather than `updater(_:didAbortWithError:)` — see that
    /// method's comment for how the two are told apart.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Analytics.record(.updateCheckCompleted(result: .upToDate))
    }

    /// Sparkle's only failure hook. It also calls this for the "no update
    /// found" outcome on some code paths (`SUNoUpdateError`, domain
    /// `SUSparkleErrorDomain`, code `1001`) in addition to
    /// `updaterDidNotFindUpdate(_:)` — Sparkle's documented behavior is
    /// that both can fire for that case depending on the check path, so
    /// the `SUNoUpdateError` code is excluded here to avoid double-counting
    /// (and to avoid misreporting a non-update as a failure). Every other
    /// error — network failure, appcast parse failure, signature
    /// mismatch — reports `failed`. Never logs `error`'s description as a
    /// prop: only the coarse outcome.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == "SUSparkleErrorDomain", nsError.code == 1001 else {
            Analytics.record(.updateCheckCompleted(result: .failed))
            return
        }
    }
}
