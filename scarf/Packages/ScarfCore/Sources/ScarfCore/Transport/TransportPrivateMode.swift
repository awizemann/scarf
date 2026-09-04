import Foundation

/// Which files a transport must create with `0600`.
///
/// Both transports write the same Hermes files, so both owe them the same
/// permissions — but only ``LocalTransport`` used to enforce it, leaving
/// `.env` (provider API keys, bot tokens) world-readable on every REMOTE
/// host Scarf writes to. That is the asymmetry this type exists to remove:
/// one basename list, consulted from both sides, so a file added here is
/// protected on both at once.
///
/// Matching is on the **basename** only. The directory is irrelevant — a
/// profile's `.env` under `~/.hermes/profiles/<id>/` holds the same class of
/// secret as the root one, and a path-prefix rule would have to enumerate
/// every profile layout to say so.
/// `public` because the iOS transport (`CitadelServerTransport`, in the
/// ScarfIOS package) is the third writer of these same files and owes them
/// the same mode — a rule that lives in one place only if both packages can
/// read it.
public enum TransportPrivateMode {

    /// Heuristic: files that conventionally hold secrets should be created
    /// with restrictive permissions so a future `scp` or editor doesn't end
    /// up exposing them.
    public static func shouldEnforce(for path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name == "auth.json" || name.hasSuffix("-tokens.json")
    }
}
