import Testing
import Foundation
@testable import ScarfCore

/// The interpreter discovery shared by Hermes Voice TTS and Live Voice.
/// It was extracted from `HermesSpeechService.synthesisScript` without
/// changing a byte of that script; these tests pin both the sharing and the
/// real /bin/sh behaviour on the two install layouts Scarf supports.
@Suite struct HermesPythonDiscoveryTests {

    @Test func speechScriptEmbedsTheSharedFragmentVerbatim() {
        let options = HermesSpeechService.Options(
            provider: "edge", voiceFingerprint: "v", hermesBinary: "~/.local/bin/hermes", hermesHome: "~/.hermes")
        let script = HermesSpeechService.synthesisScript(options: options, cacheKey: "k", text: "hi")
        let fragment = HermesPythonDiscovery.shellLines(hermesBinary: "~/.local/bin/hermes", errorMarker: "SCARF_TTS_ERROR:")
        #expect(script.contains(fragment))
    }

    /// Golden: the discovery block exactly as it stood in
    /// `HermesSpeechService.synthesisScript` BEFORE the extraction (P2,
    /// commit 78d832c0), captured from its output for this input before the
    /// refactor. Pins the "byte-identical" claim non-circularly.
    @Test func fragmentMatchesThePreExtractionSpeechScript() {
        let golden = #"""
        hb="$HOME/.local/bin/hermes"
        case "$hb" in
          */*) ;;
          *) hb=$(command -v -- "$hb" 2>/dev/null) || hb="" ;;
        esac
        if [ -z "$hb" ] || [ ! -f "$hb" ]; then
          echo "SCARF_TTS_ERROR: hermes binary not found" >&2
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
          echo "SCARF_TTS_ERROR: no Python interpreter found for $real" >&2
          exit 3
        fi
        """#
        #expect(HermesPythonDiscovery.shellLines(hermesBinary: "~/.local/bin/hermes", errorMarker: "SCARF_TTS_ERROR:") == golden)
    }

    /// The whole Hermes Voice script for a fixed input, pinned: the P2
    /// script captured before this branch touched it, plus exactly ONE new
    /// line — the sys.path guard that stops a `~/tools/` on the host from
    /// shadowing Hermes's `tools` package. Any other drift fails here.
    @Test func speechScriptIsTheP2ScriptPlusOnlyTheShadowingGuard() {
        let options = HermesSpeechService.Options(
            provider: "edge", voiceFingerprint: "v", hermesBinary: "~/.local/bin/hermes", hermesHome: "/Users/x/.hermes")
        let script = HermesSpeechService.synthesisScript(options: options, cacheKey: "abc", text: "hi 'there'")
        let golden = #"""
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH"
            hb="$HOME/.local/bin/hermes"
            case "$hb" in
              */*) ;;
              *) hb=$(command -v -- "$hb" 2>/dev/null) || hb="" ;;
            esac
            if [ -z "$hb" ] || [ ! -f "$hb" ]; then
              echo "SCARF_TTS_ERROR: hermes binary not found" >&2
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
              echo "SCARF_TTS_ERROR: no Python interpreter found for $real" >&2
              exit 3
            fi
            d=${TMPDIR:-/tmp}
            d=${d%/}
            u=$(id -u)
            sd="$d/scarf-tts-$u"
            mkdir -m 700 "$sd" 2>/dev/null
            if [ -L "$sd" ] || [ ! -d "$sd" ] || [ ! -O "$sd" ]; then
              echo "SCARF_TTS_ERROR: unsafe temp directory $sd" >&2
              exit 3
            fi
            find "$sd" -type f -mmin +30 -exec rm -f {} + 2>/dev/null
            out="$sd/scarf-tts-abc.wav"
            printf 'SCARF_TTS_BASE:%s\n' "$out"
            export HERMES_HOME='/Users/x/.hermes'
            SCARF_TTS_OUT="$out" "$py" -c 'import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]
            import json, os, sys
            from tools.tts_tool import text_to_speech_tool
            payload = json.load(sys.stdin)
            env = text_to_speech_tool(payload["text"], output_path=os.environ["SCARF_TTS_OUT"])
            sys.stdout.write("SCARF_TTS_ENV:" + env + "\n")' <<'SCARF_JSON'
            {"text":"hi 'there'"}
            SCARF_JSON
            rc=$?
            if [ "$rc" -ne 0 ]; then
              echo "SCARF_TTS_ERROR: tts_tool exited with status $rc" >&2
              exit 4
            fi
            """#
        #expect(script == golden)
        #expect(HermesSpeechService.toolPythonScript.hasPrefix(
            #"import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]"# + "\n"))
        #expect(!HermesSpeechService.toolPythonScript.contains("'"))
    }

    @Test func liveExchangeScriptEmbedsTheSameFragment() {
        let script = VoiceLiveHostExchange.script(
            hermesBinary: "/opt/hermes/bin/hermes", hermesHome: "/srv/h", requestJSON: "{}")
        #expect(script.contains(HermesPythonDiscovery.shellLines(
            hermesBinary: "/opt/hermes/bin/hermes", errorMarker: VoiceLiveHostExchange.errorMarker)))
    }

    #if os(macOS)
    /// venv layout: `hermes` is a `#!/bin/sh` wrapper symlinked from
    /// `~/.local/bin`; the interpreter is the `python` beside the target.
    @Test func findsSiblingPythonThroughASymlinkedShWrapper() async throws {
        let dir = try TempDir()
        let bin = dir.url.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try write(bin.appendingPathComponent("hermes"), "#!/bin/sh\nexit 0\n", executable: true)
        try write(bin.appendingPathComponent("python"), "#!/bin/sh\necho sibling\n", executable: true)
        let link = dir.url.appendingPathComponent("hermes-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("hermes"))
        let out = try await runDiscovery(binary: link.path)
        #expect(out.stdout.hasSuffix("/venv/bin/python"))
        #expect(out.status == 0)
    }

    /// pip/uv console script: the shebang names the interpreter directly.
    @Test func prefersAPythonShebang() async throws {
        let dir = try TempDir()
        let py = dir.url.appendingPathComponent("elsewhere/python3.12")
        try FileManager.default.createDirectory(at: py.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(py, "#!/bin/sh\n", executable: true)
        let hermes = dir.url.appendingPathComponent("hermes")
        try write(hermes, "#!\(py.path)\nimport sys\n", executable: true)
        let out = try await runDiscovery(binary: hermes.path)
        #expect(out.stdout == py.path)
    }

    /// The Hermes Voice wrapper's first line drops the working directory
    /// from `sys.path`: run from a directory holding a decoy
    /// `tools/tts_tool.py`, it must still import the real one (here, the
    /// one on PYTHONPATH).
    @Test func speechWrapperIgnoresAToolsPackageInTheWorkingDirectory() async throws {
        let dir = try TempDir()
        func fakeTools(in root: URL, marker: String) throws {
            let tools = root.appendingPathComponent("tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            try Data().write(to: tools.appendingPathComponent("__init__.py"))
            try Data("def text_to_speech_tool(text, output_path=None):\n    return \"\(marker)\"\n".utf8)
                .write(to: tools.appendingPathComponent("tts_tool.py"))
        }
        let cwd = dir.url.appendingPathComponent("home")
        let legit = dir.url.appendingPathComponent("site")
        try fakeTools(in: cwd, marker: "SHADOW")
        try fakeTools(in: legit, marker: "REAL")
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = legit.path
        environment["SCARF_TTS_OUT"] = dir.url.appendingPathComponent("out.wav").path
        let out = try await ShellTestRunner.run(
            "/usr/bin/env", arguments: ["python3", "-c", HermesSpeechService.toolPythonScript],
            stdin: Data(#"{"text":"hi"}"#.utf8), environment: environment, currentDirectory: cwd)
        #expect(out.stdout == "SCARF_TTS_ENV:REAL\n", "\(out.stderr)")
    }

    @Test func missingBinaryFailsWithTheCallersMarker() async throws {
        let out = try await runDiscovery(binary: "/nonexistent/hermes")
        #expect(out.status == 3)
        #expect(out.stderr.contains("MARK: hermes binary not found"))
    }

    // MARK: helpers

    private func runDiscovery(binary: String) async throws -> (stdout: String, stderr: String, status: Int32) {
        let script = HermesPythonDiscovery.shellLines(hermesBinary: binary, errorMarker: "MARK:") + "\nprintf '%s' \"$py\"\n"
        let out = try await ShellTestRunner.run(arguments: ["-c", script])
        return (out.stdout, out.stderr, out.status)
    }

    private func write(_ url: URL, _ text: String, executable: Bool) throws {
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private final class TempDir {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-pydisc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }
    #endif
}
