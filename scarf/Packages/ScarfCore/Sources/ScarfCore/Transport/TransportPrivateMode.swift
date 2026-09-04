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
        let name = originalBasename((path as NSString).lastPathComponent)
        return name == ".env" || name == "auth.json" || name.hasSuffix("-tokens.json")
    }

    /// Strip the suffixes Scarf's own guarded writers append when they copy
    /// a file aside, so the mode is decided by WHAT THE BYTES ARE, not by
    /// what the copy is called (P8 SEC-L2).
    ///
    /// `.env.bak` and `.env.corrupt-20260904T101112Z` hold exactly the
    /// secrets `.env` holds — the whole previous contents of it — and under
    /// a plain basename match neither one matched anything, so on every
    /// remote host Scarf writes to they landed world-readable while the
    /// original they were copied from was `0600`. The backup discipline the
    /// D-series added was quietly undoing the permission discipline.
    ///
    /// Applied repeatedly, because `.corrupt-` copies are made of files
    /// that may themselves be `.bak`s.
    static func originalBasename(_ name: String) -> String {
        var current = name
        while true {
            if current.hasSuffix(".bak") {
                current = String(current.dropLast(4))
                continue
            }
            if let range = current.range(of: ".corrupt-", options: .backwards) {
                current = String(current[current.startIndex..<range.lowerBound])
                continue
            }
            return current
        }
    }
}
