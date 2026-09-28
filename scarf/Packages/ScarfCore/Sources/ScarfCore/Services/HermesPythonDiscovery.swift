import Foundation

/// The shell fragment that finds the Python interpreter running a server's
/// `hermes` binary, for scripts that import Hermes modules on the host
/// (Hermes Voice TTS in ``HermesSpeechService``, Live Voice's session
/// exchange in ``VoiceLiveHostExchange``).
///
/// Extracted verbatim from `HermesSpeechService.synthesisScript` (P2) so both
/// services share one discovery; the speech script is byte-identical to what
/// it was before the extraction (pinned by `HermesPythonDiscoveryTests`).
///
/// Discovery: the window's resolved `hermes` binary (a bare name is looked up
/// on `PATH`) → `readlink -f` → the binary's own shebang interpreter when it
/// names a python (pip/uv console scripts), else `python` / `python3` beside
/// the symlink-resolved binary (the git/uv/pipx venv layout, where the
/// shebang is `#!/bin/sh`). When the shebang isn't a python, the script's
/// first `exec <absolute path>` line is read next: the official `install.sh`
/// launcher (`#!/usr/bin/env bash` … `exec "$INSTALL_DIR/venv/bin/python"
/// "$INSTALL_DIR/hermes"`, scripts/install.sh:2156-2171 @ v2026.9.24) names
/// the venv python directly, and a hand-written shim that execs a venv's
/// `hermes` console script is followed one level (that script's python
/// shebang, else the python beside it). Exec targets holding `$` or a
/// relative path are skipped, never expanded. This runs before the sibling
/// search so a stray `python3` beside the launcher (e.g. from
/// `uv python install` into `~/.local/bin`) can't win over the real one.
/// Nothing else is guessed. On failure the fragment prints
/// `<errorMarker> …` to stderr and `exit 3`s.
///
/// On success the shell variable `$py` holds the interpreter and `$real` the
/// resolved binary. The caller must have exported
/// `HermesConfigReader.pathPrelude` first.
enum HermesPythonDiscovery {
    static func shellLines(hermesBinary: String, errorMarker: String) -> String {
        """
        hb=\(HermesProfileScope.shellQuotePath(hermesBinary))
        case "$hb" in
          */*) ;;
          *) hb=$(command -v -- "$hb" 2>/dev/null) || hb="" ;;
        esac
        if [ -z "$hb" ] || [ ! -f "$hb" ]; then
          echo "\(errorMarker) hermes binary not found" >&2
          exit 3
        fi
        real=$(readlink -f -- "$hb" 2>/dev/null) || real=""
        [ -n "$real" ] || real="$hb"
        py=""
        first=""
        IFS= read -r first < "$real" 2>/dev/null || true
        case "$first" in
          '#!'*)
            cand=${first#??}
            cand=${cand# }
            cand=${cand%% *}
            case "${cand##*/}" in
              python*) if [ -x "$cand" ]; then py="$cand"; fi ;;
            esac ;;
        esac
        if [ -z "$py" ]; then
          case "$first" in
            '#!'*)
              dq='"'
              sq="'"
              ex=$(sed -n 's/^[[:space:]]*exec[[:space:]][[:space:]]*//p' "$real" 2>/dev/null | head -n 1)
              case "$ex" in
                "$dq"*) tgt=${ex#?}; tgt=${tgt%%"$dq"*} ;;
                "$sq"*) tgt=${ex#?}; tgt=${tgt%%"$sq"*} ;;
                *) tgt=${ex%% *} ;;
              esac
              case "$tgt" in
                *'$'*) tgt="" ;;
                /*) ;;
                *) tgt="" ;;
              esac
              if [ -n "$tgt" ] && [ -f "$tgt" ]; then
                case "${tgt##*/}" in
                  python*) if [ -x "$tgt" ]; then py="$tgt"; fi ;;
                  *)
                    t2=$(readlink -f -- "$tgt" 2>/dev/null) || t2=""
                    [ -n "$t2" ] || t2="$tgt"
                    if [ "$t2" != "$real" ]; then
                      f2=""
                      IFS= read -r f2 < "$t2" 2>/dev/null || true
                      case "$f2" in
                        '#!'*)
                          c2=${f2#??}
                          c2=${c2# }
                          c2=${c2%% *}
                          case "${c2##*/}" in
                            python*) if [ -x "$c2" ]; then py="$c2"; fi ;;
                          esac ;;
                      esac
                      if [ -z "$py" ]; then
                        d2=$(dirname -- "$t2")
                        for c in "$d2/python" "$d2/python3"; do
                          if [ -x "$c" ]; then py="$c"; break; fi
                        done
                      fi
                    fi ;;
                esac
              fi ;;
          esac
        fi
        if [ -z "$py" ]; then
          pyd=$(dirname -- "$real")
          for c in "$pyd/python" "$pyd/python3"; do
            if [ -x "$c" ]; then py="$c"; break; fi
          done
        fi
        if [ -z "$py" ]; then
          echo "\(errorMarker) no Python interpreter found for $real" >&2
          exit 3
        fi
        """
    }
}
