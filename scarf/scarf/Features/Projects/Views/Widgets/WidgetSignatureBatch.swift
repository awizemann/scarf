import SwiftUI
import Foundation
import ScarfCore

/// ONE stat per tick for the WHOLE dashboard, instead of one per widget.
///
/// Every file-reading widget (`markdown_file`, `image` with a local `path`,
/// `log_tail`) re-runs its `.task(id:)` on every coalesced watcher tick, and
/// each one used to build its own transport and issue its own `stat` to
/// decide whether its bytes could have changed. W widgets meant W SSH
/// round-trips per tick, which — after the PF batch made the cockpit's own
/// facet reload a single batched stat — was the dominant per-tick term on a
/// populated dashboard.
///
/// This is the same machinery `ProjectCockpitViewModel` uses for its facets
/// (`transport.statAll` + a `path -> "<mtime>:<size>"` map), scoped to a
/// dashboard panel: the FIRST widget to ask for a tick's signature starts
/// one `statAll` over EVERY file-reading widget path on the dashboard, and
/// the rest await that same pass. One round-trip, W answers.
///
/// ## What it deliberately does not change
///
/// - **The signature itself** is byte-identical to `WidgetFileRead.signature`
///   (`"<mtime-seconds>:<size>"`), so a widget's stored signature survives a
///   switch between the batched and the per-widget path.
/// - **Absent is a state.** A path that `statAll` answered for but that isn't
///   in its reply is `.known(nil)` — exactly what a per-widget `stat` of a
///   missing file returns — so the widget still runs its read and still
///   surfaces the read error. It is NOT treated as "unchanged".
/// - **No answer is not an answer.** `statAll` returning nil means "do not
///   trust this" (see `ServerTransport.statAll`). This publishes `.unknown`
///   for that tick, and the widget falls back to its own single `stat` —
///   i.e. it degrades to exactly the old cost on exactly the ticks where the
///   transport is already failing, and never to "nothing changed".
/// - **A widget whose path this doesn't cover** (rendered outside a panel
///   that installs the scope, or a path that didn't resolve when the panel
///   collected them) also gets `.unknown` and stats itself. A widget can
///   therefore never go stale for want of a batch.
/// What the batch can say about one path on one tick.
///
/// Deliberately a top-level `Sendable` type rather than a member of the
/// `@MainActor` batch: the widgets carry it INTO their detached read, where a
/// main-actor-isolated enum could not go.
enum WidgetSignatureLookup: Sendable, Equatable {
    /// The batched stat answered for this tick. `nil` = the file is not
    /// there (or the transport declined to describe it), which is a
    /// change-relevant state, not "unchanged".
    case known(String?)
    /// No batched answer for this tick — the caller should stat for
    /// itself. Never means "unchanged".
    case unknown
}

@MainActor
@Observable
final class WidgetSignatureBatch {
    /// The tick whose result is committed, and that result. `nil` result =
    /// the pass ran and could not be trusted.
    /// Ticks are identified by (watcher stamp, path set): a dashboard that
    /// gains a widget mid-tick must not be answered out of a map taken
    /// before that path existed. Without the path set in the key, the new
    /// path is simply missing from the committed map and reads as ABSENT —
    /// which is safe (the widget reads rather than skips) but writes a lie
    /// into the widget's stored signature for one tick.
    private struct TickKey: Equatable {
        let tick: String
        let paths: [String]
    }

    @ObservationIgnored private var committedTick: TickKey?
    @ObservationIgnored private var committed: [String: String]?

    @ObservationIgnored private var inFlightTick: TickKey?
    @ObservationIgnored private var inFlight: Task<[String: String]?, Never>?

    /// Test seam: how many batched `statAll` passes have actually run. W
    /// widgets on one tick must move this by exactly one.
    @ObservationIgnored private(set) var passCount = 0

    /// The batched signature for `path` on `tick`, running (or joining) the
    /// single pass for that tick.
    ///
    /// `among` is the full set of paths the pass should cover — supplied by
    /// the caller rather than accumulated here on purpose: the panel knows
    /// every file-reading widget's path from the dashboard it is about to
    /// render, so the first widget to ask already asks for all of them.
    /// Accumulating registrations from the widgets themselves would make the
    /// pass's coverage depend on which widget's `.task` happened to run
    /// first.
    func signature(
        for path: String,
        tick: String,
        among paths: [String],
        context: ServerContext
    ) async -> WidgetSignatureLookup {
        guard paths.contains(path) else { return .unknown }
        guard let stats = await stats(tick: tick, paths: paths, context: context) else {
            return .unknown
        }
        return .known(stats[path])
    }

    private func stats(
        tick rawTick: String, paths: [String], context: ServerContext
    ) async -> [String: String]? {
        let tick = TickKey(tick: rawTick, paths: paths)
        if committedTick == tick { return committed }
        if inFlightTick == tick, let inFlight { return await inFlight.value }

        let task = Task.detached(priority: .utility) { () -> [String: String]? in
            guard !paths.isEmpty else { return [:] }
            guard let stats = context.makeTransport().statAll(paths) else { return nil }
            var out: [String: String] = [:]
            for (path, info) in stats {
                out[path] = "\(Int(info.mtime.timeIntervalSince1970)):\(info.size)"
            }
            return out
        }
        inFlight = task
        inFlightTick = tick
        passCount += 1
        let result = await task.value
        // Only the starter of THIS tick's pass commits it — a later tick that
        // began while this one was in flight owns the slots now.
        if inFlightTick == tick {
            committed = result
            committedTick = tick
            inFlight = nil
            inFlightTick = nil
        }
        return result
    }

    // MARK: - Path collection

    /// Widget types whose rendering depends on reading a file under the
    /// project root — the ones a batched signature can serve.
    static let fileReadingTypes: Set<String> = ["markdown_file", "log_tail", "image"]

    /// Every project-root-relative widget path on `dashboard`, resolved and
    /// de-duplicated, in a stable order.
    ///
    /// Resolution goes through `WidgetPathResolver` — the same gate the
    /// widgets use — so a path this batch stats is by construction one the
    /// widget was allowed to read. A path that does not resolve is simply
    /// absent from the batch; that widget renders its own refusal card and
    /// never reads anything.
    static func filePaths(in dashboard: ProjectDashboard?, projectRoot: String?) -> [String] {
        guard let dashboard else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for section in dashboard.sections {
            for widget in section.widgets where fileReadingTypes.contains(widget.type) {
                // A remote `image` widget (url, no path) reads no file.
                guard widget.path != nil else { continue }
                guard case .success(let resolved) =
                        WidgetPathResolver.resolve(widget.path, projectRoot: projectRoot)
                else { continue }
                if seen.insert(resolved).inserted { out.append(resolved) }
            }
        }
        return out
    }
}

/// The batch plus the path set it should cover, handed down together so a
/// widget can never ask for a pass narrower than the dashboard it is part of.
@MainActor
struct WidgetSignatureScope: Equatable {
    let batch: WidgetSignatureBatch
    let paths: [String]

    /// The panel rebuilds this struct on every body evaluation around the
    /// same `@State` batch, so identity-plus-paths is the honest comparison
    /// and keeps an unchanged dashboard from invalidating every widget that
    /// reads the environment value.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.batch === rhs.batch && lhs.paths == rhs.paths
    }
}

extension Optional where Wrapped == WidgetSignatureScope {
    /// The batched answer for `path` on `tick`, or `.unknown` when there is
    /// no scope installed at all. The one call site shape every file-reading
    /// widget uses, so "no scope" and "path not covered" degrade the same way
    /// in exactly one place.
    @MainActor
    func lookup(
        path: String, tick: String, context: ServerContext
    ) async -> WidgetSignatureLookup {
        guard let scope = self else { return .unknown }
        return await scope.batch.signature(
            for: path, tick: tick, among: scope.paths, context: context
        )
    }
}

private struct WidgetSignatureScopeKey: EnvironmentKey {
    static let defaultValue: WidgetSignatureScope? = nil
}

extension EnvironmentValues {
    /// Installed by the cockpit's Dashboard panel. `nil` anywhere else —
    /// file-reading widgets then stat individually, exactly as they did
    /// before this existed.
    var widgetSignatureScope: WidgetSignatureScope? {
        get { self[WidgetSignatureScopeKey.self] }
        set { self[WidgetSignatureScopeKey.self] = newValue }
    }
}
