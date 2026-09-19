import Foundation
import CryptoKit

/// Synthesizes speech through the server's Hermes TTS stack and returns
/// magic-byte-verified WAV audio for local playback — the engine behind
/// Settings → Voice → "Hermes Voice" message playback (WS2).
///
/// **Ladder.** Two rungs, chosen by the configured `tts.provider`:
///
///  1. **kokoro** — a dedicated stdin-JSON script executed by the kokoro
///     venv's own interpreter (`tts.kokoro.python` from config.yaml,
///     defaulting to `<hermes home>/kokoro-venv/bin/python`), mirroring
///     the hermes-s2s plugin's `_synthesize_external`: `KPipeline` →
///     `soundfile` → RIFF WAV PCM16 mono 24 kHz. This deliberately
///     bypasses the orchestrator, because standalone the kokoro PLUGIN
///     provider fails to register and `text_to_speech_tool` dispatch
///     silently falls through to edge-tts while the envelope still claims
///     provider "kokoro" — and edge writes MP3 bytes whatever the file
///     extension says (WS-research, verified against the live host).
///  2. **any other provider** — `tools.tts_tool.text_to_speech_tool`
///     inside the Hermes orchestrator's venv, with explicit `provider=`
///     and `output_path`. This covers the cloud builtins AND the
///     command-provider configs under `tts.providers.*` (e.g. a
///     `kokoro-local` command wrapping the venv's `kokoro` CLI — those
///     the orchestrator dispatches natively, honoring the provider's
///     configured `output_format`). The venv interpreter is derived from
///     the hermes binary (resolved through `readlink -f`): pipx, pinokio,
///     and plain venv installs all place `python` beside the real binary.
///
/// Both rungs synthesize into the SERVER's `$TMPDIR` (never inside
/// `~/.hermes` state dirs), fetch the bytes with `readFile`, delete the
/// server temp files, then verify locally. The envelope's provider label
/// is NEVER trusted — audio routes on magic bytes, and anything that is
/// not RIFF/WAVE (the edge-tts MP3 masquerade) surfaces as
/// `providerMismatch` so the caller can fall back to the system voice.
///
/// Every command travels through `streamScript` (one opaque shell script
/// over the transport) so it works identically for local and SSH servers;
/// user text crosses as a single-line JSON heredoc, never interpolated
/// into the shell layer.
public actor HermesSpeechService {

    public let context: ServerContext
    private let transport: any ServerTransport
    private let cache: HermesTTSCache

    /// - Parameters:
    ///   - context: the server whose Hermes stack synthesizes.
    ///   - transport: injected transport; defaults to `context.makeTransport()`.
    ///     Tests pass a mock.
    ///   - cache: injected audio cache; defaults to the shared on-disk cache.
    public init(
        context: ServerContext,
        transport: (any ServerTransport)? = nil,
        cache: HermesTTSCache? = nil
    ) {
        self.context = context
        self.transport = transport ?? context.makeTransport()
        self.cache = cache ?? HermesTTSCache()
    }

    // MARK: - Public types

    /// Distilled synthesis request — everything the scripts need, already
    /// resolved from the server's `HermesConfig` by
    /// `options(config:paths:)`. Kept as one value so tests drive the
    /// ladder without touching config I/O.
    public struct Options: Sendable, Equatable {
        /// `tts.provider` (e.g. "kokoro", "openai", "edge"). Selects the ladder rung.
        public var provider: String
        /// Per-provider fingerprint of every config key that changes the
        /// audio (voice id / language / speed / venv path). Used for cache
        /// keying only — rung 2's voice comes from the server's own config.
        public var voiceFingerprint: String
        /// Kokoro rung: `tts.kokoro.voice`.
        public var kokoroVoice: String
        /// Kokoro rung: `tts.kokoro.speed`.
        public var kokoroSpeed: Double
        /// Kokoro rung: `tts.kokoro.lang_code`.
        public var kokoroLangCode: String
        /// Kokoro rung: `tts.kokoro.python`. Empty → `<hermes home>/kokoro-venv/bin/python`.
        public var kokoroPython: String
        /// Resolved `hermes` binary — rung 2 derives the orchestrator venv
        /// python from it.
        public var hermesBinary: String
        /// Hermes home (`~/.hermes` or an SSHConfig override; a leading `~`
        /// is expanded to `$HOME` inside the script).
        public var hermesHome: String

        public init(
            provider: String,
            voiceFingerprint: String,
            kokoroVoice: String,
            kokoroSpeed: Double,
            kokoroLangCode: String,
            kokoroPython: String,
            hermesBinary: String,
            hermesHome: String
        ) {
            self.provider = provider
            self.voiceFingerprint = voiceFingerprint
            self.kokoroVoice = kokoroVoice
            self.kokoroSpeed = kokoroSpeed
            self.kokoroLangCode = kokoroLangCode
            self.kokoroPython = kokoroPython
            self.hermesBinary = hermesBinary
            self.hermesHome = hermesHome
        }
    }

    /// Verified WAV audio, one element per delivery chunk, in order.
    public struct Audio: Sendable, Equatable {
        public let chunks: [Data]
        public let fromCache: Bool

        public init(chunks: [Data], fromCache: Bool) {
            self.chunks = chunks
            self.fromCache = fromCache
        }
    }

    public enum SpeechError: Error, Equatable, Sendable {
        /// The server command failed (non-zero exit, missing marker line,
        /// or a failure envelope). Carries a bounded diagnostic tail.
        case synthesisFailed(String)
        /// Fetched audio was not RIFF/WAVE — the provider-mismatch
        /// masquerade (e.g. edge-tts MP3 under a .wav name). Callers fall
        /// back to the system voice.
        case providerMismatch(actualFormat: String)
        /// Envelope reported success but named no files.
        case emptyAudio
        /// The transport itself failed (host unreachable, timeout).
        case transportFailed(String)
    }

    /// Audio container sniffed from magic bytes. `nil` means unrecognized.
    public enum AudioFormat: String, Sendable {
        case wav, mp3, ogg, flac, aiff
    }

    // MARK: - Convenience entry point

    /// Load the server's config and synthesize. Config reads go through
    /// `HermesConfigReader`'s CLI fallback chain, so hosts where
    /// config.yaml is not where Scarf expects it still work. A missing
    /// config degrades to `HermesConfig.empty` (provider "edge").
    public func synthesize(text: String) async throws -> Audio {
        let ctx = context
        let yaml = await Task.detached(priority: .utility) {
            HermesConfigReader.readRawConfig(context: ctx)
        }.value
        let config = yaml.map { HermesConfig(yaml: $0) } ?? HermesConfig.empty
        return try await synthesize(text: text, options: Self.options(config: config, paths: context.paths))
    }

    /// Build `Options` from a parsed config + path set.
    public static func options(config: HermesConfig, paths: HermesPathSet) -> Options {
        let voice = config.voice
        let provider = voice.ttsProvider.isEmpty ? "edge" : voice.ttsProvider
        return Options(
            provider: provider,
            voiceFingerprint: voiceFingerprint(provider: provider, voice: voice),
            kokoroVoice: voice.ttsKokoroVoice,
            kokoroSpeed: voice.ttsKokoroSpeed,
            kokoroLangCode: voice.ttsKokoroLangCode,
            kokoroPython: voice.ttsKokoroPython,
            hermesBinary: paths.hermesBinary,
            hermesHome: paths.home
        )
    }

    /// Every per-provider config key that changes the synthesized audio —
    /// the cache must not serve audio from before a voice/venv change.
    /// Unknown providers key on the provider alone.
    public static func voiceFingerprint(provider: String, voice: VoiceSettings) -> String {
        switch provider {
        case "kokoro":
            return "\(voice.ttsKokoroVoice)|\(voice.ttsKokoroLangCode)|\(voice.ttsKokoroSpeed)|\(voice.ttsKokoroPython)"
        case "edge":
            return voice.ttsEdgeVoice
        case "elevenlabs":
            return "\(voice.ttsElevenLabsVoiceID)|\(voice.ttsElevenLabsModelID)"
        case "openai":
            return "\(voice.ttsOpenAIVoice)|\(voice.ttsOpenAIModel)"
        case "neutts":
            return "\(voice.ttsNeuTTSModel)|\(voice.ttsNeuTTSDevice)"
        case "xai":
            return "\(voice.ttsXAIVoiceID)|\(voice.ttsXAILanguage)|\(voice.ttsXAISpeed)"
        case "deepinfra":
            return "\(voice.ttsDeepInfraModel)|\(voice.ttsDeepInfraVoice)"
        default:
            return provider
        }
    }

    // MARK: - Synthesis

    /// Run the ladder for `options.provider`, fetch + verify the audio,
    /// and cache it. Cancellation-aware at each phase boundary.
    public func synthesize(text: String, options: Options) async throws -> Audio {
        try Task.checkCancellation()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw SpeechError.synthesisFailed("empty text")
        }

        let key = HermesTTSCache.cacheKey(
            provider: options.provider,
            voiceFingerprint: options.voiceFingerprint,
            text: cleaned
        )
        if let cached = cache.cachedAudio(for: key) {
            return Audio(chunks: cached, fromCache: true)
        }
        try Task.checkCancellation()

        let timeout: TimeInterval = options.provider == "kokoro" ? 120 : 60
        let result: ProcessResult
        do {
            let script = Self.buildScript(options: options, cacheKey: key, text: cleaned)
            result = try await transport.streamScript(script, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.transportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        guard result.exitCode == 0 else {
            throw SpeechError.synthesisFailed(Self.diagnosticTail(stdout: result.stdoutString, stderr: result.stderrString))
        }
        guard let envelope = TTSEnvelope.parse(result.stdoutString) else {
            throw SpeechError.synthesisFailed(Self.diagnosticTail(stdout: result.stdoutString, stderr: result.stderrString))
        }
        guard envelope.success, envelope.error == nil else {
            throw SpeechError.synthesisFailed(envelope.error ?? "synthesis reported failure")
        }
        let paths = envelope.filePaths.isEmpty ? [envelope.filePath].compactMap { $0 } : envelope.filePaths
        guard !paths.isEmpty else { throw SpeechError.emptyAudio }

        var chunks: [Data] = []
        chunks.reserveCapacity(paths.count)
        for path in paths {
            try Task.checkCancellation()
            do {
                chunks.append(try transport.readFile(path))
            } catch {
                throw SpeechError.transportFailed("read \(path): \(error.localizedDescription)")
            }
        }
        // Server temp files are cleaned up regardless of verification
        // outcome — they live in $TMPDIR, never in Hermes state.
        for path in paths {
            try? transport.removeFile(path)
        }

        for chunk in chunks {
            let format = Self.audioFormat(of: chunk)
            guard format == .wav else {
                throw SpeechError.providerMismatch(actualFormat: format?.rawValue ?? "unknown")
            }
        }
        cache.store(chunks: chunks, key: key)
        return Audio(chunks: chunks, fromCache: false)
    }

    // MARK: - Envelope

    /// Parsed `SCARF_TTS_ENV:` line from a synthesis script. Field names
    /// mirror `tools/tts_tool.py`'s envelope and `tools/registry.tool_error`'s
    /// `{"error": …, "success": false}` shape.
    public struct TTSEnvelope: Sendable, Equatable {
        public static let marker = "SCARF_TTS_ENV:"

        public let success: Bool
        public let filePath: String?
        public let filePaths: [String]
        public let provider: String?
        public let chunkCount: Int?
        public let error: String?

        /// Scan stdout for the last marker line and decode its JSON.
        /// `nil` when no marker is present or the JSON won't decode —
        /// either way the caller reports a synthesis failure using the
        /// raw output tail.
        public static func parse(_ stdout: String) -> TTSEnvelope? {
            guard let line = stdout.split(separator: "\n", omittingEmptySubsequences: true)
                .last(where: { $0.hasPrefix(marker) }) else { return nil }
            let json = String(line.dropFirst(marker.count))
            guard let data = json.data(using: .utf8),
                  let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
            return TTSEnvelope(
                success: dto.success ?? false,
                filePath: dto.file_path,
                filePaths: dto.file_paths ?? [],
                provider: dto.provider,
                chunkCount: dto.chunk_count,
                error: dto.error
            )
        }

        private struct DTO: Decodable {
            let success: Bool?
            let file_path: String?
            let file_paths: [String]?
            let provider: String?
            let chunk_count: Int?
            let error: String?
        }
    }

    // MARK: - Magic bytes

    /// Sniff the audio container from the first bytes. Only RIFF/WAVE is
    /// accepted for playback; the rest exist so mismatch diagnostics can
    /// name what actually came back (e.g. `.mp3` for the edge masquerade).
    /// RIFF/WAVE needs 12 bytes; every other signature needs at most 4
    /// (the MPEG frame sync just 2), so short prefixes still classify.
    public static func audioFormat(of data: Data) -> AudioFormat? {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return nil }
        func matches(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            guard offset + bytes.count <= head.count else { return false }
            return zip(offset..<offset + bytes.count, bytes).allSatisfy { head[$0] == $1 }
        }
        if head.count >= 12,
           matches(0, [0x52, 0x49, 0x46, 0x46]), matches(8, [0x57, 0x41, 0x56, 0x45]) {
            return .wav            // "RIFF" … "WAVE"
        }
        if matches(0, [0x49, 0x44, 0x33]) { return .mp3 }          // "ID3"
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return .mp3 } // MPEG frame sync
        if matches(0, [0x4F, 0x67, 0x67, 0x53]) { return .ogg }    // "OggS"
        if matches(0, [0x66, 0x4C, 0x61, 0x43]) { return .flac }   // "fLaC"
        if matches(0, [0x46, 0x4F, 0x52, 0x4D]) { return .aiff }   // "FORM"
        return nil
    }

    // MARK: - Script construction

    /// Pick the ladder rung and build its script.
    static func buildScript(options: Options, cacheKey: String, text: String) -> String {
        options.provider == "kokoro"
            ? kokoroScript(options: options, cacheKey: cacheKey, text: text)
            : orchestratorScript(options: options, cacheKey: cacheKey, text: text)
    }

    /// Rung 1 — direct kokoro-venv synthesis (see class doc). The inline
    /// python mirrors the hermes-s2s plugin's `_synthesize_external`
    /// (kokoro.py): KPipeline → pipeline(text, voice, speed) → soundfile
    /// PCM16 24 kHz WAV, with the output path arriving via `SCARF_TTS_OUT`
    /// so the shell can resolve `$TMPDIR` + uid.
    ///
    /// The interpreter is `tts.kokoro.python` verbatim when configured.
    /// When that key is absent, the script probes `<home>/kokoro-venv`
    /// first and then the ROOT home's — a profile-scoped home
    /// (`~/.hermes/profiles/<name>`) shares the venv the hermes-s2s setup
    /// created under the installation root, which is where the verified
    /// layout puts it.
    static func kokoroScript(options: Options, cacheKey: String, text: String) -> String {
        let home = expandingTilde(options.hermesHome)
        let json = payloadJSON(fields: [
            "text": text,
            "voice": options.kokoroVoice,
            "lang_code": options.kokoroLangCode,
            "speed": options.kokoroSpeed,
        ])
        let prologue: String
        if options.kokoroPython.isEmpty {
            var candidates = [home]
            let root = HermesProfileScope.rootHome(forHome: options.hermesHome)
            if root != options.hermesHome { candidates.append(root) }
            let list = candidates
                .map { expandingTilde($0) + "/kokoro-venv/bin/python" }
                .map(shellDoubleQuoted)
                .joined(separator: " ")
            prologue = """
            py=""
            for c in \(list); do
              if [ -x "$c" ]; then py="$c"; break; fi
            done
            if [ -z "$py" ]; then
              echo "SCARF_TTS_ERROR: no kokoro venv python under \(shellDoubleQuoted(home)) (set tts.kokoro.python)" >&2
              exit 3
            fi
            """
        } else {
            prologue = """
            py=\(shellDoubleQuoted(expandingTilde(options.kokoroPython)))
            if [ ! -x "$py" ]; then
              echo "SCARF_TTS_ERROR: kokoro python not executable: $py" >&2
              exit 3
            fi
            """
        }
        return """
        \(prologue)
        out="${TMPDIR:-/tmp}/scarf-tts-\(cacheKey)-$(id -u).wav"
        export HERMES_HOME=\(shellDoubleQuoted(home))
        SCARF_TTS_OUT="$out" "$py" -c '\(kokoroPythonScript)' <<'SCARF_JSON'
        \(json)
        SCARF_JSON
        rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "SCARF_TTS_ERROR: kokoro exited with status $rc" >&2
          exit 4
        fi
        """
    }

    /// Rung 2 — `text_to_speech_tool` inside the orchestrator venv, with
    /// an explicit provider + output path. The venv python is derived from
    /// the resolved hermes binary (`readlink -f`, then the `python` that
    /// sits beside it — the pipx/pinokio/venv layout); a bare `python3`
    /// fallback fails cleanly into the system-voice fallback when the
    /// import can't resolve.
    static func orchestratorScript(options: Options, cacheKey: String, text: String) -> String {
        let home = expandingTilde(options.hermesHome)
        let json = payloadJSON(fields: [
            "text": text,
            "provider": options.provider,
        ])
        return """
        export \(HermesConfigReader.pathPrelude)
        hb=\(shellDoubleQuoted(expandingTilde(options.hermesBinary)))
        case "$hb" in
          */*) ;;
          *) hb=$(command -v "$hb" 2>/dev/null || printf '%s' "$hb") ;;
        esac
        real=$(readlink -f "$hb" 2>/dev/null || printf '%s' "$hb")
        pyd=$(dirname -- "$real")
        if [ -x "$pyd/python" ]; then py="$pyd/python"; else py="python3"; fi
        out="${TMPDIR:-/tmp}/scarf-tts-\(cacheKey)-$(id -u).wav"
        export HERMES_HOME=\(shellDoubleQuoted(home))
        SCARF_TTS_OUT="$out" "$py" -c '\(orchestratorPythonScript)' <<'SCARF_JSON'
        \(json)
        SCARF_JSON
        rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "SCARF_TTS_ERROR: tts_tool exited with status $rc" >&2
          exit 4
        fi
        """
    }

    /// The kokoro synth body — double quotes only, so it can sit inside
    /// single quotes in the shell layer unchanged.
    static let kokoroPythonScript = #"""
    import json, os, sys
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline
    payload = json.load(sys.stdin)
    pipeline = KPipeline(lang_code=payload["lang_code"])
    chunks = []
    for _, audio in pipeline(payload["text"], voice=payload["voice"], speed=payload["speed"]):
        if audio is None:
            continue
        if hasattr(audio, "detach"):
            audio = audio.detach().cpu().numpy()
        chunks.append(np.asarray(audio, dtype=np.float32))
    if not chunks:
        raise RuntimeError("Kokoro produced no audio")
    out = os.environ["SCARF_TTS_OUT"]
    sf.write(out, np.concatenate(chunks, axis=0), 24000)
    print("SCARF_TTS_ENV:" + json.dumps({"success": True, "file_path": out, "file_paths": [out], "provider": "kokoro", "chunk_count": 1}))
    """#

    /// The orchestrator wrapper — prints the tool's own JSON envelope
    /// behind the marker so stray CLI logging can't corrupt the parse.
    static let orchestratorPythonScript = #"""
    import json, os, sys
    from tools.tts_tool import text_to_speech_tool
    payload = json.load(sys.stdin)
    env = text_to_speech_tool(payload["text"], output_path=os.environ["SCARF_TTS_OUT"], provider=payload["provider"])
    sys.stdout.write("SCARF_TTS_ENV:" + env + "\n")
    """#

    /// Single-line JSON for the script's heredoc. The body is literal
    /// (quoted delimiter), so no shell metacharacter in the text can
    /// escape the JSON layer.
    private static func payloadJSON(fields: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            // Only reachable if a config value were non-serializable —
            // every value here is a String/Double. Degrade to an empty
            // payload; the server rejects it with a clear envelope error
            // instead of the client guessing.
            return "{}"
        }
        return json
    }

    // MARK: - Shell helpers

    /// Expand a leading `~` to the literal `$HOME` for shell evaluation —
    /// remote homes arrive unexpanded (`~/.hermes`) by convention.
    static func expandingTilde(_ path: String) -> String {
        if path == "~" { return "$HOME" }
        if path.hasPrefix("~/") { return "$HOME" + path.dropFirst() }
        return path
    }

    /// Single-quote a value for the shell. Used for strings that must not
    /// expand anything.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quote a value that may deliberately contain `$HOME` (from
    /// `expandingTilde`). Embedded double quotes are escaped; real-world
    /// Hermes paths don't carry them.
    static func shellDoubleQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Bounded diagnostic tail from a failed synthesis: the last meaningful
    /// stderr lines (Python tracebacks put the real error last), falling
    /// back to stdout, falling back to a generic label.
    static func diagnosticTail(stdout: String, stderr: String) -> String {
        let source = lastNonEmptyLines(stderr, count: 3)
            ?? lastNonEmptyLines(stdout, count: 3)
            ?? ["no output"]
        return source.joined(separator: "\n").prefix(300).description
    }

    private static func lastNonEmptyLines(_ text: String, count: Int) -> [String]? {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let tail = lines.count > count ? Array(lines[(lines.count - count)...]) : lines
        return tail.map { String($0) }
    }
}
