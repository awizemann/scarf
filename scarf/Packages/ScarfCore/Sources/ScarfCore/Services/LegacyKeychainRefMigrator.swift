import Foundation
#if canImport(os)
import os
#endif

/// Moves a project's Keychain refs off the retired 32-bit FNV binding the
/// first time each one is successfully read.
///
/// **Why the deprecation window had to be closed by code, not by time**
/// (P8 F1-M2). `TemplateKeychainRef.belongs(toProjectPath:)` still accepts
/// an 8-hex FNV account so that already-configured projects don't lose
/// every secret the day the SHA-256 binding landed. But that branch is the
/// old weakness verbatim: 32 bits of a non-cryptographic hash has chosen
/// preimages an attacker computes in milliseconds, and — because the legacy
/// account carries no template slug and the legacy comparison ignores the
/// one in the service — a single collision reaches items across every
/// template's namespace. The plan was "the next time the user saves that
/// field in the Configuration sheet, it re-mints". Which is to say: never,
/// for a secret that works. A window that only closes when a user
/// re-types a working API key is not a window, it is a permanent state.
///
/// So the window closes on READ instead, which is a thing that actually
/// happens: resolve the secret through the legacy ref, and then, before
/// handing it back, mint the modern SHA-256-bound item, repoint
/// `config.json` at it, and delete the legacy item. Each project's exposure
/// then ends at its next use rather than at its next re-configuration.
///
/// **Order matters, and it is: mint → repoint → delete.**
/// - Mint first: a new item nothing references yet is inert.
/// - Repoint second, through `GuardedJSONStore` — the same guarded
///   read-modify-write `project_set_config` uses, so a `config.json` that
///   is present-but-unreadable REFUSES the rewrite rather than orphaning
///   every other value in it, and every top-level key Scarf doesn't own
///   survives.
/// - Delete last, and ONLY if the repoint succeeded. The reverse order has
///   a state where the config still names an item that no longer exists —
///   the user's secret, gone, for a migration they never asked for. If we
///   stop after the mint, the worst case is one duplicate Keychain item and
///   a retry on the next read.
///
/// Best-effort throughout: a migration failure must never turn a working
/// `resolveSecret` into a failing one. The secret was already read; the
/// caller gets it either way.
public struct LegacyKeychainRefMigrator: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "LegacyKeychainRefMigrator")
    #endif

    /// A project's `config.json` is a handful of typed fields; past this it
    /// is not a config file we should be rewriting. Matches
    /// `ProjectMCPTools.configMaxBytes`.
    public static let configMaxBytes = 1 * 1024 * 1024

    private let transport: any ServerTransport
    private let keychain: ProjectConfigKeychain

    public nonisolated init(transport: any ServerTransport, keychain: ProjectConfigKeychain) {
        self.transport = transport
        self.keychain = keychain
    }

    /// Whether `ref` is one of the retired-form items this migrator moves.
    public nonisolated static func isLegacy(_ ref: TemplateKeychainRef) -> Bool {
        ref.projectPathHash?.count == TemplateKeychainRef.legacyHashLength
    }

    /// Re-mint `ref` under the SHA-256 binding, having just read `secret`
    /// through it.
    ///
    /// - Returns: the new ref when the item moved (config repointed, legacy
    ///   item deleted), `nil` when there was nothing to do or the migration
    ///   could not be completed safely.
    @discardableResult
    public nonisolated func migrate(
        ref: TemplateKeychainRef,
        secret: Data,
        projectPath: String,
        configPath: String
    ) -> TemplateKeychainRef? {
        guard Self.isLegacy(ref), let slug = ref.templateSlug else { return nil }
        // The field key is the account's prefix; `parse` guarantees the
        // `<fieldKey>:<hash>` shape, so this can only fail on a ref that
        // never came through it.
        guard let colon = ref.account.lastIndex(of: ":") else { return nil }
        let fieldKey = String(ref.account[..<colon])

        let fresh = TemplateKeychainRef.make(
            templateSlug: slug, fieldKey: fieldKey, projectPath: projectPath
        )
        guard fresh != ref else { return nil }

        do {
            try keychain.set(ref: fresh, secret: secret)
        } catch {
            Self.log("couldn't mint the re-bound Keychain item for \(fieldKey)", error)
            return nil
        }

        guard repoint(from: ref, to: fresh, configPath: configPath) else {
            // The new item is orphaned but harmless, and the legacy one is
            // untouched, so the secret still resolves and the next read
            // retries the whole migration.
            return nil
        }

        do {
            try keychain.delete(ref: ref)
        } catch {
            // The config already points at the new item, so the secret is
            // safe; the stale legacy item is a leftover, not a hazard —
            // nothing references it any more. Worth saying out loud though.
            Self.log("re-minted \(fieldKey) but couldn't delete the legacy Keychain item", error)
        }

        #if canImport(os)
        Self.logger.notice(
            "migrated Keychain ref for \(fieldKey, privacy: .public) in \(configPath, privacy: .public) off the legacy FNV binding"
        )
        #endif
        return fresh
    }

    /// Rewrite every occurrence of `old.uri` in `config.json`'s `values` to
    /// `new.uri`, through the guarded store. Matching on the URI rather
    /// than on the field key is deliberate: the key the ref is FILED under
    /// is the thing we'd have to trust, and this way a ref referenced from
    /// an unexpected key still moves with its item.
    private nonisolated func repoint(
        from old: TemplateKeychainRef, to new: TemplateKeychainRef, configPath: String
    ) -> Bool {
        let guarded = GuardedJSONStore(transport: transport, label: "config.json")
        let (inspection, decoded) = guarded.inspectDecoding(
            JSONValue.self, at: configPath, maxBytes: Self.configMaxBytes
        )
        if case .unreadable = inspection.state {
            Self.log(
                "refusing to repoint \(configPath) — it exists but couldn't be read", nil
            )
            return false
        }
        guard case .object(var root)? = decoded,
              case .object(var values)? = root["values"]
        else { return false }

        var changed = false
        for (key, value) in values {
            if case .string(old.uri) = value {
                values[key] = .string(new.uri)
                changed = true
            }
        }
        guard changed else { return false }

        root["values"] = .object(values)
        root["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try guarded.write(
                try encoder.encode(JSONValue.object(root)), to: configPath, after: inspection
            )
            return true
        } catch {
            Self.log("couldn't write the repointed \(configPath)", error)
            return false
        }
    }

    private nonisolated static func log(_ message: String, _ error: (any Error)?) {
        #if canImport(os)
        let detail = error?.localizedDescription ?? ""
        logger.warning("\(message, privacy: .public): \(detail, privacy: .public)")
        #endif
    }
}
