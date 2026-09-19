import Foundation
import Testing
@testable import ScarfCore

/// WS2 — Hermes-provider TTS synthesis. Drives `HermesSpeechService`
/// against a scripted mock transport: envelope parsing, magic-byte
/// routing (including the MP3 masquerade), output-path validation, shell
/// quoting, cache keying (incl. server identity) + hit, server temp
/// cleanup, cancellation, capability-gated engine routing, and failure
/// paths. One test runs the real script through `/bin/sh` against a fake
/// hermes install. No real Hermes, no network.
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
        private let handler: @Sendable (String) async throws -> (ProcessResult, [String: Data])

        /// `handler` sees the script and returns the result plus any files
        /// the "server" wrote — tests derive paths from the script's own
        /// cache key, exactly as the real script does.
        init(
            files: [String: Data] = [:],
            handler: @escaping @Sendable (String) async throws -> (ProcessResult, [String: Data])
        ) {
            self._files = files
            self.handler = handler
        }

        convenience init(result: @escaping @Sendable (String) -> ProcessResult) {
            self.init(handler: { (result($0), [:]) })
        }

        var fileNames: Set<String> {
            lock.lock(); defer { lock.unlock() }; return Set(_files.keys)
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
            let (result, written) = try await handler(script)
            store(written)
            return result
        }
        private func store(_ written: [String: Data]) {
            lock.lock(); defer { lock.unlock() }
            _files.merge(written) { _, new in new }
        }
        private func recordScript(_ script: String) {
            lock.lock(); defer { lock.unlock() }
            _scripts.append(script)
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
    }


    private func options(
        provider: String = "openai",
        binary: String = "/home/deploy/.local/bin/hermes",
        home: String = "~/.hermes"
    ) -> HermesSpeechService.Options {
        HermesSpeechService.Options(
            provider: provider,
            voiceFingerprint: "alloy|gpt-4o-mini-tts",
            hermesBinary: binary,
            hermesHome: home
        )
    }

    private func tempCache() -> HermesTTSCache {
        HermesTTSCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-tts-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func remoteContext(_ name: String = "tts-host", id: UUID = UUID()) -> ServerContext {
        ServerContext(id: id, displayName: name, kind: .ssh(SSHConfig(host: "h")))
    }

    private func service(
        transport: SpeechTransport,
        cache: HermesTTSCache? = nil,
        context: ServerContext = HermesSpeechServiceTests.remoteContext()
    ) -> HermesSpeechService {
        HermesSpeechService(context: context, transport: transport, cache: cache ?? tempCache())
    }

    /// The 64-hex cache key the script embeds in its output base.
    static func key(in script: String) -> String {
        guard let range = script.range(of: #"scarf-tts-[0-9a-f]{64}\.wav"#, options: .regularExpression) else {
            return "missing-key"
        }
        return String(script[range].dropFirst("scarf-tts-".count).dropLast(".wav".count))
    }

    static let tmp = "/var/folders/xy/T"

    /// Server-side base path the real script would build for `script`.
    static func base(for script: String) -> String {
        "\(tmp)/scarf-tts-501/scarf-tts-\(key(in: script)).wav"
    }

    /// Stdout of a well-behaved run: base marker first, tool noise, then
    /// the envelope naming `paths`.
    static func stdout(base: String, paths: [String]) -> String {
        let list = paths.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        SCARF_TTS_BASE:\(base)
        INFO loading provider…
        SCARF_TTS_ENV:{"success": true, "file_path": "\(paths.first ?? "")", "file_paths": [\(list)], "provider": "openai", "chunk_count": \(paths.count)}
        """
    }

    /// Transport whose "server" writes `data` at the base path (or at the
    /// names `derive` produces from it) and reports them in the envelope.
    static func succeeding(
        data: Data = wavBytes,
        derive: @escaping @Sendable (String) -> [String] = { [$0] }
    ) -> SpeechTransport {
        SpeechTransport { script in
            let base = Self.base(for: script)
            let paths = derive(base)
            var files: [String: Data] = [:]
            for path in paths { files[path] = data }
            return (ProcessResult(exitCode: 0, stdout: Data(Self.stdout(base: base, paths: paths).utf8), stderr: Data()), files)
        }
    }

    // MARK: - Envelope parsing

    @Test func envelopeParsesMarkerLineAmongNoise() {
        let envelope = HermesSpeechService.TTSEnvelope.parse(
            "warning: model load\nSCARF_TTS_ENV:{\"success\": true, \"file_path\": \"/tmp/a.wav\", \"file_paths\": [\"/tmp/a.wav\", \"/tmp/b.wav\"], \"provider\": \"openai\", \"chunk_count\": 2}\ntail noise"
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

    // MARK: - Script shape

    @Test func scriptCallsHermesToolWithoutProviderOverride() {
        let script = HermesSpeechService.synthesisScript(options: options(), cacheKey: "abc123", text: "hello")
        #expect(script.contains("from tools.tts_tool import text_to_speech_tool"))
        #expect(script.contains("output_path=os.environ[\"SCARF_TTS_OUT\"]"))
        // Hermes resolves the provider itself (keeps `nous` → openai).
        #expect(!script.contains("provider="))
        #expect(!script.contains("\"provider\""))
        // The kokoro rung is gone for good.
        #expect(!script.lowercased().contains("kokoro"))
        // Text rides the quoted-delimiter JSON heredoc.
        #expect(script.contains("<<'SCARF_JSON'"))
        #expect(script.contains("{\"text\":\"hello\"}"))
        // Base announced before the tool runs.
        let marker = script.range(of: "SCARF_TTS_BASE:")
        let tool = script.range(of: "text_to_speech_tool(")
        #expect(marker != nil && tool != nil && marker!.lowerBound < tool!.lowerBound)
        // The python body must survive single-quoting.
        #expect(!HermesSpeechService.toolPythonScript.contains("'"))
    }

    @Test func scriptDerivesInterpreterFromHermesBinaryOnly() {
        let script = HermesSpeechService.synthesisScript(options: options(), cacheKey: "k", text: "hi")
        #expect(script.contains(HermesConfigReader.pathPrelude))
        #expect(script.contains("hb='/home/deploy/.local/bin/hermes'"))
        #expect(script.contains("readlink -f"))
        #expect(script.contains("'#!'*)"))
        // No personal or guessed install paths, no bare-python fallback.
        #expect(!script.contains("kokoro-venv"))
        #expect(!script.contains("py=\"python3\""))
        #expect(!script.contains("/Users/"))
    }

    // MARK: - Shell quoting

    /// Config paths go through Scarf's shared quoter.
    @Test func scriptQuotesConfigPathsWithTheSharedQuoter() {
        let script = HermesSpeechService.synthesisScript(
            options: options(binary: "/srv/$(id)/hermes", home: "~/.hermes/profiles/w"),
            cacheKey: "k", text: "hi"
        )
        #expect(script.contains("hb='/srv/$(id)/hermes'"))
        #expect(script.contains("export HERMES_HOME=\"$HOME/.hermes/profiles/w\""))
    }

    /// Evaluate the quoted form in a real shell: command substitution,
    /// backticks, variables and embedded quotes must all come back
    /// literally, and nothing must execute.
    @Test func sharedQuoterDefeatsCommandSubstitutionInARealShell() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pwned = dir.appendingPathComponent("pwned").path
        let hostile = [
            "/srv/$(touch \(pwned))/hermes",
            "/srv/`touch \(pwned)`/hermes",
            "/srv/it's \"quoted\" $PATH ${IFS}/hermes",
            "~/$(touch \(pwned))",
        ]
        for value in hostile {
            let printed = try await ShellTestRunner.run(
                arguments: ["-c", "printf '%s' \(HermesProfileScope.shellQuotePath(value))"]).stdout
            let expected = value.hasPrefix("~/") ? NSHomeDirectory() + value.dropFirst() : value
            #expect(printed == expected)
        }
        #expect(!FileManager.default.fileExists(atPath: pwned))
    }

    // MARK: - Output path validation

    private static let key64 = String(repeating: "ab", count: 32)

    @Test func outputBaseParsesOnlyThisRequestsShape() {
        typealias Base = HermesSpeechService.OutputBase
        let k = Self.key64
        let good = Base.parse("SCARF_TTS_BASE:/var/folders/x//T/scarf-tts-501/scarf-tts-\(k).wav\n", cacheKey: k)
        #expect(good == Base(directory: "/var/folders/x/T/scarf-tts-501", stem: "scarf-tts-\(k)"))
        // First marker wins — a later line printed by the tool can't move it.
        let first = Base.parse(
            "SCARF_TTS_BASE:/tmp/scarf-tts-501/scarf-tts-\(k).wav\nSCARF_TTS_BASE:/etc/scarf-tts-0/scarf-tts-\(k).wav",
            cacheKey: k
        )
        #expect(first?.directory == "/tmp/scarf-tts-501")
        #expect(Base.parse("SCARF_TTS_BASE:/tmp/scarf-tts-501/scarf-tts-\(k).wav", cacheKey: "other") == nil)
        #expect(Base.parse("SCARF_TTS_BASE:tmp/scarf-tts-501/scarf-tts-\(k).wav", cacheKey: k) == nil)
        #expect(Base.parse("SCARF_TTS_BASE:/tmp/../etc/scarf-tts-501/scarf-tts-\(k).wav", cacheKey: k) == nil)
        #expect(Base.parse("SCARF_TTS_BASE:/tmp/scarf-tts-x/scarf-tts-\(k).wav", cacheKey: k) == nil)
        #expect(Base.parse("SCARF_TTS_BASE:/tmp/scarf-tts-501/scarf-tts-\(k).mp3", cacheKey: k) == nil)
        #expect(Base.parse("SCARF_TTS_BASE:/tmp/scarf-tts-\(k).wav", cacheKey: k) == nil)       // not in the private dir
        #expect(Base.parse("SCARF_TTS_BASE:/scarf-tts-\(k).wav", cacheKey: k) == nil)
        #expect(Base.parse("no marker", cacheKey: k) == nil)
    }

    @Test func outputBaseAcceptsExactlyHermesDerivations() throws {
        let k = Self.key64
        let dir = "/tmp/T/scarf-tts-501"
        let base = HermesSpeechService.OutputBase(directory: dir, stem: "scarf-tts-\(k)")
        let stem = "\(dir)/scarf-tts-\(k)"
        // Base, suffix swaps, chunk and part names — and `//` normalizes.
        let accepted = [
            "\(stem).wav", "\(stem).mp3", "\(stem).ogg", "\(stem).flac",
            "\(stem).chunk001.wav", "\(stem).chunk012.mp3",
            "\(stem).part01.wav", "\(stem).part12.ogg",
            "/tmp//T/scarf-tts-501/scarf-tts-\(k).wav",
        ]
        for path in accepted {
            #expect(try base.validate([path]).count == 1, "\(path)")
        }
        #expect(try base.validate(["\(stem).part01.wav", "\(stem).part01.wav"]) == ["\(stem).part01.wav"])

        let rejected = [
            "/etc/passwd",
            "\(dir)/other.wav",
            "/tmp/other/scarf-tts-501/scarf-tts-\(k).wav",           // wrong directory
            "\(dir)/sub/scarf-tts-\(k).wav",                           // subdirectory
            "/tmp/T/scarf-tts-501/../scarf-tts-501/scarf-tts-\(k).wav", // traversal
            "\(dir)/./scarf-tts-\(k).wav",
            "tmp/T/scarf-tts-501/scarf-tts-\(k).wav",                 // relative
            "\(stem)evil.wav",                                          // stem lookalike
            "/tmp/T/scarf-tts-502/scarf-tts-\(k).wav",                // other uid's dir
            "\(dir)/scarf-tts-\(String(repeating: "cd", count: 32)).wav", // other request
            "\(stem).chunk01.wav", "\(stem).part1.wav", "\(stem).chunk001",
            "\(stem).", "\(stem).wav.sh.bak", "\(stem).w/v",
            "\(dir)/.scarf-tts-\(k).delivery001.abc.wav",
            "\(stem).wav\nrm",
        ]
        for path in rejected {
            #expect(throws: HermesSpeechService.SpeechError.unexpectedOutputPath(path)) {
                _ = try base.validate([path])
            }
        }
    }

    // MARK: - Happy path + cleanup

    @Test func synthesizeFetchesVerifiesAndCleansUpServerTemp() async throws {
        let transport = Self.succeeding()
        let audio = try await service(transport: transport).synthesize(text: "hello", options: options())
        #expect(audio.chunks == [Self.wavBytes])
        #expect(audio.fromCache == false)
        let base = Self.base(for: (transport.scripts.first ?? ""))
        #expect(transport.reads == [base])
        #expect(transport.removes == [base])
        #expect(transport.scripts.count == 1)
    }

    @Test func synthesizeReadsEveryDeliveryPartInOrder() async throws {
        let transport = Self.succeeding { base in
            let stem = String(base.dropLast(".wav".count))
            return ["\(stem).part01.wav", "\(stem).part02.wav"]
        }
        let audio = try await service(transport: transport).synthesize(text: "long", options: options())
        #expect(audio.chunks.count == 2)
        let stem = String(Self.base(for: (transport.scripts.first ?? "")).dropLast(".wav".count))
        #expect(transport.reads == ["\(stem).part01.wav", "\(stem).part02.wav"])
        #expect(Set(transport.removes) == Set(["\(stem).part01.wav", "\(stem).part02.wav"]))
    }

    // MARK: - Path safety end to end

    /// An envelope naming a file the script never asked for is refused
    /// BEFORE any read or delete — even when the base is valid.
    @Test func envelopeNamingForeignPathIsNeverReadOrDeleted() async {
        let transport = SpeechTransport { script in
            let base = Self.base(for: script)
            let stdout = Self.stdout(base: base, paths: [base, "/Users/me/.ssh/id_ed25519"])
            return (ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data()),
                    [base: Self.wavBytes, "/Users/me/.ssh/id_ed25519": Data("secret".utf8)])
        }
        await #expect(throws: HermesSpeechService.SpeechError.unexpectedOutputPath("/Users/me/.ssh/id_ed25519")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
        #expect(transport.reads.isEmpty)
        #expect(transport.removes.isEmpty)
        #expect(transport.fileNames.contains("/Users/me/.ssh/id_ed25519"))
    }

    /// Without the script's own base announcement nothing is trusted.
    @Test func missingBaseMarkerRefusesEveryPath() async {
        let transport = SpeechTransport(result: { _ in
            ProcessResult(
                exitCode: 0,
                stdout: Data("SCARF_TTS_ENV:{\"success\": true, \"file_path\": \"/tmp/x.wav\", \"file_paths\": [\"/tmp/x.wav\"]}\n".utf8),
                stderr: Data()
            )
        })
        await #expect(throws: HermesSpeechService.SpeechError.unexpectedOutputPath("no output base announced")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
        #expect(transport.reads.isEmpty)
        #expect(transport.removes.isEmpty)
    }

    /// A base line for a DIFFERENT request (stale key) is not this one's.
    @Test func baseMarkerForAnotherRequestIsRejected() async {
        let transport = SpeechTransport { script in
            let other = "\(Self.tmp)/scarf-tts-501/scarf-tts-\(String(repeating: "0", count: 64)).wav"
            return (ProcessResult(exitCode: 0, stdout: Data(Self.stdout(base: other, paths: [other]).utf8), stderr: Data()),
                    [other: Self.wavBytes])
        }
        await #expect(throws: HermesSpeechService.SpeechError.unexpectedOutputPath("no output base announced")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
        #expect(transport.reads.isEmpty)
        #expect(transport.removes.isEmpty)
    }

    // MARK: - Real script, fake install

    /// Runs the ACTUAL script through `/bin/sh` (LocalTransport) against a
    /// fake hermes install: the binary's shebang names a stand-in "python"
    /// that records `HERMES_HOME`, writes WAV bytes to `$SCARF_TTS_OUT`
    /// and prints an envelope. Proves shebang discovery, `$TMPDIR` base
    /// normalization, path validation against real paths, cleanup, and
    /// that a hostile home path is passed literally and never executed.
    @Test func realScriptRunsAgainstFakeInstallAndQuotesHostileHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-fake-hermes-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = root.appendingPathComponent("fixture.wav")
        try Self.wavBytes.write(to: fixture)
        let homeRecord = root.appendingPathComponent("home.txt").path
        let pwned = root.appendingPathComponent("pwned").path

        let python = bin.appendingPathComponent("python3")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '%s' "$HERMES_HOME" > '\(homeRecord)'
        cp '\(fixture.path)' "$SCARF_TTS_OUT"
        echo "SCARF_TTS_ENV:{\\"success\\": true, \\"file_path\\": \\"$SCARF_TTS_OUT\\", \\"file_paths\\": [\\"$SCARF_TTS_OUT\\"]}"
        """.write(to: python, atomically: true, encoding: .utf8)
        let hermes = bin.appendingPathComponent("hermes")
        try "#!\(python.path)\nimport sys\n".write(to: hermes, atomically: true, encoding: .utf8)
        for file in [python, hermes] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let hostileHome = root.path + "/home $(touch \(pwned)) `touch \(pwned)` 'q'"
        let context = ServerContext(id: UUID(), displayName: "fake", kind: .local)
        let svc = HermesSpeechService(context: context, transport: LocalTransport(contextID: context.id), cache: tempCache())
        let audio = try await svc.synthesize(
            text: "hello from the real script",
            options: options(binary: hermes.path, home: hostileHome)
        )
        #expect(audio.chunks == [Self.wavBytes])
        #expect(try String(contentsOfFile: homeRecord, encoding: .utf8) == hostileHome)
        #expect(!FileManager.default.fileExists(atPath: pwned))
        // The server temp file was removed after the read, and the private
        // per-user directory exists with owner-only permissions.
        let tmp = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")
        let dir = (tmp as NSString).appendingPathComponent("scarf-tts-\(getuid())")
        let key = HermesTTSCache.cacheKey(
            server: HermesSpeechService.serverIdentity(context), provider: "openai",
            voiceFingerprint: "alloy|gpt-4o-mini-tts", text: "hello from the real script")
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/scarf-tts-\(key).wav"))
        let perms = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    // MARK: - Cancellation

    /// Stop while synthesis is in flight: the round trip is abandoned with
    /// `CancellationError`, and nothing is read, deleted, or cached.
    ///
    /// The fake host parks until the synthesis task is cancelled, with no
    /// clock involved; the time limit turns a cancellation that never
    /// arrives into a failure instead of a hang.
    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringSynthesisThrowsAndTouchesNothing() async {
        let transport = SpeechTransport { _ in
            try await Self.parkUntilCancelled()
        }
        let cache = tempCache()
        let svc = service(transport: transport, cache: cache)
        let opts = options()
        let task = Task { try await svc.synthesize(text: "long reply", options: opts) }
        while transport.scripts.isEmpty { await Task.yield() }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.reads.isEmpty)
        #expect(transport.removes.isEmpty)
    }

    /// Suspends until the calling task is cancelled, then throws
    /// `CancellationError` — what `Task.sleep` does when cancelled, without
    /// a duration to pick. `AsyncStream`'s iterator ends on cancellation;
    /// the continuation is held so the stream cannot finish on its own.
    static func parkUntilCancelled() async throws -> Never {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        for await _ in stream {}
        withExtendedLifetime(continuation) {}
        throw CancellationError()
    }

    // MARK: - Cache

    @Test func cacheKeySeparatesServerProviderVoiceAndText() {
        let base = HermesTTSCache.cacheKey(server: "a", provider: "openai", voiceFingerprint: "alloy|m", text: "hello")
        #expect(base == HermesTTSCache.cacheKey(server: "a", provider: "openai", voiceFingerprint: "alloy|m", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(server: "b", provider: "openai", voiceFingerprint: "alloy|m", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(server: "a", provider: "edge", voiceFingerprint: "alloy|m", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(server: "a", provider: "openai", voiceFingerprint: "echo|m", text: "hello"))
        #expect(base != HermesTTSCache.cacheKey(server: "a", provider: "openai", voiceFingerprint: "alloy|m", text: "hello again"))
        // Length-prefixing: moving a separator between fields changes the key.
        #expect(HermesTTSCache.cacheKey(server: "a|b", provider: "c", voiceFingerprint: "", text: "t")
            != HermesTTSCache.cacheKey(server: "a", provider: "b|c", voiceFingerprint: "", text: "t"))
    }

    @Test func secondSynthesisIsACacheHitThatSkipsTheServer() async throws {
        let transport = Self.succeeding()
        let svc = service(transport: transport, cache: tempCache())
        let first = try await svc.synthesize(text: "same words", options: options())
        let second = try await svc.synthesize(text: "same words", options: options())
        #expect(first.fromCache == false)
        #expect(second.fromCache == true)
        #expect(second.chunks == first.chunks)
        // One server round trip total — the hit never left the Mac.
        #expect(transport.scripts.count == 1)
    }

    /// Same text, same config, different server: never a shared entry.
    @Test func cacheIsPartitionedByServer() async throws {
        let cache = tempCache()
        let a = Self.succeeding()
        let b = Self.succeeding()
        _ = try await service(transport: a, cache: cache, context: Self.remoteContext("a")).synthesize(text: "hi", options: options())
        let fromB = try await service(transport: b, cache: cache, context: Self.remoteContext("b")).synthesize(text: "hi", options: options())
        #expect(fromB.fromCache == false)
        #expect(b.scripts.count == 1)
        #expect(Self.key(in: (a.scripts.first ?? "")) != Self.key(in: (b.scripts.first ?? "")))
    }

    /// A profile switch on the same server is a different identity too.
    @Test func serverIdentityIncludesProfileHome() {
        let id = UUID()
        let base = ServerContext(id: id, displayName: "h", kind: .ssh(SSHConfig(host: "h")))
        let scoped = base.scoped(toProfile: "work")
        #expect(HermesSpeechService.serverIdentity(base) != HermesSpeechService.serverIdentity(scoped))
    }

    @Test func productionCacheLivesUnderCaches() {
        let path = HermesTTSCache().directory.path
        #expect(path.contains("/Library/Caches/"))
        #expect(path.hasSuffix("/scarf/tts"))
        #expect(!path.contains("Application Support"))
    }

    @Test func cacheStoreAndLoadRoundTripsWithoutServer() {
        let cache = tempCache()
        let key = HermesTTSCache.cacheKey(server: "s", provider: "openai", voiceFingerprint: "f", text: "t")
        cache.store(chunks: [Self.wavBytes, Self.wavBytes], key: key)
        #expect(cache.cachedAudio(for: key) == [Self.wavBytes, Self.wavBytes])
        #expect(cache.cachedAudio(for: "missing-key") == nil)
    }

    @Test func tornCacheEntryReadsAsMissAndSelfHeals() {
        let cache = tempCache()
        let key = HermesTTSCache.cacheKey(server: "s", provider: "openai", voiceFingerprint: "f", text: "t")
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

    /// Hermes's default `edge` provider writes MP3 into the `.wav` path;
    /// the bytes decide, and MP3 plays (and caches as `.mp3`).
    @Test func mp3UnderWavNameIsAcceptedByMagicBytes() async throws {
        let transport = Self.succeeding(data: Self.mp3Bytes)
        let cache = tempCache()
        let svc = service(transport: transport, cache: cache)
        let first = try await svc.synthesize(text: "hello", options: options())
        #expect(first.format == .mp3)
        #expect(first.chunks == [Self.mp3Bytes])
        let again = try await svc.synthesize(text: "hello", options: options())
        #expect(again.fromCache)
        #expect(again.format == .mp3)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        #expect(names.contains { $0.hasSuffix("-00.mp3") })
        #expect(!names.contains { $0.hasSuffix(".wav") })
    }

    @Test func oggThrowsProviderMismatchAndIsNotCached() async {
        let ogg = Data([0x4F, 0x67, 0x67, 0x53]) + Data(repeating: 0, count: 12)
        let transport = Self.succeeding(data: ogg)
        let cache = tempCache()
        let context = Self.remoteContext()
        let svc = service(transport: transport, cache: cache, context: context)
        await #expect(throws: HermesSpeechService.SpeechError.providerMismatch(actualFormat: "ogg")) {
            _ = try await svc.synthesize(text: "hello", options: self.options())
        }
        // The temp file was still cleaned up server-side, and nothing
        // poisoned the cache.
        #expect(transport.removes == [Self.base(for: transport.scripts.first ?? "")])
        #expect(cache.cachedAudio(for: HermesTTSCache.cacheKey(
            server: HermesSpeechService.serverIdentity(context), provider: "openai",
            voiceFingerprint: options().voiceFingerprint, text: "hello"
        )) == nil)
    }

    /// One player connection serves the whole message, so chunks must agree.
    @Test func mixedChunkFormatsAreAMismatch() async {
        let transport = SpeechTransport { script in
            let stem = String(Self.base(for: script).dropLast(".wav".count))
            let a = "\(stem).part01.wav", b = "\(stem).part02.mp3"
            return (ProcessResult(exitCode: 0, stdout: Data(Self.stdout(base: Self.base(for: script), paths: [a, b]).utf8), stderr: Data()),
                    [a: Self.wavBytes, b: Self.mp3Bytes])
        }
        await #expect(throws: HermesSpeechService.SpeechError.providerMismatch(actualFormat: "mp3+wav")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
    }

    @Test func nonZeroExitThrowsSynthesisFailed() async {
        let transport = SpeechTransport(result: { _ in
            ProcessResult(
                exitCode: 4,
                stdout: Data(),
                stderr: Data("Traceback (most recent call last)\nModuleNotFoundError: No module named 'tools'\n".utf8)
            )
        })
        do {
            _ = try await service(transport: transport).synthesize(text: "hello", options: options())
            Issue.record("expected synthesisFailed")
        } catch let error as HermesSpeechService.SpeechError {
            guard case .synthesisFailed(let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(detail.contains("No module named 'tools'"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func failureEnvelopeSurfacesToolError() async {
        let transport = SpeechTransport(result: { _ in
            ProcessResult(
                exitCode: 0,
                stdout: Data("SCARF_TTS_ENV:{\"success\": false, \"error\": \"OpenAI API key missing\"}\n".utf8),
                stderr: Data()
            )
        })
        await #expect(throws: HermesSpeechService.SpeechError.synthesisFailed("OpenAI API key missing")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
    }

    @Test func missingMarkerLineThrowsSynthesisFailed() async {
        let transport = SpeechTransport(result: { _ in
            ProcessResult(exitCode: 0, stdout: Data("silence…\n".utf8), stderr: Data())
        })
        await #expect(throws: HermesSpeechService.SpeechError.synthesisFailed("silence…")) {
            _ = try await self.service(transport: transport).synthesize(text: "hello", options: self.options())
        }
    }

    /// A validated path that can't be read still gets cleaned up.
    @Test func unreadableEnvelopeFileSurfacesTransportFailureAndStillCleansUp() async {
        let transport = SpeechTransport { script in
            let base = Self.base(for: script)
            return (ProcessResult(exitCode: 0, stdout: Data(Self.stdout(base: base, paths: [base]).utf8), stderr: Data()), [:])
        }
        do {
            _ = try await service(transport: transport).synthesize(text: "hello", options: options())
            Issue.record("expected transportFailed")
        } catch let error as HermesSpeechService.SpeechError {
            guard case .transportFailed = error else { Issue.record("wrong error: \(error)"); return }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(transport.removes == [Self.base(for: (transport.scripts.first ?? ""))])
    }

    // MARK: - Config → options

    @Test func optionsResolveFromParsedConfig() {
        let config = HermesConfig(yaml: "tts:\n  provider: openai\n  openai:\n    voice: echo\n")
        let paths = HermesPathSet(home: "/Users/t/.hermes", isRemote: false, binaryHint: nil)
        let options = HermesSpeechService.options(config: config, paths: paths)
        #expect(options.provider == "openai")
        #expect(options.hermesHome == "/Users/t/.hermes")
        #expect(options.voiceFingerprint.contains("echo"))
    }

    @Test func absentProviderKeysOnHermesDefault() {
        let options = HermesSpeechService.options(
            config: HermesConfig(yaml: "model:\n  default: m\n"),
            paths: HermesPathSet(home: "~/.hermes", isRemote: true, binaryHint: nil)
        )
        #expect(options.provider == "edge")
        #expect(options.hermesBinary == "hermes")
    }

    @Test func kokoroConfigKeysAreNoLongerParsed() {
        // `tts.kokoro.*` belonged to a third-party plugin; Scarf no longer
        // models it in any TYPED field. The block still parses without
        // error and changes none of the typed fields.
        let withBlock = HermesConfig(yaml: "tts:\n  provider: openai\n  kokoro:\n    python: /venv/bin/python\n")
        let without = HermesConfig(yaml: "tts:\n  provider: openai\n")
        var withBlockVoice = withBlock.voice
        var withoutVoice = without.voice
        withBlockVoice.ttsSectionFingerprint = ""
        withoutVoice.ttsSectionFingerprint = ""
        #expect(withBlockVoice == withoutVoice)
        // t-eb402e82: unlike the typed fields, `ttsSectionFingerprint` DOES
        // see `tts.kokoro.*` — it hashes the whole parsed `tts:` section, so
        // a config-only-Scarf-can't-model edit still invalidates the TTS
        // cache instead of silently replaying stale audio.
        #expect(withBlock.voice.ttsSectionFingerprint != without.voice.ttsSectionFingerprint)
    }

    @Test func voiceChatModeDefaultsMatchHermes() {
        // `hermes_cli/config_defaults.py:1132-1137` @ v2026.9.14.
        let absent = HermesConfig(yaml: "model:\n  default: m\n").voice
        #expect(absent.voiceChatMode == "chained")
        #expect(VoiceSettings.empty.voiceChatMode == "chained")
        let set = HermesConfig(yaml: "voice:\n  voice_chat_mode: gpt-live\n").voice
        #expect(set.voiceChatMode == "gpt-live")
    }

    @Test func voiceFingerprintTracksProviderSpecificKeys() {
        var voice = VoiceSettings.empty
        voice.ttsOpenAIVoice = "alloy"
        let openaiA = HermesSpeechService.voiceFingerprint(provider: "openai", voice: voice)
        voice.ttsOpenAIVoice = "echo"
        let openaiB = HermesSpeechService.voiceFingerprint(provider: "openai", voice: voice)
        #expect(openaiA != openaiB)
        // t-eb402e82: every fingerprint carries the whole-`tts:`-section hash
        // as a `|tts:<hash>` suffix, so an unknown provider's fingerprint is
        // the provider name plus that suffix, not the bare name.
        #expect(HermesSpeechService.voiceFingerprint(provider: "unknown-provider", voice: voice)
            == "unknown-provider|tts:\(voice.ttsSectionFingerprint)")
        // `nous` speaks with the OpenAI voice, so it keys on it too.
        #expect(HermesSpeechService.voiceFingerprint(provider: "nous", voice: voice) == openaiB)
    }

    // MARK: - Capability gating + per-window routing

    @Test func hermesEngineRequiresPreferenceAndCapability() {
        typealias Engine = HermesSpeechService.PlaybackEngine
        let new = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let old = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(Engine.resolve(preference: "hermes", capabilities: new) == .hermes)
        // Older or undetected host: the system voice, whatever the preference.
        #expect(Engine.resolve(preference: "hermes", capabilities: old) == .system)
        #expect(Engine.resolve(preference: "hermes", capabilities: .empty) == .system)
        #expect(Engine.resolve(preference: nil, capabilities: new) == .system)
        #expect(Engine.resolve(preference: "system", capabilities: new) == .system)
        #expect(Engine.resolve(preference: "kokoro", capabilities: new) == .system)
    }

    /// Playback identity is per server: the same message id in two
    /// windows is two different playbacks, and the service synthesizes on
    /// exactly the server the id names.
    @Test func playbackIdentityIsPerServer() async throws {
        let a = Self.remoteContext("a")
        let b = Self.remoteContext("b")
        #expect(HermesSpeechService.PlaybackID(server: a, messageId: 42)
            != HermesSpeechService.PlaybackID(server: b, messageId: 42))
        #expect(HermesSpeechService.PlaybackID(server: a, messageId: 42)
            == HermesSpeechService.PlaybackID(server: a, messageId: 42))
        let svc = HermesSpeechService(context: b, transport: Self.succeeding(), cache: tempCache())
        let context = await svc.context
        #expect(context == b)
    }
}
