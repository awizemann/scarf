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

    @Test func liveExchangeScriptEmbedsTheSameFragment() {
        let script = VoiceLiveHostExchange.script(
            hermesBinary: "/opt/hermes/bin/hermes", hermesHome: "/srv/h", requestJSON: "{}")
        #expect(script.contains(HermesPythonDiscovery.shellLines(
            hermesBinary: "/opt/hermes/bin/hermes", errorMarker: VoiceLiveHostExchange.errorMarker)))
    }

    #if os(macOS)
    /// venv layout: `hermes` is a `#!/bin/sh` wrapper symlinked from
    /// `~/.local/bin`; the interpreter is the `python` beside the target.
    @Test func findsSiblingPythonThroughASymlinkedShWrapper() throws {
        let dir = try TempDir()
        let bin = dir.url.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try write(bin.appendingPathComponent("hermes"), "#!/bin/sh\nexit 0\n", executable: true)
        try write(bin.appendingPathComponent("python"), "#!/bin/sh\necho sibling\n", executable: true)
        let link = dir.url.appendingPathComponent("hermes-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("hermes"))
        let out = try runDiscovery(binary: link.path)
        #expect(out.stdout.hasSuffix("/venv/bin/python"))
        #expect(out.status == 0)
    }

    /// pip/uv console script: the shebang names the interpreter directly.
    @Test func prefersAPythonShebang() throws {
        let dir = try TempDir()
        let py = dir.url.appendingPathComponent("elsewhere/python3.12")
        try FileManager.default.createDirectory(at: py.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(py, "#!/bin/sh\n", executable: true)
        let hermes = dir.url.appendingPathComponent("hermes")
        try write(hermes, "#!\(py.path)\nimport sys\n", executable: true)
        let out = try runDiscovery(binary: hermes.path)
        #expect(out.stdout == py.path)
    }

    @Test func missingBinaryFailsWithTheCallersMarker() throws {
        let out = try runDiscovery(binary: "/nonexistent/hermes")
        #expect(out.status == 3)
        #expect(out.stderr.contains("MARK: hermes binary not found"))
    }

    // MARK: helpers

    private func runDiscovery(binary: String) throws -> (stdout: String, stderr: String, status: Int32) {
        let script = HermesPythonDiscovery.shellLines(hermesBinary: binary, errorMarker: "MARK:") + "\nprintf '%s' \"$py\"\n"
        let out = try ShellTestRunner.run(arguments: ["-c", script])
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
