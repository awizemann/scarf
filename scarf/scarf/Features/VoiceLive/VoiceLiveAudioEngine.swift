import AVFoundation
import ScarfCore

/// AVAudioEngine glue for the live voice session: mic tap → PCM16 @ 24 kHz
/// chunks for the realtime service, and scheduled-buffer playback of the
/// PCM16 the service delivers back.
///
/// All sample math lives in `ScarfCore.RealtimeAudioMath` (pure, tested);
/// this class only adapts `AVAudioPCMBuffer` to arrays and owns the
/// AVAudioEngine lifecycle. The input tap runs on an audio thread and
/// deliberately touches NO engine state — it converts, measures RMS, and
/// hands results to the injected `@Sendable` sinks, so no lock is needed
/// on the hot path.
///
/// Control surface is an actor: AVAudioEngine calls are serialized without
/// a queue, `play`/`cutPlayback` arrive from the MainActor event pump in
/// order, and `cutPlayback` (barge-in) is one actor hop from the service
/// event — `stop()` + `play()` flushes every scheduled buffer instantly.
///
/// One engine instance per voice session, like the realtime service
/// itself; a restart builds a fresh one.
actor VoiceLiveAudioEngine {
    enum SetupError: LocalizedError {
        /// Zero channels/rate on the input node — either no microphone is
        /// present or macOS denied mic access (System Settings → Privacy
        /// & Security → Microphone).
        case microphoneUnavailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return "No microphone is available. Grant Scarf microphone access in System Settings → Privacy & Security, then try again."
            case .engineStartFailed(let reason):
                return "Couldn't start the audio engine: \(reason)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    private var isRunning = false

    /// Install the mic tap and start input + playback.
    /// - Parameters:
    ///   - onChunk: raw LE PCM16 mono @ 24 kHz, called on an audio thread.
    ///   - onLevel: mic RMS (0…1) per tap window, called on an audio thread.
    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void
    ) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw SetupError.microphoneUnavailable
        }

        guard let playback = AVAudioFormat(
            standardFormatWithSampleRate: RealtimeAudioMath.sampleRate,
            channels: 1
        ) else {
            throw SetupError.engineStartFailed("couldn't create the 24 kHz playback format")
        }
        playbackFormat = playback

        // The tap works on the hardware format (input nodes reject
        // arbitrary target formats); conversion to 24 kHz mono PCM16 is
        // done per-buffer in `processInput`. 4800 frames @ 48 kHz ≈ a
        // 100 ms cadence — small enough for VAD latency, large enough
        // to keep message volume sane. Only plain values are captured
        // (`AVAudioFormat` isn't Sendable); the buffer carries its own
        // format for the channel/interleave questions.
        let sourceRate = native.sampleRate
        input.installTap(onBus: 0, bufferSize: 4800, format: native) { buffer, _ in
            processInput(
                buffer,
                sourceRate: sourceRate,
                onChunk: onChunk,
                onLevel: onLevel
            )
        }

        engine.attach(player)
        // Connecting at 24 kHz mono lets the engine handle the final
        // hardware rate conversion downstream of the mixer — scheduled
        // buffers stay in the realtime API's native format end-to-end.
        engine.connect(player, to: engine.mainMixerNode, format: playback)

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SetupError.engineStartFailed(error.localizedDescription)
        }
        // Start the player silent (nothing scheduled): scheduling and
        // cutPlayback never have to wonder whether it is playing.
        player.play()
        isRunning = true
    }

    /// Schedule received assistant audio (raw LE PCM16 mono @ 24 kHz)
    /// for playback.
    func play(pcm16: Data) {
        guard isRunning, let format = playbackFormat else { return }
        let samples = RealtimeAudioMath.floatSamples(fromPCM16: pcm16)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(buffer)
    }

    /// Barge-in: flush everything scheduled. `stop()` clears the
    /// player's queue and timeline; the immediate `play()` keeps the
    /// node live for the next response — a stopped node would silently
    /// drop every later `scheduleBuffer`.
    func cutPlayback() {
        guard isRunning else { return }
        player.stop()
        player.play()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }
}

/// Convert one tap buffer to the realtime format and report level.
/// Audio-thread context: pure math + the caller's `@Sendable` sinks only.
/// `nonisolated` opts out of the app target's MainActor default
/// isolation — this runs on the engine's render thread.
nonisolated private func processInput(
    _ buffer: AVAudioPCMBuffer,
    sourceRate: Double,
    onChunk: @Sendable (Data) -> Void,
    onLevel: @Sendable (Double) -> Void
) {
    guard let channelData = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    let channelCount = Int(buffer.format.channelCount)

    // Down to mono first — level and rate conversion both want a
    // single channel, and averaging (not left-only) preserves level
    // for stereo desk mics.
    let mono: [Float]
    if buffer.format.isInterleaved {
        let interleaved = UnsafeBufferPointer(start: channelData[0], count: frames * channelCount)
        mono = RealtimeAudioMath.monoFromInterleaved(Array(interleaved), channelCount: channelCount)
    } else {
        var planar: [[Float]] = []
        planar.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            planar.append(Array(UnsafeBufferPointer(start: channelData[channel], count: frames)))
        }
        mono = RealtimeAudioMath.monoFromPlanar(channels: planar)
    }

    let level = RealtimeAudioMath.rms(mono)
    let resampled = RealtimeAudioMath.resample(mono, from: sourceRate, to: RealtimeAudioMath.sampleRate)
    onChunk(RealtimeAudioMath.pcm16Data(fromFloatSamples: resampled))
    onLevel(Double(level))
}
