import Foundation
import ScarfCore

/// The most recent `ProjectDoctorService` verdict per server, shared across
/// every cockpit view model.
///
/// The doctor's report is REGISTRY-WIDE, but the cockpit builds a fresh view
/// model per project (`.task(id: project.id)`). Caching the verdict on the
/// view model therefore re-ran a full registry-wide scan — a directory crawl
/// plus a read per project, every one an SSH round-trip on a remote context —
/// each time the user clicked a different project in the sidebar, and again
/// on every click back. Keyed per server because two windows can front
/// different hosts whose registries have nothing to do with each other.
///
/// Freshness is a short window, not forever: the registry is agent-writable,
/// so a verdict from ten minutes ago is a guess. Anything that knowingly
/// changes the registry — closing the doctor sheet — calls `invalidate`.
@MainActor
final class ProjectHealthCache {
    static let shared = ProjectHealthCache()

    /// How long a verdict is reused before the next cockpit open re-scans.
    static let freshness: TimeInterval = 5 * 60

    private struct Entry {
        var report: ProjectDoctorReport?
        var stamp: Date
    }

    private var entries: [ServerID: Entry] = [:]

    private init() {}

    /// The last COMPLETED verdict, or `nil` when there is none or it has
    /// aged out. An in-flight scan reads as `nil` here — it has no verdict to
    /// show yet — which is why claiming is a separate call.
    func report(_ server: ServerID) -> ProjectDoctorReport? {
        guard let entry = entries[server],
              Date().timeIntervalSince(entry.stamp) < Self.freshness
        else { return nil }
        return entry.report
    }

    /// `true` when the caller should run the scan: nothing fresh is cached
    /// AND no other load already claimed it. Claiming marks a scan in flight
    /// so two overlapping loads don't both crawl; the claim ages out like any
    /// other entry, so a scan that never finishes can't wedge the row
    /// forever.
    func claimIfIdle(_ server: ServerID) -> Bool {
        if let entry = entries[server], Date().timeIntervalSince(entry.stamp) < Self.freshness {
            return false  // fresh verdict, or someone else is scanning
        }
        entries[server] = Entry(report: nil, stamp: Date())
        return true
    }

    func store(_ report: ProjectDoctorReport, for server: ServerID) {
        entries[server] = Entry(report: report, stamp: Date())
    }

    func invalidate(_ server: ServerID) {
        entries[server] = nil
    }
}
