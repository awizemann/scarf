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
/// shebang is `#!/bin/sh`). Nothing else is guessed. On failure the fragment
/// prints `<errorMarker> …` to stderr and `exit 3`s.
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
