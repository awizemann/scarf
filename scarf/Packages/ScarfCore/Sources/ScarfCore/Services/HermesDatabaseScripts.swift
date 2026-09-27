import Foundation

/// The host-side bash that Manage Servers → Back Up / Restore run against a
/// Hermes home's SQLite databases. Kept in one place because backup and
/// restore must agree on which files are databases, on the directories
/// Scarf stages them in, and on what counts as "held open".
///
/// Every script here runs under `bash -lc` (local or over SSH), so it may
/// use bash arrays and `read -d ''`, but only POSIX-ish tools that GNU,
/// BSD and busybox userlands all ship: `find` (with `-print0`, `-prune`,
/// `-mmin`), `readlink`, `sed`, `sort`, `lsof` where present.
enum HermesDatabaseScripts {

    /// Prefix of the directory a backup writes its snapshots into, inside
    /// the Hermes home: the same filesystem as the databases, and a
    /// directory the Hermes user can always write. `/tmp` is often a small
    /// tmpfs that a multi-GB state.db won't fit in.
    static let snapshotDirPrefix = ".scarf-backup-snapshot-"

    /// Prefix of the directory a restore stages database snapshots in,
    /// inside the target Hermes home, before renaming them into place.
    static let stagingDirPrefix = ".scarf-restore-staging-"

    /// How long a Scarf staging directory must have been untouched (it and
    /// everything in it) before a later run treats it as left behind by a
    /// killed run and removes it. Well above the longest single step that
    /// writes into one (the 15-minute snapshot ceiling), so a run still in
    /// progress in another Scarf window is never swept.
    static let leftoverAgeMinutes = 60

    /// Single-quote for bash.
    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Leftovers

    /// Remove Scarf's own snapshot / staging directories directly inside
    /// `home` that a killed run left behind. Only Scarf-named directories,
    /// and only when neither the directory nor anything in it changed in
    /// the last ``leftoverAgeMinutes``.
    static func leftoverCleanup(home: String) -> String {
        """
        for scarf_left in \(q(home))/\(snapshotDirPrefix)* \(q(home))/\(stagingDirPrefix)*; do
          [ -d "$scarf_left" ] || continue
          [ -z "$(find "$scarf_left" -mmin -\(leftoverAgeMinutes) -print 2>/dev/null | head -n 1)" ] && rm -rf "$scarf_left"
        done
        """
    }

    // MARK: - Snapshot

    /// A bash function `scarf_snap SRC DEST` that writes a consistent copy of
    /// the SQLite database SRC to DEST without any way to write SRC, and
    /// prints the method used. Tried in order, first success wins:
    ///
    /// 1. `sqlite3 -readonly … VACUUM INTO` (SQLite 3.27+): one read
    ///    transaction, so a busy writer can't make it start over.
    /// 2. `sqlite3 -readonly … .backup`, for an older sqlite3.
    /// 3. The same `.backup` on a READWRITE connection with
    ///    `PRAGMA query_only=1` and `.dbconfig no_ckpt_on_close on`, for a
    ///    sqlite3 that can't open a WAL database read-only once its `-wal`
    ///    and `-shm` are gone (a stopped Hermes; Apple's `/usr/bin/sqlite3`
    ///    is one). Only when the CLI proved on `:memory:` that it honours
    ///    `no_ckpt_on_close`, exactly as `RemoteSQLiteBackend`'s relaxed
    ///    reads do: a writable connection that is the last to close would
    ///    otherwise checkpoint the WAL into the database (charter C3).
    /// 4. `python3`'s `sqlite3.Connection.backup()` from a `mode=ro` URI.
    ///    Not on macOS, where `/usr/bin/python3` can be the Command Line
    ///    Tools installer stub.
    static let snapshotFunction: String = {
        let python = [
            "import sqlite3,sys,urllib.request as u",
            "s=sqlite3.connect('file:'+u.pathname2url(sys.argv[1])+'?mode=ro',uri=True,timeout=10)",
            "d=sqlite3.connect(sys.argv[2])",
            "s.backup(d)",
            "d.close()",
            "s.close()",
        ].joined(separator: "\n")
        return """
        scarf_ckpt_guard=0
        if command -v sqlite3 >/dev/null 2>&1; then
          case "$(sqlite3 :memory: '.dbconfig no_ckpt_on_close on' 2>/dev/null)" in *'no_ckpt_on_close on'*) scarf_ckpt_guard=1 ;; esac
        fi
        scarf_snap() {
          scarf_src=$1; scarf_dest=$2; scarf_err=""
          scarf_sql=${scarf_dest//\\'/\\'\\'}
          scarf_dot=${scarf_dest//\\\\/\\\\\\\\}; scarf_dot=${scarf_dot//\\"/\\\\\\"}
          if command -v sqlite3 >/dev/null 2>&1; then
            if scarf_err=$(sqlite3 -readonly -cmd '.timeout 10000' "$scarf_src" "VACUUM INTO '$scarf_sql'" 2>&1 >/dev/null); then echo sqlite3; return 0; fi
            rm -f "$scarf_dest"
            if scarf_err=$(sqlite3 -readonly -cmd '.timeout 10000' "$scarf_src" ".backup \\"$scarf_dot\\"" 2>&1 >/dev/null); then echo sqlite3; return 0; fi
            rm -f "$scarf_dest"
            if [ "$scarf_ckpt_guard" = 1 ] && scarf_err=$(sqlite3 -cmd '.output /dev/null' -cmd '.dbconfig no_ckpt_on_close on' -cmd '.output stdout' -cmd 'PRAGMA query_only=1' -cmd '.timeout 10000' "$scarf_src" ".backup \\"$scarf_dot\\"" 2>&1 >/dev/null); then echo sqlite3-query-only; return 0; fi
            rm -f "$scarf_dest"
          fi
          if [ "$(uname -s 2>/dev/null)" != Darwin ] && command -v python3 >/dev/null 2>&1 && scarf_err=$(python3 -c \(q(python)) "$scarf_src" "$scarf_dest" 2>&1 >/dev/null); then echo python3; return 0; fi
          rm -f "$scarf_dest"
          printf '%s: %s\\n' "$scarf_src" "${scarf_err:-no sqlite3 or python3 could read it}" >&2
          return 1
        }
        """
    }()

    /// Snapshot every `*.db` regular file under `home` into the same
    /// relative path under `snapshotDir`, skipping Scarf's own directories
    /// and the subtrees the backup excludes (`prunedDirs`, relative to the
    /// home). Hermes's own backup snapshots every `*.db` the same way
    /// (`hermes_cli/backup.py:590-610` @ v2026.9.24).
    ///
    /// Output, one line each: `SCARF_DB_OK<TAB>method<TAB>relpath`,
    /// `SCARF_DB_FAIL<TAB>relpath`, then `SCARF_SNAPSHOT_DONE`.
    static func snapshotAll(home: String, snapshotDir: String, prunedDirs: [String]) -> String {
        var prunes = ["-path './\(snapshotDirPrefix)*'", "-path './\(stagingDirPrefix)*'"]
        prunes += prunedDirs.map { "-path \(q("./" + $0))" }
        return """
        \(leftoverCleanup(home: home))
        cd \(q(home)) || exit 1
        scarf_out=\(q(snapshotDir))
        mkdir -p "$scarf_out" || exit 1
        \(snapshotFunction)
        while IFS= read -r -d '' scarf_f; do
          scarf_rel=${scarf_f#./}
          case "$scarf_rel" in *$'\\n'*|*$'\\t'*) continue ;; esac
          mkdir -p "$scarf_out/$(dirname "$scarf_rel")" || { printf 'SCARF_DB_FAIL\\t%s\\n' "$scarf_rel"; continue; }
          if scarf_m=$(scarf_snap "$scarf_f" "$scarf_out/$scarf_rel"); then
            printf 'SCARF_DB_OK\\t%s\\t%s\\n' "$scarf_m" "$scarf_rel"
          else
            printf 'SCARF_DB_FAIL\\t%s\\n' "$scarf_rel"
          fi
        done < <(find . \\( \(prunes.joined(separator: " -o ")) \\) -prune -o -type f -name '*.db' -print0)
        echo SCARF_SNAPSHOT_DONE
        """
    }

    struct SnapshotReport: Equatable {
        var ok: [(path: String, method: String)]
        var failed: [String]
        var finished: Bool

        static func == (a: SnapshotReport, b: SnapshotReport) -> Bool {
            a.ok.map(\.path) == b.ok.map(\.path) && a.ok.map(\.method) == b.ok.map(\.method)
                && a.failed == b.failed && a.finished == b.finished
        }
    }

    static func parseSnapshotReport(_ stdout: String) -> SnapshotReport {
        var report = SnapshotReport(ok: [], failed: [], finished: false)
        for line in stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "SCARF_DB_OK" where fields.count == 3: report.ok.append((fields[2], fields[1]))
            case "SCARF_DB_FAIL" where fields.count == 2: report.failed.append(fields[1])
            case "SCARF_SNAPSHOT_DONE": report.finished = true
            default: break
            }
        }
        return report
    }

    // MARK: - Holders

    /// A bash snippet that sets `holders` to the PIDs of the processes
    /// (other than `ownPID`) holding any of `databases` (absolute paths) or
    /// their `-wal`/`-shm` open, or to `UNKNOWN` when the host offers no way
    /// to tell.
    ///
    /// Linux: every `/proc/<pid>/fd` link, compared by its target and never
    /// by parsing `ls` output (a login profile's `QUOTING_STYLE` or a name
    /// containing ` -> ` would otherwise hide a holder). `find -lname` does
    /// it in one process where `find` supports it, else `readlink` per link.
    /// An already-unlinked `(deleted)` target still counts as held, the
    /// split-brain fingerprint Hermes checks for
    /// (`hermes_cli/backup.py:469-506` @ v2026.9.24). Each database's
    /// directory is resolved with `pwd -P` first because `/proc` links name
    /// real paths. Elsewhere (the Mac's own local server): `lsof -t` on the
    /// files that exist. Other users' processes are invisible without root,
    /// exactly as they are to Hermes's own check.
    ///
    /// `procRoot` and `forceReadlink` exist for the tests, which build a
    /// fake `/proc` of symlinks on a Mac.
    static func holderScan(
        databases: [String],
        ownPID: Int32?,
        procRoot: String? = nil,
        forceReadlink: Bool = false
    ) -> String {
        let useProc = procRoot == nil
            ? "[ \"$(uname -s 2>/dev/null)\" = Linux ] && [ -d /proc/self/fd ]"
            : "true"
        return """
        scarf_dbs=(\(databases.map(q).joined(separator: " ")))
        scarf_own=\(ownPID.map(String.init) ?? "")
        scarf_proc=\(q(procRoot ?? "/proc"))
        holders=""
        scarf_found=""
        scarf_targets=()
        for scarf_d in "${scarf_dbs[@]}"; do
          scarf_dir=$(dirname "$scarf_d"); scarf_base=$(basename "$scarf_d")
          if [ -d "$scarf_dir" ]; then scarf_dir=$(cd "$scarf_dir" && pwd -P); fi
          scarf_targets+=("$scarf_dir/$scarf_base" "$scarf_dir/$scarf_base-wal" "$scarf_dir/$scarf_base-shm")
        done
        if \(useProc); then
          if [ \(forceReadlink ? "0" : "1") = 1 ] && find / -maxdepth 0 -lname scarf-probe >/dev/null 2>&1; then
            scarf_pat=()
            for scarf_t in "${scarf_targets[@]}"; do
              scarf_e=$(printf '%s' "$scarf_t" | sed 's/[][*?\\\\]/\\\\&/g')
              [ ${#scarf_pat[@]} -gt 0 ] && scarf_pat+=(-o)
              scarf_pat+=(-lname "$scarf_e" -o -lname "$scarf_e (deleted)")
            done
            scarf_found=$(find "$scarf_proc"/[0-9]*/fd -mindepth 1 -maxdepth 1 \\( "${scarf_pat[@]}" \\) -print 2>/dev/null | sed -n 's#^.*/\\([0-9][0-9]*\\)/fd/[^/]*$#\\1#p' | sort -u)
          else
            for scarf_l in "$scarf_proc"/[0-9]*/fd/*; do
              scarf_t=$(readlink "$scarf_l" 2>/dev/null) || continue
              scarf_t=${scarf_t% (deleted)}
              for scarf_x in "${scarf_targets[@]}"; do
                if [ "$scarf_t" = "$scarf_x" ]; then scarf_p=${scarf_l%/fd/*}; scarf_found="$scarf_found ${scarf_p##*/}"; break; fi
              done
            done
          fi
        elif command -v lsof >/dev/null 2>&1 || [ -x /usr/sbin/lsof ]; then
          scarf_lsof=$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)
          set --
          for scarf_t in "${scarf_targets[@]}"; do [ -e "$scarf_t" ] && set -- "$@" "$scarf_t"; done
          if [ $# -gt 0 ]; then scarf_found=$("$scarf_lsof" -t -- "$@" 2>/dev/null | sort -u); fi
        else
          holders=UNKNOWN
        fi
        if [ "$holders" != UNKNOWN ]; then
          for scarf_p in $scarf_found; do [ "$scarf_p" = "$scarf_own" ] || case " $holders " in *" $scarf_p "*) ;; *) holders="$holders $scarf_p" ;; esac; done
        fi
        """
    }
}
