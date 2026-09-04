import Foundation
import Security
import os

/// Thin wrapper around the macOS Keychain for template-config secrets.
///
/// **Lifted into ScarfCore** (originally lived only in the Mac app
/// target as `scarf/scarf/Core/Services/ProjectConfigKeychain.swift`) so
/// the `scarf-projects` MCP server's `project_set_config` tool can mint
/// and resolve refs through the SAME Keychain calls the app's
/// Configuration UI uses — never a second, MCP-only implementation of
/// Keychain I/O. The app target keeps a `typealias` pointing back here
/// (see that file) so there is exactly one implementation, not two
/// copies that could drift.
///
/// **What we store.** Generic passwords (kSecClassGenericPassword) in
/// the login Keychain. Each item is identified by a (service, account)
/// pair derived from the template slug + field key + project-path hash
/// — see `TemplateKeychainRef.make`. The stored Data is the user's
/// raw secret bytes; we never transform or encode them.
///
/// **What shows to the user.** macOS prompts "Scarf wants to access
/// the Keychain" the first time we read a secret in a given session.
/// User approves; subsequent reads in that session are silent. We
/// never bypass this — the prompt is the user's trust boundary.
public struct ProjectConfigKeychain: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectConfigKeychain")

    /// Which Keychain to target. The default is the login Keychain
    /// (`nil` uses the user's default chain). Tests pass an explicit
    /// namespace suffix so integration tests can roundtrip without
    /// polluting real user state.
    public let testServiceSuffix: String?

    public nonisolated init(testServiceSuffix: String? = nil) {
        self.testServiceSuffix = testServiceSuffix
    }

    /// Write or overwrite the secret for (service, account). Tests
    /// route their items through a distinct service prefix via
    /// `testServiceSuffix` so they can't leak into the user's real
    /// Keychain.
    public nonisolated func set(service: String, account: String, secret: Data) throws {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
        // Try update first — cheaper than delete-then-add and doesn't
        // trip macOS's "item already exists" if another thread raced us.
        let update: [String: Any] = [
            kSecValueData as String: secret,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw Self.error(status: updateStatus, op: "update")
        }
        var insert = query
        insert[kSecValueData as String] = secret
        // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — stays in
        // this device's Keychain, not synced via iCloud, usable after
        // first unlock (so background cron triggers can read).
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw Self.error(status: addStatus, op: "add")
        }
    }

    /// Retrieve the secret for (service, account). Returns `nil` when
    /// the item simply doesn't exist (user never set it, or an
    /// uninstall already removed it). Throws on every other Keychain
    /// error so callers don't silently treat "access denied" or
    /// "corrupt keychain" as "no value."
    public nonisolated func get(service: String, account: String) throws -> Data? {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            throw Self.error(status: status, op: "get")
        }
        return result as? Data
    }

    /// Delete the secret for (service, account). Absent item is a
    /// no-op; any other failure throws.
    public nonisolated func delete(service: String, account: String) throws {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw Self.error(status: status, op: "delete")
    }

    /// Convenience: apply the test suffix when in test mode.
    private nonisolated func resolved(service: String) -> String {
        guard let suffix = testServiceSuffix, !suffix.isEmpty else { return service }
        return "\(service).\(suffix)"
    }

    /// Build a useful NSError from a Keychain OSStatus. Logs at warning
    /// — callers decide whether the failure is fatal.
    private nonisolated static func error(status: OSStatus, op: String) -> NSError {
        let description = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
        logger.warning("Keychain \(op, privacy: .public) failed: \(status) \(description, privacy: .public)")
        return NSError(
            domain: "com.scarf.keychain",
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Keychain \(op) failed (\(status)): \(description)"
            ]
        )
    }
}

// MARK: - Ref-shaped convenience layer

public extension ProjectConfigKeychain {
    /// Set a secret using a pre-built `TemplateKeychainRef`. Mirrors the
    /// service/account plumbing every caller would otherwise repeat.
    nonisolated func set(ref: TemplateKeychainRef, secret: Data) throws {
        try set(service: ref.service, account: ref.account, secret: secret)
    }

    nonisolated func get(ref: TemplateKeychainRef) throws -> Data? {
        try get(service: ref.service, account: ref.account)
    }

    nonisolated func delete(ref: TemplateKeychainRef) throws {
        try delete(service: ref.service, account: ref.account)
    }
}

// MARK: - Template slug

/// Filesystem-safe slug derived from a template manifest `id`
/// (`"owner/name"` → `"owner-name"`). Used for the install directory
/// name, skills namespace, cron-job tag, and — via
/// `TemplateKeychainRef.make(templateSlug:...)` — the Keychain service
/// namespace `com.scarf.template.<slug>`.
///
/// Lifted into ScarfCore alongside `TemplateKeychainRef` so both the app
/// target's `ProjectTemplateManifest.slug` and the `scarf-projects` MCP
/// server's `project_set_config` tool derive the SAME slug from the SAME
/// manifest id — a divergence here would mint Keychain refs the app's
/// Configuration UI could never resolve, or vice versa.
public enum TemplateSlug {
    public nonisolated static func derive(fromID id: String) -> String {
        let ascii = id.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
            return "-"
        }
        let collapsed = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "template" : collapsed
    }
}

// MARK: - Keychain reference

/// One secret stored via `ProjectConfigKeychain`. We derive both halves
/// (service + account) from the template slug + project-path hash so two
/// installs of the same template in different dirs don't collide in the
/// login Keychain.
///
/// **Lifted into ScarfCore** alongside `ProjectConfigKeychain` — see the
/// note on that type. The app target's `TemplateConfig.swift` keeps a
/// `typealias TemplateKeychainRef = ScarfCore.TemplateKeychainRef`.
public struct TemplateKeychainRef: Sendable, Equatable {
    /// Macro service name, e.g. `com.scarf.template.awizemann-site-status-checker`.
    public let service: String
    /// Account name: `<fieldKey>:<projectPathHashShort>`. The hash suffix
    /// guarantees uniqueness across multiple installs of the same template.
    public let account: String

    public nonisolated init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// `"keychain://<service>/<account>"` — what lands in `config.json`.
    public nonisolated var uri: String { "keychain://\(service)/\(account)" }

    /// The one service namespace Scarf ever reads or deletes. Every ref
    /// Scarf mints is `com.scarf.template.<slug>`; a ref naming anything
    /// else (`com.apple.…`, an SSH key service, another app's items) is
    /// not ours and must never reach `SecItem*`.
    public nonisolated static let serviceNamespace = "com.scarf.template."

    /// Parse a `keychain://…` URI back into a ref. Returns `nil` when the
    /// input isn't well-formed so callers can distinguish a missing ref
    /// from a malformed one.
    ///
    /// **Trust boundary.** `config.json` and `template.lock.json` are
    /// agent-writable, so the URIs that reach here are attacker-controlled
    /// input, not records of what Scarf did. Parsing therefore enforces
    /// the shape Scarf mints rather than accepting any (service, account)
    /// pair: the service must live under `serviceNamespace` with a
    /// non-empty slug, and the account must be `<fieldKey>:<8-hex-hash>`.
    /// That confines every read/delete to items Scarf itself could have
    /// created. Binding a ref to the OWNING project is a second, separate
    /// check — see `belongs(toProjectPath:)`.
    public nonisolated static func parse(_ uri: String) -> TemplateKeychainRef? {
        guard uri.hasPrefix("keychain://") else { return nil }
        let rest = String(uri.dropFirst("keychain://".count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let service = String(rest[..<slash])
        let account = String(rest[rest.index(after: slash)...])
        guard !service.isEmpty, !account.isEmpty else { return nil }
        // Namespace: com.scarf.template.<slug>, slug non-empty and free of
        // separators that would let a crafted uri smuggle structure.
        guard service.hasPrefix(serviceNamespace) else { return nil }
        let slug = String(service.dropFirst(serviceNamespace.count))
        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        // Account: <fieldKey>:<8 hex chars>. Split on the LAST colon so a
        // field key containing one still parses.
        guard let colon = account.lastIndex(of: ":") else { return nil }
        let fieldKey = String(account[..<colon])
        let hash = String(account[account.index(after: colon)...])
        guard !fieldKey.isEmpty,
              !fieldKey.contains("/"),
              hash.count == 8,
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return TemplateKeychainRef(service: service, account: account)
    }

    /// The project-path fingerprint baked into this ref's account, i.e.
    /// which project's install minted it. Non-nil for any ref that came
    /// through `parse` (which enforces the shape).
    public nonisolated var projectPathHash: String? {
        guard let colon = account.lastIndex(of: ":") else { return nil }
        return String(account[account.index(after: colon)...])
    }

    /// Is this ref one that an install rooted at `projectPath` could have
    /// minted? Cross-project isolation lives here: project A's
    /// `config.json` naming project B's ref fails this check, so B's
    /// secret is never resolved into A's env block (or deleted by A's
    /// uninstall).
    ///
    /// Both the raw and the symlink-resolved spelling of the path are
    /// accepted, because a registry row can hold `/tmp/x` for a project
    /// installed as `/private/tmp/x` (and vice versa) — the same
    /// directory either way.
    public nonisolated func belongs(toProjectPath projectPath: String) -> Bool {
        guard let hash = projectPathHash else { return false }
        return Self.acceptableHashes(forProjectPath: projectPath).contains(hash)
    }

    /// Every path-hash that legitimately denotes `projectPath`. The
    /// spellings differ in practice (`/tmp/x` vs `/private/tmp/x`, a
    /// trailing slash, a symlinked parent), and `Foundation` normalizes
    /// them inconsistently — `resolvingSymlinksInPath` STRIPS a `/private`
    /// prefix rather than adding one — so enumerate the variants instead
    /// of trusting one canonical form.
    public nonisolated static func acceptableHashes(forProjectPath projectPath: String) -> Set<String> {
        var spellings: Set<String> = [projectPath]
        let standardized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        spellings.insert(standardized)
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        spellings.insert(resolved)
        for path in Array(spellings) {
            if path.hasPrefix("/private/") {
                spellings.insert(String(path.dropFirst("/private".count)))
            } else {
                spellings.insert("/private" + path)
            }
        }
        return Set(spellings.map(shortHash(of:)))
    }

    /// Build a ref from a template slug + field key + project path.
    /// The hash suffix is a fingerprint of the absolute project path.
    /// Stable across launches, different between `/Users/a/proj1` and
    /// `/Users/a/proj2`.
    public nonisolated static func make(
        templateSlug: String,
        fieldKey: String,
        projectPath: String
    ) -> TemplateKeychainRef {
        TemplateKeychainRef(
            service: "com.scarf.template.\(templateSlug)",
            account: "\(fieldKey):\(Self.shortHash(of: projectPath))"
        )
    }

    public nonisolated static func shortHash(of string: String) -> String {
        // 8 hex chars is 32 bits of uniqueness — plenty for
        // distinguishing a handful of project dirs per template install.
        let data = Data(string.utf8)
        var hash: UInt32 = 0x811c9dc5
        for byte in data {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return String(format: "%08x", hash)
    }
}
