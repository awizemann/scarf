import Foundation
import Testing
@testable import ScarfCore

/// WS2 — Hermes-provider TTS synthesis. Drives `HermesSpeechService`
/// against a scripted mock transport: envelope parsing, magic-byte
/// routing (including the edge-tts MP3 masquerade), cache keying + hit,
/// ladder selection, server temp cleanup, and failure paths. No real
/// server, no torch, no timing.
@Suite struct HermesSpeechServiceTests {

    // MARK: - Fixtures

    /// Minimal RIFF/WAVE header (PCM, mono, 24 kHz) + payload. Never
    /// decoded — only the magic bytes matter.
    static let wavBytes: Data = {
        var data = Data([0x52, 0x49, 0x46, 0x46])          // "RIFF"
        data.append(Data(repeating: 0x00, count: 4))        // size
        data.append(Data([0x57, 0x41, 0x56, 0x45]))        // "WAVE"
        data.append(Data([0x66, 0x6D, 0x74, 0x20]))        // "fmt "
        data.append(Data(repeating: 0x01, count: 8))        // chunk
        data.append(Data(repeating: 0x00, count: 32))       // body
        return data
    }()

    /// MP3 frame-sync header — what edge-tts actually writes, whatever
    /// the file extension promised.
    static let mp3Bytes = Data([0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00])

    /// Scripts `streamScript`, backs file I/O with an in-memory map, and
    /// records every script / read / remove for assertions.
    final class SpeechTransport: ServerTransport, @unchecked Sendable {
        let contextID: ServerID = UUID()
        let isRemote: Bool = true

        private let lock = NSLock()
        private var _files: [String: Data]
        private var _scripts: [String] = []
        private var _reads: [String] = []
        private var _removes: [String] = []
        private let handler: @Sendable (String) -> ProcessResult

        init(
            files: [String: Data] = [:],
            handler: @escaping @Sendable (String) -> ProcessResult = { _ in
                ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ) {
            self._files = files
            self.handler = handler
        }

        var scripts: [String] {
            lock.lock(); defer { lock.unlock() }; return _scripts
        }
        var reads: [String] {
            lock.lock(); defer { lock.unlock() }; return _reads
        }
        var removes: [String] {
            lock.lock(); defer { lock.unlock() }; return _removes
        }

        func readFile(_ path: String) throws -> Data {
            lock.lock(); _reads.append(path); defer { lock.unlock() }
            guard let data = _files[path] else {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            return data
        }
        func unguardedWriteFile(_ path: String, data: Data) throws {
            lock.lock(); _files[path] = data; lock.unlock()
        }
        func fileExists(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }; return _files[path] != nil
        }
        func stat(_ path: String) -> FileStat? { FileStat(size: 0, mtime: Date(), isDirectory: false) }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {
            lock.lock(); _removes.append(path); _files.removeValue(forKey: path); lock.unlock()
        }
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish(throwing: TransportError.other(message: "unsupported")) }
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            recordScript(script)
            return handler(script)
        }
        private func recordScript(_ script: String) {
            lock.lock(); defer { lock.unlock() }
            _scripts.append(script)
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
    }

    private func kokoroOptions(
        python: String = "/srv/hermes/kokoro-venv/bin/python",
        home: String = "~/.hermes"
    ) -> HermesSpeechService.Options {
        HermesSpeechService.Options(
            provider: "kokoro",
            voiceFingerprint: "af_sky|a|1.0|\(python)",
            kokoroVoice: "af_sky",
            kokoroSpeed: 1.0,
            kokoroLangCode: "a",
            kokoroPython: python,
            hermesBinary: "/home/deploy/.local/bin/hermes",
            hermesHome: home
        )
    }

    private func builtinOptions(provider: String = "openai") -> HermesSpeechService.Options {
        HermesSpeechService.Options(
            provider: provider,
            voiceFingerprint: "alloy|gpt-4o-mini-tts",
            kokoroVoice: "af_heart",
            kokoroSpeed: 1.0,
            kokoroLangCode: "a",
            kokoroPython: "",
            hermesBinary: "/home/deploy/.local/bin/hermes",
            hermesHome: "~/.hermes"
        )
    }

    private func tempCache() -> HermesTTSCache {
        HermesTTSCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-tts-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func remoteContext() -> ServerContext {
        ServerContext(id: UUID(), displayName: "tts-host", kind: .ssh(SSHConfig(host: "h")))
    }

    private func service(transport: SpeechTransport, cache: HermesTTSCache? = nil) -> HermesSpeechService {
        HermesSpeechService(context: remoteContext(), transport: transport, cache: cache ?? tempCache())
    }

    /// A successful kokoro-style envelope against `path`.
    private func successEnvelope(path: String) -> String {
        """
        loading torch…
        SCARF_TTS_ENV:{"success": true, "file_path": "\(path)", "file_paths": ["\(path)"], "provider": "kokoro", "chunk_count": 1}
        """
    }

    // MARK: - Envelope parsing

    @Test func envelopeParsesMarkerLineAmongNoise() {
        let envelope = HermesSpeechService.TTSEnvelope.parse(
            "warning: torch load\nSCARF_TTS_ENV:{\"success\": true, \"file_path\": \"/tmp/a.wav\", \"file_paths\": [\"/tmp/a.wav\", \"/tmp/b.wav\"], \"provider\": \"openai\", \"chunk_count\": 2}\ntail noise"
        )
        #expect(envelope != nil)
        #expect(envelope?.success == true)
        #expect(envelope?.filePath == "/tmp/a.wav")
        #expect(envelope?.filePaths == ["/tmp/a.wav", "/tmp/b.wav"])
        #expect(envelope?.provider == "openai")
        #expect(envelope?.chunkCount == 2)
    }

    @Test func envelopeParsesFailureShape() {
        let envelope = HermesSpeechService.TTSEnvelope.parse(
            "SCARF_TTS_ENV:{\"success\": false, \"error\": \"Text is empty after TTS cleanup\"}"
        )
        #expect(envelope?.success == false)
        #expect(envelope?.error == "Text is empty after TTS cleanup")
    }

    @Test func envelopeReturnsNilWithoutMarkerOrBadJSON() {
        #expect(HermesSpeechService.TTSEnvelope.parse("plain output, no marker") == nil)
        #expect(HermesSpeechService.TTSEnvelope.parse("SCARF_TTS_ENV:not json") == nil)
    }

    // MARK: - Magic bytes

    @Test func audioFormatRoutesContainers() {
        #expect(HermesSpeechService.audioFormat(of: Self.wavBytes) == .wav)
        #expect(HermesSpeechService.audioFormat(of: Self.mp3Bytes) == .mp3)
        // "ID3"-tagged MP3 — the other masquerade shape.
        #expect(HermesSpeechService.audioFormat(of: Data([0x49, 0x44, 0x33, 0x03]) + Data(repeating: 0, count: 8)) == .mp3)
        #expect(HermesSpeechService.audioFormat(of: Data([0x4F, 0x67, 0x67, 0x53]) + Data(repeating: 0, count: 8)) == .ogg)
        #expect(HermesSpeechService.audioFormat(of: Data(repeating: 0x7F, count: 12)) == nil)
        #expect(HermesSpeechService.audioFormat(of: Data([0x52, 0x49, 0x46, 0x46])) == nil) // truncated RIFF
    }

    // MARK: - Ladder selection

    @Test func kokoroProviderBuildsDirectVenvScript() {
        let script = HermesSpeechService.buildScript(
            options: kokoroOptions(), cacheKey: "abc123", text: "hello"
        )
        // Rung 1: the configured venv python + KPipeline mirror, and NO
        // orchestrator import.
        #expect(script.contains("/srv/hermes/kokoro-venv/bin/python"))
        #expect(script.contains("from kokoro import KPipeline"))
        #expect(!script.contains("text_to_speech_tool"))
        // Text rides the JSON heredoc, shell-quoted delimiters intact.
        #expect(script.contains("<<'SCARF_JSON'"))
        #expect(script.contains("\"text\":\"hello\"") || script.contains("\"text\": \"hello\""))
        // Voice / lang code / speed all reach the payload.
        #expect(script.contains("af_sky"))
        #expect(script.contains("\"lang_code\":\"a\"") || script.contains("\"lang_code\": \"a\""))
    }

    @Test func kokoroDefaultsVenvPythonUnderHermesHome() {
        let script = HermesSpeechService.buildScript(
            options: kokoroOptions(python: ""), cacheKey: "k", text: "hi"
        )
        // Empty tts.kokoro.python → <home>/kokoro-venv/bin/python, with
        // the unexpanded remote `~` mapped to $HOME for the shell.
        #expect(script.contains("$HOME/.hermes/kokoro-venv/bin/python"))
    }

    @Test func kokoroDefaultProbesProfileHomeThenInstallationRoot() {
        // A profile-scoped home shares the root installation's venv: when
        // tts.kokoro.python is absent the script probes <home> first, then
        // the root home (HermesProfileScope.rootHome strips /profiles/<n>).
        let options = kokoroOptions(python: "", home: "~/.hermes/profiles/work")
        let script = HermesSpeechService.buildScript(options: options, cacheKey: "k", text: "hi")
        #expect(script.contains("$HOME/.hermes/profiles/work/kokoro-venv/bin/python"))
        #expect(script.contains("$HOME/.hermes/kokoro-venv/bin/python"))
    }

    @Test func builtinProviderBuildsOrchestratorScript() {
        let script = HermesSpeechService.buildScript(
            options: builtinOptions(provider: "openai"), cacheKey: "k2", text: "hi there"
        )
        // Rung 2: explicit provider through text_to_speech_tool, venv
        // python derived from the hermes binary, and no kokoro imports.
        #expect(script.contains("text_to_speech_tool"))
        #expect(script.contains("\"provider\":\"openai\"") || script.contains("\"provider\": \"openai\""))
        #expect(script.contains("readlink -f"))
        #expect(script.contains("/home/deploy/.local/bin/hermes"))
        #expect(script.contains("HERMES_HOME"))
        #expect(!script.contains("KPipeline"))
    }

    @Test func tildePathsExpandToShellHome() {
        #expect(HermesSpeechService.expandingTilde("~") == "$HOME")
        #expect(HermesSpeechService.expandingTilde("~/.hermes") == "$HOME/.hermes")
        #expect(HermesSpeechService.expandingTilde("/abs/path") == "/abs/path")
    }

    // MARK: - Happy path + cleanup

    @Test func synthesizeFetchesVerifiesAndCleansUpServerTemp() async throws {
        let out = "/tmp/scarf-tts-x-501.wav"
        let transport = SpeechTransport(
            files: [out: Self.wavBytes],
            handler: { _ in
                ProcessResult(exitCode: 0, stdout: Data(self.successEnvelope(path: out).utf8), stderr: Data())
            }
        )
        let audio = try await service(transport: transport).synthesize(text: "hello", options: kokoroOptions())
        #expect(audio.chunks == [Self.wavBytes])
        #expect(audio.fromCache == false)
        #expect(transport.reads == [out])
        #expect(transport.removes == [out])
        #expect(transport.scripts.count == 1)
    }

    @Test func synthesizeReadsEveryDeliveryChunkInOrder() async throws {
        let first = "/tmp/scarf-tts-y-501.wav"
        let second = "/tmp/scarf-tts-y-501.part02.wav"
        let envelope = """
        SCARF_TTS_ENV:{"success": true, "file_paths": ["\(first)", "\(second)"], "provider": "openai", "chunk_count": 2}
        """
        let transport = SpeechTransport(
            files: [first: Self.wavBytes, second: Self.wavBytes],
            handler: { _ in ProcessResult(exitCode: 0, stdout: Data(envelope.utf8), stderr: Data()) }
        )
        let audio = try await service(transport: transport).synthesize(text: "long", options: builtinOptions())
        #expect(audio.chunks.count == 2)
        #expect(transport.reads == [first, second])
        #expect(Set(transport.removes) == Set([first, second]))
    }

    // MARK: - Cache

    @Test func cacheKeySeparatesProviderVoiceAndText() {
        let base = HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "af_sky|a|1.0|", text: "hello")
        #expect(base == HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "af_sky|a|1.0|", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(provider: "openai", voiceFingerprint: "af_sky|a|1.0|", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "af_heart|a|1.0|", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "af_sky|a|1.0|", text: "hello again"))
    }

    @Test func secondSynthesisIsACacheHitThatSkipsTheServer() async throws {
        let out = "/tmp/scarf-tts-cache-501.wav"
        let transport = SpeechTransport(
            files: [out: Self.wavBytes],
            handler: { _ in
                ProcessResult(exitCode: 0, stdout: Data(self.successEnvelope(path: out).utf8), stderr: Data())
            }
        )
        let cache = tempCache()
        let svc = service(transport: transport, cache: cache)

        let first = try await svc.synthesize(text: "same words", options: kokoroOptions())
        let second = try await svc.synthesize(text: "same words", options: kokoroOptions())
        #expect(first.fromCache == false)
        #expect(second.fromCache == true)
        #expect(second.chunks == first.chunks)
        // One server round trip total — the hit never left the Mac.
        #expect(transport.scripts.count == 1)
        #expect(transport.reads == [out])
    }

    @Test func cacheStoreAndLoadRoundTripsWithoutServer() {
        let cache = tempCache()
        let key = HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "f", text: "t")
        cache.store(chunks: [Self.wavBytes, Self.wavBytes], key: key)
        #expect(cache.cachedAudio(for: key) == [Self.wavBytes, Self.wavBytes])
        #expect(cache.cachedAudio(for: "missing-key") == nil)
    }

    @Test func tornCacheEntryReadsAsMissAndSelfHeals() {
        let cache = tempCache()
        let key = HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: "f", text: "t")
        cache.store(chunks: [Self.wavBytes], key: key)
        // Simulate a torn entry: delete the chunk behind the manifest's back.
        try? FileManager.default.removeItem(
            at: cache.directory.appendingPathComponent("\(key)-00.wav")
        )
        #expect(cache.cachedAudio(for: key) == nil)
        // The corrupt manifest is gone, so a fresh store sticks.
        cache.store(chunks: [Self.wavBytes], key: key)
        #expect(cache.cachedAudio(for: key) == [Self.wavBytes])
    }

    // MARK: - Failure paths

    @Test func mp3MasqueradeThrowsProviderMismatchAndIsNotCached() async {
        let out = "/tmp/scarf-tts-masq-501.wav"
        let transport = SpeechTransport(
            files: [out: Self.mp3Bytes],
            handler: { _ in
                ProcessResult(exitCode: 0, stdout: Data(self.successEnvelope(path: out).utf8), stderr: Data())
            }
        )
        let cache = tempCache()
        let svc = service(transport: transport, cache: cache)
        await #expect(throws: HermesSpeechService.SpeechError.providerMismatch(actualFormat: "mp3")) {
            _ = try await svc.synthesize(text: "hello", options: kokoroOptions())
        }
        // The temp file was still cleaned up server-side, and nothing
        // poisoned the cache.
        #expect(transport.removes == [out])
        #expect(cache.cachedAudio(
            for: HermesTTSCache.cacheKey(provider: "kokoro", voiceFingerprint: kokoroOptions().voiceFingerprint, text: "hello")
        ) == nil)
    }

    @Test func nonZeroExitThrowsSynthesisFailed() async {
        let transport = SpeechTransport { _ in
            ProcessResult(
                exitCode: 4,
                stdout: Data(),
                stderr: Data("Traceback (most recent call last)\nRuntimeError: Kokoro produced no audio\n".utf8)
            )
        }
        let svc = service(transport: transport)
        do {
            _ = try await svc.synthesize(text: "hello", options: kokoroOptions())
            Issue.record("expected synthesisFailed")
        } catch let error as HermesSpeechService.SpeechError {
            guard case .synthesisFailed(let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(detail.contains("Kokoro produced no audio"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func failureEnvelopeSurfacesToolError() async {
        let transport = SpeechTransport { _ in
            ProcessResult(
                exitCode: 0,
                stdout: Data("SCARF_TTS_ENV:{\"success\": false, \"error\": \"OpenAI API key missing\"}\n".utf8),
                stderr: Data()
            )
        }
        let svc = service(transport: transport)
        do {
            _ = try await svc.synthesize(text: "hello", options: builtinOptions())
            Issue.record("expected synthesisFailed")
        } catch let error as HermesSpeechService.SpeechError {
            guard case .synthesisFailed(let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(detail.contains("OpenAI API key missing"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func missingMarkerLineThrowsSynthesisFailed() async {
        let transport = SpeechTransport { _ in
            ProcessResult(exitCode: 0, stdout: Data("silence…\n".utf8), stderr: Data())
        }
        let svc = service(transport: transport)
        await #expect(throws: (any Error).self) {
            _ = try await svc.synthesize(text: "hello", options: builtinOptions())
        }
    }

    @Test func missingEnvelopeFileSurfacesTransportFailure() async {
        let transport = SpeechTransport { _ in
            ProcessResult(
                exitCode: 0,
                stdout: Data("SCARF_TTS_ENV:{\"success\": true, \"file_path\": \"/tmp/gone.wav\", \"file_paths\": []}\n".utf8),
                stderr: Data()
            )
        }
        let svc = service(transport: transport)
        await #expect(throws: (any Error).self) {
            _ = try await svc.synthesize(text: "hello", options: builtinOptions())
        }
    }

    // MARK: - Config → options

    @Test func optionsResolveFromParsedConfig() {
        let yaml = """
        tts:
          provider: kokoro
          kokoro:
            python: /venv/bin/python
            voice: af_sky
            speed: 1.2
            lang_code: b
        """
        let config = HermesConfig(yaml: yaml)
        #expect(config.voice.ttsKokoroVoice == "af_sky")
        #expect(config.voice.ttsKokoroSpeed == 1.2)
        #expect(config.voice.ttsKokoroLangCode == "b")
        #expect(config.voice.ttsKokoroPython == "/venv/bin/python")

        let paths = HermesPathSet(home: "/Users/t/.hermes", isRemote: false, binaryHint: nil)
        let options = HermesSpeechService.options(config: config, paths: paths)
        #expect(options.provider == "kokoro")
        #expect(options.kokoroVoice == "af_sky")
        #expect(options.hermesHome == "/Users/t/.hermes")
        #expect(options.voiceFingerprint.contains("af_sky"))
    }

    @Test func absentKokoroBlockParsesPluginDefaults() {
        let config = HermesConfig(yaml: "model:\n  default: m\n")
        #expect(config.voice.ttsKokoroVoice == "af_heart")
        #expect(config.voice.ttsKokoroSpeed == 1.0)
        #expect(config.voice.ttsKokoroLangCode == "a")
        #expect(config.voice.ttsKokoroPython.isEmpty)
    }

    @Test func voiceFingerprintTracksProviderSpecificKeys() {
        var voice = VoiceSettings.empty
        voice.ttsOpenAIVoice = "alloy"
        let openaiA = HermesSpeechService.voiceFingerprint(provider: "openai", voice: voice)
        voice.ttsOpenAIVoice = "echo"
        let openaiB = HermesSpeechService.voiceFingerprint(provider: "openai", voice: voice)
        #expect(openaiA != openaiB)
        #expect(HermesSpeechService.voiceFingerprint(provider: "unknown-provider", voice: voice) == "unknown-provider")
    }
}
