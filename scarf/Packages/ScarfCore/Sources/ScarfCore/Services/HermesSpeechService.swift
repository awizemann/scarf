import Foundation
import CryptoKit

/// Synthesizes speech through ONE server's Hermes TTS stack and returns
/// magic-byte-verified WAV audio for local playback — the engine behind
/// Settings → Voice → "Hermes Voice" message playback (WS2).
///
/// **One path, Hermes's own.** The script imports
/// `tools.tts_tool.text_to_speech_tool` inside the interpreter that runs
/// the server's `hermes` binary and calls it with an explicit
/// `output_path`. Hermes resolves the provider from the server's own
/// `tts.*` config (so `nous` → OpenAI, command providers under
/// `tts.providers.*`, and plugin providers all dispatch exactly as they
/// do for the agent), writes the audio, and returns its JSON envelope.
/// Gated on `HermesCapabilities.hasHermesSpeechSynthesis` (v0.20.1+) by
/// the caller — below that the tool has no `file_paths` envelope and the
/// long-form chunk naming this service validates against doesn't exist.
///
/// **Interpreter discovery** reuses Scarf's hermes resolution: the
/// window's `paths.hermesBinary` under `HermesConfigReader.pathPrelude`.
/// The interpreter is the binary's own shebang (pip/uv console scripts
/// name their venv's python there), falling back to the `python` beside
/// the symlink-resolved binary. Nothing else is guessed — a wrapper
/// `hermes` (e.g. `docker compose exec`) fails cleanly into the caller's
/// system-voice fallback.
///
/// **Server temp files.** The script writes into a private per-user
/// directory under the SERVER's `$TMPDIR` — `scarf-tts-<uid>/`, created
/// `0700` and refused if it is a symlink or owned by anyone else (a shared
/// `/tmp` must not let another user pre-plant it) — as
/// `scarf-tts-<cacheKey>.wav`, and announces that base on a
/// `SCARF_TTS_BASE:` line before Hermes runs. Leftovers from abandoned
/// runs (a stop mid-synthesis kills the transport, not the remote tool)
/// are swept from that directory after 30 minutes. Only paths Hermes
/// derives from that base (`<stem>.<ext>`, `<stem>.chunkNNN.<ext>`,
/// `<stem>.partNN.<ext>`, in the base's own directory) are read or
/// deleted; anything else in the envelope aborts the synthesis untouched.
/// Neither the envelope's provider label nor any file extension is
/// trusted — audio routes on magic bytes. Hermes's default `edge` provider
/// writes MP3 whatever the requested extension
/// (`_generate_edge_tts` → `Communicate.save`,
/// `tools/tts_tool_providers.py:196-204` @ v2026.9.14), and OpenAI-style
/// providers pick their format from it (`_tts_response_format_from_path`,
/// `:72-75`), so WAV, MP3, FLAC and AIFF — everything `AVAudioFile` decodes
/// on macOS — are accepted; anything else (Ogg/Opus, unknown) surfaces as
/// `providerMismatch` so the caller can fall back to the system voice.
///
/// Every command travels through `streamScript` (one opaque shell script
/// over the transport) so it works identically for local and SSH servers.
/// User text crosses as a single-line JSON heredoc with a quoted
/// delimiter, and config-derived paths are single-quoted — nothing from
/// either is ever evaluated by the shell.
public actor HermesSpeechService {

    public let context: ServerContext
    private let transport: any ServerTransport
    private let cache: HermesTTSCache

    /// Upper bound on one synthesis round trip. Matches Hermes's own
    /// `DEFAULT_COMMAND_TTS_TIMEOUT_SECONDS` (120,
    /// `tools/tts_command_provider.py:273` @ v2026.9.14): a slow local
    /// command provider must be able to finish, and the caller's stop
    /// control cancels (and kills) the round trip long before this.
    static let synthesisTimeout: TimeInterval = 120

    /// - Parameters:
    ///   - context: the server whose Hermes stack synthesizes. Message text
    ///     is only ever sent to THIS server.
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

    /// Distilled synthesis request — everything the script needs, already
    /// resolved from the server's `HermesConfig` by
    /// `options(config:paths:)`. Kept as one value so tests drive the
    /// service without touching config I/O.
    public struct Options: Sendable, Equatable {
        /// `tts.provider` (empty → Hermes's default "edge"). Cache keying
        /// only: Hermes resolves the provider from its own config, so the
        /// script never passes it.
        public var provider: String
        /// Per-provider fingerprint of every config key that changes the
        /// audio (voice id / model / language / speed). Cache keying only.
        public var voiceFingerprint: String
        /// Resolved `hermes` binary — the script derives the interpreter
        /// from it.
        public var hermesBinary: String
        /// Hermes home (`~/.hermes`, a profile home, or an SSHConfig
        /// override). Exported as `HERMES_HOME` so the tool reads this
        /// window's profile config.
        public var hermesHome: String

        public init(
            provider: String,
            voiceFingerprint: String,
            hermesBinary: String,
            hermesHome: String
        ) {
            self.provider = provider
            self.voiceFingerprint = voiceFingerprint
            self.hermesBinary = hermesBinary
            self.hermesHome = hermesHome
        }
    }

    /// Verified audio, one element per delivery chunk, in order, all of
    /// one playable container `format`.
    public struct Audio: Sendable, Equatable {
        public let chunks: [Data]
        public let format: AudioFormat
        public let fromCache: Bool

        public init(chunks: [Data], format: AudioFormat, fromCache: Bool) {
            self.chunks = chunks
            self.format = format
            self.fromCache = fromCache
        }
    }

    public enum SpeechError: Error, Equatable, Sendable {
        /// The server command failed (non-zero exit, missing marker line,
        /// or a failure envelope). Carries a bounded diagnostic tail.
        case synthesisFailed(String)
        /// Fetched audio is not a container Scarf can play (Ogg/Opus,
        /// unrecognized bytes) or the chunks disagree. Callers fall back to
        /// the system voice.
        case providerMismatch(actualFormat: String)
        /// Envelope reported success but named no files.
        case emptyAudio
        /// The envelope named a path this synthesis was never told to
        /// write (or the script never announced its output base). Nothing
        /// named by the envelope is read or deleted.
        case unexpectedOutputPath(String)
        /// The transport itself failed (host unreachable, timeout).
        case transportFailed(String)
    }

    /// Audio container sniffed from magic bytes. `nil` means unrecognized.
    public enum AudioFormat: String, Sendable {
        case wav, mp3, ogg, flac, aiff

        /// Decodable by `AVAudioFile` on macOS. Ogg/Opus is left out: the
        /// fallback to the system voice is preferable to a decode failure.
        public var isPlayable: Bool { self != .ogg }
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
        try Task.checkCancellation()
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
            hermesBinary: paths.hermesBinary,
            hermesHome: paths.home
        )
    }

    /// Every per-provider config key that changes the synthesized audio —
    /// the cache must not serve audio from before a voice change.
    ///
    /// **t-eb402e82.** The per-provider switch below only tracks the
    /// handful of keys Scarf has a typed `VoiceSettings` field for, so it
    /// stayed blind to two whole classes of edit: the GLOBAL `tts.speed`
    /// (applies under every provider, and no `VoiceSettings` field reads
    /// it), and `tts.providers.<name>.*` sub-settings for command/plugin
    /// providers — unknown providers used to key on the provider name
    /// ALONE, so editing a command provider's `command` kept serving the
    /// older cached audio for already-spoken text until the cache evicted
    /// it. `voice.ttsSectionFingerprint` — a hash of the ENTIRE parsed
    /// `tts:` section (`HermesYAML.ttsSectionFingerprint`) — is appended
    /// unconditionally so any `tts.*` edit invalidates the cache, whether
    /// or not this switch has a case for the key that changed.
    public static func voiceFingerprint(provider: String, voice: VoiceSettings) -> String {
        let perProvider: String
        switch provider {
        case "edge":
            perProvider = voice.ttsEdgeVoice
        case "elevenlabs":
            perProvider = "\(voice.ttsElevenLabsVoiceID)|\(voice.ttsElevenLabsModelID)"
        case "openai", "nous":
            // `nous` is served by the OpenAI path with the `tts.openai.*`
            // voice (`_get_provider`, `tools/tts_tool.py:140-144`).
            perProvider = "\(voice.ttsOpenAIVoice)|\(voice.ttsOpenAIModel)"
        case "neutts":
            perProvider = "\(voice.ttsNeuTTSModel)|\(voice.ttsNeuTTSDevice)"
        case "xai":
            perProvider = "\(voice.ttsXAIVoiceID)|\(voice.ttsXAILanguage)|\(voice.ttsXAISpeed)"
        case "deepinfra":
            perProvider = "\(voice.ttsDeepInfraModel)|\(voice.ttsDeepInfraVoice)"
        default:
            perProvider = provider
        }
        return "\(perProvider)|tts:\(voice.ttsSectionFingerprint)"
    }

    /// Identity of the server (and profile) that synthesizes — part of the
    /// cache key, so two servers configured alike never share audio and a
    /// profile switch never serves another profile's voice.
    static func serverIdentity(_ context: ServerContext) -> String {
        "\(context.id.uuidString)|\(context.paths.home)"
    }

    // MARK: - Synthesis

    /// Run the tool on the server, fetch + verify the audio, and cache it.
    /// Cancellation-aware at each phase boundary; cancelling the calling
    /// task also terminates the in-flight script (`SSHScriptRunner`).
    public func synthesize(text: String, options: Options) async throws -> Audio {
        try Task.checkCancellation()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw SpeechError.synthesisFailed("empty text")
        }

        let key = HermesTTSCache.cacheKey(
            server: Self.serverIdentity(context),
            provider: options.provider,
            voiceFingerprint: options.voiceFingerprint,
            text: cleaned
        )
        if let cached = cache.cachedAudio(for: key),
           let format = Self.commonPlayableFormat(of: cached) {
            return Audio(chunks: cached, format: format, fromCache: true)
        }
        try Task.checkCancellation()

        let result: ProcessResult
        do {
            let script = Self.synthesisScript(options: options, cacheKey: key, text: cleaned)
            result = try await transport.streamScript(script, timeout: Self.synthesisTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.transportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let stdout = result.stdoutString
        guard result.exitCode == 0 else {
            throw SpeechError.synthesisFailed(Self.diagnosticTail(stdout: stdout, stderr: result.stderrString))
        }
        guard let envelope = TTSEnvelope.parse(stdout) else {
            throw SpeechError.synthesisFailed(Self.diagnosticTail(stdout: stdout, stderr: result.stderrString))
        }
        guard envelope.success, envelope.error == nil else {
            throw SpeechError.synthesisFailed(envelope.error ?? "synthesis reported failure")
        }
        let named = envelope.filePaths.isEmpty ? [envelope.filePath].compactMap { $0 } : envelope.filePaths
        guard !named.isEmpty else { throw SpeechError.emptyAudio }

        // Path safety BEFORE any read or delete: every named file must be
        // one Hermes derived from the base this script announced.
        guard let base = OutputBase.parse(stdout, cacheKey: key) else {
            throw SpeechError.unexpectedOutputPath("no output base announced")
        }
        let paths = try base.validate(named)

        var chunks: [Data] = []
        chunks.reserveCapacity(paths.count)
        var readError: Error?
        for path in paths {
            if Task.isCancelled { break }
            do {
                chunks.append(try transport.readFile(path))
            } catch {
                readError = SpeechError.transportFailed("read \(path): \(error.localizedDescription)")
                break
            }
        }
        // Server temp files are cleaned up regardless of read or
        // verification outcome — they live in $TMPDIR, never in Hermes
        // state, and every path here passed validation above.
        for path in paths {
            try? transport.removeFile(path)
        }
        try Task.checkCancellation()
        if let readError { throw readError }

        guard let format = Self.commonPlayableFormat(of: chunks) else {
            let sniffed = chunks.map { Self.audioFormat(of: $0)?.rawValue ?? "unknown" }
            throw SpeechError.providerMismatch(actualFormat: Array(Set(sniffed)).sorted().joined(separator: "+"))
        }
        cache.store(chunks: chunks, key: key, format: format.rawValue)
        return Audio(chunks: chunks, format: format, fromCache: false)
    }

    // MARK: - Envelope

    /// Parsed `SCARF_TTS_ENV:` line from the synthesis script. Field names
    /// mirror `text_to_speech_tool`'s envelope (`tools/tts_tool.py:445-454`
    /// @ v2026.9.14) and `tools/registry.tool_error`'s
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

    // MARK: - Output paths

    /// The output base the script announced (`SCARF_TTS_BASE:` line,
    /// printed by the shell BEFORE Hermes runs — the first such line wins,
    /// so nothing the tool prints later can move it), and the file names
    /// Hermes may derive from it.
    ///
    /// Derivations, verified at v2026.9.14 (and unchanged in shape since
    /// the v2026.8.13 = 0.20.1 floor):
    ///  - suffix swap: `_configured_command_tts_output_path` →
    ///    `path.with_suffix(".<output_format>")`
    ///    (`tools/tts_command_provider.py:304-306`), `_convert_to_opus` →
    ///    `<stem>.ogg` and `_repair_ogg_container` → `<stem>.<container>`
    ///    (`tools/tts_tool_delivery.py:289-292`, `:310-321`), and the
    ///    delivery base `base_path.with_suffix(<encoded suffix>)`
    ///    (`tools/tts_tool.py:440`);
    ///  - long-form chunks: `<stem>.chunkNNN<suffix>` (`tools/tts_tool.py:381`);
    ///  - delivery parts: `<stem>.partNN<suffix>`
    ///    (`tools/tts_tool_delivery.py:413`).
    /// All stay in the base's directory. Hermes's own dotted scratch files
    /// (`.<stem>.delivery…`) are swept by the tool itself and never appear
    /// in the envelope.
    struct OutputBase: Equatable {
        static let marker = "SCARF_TTS_BASE:"

        /// Normalized absolute directory (no trailing slash, `//` collapsed),
        /// always ending in `/scarf-tts-<uid>`.
        let directory: String
        /// `scarf-tts-<cacheKey>`.
        let stem: String

        /// First marker line, accepted only if it names
        /// `<abs dir>/scarf-tts-<digits>/scarf-tts-<cacheKey>.wav` — the
        /// exact shape the script builds for THIS request's key.
        static func parse(_ stdout: String, cacheKey: String) -> OutputBase? {
            guard let line = stdout.split(separator: "\n", omittingEmptySubsequences: true)
                .first(where: { $0.hasPrefix(marker) }),
                  let path = normalizedAbsolutePath(String(line.dropFirst(marker.count))),
                  let slash = path.lastIndex(of: "/") else { return nil }
            let name = String(path[path.index(after: slash)...])
            let directory = slash == path.startIndex ? "" : String(path[..<slash])
            let stem = "scarf-tts-\(cacheKey)"
            guard name == stem + ".wav" else { return nil }
            let dirName = directory.split(separator: "/").last ?? ""
            let uid = dirName.dropFirst("scarf-tts-".count)
            guard dirName.hasPrefix("scarf-tts-"), !uid.isEmpty,
                  uid.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return OutputBase(directory: directory, stem: stem)
        }

        /// Normalized, de-duplicated paths in envelope order — or a throw
        /// naming the first path that isn't a derivation of this base.
        func validate(_ paths: [String]) throws -> [String] {
            var out: [String] = []
            for raw in paths {
                guard let path = Self.normalizedAbsolutePath(raw), isDerived(path) else {
                    throw SpeechError.unexpectedOutputPath(raw)
                }
                if !out.contains(path) { out.append(path) }
            }
            return out
        }

        func isDerived(_ path: String) -> Bool {
            guard let slash = path.lastIndex(of: "/") else { return false }
            let dir = slash == path.startIndex ? "" : String(path[..<slash])
            guard dir == directory else { return false }
            let name = String(path[path.index(after: slash)...])
            guard name.hasPrefix(stem + ".") else { return false }
            var rest = name.dropFirst(stem.count + 1)   // after "<stem>."
            // Optional ".chunkNNN" / ".partNN" infix.
            if let infix = Self.strip(&rest, tag: "chunk", digits: 3) ?? Self.strip(&rest, tag: "part", digits: 2) {
                guard infix else { return false }
            }
            // Extension: 1–8 ASCII alphanumerics, nothing after it.
            return (1...8).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        /// If `rest` starts with `<tag>`, consume `<tag><digits>.` and
        /// return whether it was well-formed; `nil` when `tag` is absent.
        private static func strip(_ rest: inout Substring, tag: String, digits: Int) -> Bool? {
            guard rest.hasPrefix(tag) else { return nil }
            let body = rest.dropFirst(tag.count)
            let number = body.prefix(digits)
            guard number.count == digits, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            let after = body.dropFirst(digits)
            guard after.hasPrefix(".") else { return false }
            rest = after.dropFirst()
            return true
        }

        /// Absolute path with `//` collapsed and any trailing slash
        /// dropped; `nil` for relative paths, control characters, or any
        /// `.` / `..` component (never resolved — refused).
        static func normalizedAbsolutePath(_ raw: String) -> String? {
            guard raw.hasPrefix("/"),
                  !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            let components = raw.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty,
                  !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            return "/" + components.joined(separator: "/")
        }
    }

    // MARK: - Magic bytes

    /// The one playable container every chunk shares, or `nil` when any
    /// chunk is unplayable/unrecognized or they disagree (one player-node
    /// connection format serves the whole message).
    static func commonPlayableFormat(of chunks: [Data]) -> AudioFormat? {
        let formats = Set(chunks.map { audioFormat(of: $0) })
        guard formats.count == 1, let only = formats.first, let format = only, format.isPlayable else { return nil }
        return format
    }

    /// Sniff the audio container from the first bytes. `ogg` is recognized
    /// only so mismatch diagnostics can name it.
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

    /// `text_to_speech_tool(text, output_path=…)` inside the hermes
    /// binary's own interpreter (see class doc for discovery). The shell
    /// layer only ever sees: the PATH prelude, config paths quoted by
    /// `HermesProfileScope.shellQuotePath` (Scarf's shared quoter — a
    /// leading `~` is the one deliberate `$HOME` expansion; `$(…)`,
    /// backticks, `$VAR` and quotes stay literal), the hex cache key, and
    /// a quoted-delimiter heredoc carrying the JSON text.
    static func synthesisScript(options: Options, cacheKey: String, text: String) -> String {
        let json = payloadJSON(fields: ["text": text])
        return """
        export \(HermesConfigReader.pathPrelude)
        \(HermesPythonDiscovery.shellLines(hermesBinary: options.hermesBinary, errorMarker: "SCARF_TTS_ERROR:"))
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
        out="$sd/scarf-tts-\(cacheKey).wav"
        printf '\(OutputBase.marker)%s\\n' "$out"
        export HERMES_HOME=\(HermesProfileScope.shellQuotePath(options.hermesHome))
        SCARF_TTS_OUT="$out" "$py" -c '\(toolPythonScript)' <<'SCARF_JSON'
        \(json)
        SCARF_JSON
        rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "SCARF_TTS_ERROR: tts_tool exited with status $rc" >&2
          exit 4
        fi
        """
    }

    /// The tool wrapper — prints the tool's own JSON envelope behind the
    /// marker so stray logging can't corrupt the parse. No single quotes:
    /// it sits inside single quotes in the shell layer unchanged.
    /// `provider=` is deliberately NOT passed: Hermes's `_get_provider`
    /// (`tools/tts_tool.py:140-144` @ v2026.9.14) applies its own default
    /// and the `nous` → `openai` mapping, which an explicit override
    /// bypasses (`_apply_call_overrides`, `:256-261`).
    ///
    /// The first line drops the working directory from `sys.path`: `python
    /// -c` puts it first, and over SSH that is `$HOME`, where a `~/tools/`
    /// (or `~/json.py`) would shadow Hermes's `tools` package or the stdlib.
    /// It runs before any other import. The working directory itself is
    /// left alone (unlike Live Voice's `cd /`), because a configured TTS
    /// command provider may rely on it.
    static let toolPythonScript = #"""
    import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]
    import json, os, sys
    from tools.tts_tool import text_to_speech_tool
    payload = json.load(sys.stdin)
    env = text_to_speech_tool(payload["text"], output_path=os.environ["SCARF_TTS_OUT"])
    sys.stdout.write("SCARF_TTS_ENV:" + env + "\n")
    """#

    /// Single-line JSON for the script's heredoc. The body is literal
    /// (quoted delimiter), so no shell metacharacter in the text can
    /// escape the JSON layer; a line equal to the delimiter can't occur
    /// because JSON escapes every newline.
    private static func payloadJSON(fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            // Unreachable for a [String: String]. Degrade to an empty
            // payload; the server rejects it with a clear error instead of
            // the client guessing.
            return "{}"
        }
        return json
    }

    // MARK: - Shell helpers

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

// MARK: - Playback routing

extension HermesSpeechService {

    /// Which engine plays a message. The user's choice is a client-side
    /// preference (UserDefaults, shared across windows); whether "hermes"
    /// is honoured is decided PER WINDOW from that window's server
    /// capabilities, so one window on a new host and another on an old
    /// host each do the right thing.
    public enum PlaybackEngine: String, Sendable, CaseIterable {
        case system
        case hermes

        /// UserDefaults key shared with the Settings → Voice picker.
        public static let defaultsKey = "scarf.speech.playbackEngine"

        /// `.hermes` only when the user chose it AND this window's host
        /// has `hasHermesSpeechSynthesis`; any other value (unset,
        /// unknown, or an undetected/older host) is the system voice —
        /// the pre-Hermes-Voice behaviour, unchanged.
        public static func resolve(preference: String?, capabilities: HermesCapabilities) -> PlaybackEngine {
            guard preference == PlaybackEngine.hermes.rawValue,
                  capabilities.hasHermesSpeechSynthesis else { return .system }
            return .hermes
        }
    }

    /// Identity of one message's playback: the server (and profile) the
    /// message came from plus its id. Message ids are per-`state.db`, so
    /// two windows can both show a message 42 — keying on the id alone
    /// would flip the other window's speaker button too.
    public struct PlaybackID: Hashable, Sendable {
        public let server: ServerContext
        public let messageId: Int

        public init(server: ServerContext, messageId: Int) {
            self.server = server
            self.messageId = messageId
        }
    }
}
