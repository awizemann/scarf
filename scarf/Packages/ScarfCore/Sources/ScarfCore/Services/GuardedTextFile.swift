import Foundation
#if canImport(os)
import os
#endif

/// `GuardedJSONStore`'s discipline for the files that are NOT JSON:
/// `~/.hermes/config.yaml`, `~/.hermes/.env`, `MEMORY.md`, `USER.md`.
///
/// **Why this exists.** Every writer of those files is a whole-file
/// read-modify-write, and each one had grown its OWN copy of the read
/// (`readText(path) ?? ""`, `try? readFile … else header`, `readFile(path)
/// ?? ""`). That is the per-writer disease: the guard gets applied to a
/// FILE by whichever writer someone happened to audit, and the next writer
/// of the same file re-opens the hole. `config.yaml` alone had five
/// independent writers (`KanbanToolsetEnabler` ×2, `HermesFileService`'s MCP
/// patch + its two restores, `SettingsViewModel.saveDirectYAML`,
/// `GatewayConfigWriter.saveList`) and exactly zero of them could tell a
/// dropped SSH round-trip from an empty file — so one blip published a
/// config containing only the section being edited.
///
/// **What it keeps from `GuardedJSONStore`** (see that type's header for the
/// full argument): proof, not inference — a failed read is damage only when
/// a `stat` CONFIRMS the file and a RETRIED read fails too; a write keeps a
/// one-deep `.bak` of the bytes it replaces.
///
/// **What it deliberately changes:**
/// 1. **Zero bytes is a LEGAL state, not damage.** Scarf never writes a
///    zero-length JSON sidecar, so an empty one was truncated by somebody.
///    An empty `.env` or an empty `MEMORY.md` is a real thing a person
///    made, and refusing to write over it would freeze the surface. This is
///    exactly the reclassification `GuardedJSONStore.Inspection`'s public
///    initializer documents. `exists` stays `true` for such a file, so
///    "absent ⇒ create fresh" and "present but empty" remain distinct for
///    callers that care (`.env`'s header line).
/// 2. **Bytes that are not UTF-8 are a REFUSAL, not a rebuild.** These
///    files are hand-authored prose and configuration whose contents exist
///    nowhere else — the `projects.json` rule, not the sidecar rule. We
///    hold bytes we cannot interpret; replacing them would be the same
///    destruction by a slower route.
/// 3. **No `createDirectory` before publishing.** The parents of these four
///    files always exist, none of the writers this replaced created them,
///    and several of these call sites run synchronously on the main actor
///    (C10) where a gratuitous extra round-trip is a hang.
public struct GuardedTextFile: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "GuardedTextFile")
    #endif

    /// What a guarded load found, and the proof a later `write` needs.
    public struct Loaded: Sendable {
        /// The file's text. `""` for both an absent file and an empty one —
        /// check `exists` to tell them apart.
        public let text: String
        /// Whether the file is actually there. `false` only when a `stat`
        /// could not confirm it after the read failed.
        public let exists: Bool
        /// The inspection this load is based on. `write` consumes it rather
        /// than re-reading: a second read would cost another round-trip AND
        /// open a fresh read-then-write window.
        public let inspection: GuardedJSONStore.Inspection

        public init(text: String, exists: Bool, inspection: GuardedJSONStore.Inspection) {
            self.text = text
            self.exists = exists
            self.inspection = inspection
        }
    }

    /// Why a guarded text write was refused. Separate from
    /// `GuardedStoreError` so the "we refused" cases for irreplaceable text
    /// carry their own, user-facing wording.
    public enum Refusal: LocalizedError, Sendable, Equatable {
        /// Stat-confirmed but unreadable (twice), or too large to hold.
        case unreadable(path: String, label: String)
        /// We hold the bytes; they are not UTF-8. Replacing them would
        /// destroy content nobody has seen.
        case notUTF8(path: String, label: String)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(path, label):
                return "\(label) at \(path) exists but couldn't be read; refusing to overwrite it."
            case let .notUTF8(path, label):
                return "\(label) at \(path) isn't valid UTF-8 text; refusing to overwrite it."
            }
        }
    }

    public let transport: any ServerTransport
    /// Short name used in log lines and refusal messages (`"config.yaml"`).
    public let label: String

    /// Generous: these are hand-sized files (a fat `config.yaml` is ~10 KB).
    /// The cap is a sanity bound on holding a runaway file in memory, not a
    /// tuning knob — anything past it is refused, never republished over.
    public static let defaultMaxBytes = 32 * 1024 * 1024

    public nonisolated init(transport: any ServerTransport, label: String) {
        self.transport = transport
        self.label = label
    }

    // MARK: - Read

    /// Read `path` with proof, or throw a `Refusal`.
    ///
    /// A healthy load is still ONE read: the stat + retry probe runs only
    /// after a read has already failed.
    public nonisolated func load(
        _ path: String,
        maxBytes: Int = GuardedTextFile.defaultMaxBytes
    ) throws -> Loaded {
        let store = GuardedJSONStore(transport: transport, label: label)
        let inspection = store.inspect(path, maxBytes: maxBytes)
        switch inspection.state {
        case .absent:
            return Loaded(text: "", exists: false, inspection: inspection)
        case .unreadable(let damagedPath):
            // Rule 1: zero bytes is a legal empty text file, not damage.
            if inspection.bytes?.isEmpty == true {
                return Loaded(
                    text: "",
                    exists: true,
                    inspection: GuardedJSONStore.Inspection(state: .absent, bytes: nil)
                )
            }
            throw Refusal.unreadable(path: damagedPath, label: label)
        case .quarantined:
            // Over the size cap. The bytes are safe in the quarantine copy,
            // but we still will not publish a rewrite of a file we never
            // parsed (rule 2's reasoning, by size instead of encoding).
            throw Refusal.unreadable(path: path, label: label)
        case .present:
            guard let bytes = inspection.bytes else {
                throw Refusal.unreadable(path: path, label: label)
            }
            guard let text = String(data: bytes, encoding: .utf8) else {
                #if canImport(os)
                Self.logger.error(
                    "\(self.label, privacy: .public) at \(path, privacy: .public) is not valid UTF-8; refusing to overwrite"
                )
                #endif
                throw Refusal.notUTF8(path: path, label: label)
            }
            return Loaded(text: text, exists: true, inspection: inspection)
        }
    }

    // MARK: - Write

    /// Publish `text` over `path`, keeping a one-deep `.bak` of the bytes it
    /// replaces.
    ///
    /// - Parameter loaded: the load this write is based on. It carries the
    ///   proof that the predecessor was readable — which is why a `Loaded`
    ///   is the only way to reach this method.
    public nonisolated func write(_ text: String, to path: String, after loaded: Loaded) throws {
        let data = Data(text.utf8)
        if let existing = loaded.inspection.bytes, !existing.isEmpty, existing != data {
            // Best effort: losing the backup is not a reason to fail the
            // write the user asked for.
            do {
                // UNGUARDED-WRITE(G): GuardedTextFile's own one-deep .bak publish.
                try transport.unguardedWriteFile(path + ".bak", data: existing)
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "Could not refresh \(self.label, privacy: .public).bak: \(error.localizedDescription, privacy: .public)"
                )
                #endif
            }
        }
        // The refusal already happened in `load`, whose proof `loaded` carries.
        // UNGUARDED-WRITE(G): GuardedTextFile's own guarded publish.
        try transport.unguardedWriteFile(path, data: data)
    }
}
