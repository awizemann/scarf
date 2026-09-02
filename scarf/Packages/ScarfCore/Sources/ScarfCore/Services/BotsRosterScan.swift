import Foundation

/// One roster entry as the scan produces it: a profile id, the raw bytes of
/// its `profile.yaml` (already bounded), and a cheap stat of its avatar file.
///
/// The avatar's **bytes are deliberately absent**. A 12-profile host with
/// photo avatars is 24MB of image data; pulling that before the roster can
/// paint is the A1-M3 finding. The stat is what the roster needs — it is the
/// avatar cache key (path + size + mtime), so a re-scan after a metadata save
/// resolves to bytes already in memory and transfers nothing.
public struct BotRosterEntry: Sendable, Equatable {
    public let identity: HermesBotIdentity
    public let avatar: BotAvatarStat?

    public init(identity: HermesBotIdentity, avatar: BotAvatarStat?) {
        self.identity = identity
        self.avatar = avatar
    }
}

/// Where a profile's avatar lives and what it looked like at scan time.
///
/// `size`/`mtime` exist to key a cache. They are a *hint*, not an identity:
/// a remote `stat` reports mtime in whole seconds, so two writes inside one
/// second with the same byte count collide. Cache invalidation on the write
/// path is therefore mandatory and this key is the cheap fast path, not the
/// correctness argument (see ``BotAvatarCache``).
public struct BotAvatarStat: Sendable, Equatable {
    public let path: String
    public let mime: String
    public let size: Int64
    /// Whole seconds since the epoch, as both `stat -c %Y` and `stat -f %m`
    /// report it.
    public let mtime: Int64

    public init(path: String, mime: String, size: Int64, mtime: Int64) {
        self.path = path
        self.mime = mime
        self.size = size
        self.mtime = mtime
    }
}

/// The batched profile scan: one `sh` round trip that enumerates
/// `<root>/profiles`, reads every `profile.yaml`, and stats every avatar —
/// instead of the per-file path's `listDirectory` + (`stat` + `stat` +
/// `readFile`) × N + up to 3 `fileExists` probes × N, each of which is its own
/// SSH command (audit A1-M3).
///
/// ## The parity contract
///
/// This must produce **exactly** what `BotsService.rosterEntriesPerFile()`
/// produces, including its degradations, because the fallback silently swaps
/// one for the other:
///
/// - roster order is `default` first, then valid named ids sorted — the
///   ordering is applied in Swift on both paths, from the same
///   `HermesProfileScope.isValidName` filter, so the shell's glob order and
///   locale collation never reach it;
/// - only directories count (`[ -d ]` follows symlinks, matching
///   `transport.stat(...)?.isDirectory`);
/// - a `profile.yaml` that is absent, larger than `maxProfileYAMLBytes`, or
///   not valid UTF-8 yields the same empty identity as a missing one, matching
///   `readBoundedText` returning nil — and `PRESENT`/`ABSENT` is carried as an
///   explicit flag so an empty-but-present file is never confused with either;
/// - a malformed `profile.yaml` still yields a row (Hermes' own
///   `read_profile_meta` swallows every exception so one bad file cannot empty
///   `hermes profile list`; `HermesBotProfileYAML.parse` does the same).
///
/// ## Refusing rather than degrading
///
/// Every failure mode here ends in `nil` from ``parse(_:rootHome:)`` — no
/// `base64` on the host, a truncated stream, a non-zero exit — and `nil` means
/// the caller runs the per-file path. That matters: quietly reporting "no
/// `profile.yaml`" for a profile that has one would render a configured bot as
/// an unmanaged profile, which is worse than being slow. The `OK` sentinel is
/// what makes truncation detectable at all.
public enum BotsRosterScan {

    /// Field separator. A tab cannot appear in a valid profile id
    /// (`^[a-z0-9][a-z0-9_-]{0,63}$`) and never appears in base64.
    private static let separator = "\t"

    // MARK: - Script

    /// POSIX single-quote, with a `~/` prefix left live so it still expands.
    ///
    /// `'\''` is the only way to get a quote inside a single-quoted word in
    /// `sh`; everything else — `$`, backtick, newline, `;` — is inert inside
    /// one, which is the whole reason this quotes rather than escapes.
    static func quote(_ path: String) -> String {
        func singleQuoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"" + singleQuoted(String(path.dropFirst(1)))
        }
        return singleQuoted(path)
    }

    /// The scan script for one root home.
    public static func script(rootHome: String, maxYAMLBytes: Int) -> String {
        let root = quote(rootHome)
        let extensions = HermesBotAvatar.probeOrder.map { $0.ext }.joined(separator: " ")
        return """
        ROOT=\(root)
        MAX=\(maxYAMLBytes)
        if command -v base64 >/dev/null 2>&1; then
          b64() { base64 < "$1" 2>/dev/null | tr -d '\\n'; }
        elif command -v openssl >/dev/null 2>&1; then
          b64() { openssl base64 < "$1" 2>/dev/null | tr -d '\\n'; }
        else
          printf 'E\\tno-base64\\n'
          exit 0
        fi
        statline() {
          stat -c '%s %Y' "$1" 2>/dev/null || stat -f '%z %m' "$1" 2>/dev/null
        }
        emit() {
          d="$1"
          n="$2"
          f="$d/profile.yaml"
          if [ -f "$f" ]; then
            sz=`wc -c < "$f" 2>/dev/null | tr -d ' '`
            if [ -n "$sz" ] && [ "$sz" -le "$MAX" ] 2>/dev/null; then
              printf 'Y\\t%s\\t1\\t' "$n"
              b64 "$f"
              printf '\\n'
            else
              printf 'Y\\t%s\\t0\\t\\n' "$n"
            fi
          else
            printf 'Y\\t%s\\t0\\t\\n' "$n"
          fi
          for e in \(extensions); do
            a="$d/assets/avatar.$e"
            if [ -f "$a" ]; then
              # A host whose `stat` answers neither form still reports the
              # avatar — with a degenerate `0 0` cache key. Dropping the line
              # instead would make the batched path find no avatar where the
              # per-file path finds one, which is exactly the divergence this
              # scan is not allowed to have.
              s=`statline "$a"`
              [ -n "$s" ] || s='0 0'
              # `d`/`n` were captured into variables at the top of `emit`, so
              # clobbering the positional parameters here is safe — it is the
              # portable way to split "<size> <mtime>" into two fields.
              set -- $s
              printf 'A\\t%s\\t%s\\t%s\\t%s\\n' "$n" "$e" "${1:-0}" "${2:-0}"
              break
            fi
          done
        }
        emit "$ROOT" default
        if [ -d "$ROOT/profiles" ]; then
          for d in "$ROOT"/profiles/*; do
            [ -d "$d" ] || continue
            emit "$d" "`basename "$d"`"
          done
        fi
        printf 'OK\\n'
        """
    }

    // MARK: - Parsing

    /// Turn the script's stdout into roster entries, or `nil` when the output
    /// is not a complete, trustworthy scan.
    ///
    /// - Parameter rootHome: the *root* home the script was built from; every
    ///   returned path is derived from it exactly as `BotsService` derives it,
    ///   never from anything the remote printed.
    public static func parse(_ stdout: String, rootHome: String) -> [BotRosterEntry]? {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.contains("OK") else { return nil }
        if lines.contains(where: { $0.hasPrefix("E" + separator) }) { return nil }

        struct Partial {
            var yaml: String?
            var avatar: BotAvatarStat?
        }
        var partials: [String: Partial] = [:]
        var order: [String] = []

        for line in lines {
            let fields = line.components(separatedBy: separator)
            guard let marker = fields.first else { continue }
            switch marker {
            case "Y":
                guard fields.count >= 4 else { continue }
                let name = fields[1]
                guard isAddressable(name) else { continue }
                if partials[name] == nil {
                    partials[name] = Partial()
                    order.append(name)
                }
                guard fields[2] == "1" else { continue }
                // Absent / oversized already decided by the shell; a decode
                // failure here degrades to the same "no metadata" the
                // per-file path produces for a non-UTF-8 file.
                if let data = Data(base64Encoded: fields[3]),
                   let text = String(data: data, encoding: .utf8) {
                    partials[name]?.yaml = text
                }
            case "A":
                guard fields.count >= 5, let existing = partials[fields[1]] else { continue }
                let name = fields[1]
                let ext = fields[2]
                guard let mime = HermesBotAvatar.probeOrder.first(where: { $0.ext == ext })?.mime,
                      let size = Int64(fields[3]),
                      let mtime = Int64(fields[4]) else { continue }
                var updated = existing
                updated.avatar = BotAvatarStat(
                    path: profileDirectory(name, rootHome: rootHome) + "/assets/avatar." + ext,
                    mime: mime,
                    size: size,
                    mtime: mtime
                )
                partials[name] = updated
            default:
                continue
            }
        }

        // `default` first, then named ids sorted — computed here rather than
        // trusted from the wire, so both scan paths order identically.
        guard partials[HermesProfileScope.defaultProfileName] != nil else { return nil }
        let named = order
            .filter { $0 != HermesProfileScope.defaultProfileName }
            .sorted()
        return ([HermesProfileScope.defaultProfileName] + named).compactMap { name in
            guard let partial = partials[name] else { return nil }
            let dir = profileDirectory(name, rootHome: rootHome)
            let identity: HermesBotIdentity
            if let yaml = partial.yaml {
                identity = HermesBotProfileYAML.parse(yaml, profileName: name, profileDirectory: dir)
            } else {
                identity = HermesBotIdentity(profileName: name, profileDirectory: dir)
            }
            return BotRosterEntry(identity: identity, avatar: partial.avatar)
        }
    }

    private static func isAddressable(_ name: String) -> Bool {
        name == HermesProfileScope.defaultProfileName || HermesProfileScope.isValidName(name)
    }

    private static func profileDirectory(_ name: String, rootHome: String) -> String {
        HermesProfileScope.resolveHome(baseHome: rootHome, profile: name)
    }
}
