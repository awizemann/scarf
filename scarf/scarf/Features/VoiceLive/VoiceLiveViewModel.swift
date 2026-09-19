import Foundation
import Observation
import ScarfCore
import os

/// Drives `VoiceLiveView`: owns one realtime voice session at a time and
/// the audio engine behind it.
///
/// All session policy lives in ScarfCore (`VoiceLivePhaseReducer` for
/// transitions, `OpenAIRealtimeVoiceService` for the wire); this model
/// only routes audio side effects alongside the reducer's decisions and
/// accumulates transcripts for display.
///
/// v1 scope: the live session is STANDALONE — it talks to the realtime
/// endpoint directly and does not round-trip through Hermes' chat state,
/// so the transcripts shown here are display-only and never land in the
/// conversation. Pass 2 wires the relay backend behind the same
/// `RealtimeVoiceService` protocol.
@Observable
@MainActor
final class VoiceLiveViewModel {
    private(set) var phase: VoiceLivePhase = .idle
    /// Committed utterance blocks — one entry per finished user
    /// utterance / assistant speaking turn. Deltas append to the live
    /// tails only, so per-delta work never re-lays-out settled text.
    private(set) var userTranscriptBlocks: [String] = []
    private(set) var userTranscriptLive = ""
    private(set) var assistantTranscriptBlocks: [String] = []
    private(set) var assistantTranscriptLive = ""
    /// Live mic RMS (0…1) from the input tap — real level data, not a
    /// cosmetic animation.
    private(set) var micLevel: Double = 0

    private let serviceFactory: @MainActor @Sendable (ServerContext, RealtimeVoiceConfiguration) -> any RealtimeVoiceService
    private let context: ServerContext
    private var service: (any RealtimeVoiceService)?
    private var engine: VoiceLiveAudioEngine?
    private var eventTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.scarf", category: "VoiceLive")

    init(
        context: ServerContext,
        serviceFactory: @escaping @MainActor @Sendable (ServerContext, RealtimeVoiceConfiguration) -> any RealtimeVoiceService = VoiceLiveViewModel.openAIService
    ) {
        self.context = context
        self.serviceFactory = serviceFactory
    }

    /// Production wiring: mint over the server's transport, speak over
    /// the OpenAI realtime socket.
    private static func openAIService(context: ServerContext, configuration: RealtimeVoiceConfiguration) -> any RealtimeVoiceService {
        let minter = HermesHostRealtimeTokenMinter(
            transport: context.makeTransport(),
            hermesHome: context.paths.home
        )
        return OpenAIRealtimeVoiceService(
            configuration: configuration,
            minter: minter,
            socket: URLSessionRealtimeSocket()
        )
    }

    // MARK: - Lifecycle

    /// Start (or, from a terminal phase, restart) a session. Safe to
    /// call repeatedly from `onAppear`-style sites — an in-flight
    /// session is never restarted implicitly.
    func start() async {
        guard phase == .idle || phase.isTerminal else { return }

        releaseSession()
        phase = .connecting

        let configuration: RealtimeVoiceConfiguration
        do {
            configuration = try await Self.realtimeConfiguration(for: context)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fail(message)
            return
        }
        let service = serviceFactory(context, configuration)
        self.service = service

        // Pump before connecting: the service buffers events, and a
        // socket death during `start()` must land in the reducer, not
        // in a stream nobody is reading.
        let events = service.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handle(event)
            }
        }

        do {
            try await service.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("Voice session failed to start: \(message, privacy: .public)")
            fail(message)
            return
        }

        let audioEngine = VoiceLiveAudioEngine()
        do {
            try await audioEngine.start(
                onChunk: { chunk in
                    service.enqueueAudioChunk(chunk)
                },
                onLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.micLevel = level
                    }
                }
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("Audio engine failed: \(message, privacy: .public)")
            fail(message)
            await service.stop()
            return
        }
        engine = audioEngine
    }

    /// User-initiated end. Stops audio + transport and settles the UI.
    func stop() {
        guard !phase.isTerminal, phase != .idle else { return }
        phase = .ended
        micLevel = 0
        releaseSession()
    }

    // MARK: - Event routing

    private func handle(_ event: RealtimeVoiceEvent) async {
        let next = VoiceLivePhaseReducer.next(phase, after: event)
        // @Observable fires observers on every assignment, equal or not.
        // Transcript/audio deltas arrive at delta cadence and rarely move
        // the phase — skip the write so the view body doesn't re-evaluate
        // for a no-op.
        if next != phase {
            phase = next
        }

        switch event {
        case .outputAudioDelta(_, let data):
            await engine?.play(pcm16: data)

        case .userSpeechStarted, .responseCancelled:
            // Barge-in: the service already truncated server-side; cut
            // whatever is still queued locally.
            await engine?.cutPlayback()

        case .userTranscriptDelta(let delta):
            userTranscriptLive += delta

        case .userTranscriptCompleted(let final):
            commitUserTranscript(final.isEmpty ? userTranscriptLive : final)

        case .assistantTranscriptDelta(let delta):
            assistantTranscriptLive += delta

        case .outputItemStarted:
            // New speaking turn → settle the previous turn as its own
            // block so only the in-flight tail re-lays out per delta.
            commitAssistantTranscript()

        case .closed:
            // Terminal: the service finished its stream. Keep the
            // transcripts on screen; silence the mic meter.
            commitUserTranscript(userTranscriptLive)
            commitAssistantTranscript()
            micLevel = 0

        default:
            break
        }
    }

    private func commitUserTranscript(_ text: String) {
        let settled = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty else { return }
        userTranscriptBlocks.append(settled)
        userTranscriptLive = ""
    }

    private func commitAssistantTranscript() {
        let settled = assistantTranscriptLive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty else { return }
        assistantTranscriptBlocks.append(settled)
        assistantTranscriptLive = ""
    }

    /// True once any transcript content exists — drives the empty state.
    var hasTranscriptContent: Bool {
        !userTranscriptBlocks.isEmpty || !userTranscriptLive.isEmpty
            || !assistantTranscriptBlocks.isEmpty || !assistantTranscriptLive.isEmpty
    }

    // MARK: - Teardown

    private func fail(_ message: String) {
        phase = .failed(message)
        micLevel = 0
        releaseSession()
    }

    /// Drop references to the current session's service, engine, and
    /// pump, stopping both I/O halves. Transcripts stay as they were —
    /// they describe the session that just ended.
    private func releaseSession() {
        eventTask?.cancel()
        eventTask = nil

        let service = self.service
        let engine = self.engine
        self.service = nil
        self.engine = nil

        guard service != nil || engine != nil else { return }
        Task {
            await engine?.stop()
            await service?.stop()
        }
    }

    private static func realtimeConfiguration(for context: ServerContext) async throws -> RealtimeVoiceConfiguration {
        try await Task.detached(priority: .userInitiated) {
            let voice = HermesFileService(context: context).loadConfig().voice
            let mode = voice.voiceChatMode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mode.isEmpty && mode != "gpt-live" {
                throw RealtimeVoiceError.connectionFailed(
                    reason: "Hermes voice chat mode is set to \(mode), not gpt-live."
                )
            }
            let configuredModel = voice.gptLiveModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputVoice = voice.gptLiveVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            let instructions = voice.gptLiveInstructions.trimmingCharacters(in: .whitespacesAndNewlines)

            // The direct ephemeral-token path only serves the realtime
            // family — the gpt-live models are exclusive to
            // `/v1/live/sessions`, which rejects ephemeral tokens, so a
            // configured live-family id (including the `gpt_live.model`
            // default) falls back to the current realtime model until
            // the pass-2 relay backend lands.
            let model: String
            if configuredModel.isEmpty || configuredModel.hasPrefix("gpt-live") {
                model = "gpt-realtime-2.1"
            } else {
                model = configuredModel
            }

            return RealtimeVoiceConfiguration(
                model: model,
                voice: outputVoice.isEmpty ? "marin" : outputVoice,
                instructions: instructions
            )
        }.value
    }
}
