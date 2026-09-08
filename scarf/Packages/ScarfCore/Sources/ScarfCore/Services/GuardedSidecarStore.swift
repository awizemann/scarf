import Foundation

/// What a store does with bytes it HELD but could not use — i.e. with
/// undecodable JSON.
///
/// **Not the size cap.** Bytes past ``GuardedSidecarStore/maxBytes`` are
/// refused by a `stat` BEFORE they are read (GW-F5 / SEC F3), so there are
/// no bytes to hold, no `.corrupt-` copy to make, and nothing for a policy
/// to choose between: both policies refuse an oversized file. This enum is
/// about the decode failure only.
///
/// **This is a property of the FILE, not of the store type.** Two stores
/// built on the same `GuardedJSONStore` want opposite answers, and picking
/// the wrong one is a data-loss bug in either direction, so the choice is
/// declared per adopter and never defaulted.
public enum GuardedDamagePolicy: Sendable, Equatable {
    /// The rows exist NOWHERE ELSE, so rebuilding from empty destroys them.
    /// Unusable bytes are still copied aside for the human, but the state is
    /// reclassified to `.unreadable` and every write stays refused until a
    /// person fixes the file. `projects.json`, `servers.json`,
    /// `model_presets.json`.
    case refuseForever

    /// The file is a REBUILDABLE index: every row can be re-derived from a
    /// user action or another source of truth, and a permanently frozen file
    /// would be worse than a quarantined one. Unusable bytes are copied
    /// aside and the store rebuilds from empty. `miniapp_grants.json`
    /// (the permission sheet re-asks), `session_project_map.json` (the next
    /// chat re-records), `project.json`, `manifest.json`.
    case quarantineAndRebuild
}

/// **The adoption path for a new Scarf-owned JSON sidecar.** Conform, declare
/// three things, and the read-then-write discipline
/// `GuardedJSONStore` implements arrives already wired: proof-based
/// absent-vs-unreadable, zero-bytes-is-damage, quarantine with dedup, a
/// one-deep `.bak`, an atomic publish — and the damage policy applied to the
/// decode failure. (The size cap is not a policy question: it is refused
/// stat-first, unread, for every adopter.)
///
/// ```swift
/// struct WidgetPinStore: GuardedSidecarStore {
///     static let label = "widget_pins.json"
///     static let maxBytes = 1 * 1024 * 1024
///     static let damagePolicy = GuardedDamagePolicy.quarantineAndRebuild
///     let context: ServerContext
///     var transport: any ServerTransport { context.makeTransport() }
/// }
/// ```
///
/// ## 1. Which damage policy?
///
/// Ask one question: *if these bytes are gone, can the user get them back
/// without knowing they were lost?* A grant is re-granted by the permission
/// sheet that reappears; an attribution is re-recorded on the next chat —
/// `.quarantineAndRebuild`. A saved model preset, a configured SSH server,
/// a project row exists nowhere else and its silent disappearance is the
/// data loss — `.refuseForever`. When in doubt pick `.refuseForever`: a
/// frozen file is a support ticket, a rebuilt one is a deletion.
///
/// `.refuseForever` is honoured HERE, in the defaults below, rather than by
/// each adopter: `ServerRegistry` hand-rolled the reclassification (GW-E2b)
/// and had to remember it on every branch that produced a quarantine, which
/// is exactly what a new store forgets. The original bytes are still
/// quarantined either way and the copy's path survives on
/// `Inspection.quarantineCopy`, so a refusing store can still tell the user
/// where its file went.
///
/// ## 2. Which shape?
///
/// The invariant to preserve is not "there is one `mutate {}`" — it is
/// **A PUBLISH VALIDATES AGAINST THE SAME INSPECTION THE IN-MEMORY STATE WAS
/// BUILT FROM.** Two shapes satisfy it and both are supported:
///
/// - **Closure** (`ProjectManifestStore`, `MiniAppGrantStore`): inspect,
///   mutate, publish in one call. Nothing is held, so nothing can go stale.
///   Prefer this. Note that reverting it to `load()` + `persist()` reopens
///   the hole even with the guard in place — the write would then be checked
///   against a DIFFERENT read than the one it was computed from.
/// - **Held inspection** (`ServerRegistry`): the in-memory list is the
///   source for many small mutating methods that each end in `save()`.
///   Store the inspection from the load and pass it to
///   ``publish(_:to:after:)`` — whose parameter is OPTIONAL precisely so
///   that a store which has not inspected yet (or dropped its inspection)
///   is REFUSED rather than publishing against nothing. Re-record the
///   inspection after a successful publish; the file provably holds those
///   bytes now.
///
/// ## 3. "Should I create this?" — the cheap counterpart
///
/// ``probeExistence(_:)`` answers the create-if-missing gate
/// (`if !fileExists { write }`), which is the same absent-vs-unreadable
/// INFERENCE as `try? decode ?? []` wearing a different hat: over SSH
/// `fileExists` is a round trip, one dropped round trip answers `false`, and
/// the scaffold placeholder then lands on top of the real file. Two
/// independent probes must agree before a path is called empty. Use it when
/// you only need the yes/no; use ``inspect(_:)`` when you need the contents,
/// because the two probes cost less than pulling an unknown number of bytes
/// across a transport to answer a boolean.
///
/// ## 4. Unknown keys
///
/// If anything other than this build ever writes the file — a newer Scarf, a
/// template author, Hermes, another device — re-encoding through the typed
/// model DELETES every key this build has not heard of. Two working
/// precedents: mutate the JSON object graph directly
/// (`ProjectManifestStore.setField`, which decodes to `JSONValue`), or give
/// the model an `extra: [String: JSONValue]` swept with `AnyCodingKey`
/// (`ScarfProject.extra`, `SessionProjectMap.extra`). Single-writer,
/// schema-versioned files may skip this — `servers.json` documents that it
/// does.
///
/// ## 5. `.bak` semantics
///
/// One deep, written by ``publish(_:to:after:)`` from the bytes the
/// inspection already holds (no second read), best-effort — losing the
/// backup never fails the user's write. It is NOT refreshed on a quarantine
/// cycle: the unusable bytes are already in the `.corrupt-<stamp>` copy, and
/// overwriting the `.bak` with them would cost the user their last good
/// version too. Two things to check before adopting: whoever LISTS the
/// containing directory must filter `.bak` (the Skills picker did not, and
/// showed it), and if the file holds secrets, `TransportPrivateMode` must
/// recognise the `.bak`/`.corrupt-` basename as private.
public protocol GuardedSidecarStore {
    /// Short name for logs and refusal messages (`"miniapp_grants.json"`).
    static var label: String { get }
    /// Anything larger is not this file: it is refused on a `stat`, without
    /// ever being read — a memory-pressured phone must not hold it, let
    /// alone decode it. Both damage policies refuse on size.
    static var maxBytes: Int { get }
    /// See ``GuardedDamagePolicy``. Deliberately un-defaulted.
    static var damagePolicy: GuardedDamagePolicy { get }
    /// Usually `context.makeTransport()`. `nonisolated` so an actor-isolated
    /// or `@MainActor` store can still use the defaults below.
    nonisolated var transport: any ServerTransport { get }
}

extension GuardedSidecarStore {
    /// The underlying guard. Public so an adopter can reach the parts this
    /// protocol deliberately does not wrap (`GuardedJSONStore.quarantine`).
    public nonisolated var guarded: GuardedJSONStore {
        GuardedJSONStore(transport: transport, label: Self.label)
    }

    /// One read answering every question a guarded write has to ask, with
    /// ``GuardedDamagePolicy`` already applied.
    public nonisolated func inspect(_ path: String) -> GuardedJSONStore.Inspection {
        Self.applyingPolicy(guarded.inspect(path, maxBytes: Self.maxBytes), path: path)
    }

    /// ``inspect(_:)`` plus a decode, with the policy applied to the decode
    /// failure. (An oversized file never reaches the decoder: it is refused
    /// on the `stat`.)
    public nonisolated func inspectDecoding<T: Decodable>(
        _ type: T.Type,
        at path: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> (inspection: GuardedJSONStore.Inspection, value: T?) {
        let (inspection, value) = guarded.inspectDecoding(
            type, at: path, maxBytes: Self.maxBytes, decoder: decoder
        )
        return (Self.applyingPolicy(inspection, path: path), value)
    }

    /// Publish `data`, refusing when the predecessor was damage — or when
    /// there is no inspection to validate against at all.
    ///
    /// - Parameter inspection: the inspection this write is based on. `nil`
    ///   means the store never inspected (or dropped what it had), which is
    ///   a refusal: a publish that validates against nothing is the
    ///   destroy shape this whole discipline exists to end.
    public nonisolated func publish(
        _ data: Data,
        to path: String,
        after inspection: GuardedJSONStore.Inspection?
    ) throws {
        guard let inspection else {
            throw GuardedStoreError.refusedUninspectedWrite(path: path, label: Self.label)
        }
        try guarded.write(data, to: path, after: inspection)
    }

    /// "Is it safe to CREATE this file?", proven by two independent probes.
    /// The cheap create-only counterpart to ``inspect(_:)`` — see the
    /// protocol's section 3.
    public nonisolated func probeExistence(_ path: String) -> GuardedJSONStore.Existence {
        GuardedJSONStore.probeExistence(path, transport: transport)
    }

    /// `.refuseForever` turns a quarantine into a refusal while KEEPING the
    /// copy's path, so the adopter can still tell the user where the bytes
    /// went. `.quarantineAndRebuild` is `GuardedJSONStore`'s own behavior
    /// and passes through untouched.
    nonisolated static func applyingPolicy(
        _ inspection: GuardedJSONStore.Inspection, path: String
    ) -> GuardedJSONStore.Inspection {
        guard damagePolicy == .refuseForever,
              case .quarantined(let copy) = inspection.state
        else { return inspection }
        return GuardedJSONStore.Inspection(
            state: .unreadable(path: path), bytes: inspection.bytes, quarantineCopy: copy
        )
    }
}
