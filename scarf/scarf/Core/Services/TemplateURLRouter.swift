import Foundation
import Observation
import os

/// Process-wide router for `scarf://install?url=…` URLs. The app delegate's
/// `onOpenURL` hands the URL in here; the Projects feature observes
/// `pendingInstallURL` and presents the install sheet when it flips non-nil.
///
/// Lives outside SwiftUI so a URL can arrive before any window exists (cold
/// launch from a browser link) and still be picked up by the first
/// `ProjectsView` that appears.
@Observable
@MainActor
final class TemplateURLRouter {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateURLRouter")

    static let shared = TemplateURLRouter()

    /// Non-nil when an install request is waiting to be handled. Can be
    /// either a remote `https://…` URL (from a `scarf://install?url=…` deep
    /// link) or a local `file://…` URL (from a Finder double-click on a
    /// `.scarftemplate` file, or a drag onto the app icon). Observers read
    /// this, dispatch by scheme, present the install sheet, then call
    /// `consume` to clear it. Only one pending install at a time — if a
    /// second arrives before the first is consumed, it replaces the first
    /// (matches browser-link intuition where the latest click wins).
    var pendingInstallURL: URL?

    private init() {}

    /// Parse and validate an inbound URL. Returns `true` if the URL was
    /// recognized and staged for handling. Unknown schemes or malformed
    /// payloads return `false` so the caller can log/ignore. Supports:
    ///
    /// - `scarf://install?url=https://…` — remote template URL from a web link.
    /// - `file:///…/foo.scarftemplate` — local file from a Finder
    ///   double-click or a drag onto the app icon.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        if url.isFileURL {
            return handleFileURL(url)
        }
        if url.scheme?.lowercased() == "scarf" {
            return handleScarfURL(url)
        }
        Self.logger.warning("Ignored URL with unknown scheme: \(url.absoluteString, privacy: .public)")
        return false
    }

    private func handleFileURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "scarftemplate" else {
            Self.logger.warning("file:// URL handed to Scarf but not a .scarftemplate: \(url.absoluteString, privacy: .public)")
            return false
        }
        pendingInstallURL = url
        Self.logger.info("file:// install staged \(url.path, privacy: .public)")
        return true
    }

    private func handleScarfURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "install" else {
            Self.logger.warning("Ignored unknown scarf:// host: \(url.absoluteString, privacy: .public)")
            return false
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remote = URL(string: raw) else {
            Self.logger.warning("scarf://install missing or invalid ?url=: \(url.absoluteString, privacy: .public)")
            return false
        }
        // Refuse anything but https — defense-in-depth against a browser or
        // mail client that would happily hand us a javascript: or http://
        // URL pointing at something unexpected.
        guard remote.scheme?.lowercased() == "https" else {
            Self.logger.warning("scarf://install refused non-https url=\(remote.absoluteString, privacy: .public)")
            return false
        }
        pendingInstallURL = remote
        Self.logger.info("scarf://install staged \(remote.absoluteString, privacy: .public)")
        return true
    }

    /// Called by the install sheet once it has picked up the URL.
    func consume() {
        pendingInstallURL = nil
    }
}
