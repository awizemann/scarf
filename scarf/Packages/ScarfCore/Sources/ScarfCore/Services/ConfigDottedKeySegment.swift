import Foundation

/// Escapes a user-supplied string for safe interpolation into one segment
/// of a dotted `hermes config` key path (`quick_commands.<name>.type`,
/// `credential_pool_strategies.<provider>`, ...).
///
/// `hermes config set/get/unset` uses `.` as the nesting separator. Before
/// v0.21, a literal `.` inside an interpolated segment (e.g. a quick
/// command named "v1.2 deploy") was silently split into bogus nested maps
/// — corrupting `config.yaml` (hermes-agent #84064). v0.21 added
/// backslash-dot escaping (`_split_key_path`, ``\.`` = literal dot) plus a
/// loud refusal when a write would shadow an existing dotted literal key
/// (see ``HermesCapabilities/hasConfigDottedKeyEscape``).
///
/// This helper is the single place Scarf decides how to neutralize a dot
/// in an interpolated segment, so every writer stays correct on both host
/// generations without re-deriving the escaping rule:
///  - **v0.21+ hosts** (`hasConfigDottedKeyEscape == true`): escape `.` as
///    `\.` so the segment round-trips through `_split_key_path` intact.
///  - **Pre-v0.21 hosts**: there is no escape syntax, so a dot would still
///    corrupt the config. Strip dots out instead — extending the
///    space-to-underscore sanitization Scarf already applied — so older
///    hosts never receive a key that splits wrong.
///
/// Space-to-underscore sanitization is folded in here too (previously
/// duplicated at each call site) since it's applied unconditionally on
/// both host generations.
///
/// ## Cold cache: the pre-v0.21 branch is the safe default, deliberately
/// `HermesCapabilities` is populated by an async `hermes --version` probe,
/// so a write issued before that probe lands sees `.empty` and takes the
/// **strip** branch even on a genuine v0.21 host. That is the intended
/// failure direction and must not be "fixed":
///  - Stripping is *lossy but never corrupting* — "v1.2 deploy" becomes
///    `v12_deploy`, one key, exactly where the user can see it and rename
///    it.
///  - Escaping optimistically would be *corrupting* when the guess is
///    wrong — a pre-v0.21 host has no `_split_key_path` escape handling,
///    so a literal `\.` splits anyway and scatters bogus nested maps
///    through `config.yaml` (hermes-agent #84064), the exact bug this
///    helper exists to prevent.
/// Unknown capability therefore means "assume the older, stricter host".
public enum ConfigDottedKeySegment {
    /// Sanitize/escape `segment` for use as one path component passed to
    /// `hermes config set/get/unset`. Byte-identical to the input (modulo
    /// the existing space→underscore rule) when `segment` contains no dot,
    /// on either host generation — this is a strict extension, not a
    /// behavior change, for the common dot-free case.
    public static func escaped(_ segment: String, capabilities: HermesCapabilities) -> String {
        let spaceSanitized = segment.replacingOccurrences(of: " ", with: "_")
        guard spaceSanitized.contains(".") else { return spaceSanitized }
        if capabilities.hasConfigDottedKeyEscape {
            return spaceSanitized.replacingOccurrences(of: ".", with: "\\.")
        }
        return spaceSanitized.replacingOccurrences(of: ".", with: "")
    }
}
