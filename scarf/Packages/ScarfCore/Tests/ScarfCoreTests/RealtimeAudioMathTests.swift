import Testing
import Foundation
@testable import ScarfCore

/// The pure half of the live-voice audio path: PCM16 little-endian
/// coding, channel mixdown, rate conversion (the 48 kHz hardware →
/// 24 kHz realtime path above all), and level estimation. Synthetic
/// samples only — these functions never see AVFoundation.
@Suite struct RealtimeAudioMathTests {

    // MARK: - PCM16 ↔ Float32

    @Test func pcm16DecodeIsLittleEndian() {
        // Raw bytes 0x02,0x01 → Int16 0x0102 = 258.
        let samples = RealtimeAudioMath.floatSamples(fromPCM16: Data([0x02, 0x01]))
        #expect(samples == [Float(258) / 32_768.0])
    }

    @Test func pcm16NegativeValuesDecode() {
        // Raw bytes 0x00,0x80 → Int16 0x8000 = -32768.
        let samples = RealtimeAudioMath.floatSamples(fromPCM16: Data([0x00, 0x80]))
        #expect(samples == [-1.0])
    }

    @Test func pcm16DecodeDropsTornTrailingByte() {
        let samples = RealtimeAudioMath.floatSamples(fromPCM16: Data([0x00, 0x00, 0xFF]))
        #expect(samples.count == 1)
    }

    @Test func pcm16RoundTripPreservesSamples() {
        let original: [Float] = [0, 0.25, -0.25, 0.9, -0.9, 0.001]
        let data = RealtimeAudioMath.pcm16Data(fromFloatSamples: original)
        let decoded = RealtimeAudioMath.floatSamples(fromPCM16: data)
        #expect(decoded.count == original.count)
        for (a, b) in zip(original, decoded) {
            #expect(abs(a - b) < 0.001)
        }
    }

    @Test func pcm16EncodeClampsOutOfRangeSamples() {
        let data = RealtimeAudioMath.pcm16Data(fromFloatSamples: [2.0, -2.0])
        let samples = RealtimeAudioMath.floatSamples(fromPCM16: data)
        #expect(samples[0] <= 1.0)
        #expect(samples[1] >= -1.0)
    }

    // MARK: - Mixdown

    @Test func interleavedStereoAveragesChannels() {
        // Frames: [1, 0] → 0.5, [0.5, -0.5] → 0.0
        let mono = RealtimeAudioMath.monoFromInterleaved([1, 0, 0.5, -0.5], channelCount: 2)
        #expect(mono.count == 2)
        #expect(abs(mono[0] - 0.5) < 1e-6)
        #expect(abs(mono[1]) < 1e-6)
    }

    @Test func interleavedMonoIsUnchanged() {
        #expect(RealtimeAudioMath.monoFromInterleaved([0.1, -0.2], channelCount: 1) == [0.1, -0.2])
    }

    @Test func interleavedTrailingIncompleteFrameDropped() {
        let mono = RealtimeAudioMath.monoFromInterleaved([1, 1, 0.4], channelCount: 2)
        #expect(mono == [1.0])
    }

    @Test func planarChannelsAverage() {
        let mono = RealtimeAudioMath.monoFromPlanar(channels: [[1, 0.5], [0, 0.5]])
        #expect(mono.count == 2)
        #expect(abs(mono[0] - 0.5) < 1e-6)
        #expect(abs(mono[1] - 0.5) < 1e-6)
    }

    @Test func singlePlanarChannelPassesThrough() {
        #expect(RealtimeAudioMath.monoFromPlanar(channels: [[0.3, -0.3]]) == [0.3, -0.3])
    }

    // MARK: - Resampling

    @Test func integerDownsampleFrom48kTo24kSelectsExactSamples() {
        // 6 frames @ 48 kHz → 3 frames @ 24 kHz, taking every 2nd
        // sample verbatim (positions 0, 2, 4).
        let input: [Float] = [1, -1, 0.5, -0.5, 0.25, -0.25]
        let output = RealtimeAudioMath.resample(input, from: 48_000, to: 24_000)
        #expect(output == [1, 0.5, 0.25])
    }

    @Test func equalRatesAreIdentity() {
        let input: [Float] = [0.1, -0.4, 0.7]
        #expect(RealtimeAudioMath.resample(input, from: 24_000, to: 24_000) == input)
    }

    @Test func upsamplingInterpolatesBetweenSamples() {
        // 24 kHz → 48 kHz: 2 samples become 4; the inserted points land
        // midway between neighbors.
        let output = RealtimeAudioMath.resample([0, 1], from: 24_000, to: 48_000)
        #expect(output.count == 4)
        #expect(abs(output[0]) < 1e-6)
        #expect(abs(output[1] - 0.5) < 1e-6)
        #expect(abs(output[2] - 1.0) < 1e-6)
        #expect(abs(output[3] - 1.0) < 1e-6)
    }

    @Test func fractionalRatioProducesBoundedOutput() {
        // 44.1 kHz hardware → 24 kHz realtime: length is floor(n * 24/44.1).
        let input = (0..<4410).map { Float(sin(Double($0) * 0.05)) }
        let output = RealtimeAudioMath.resample(input, from: 44_100, to: 24_000)
        #expect(output.count == 2_400)
        for sample in output {
            #expect(sample.isFinite)
            #expect(abs(sample) <= 1.0)
        }
    }

    @Test func emptyAndDegenerateInputsAreSafe() {
        #expect(RealtimeAudioMath.resample([], from: 48_000, to: 24_000).isEmpty)
        #expect(RealtimeAudioMath.resample([0.5], from: 48_000, to: 24_000).isEmpty)
        #expect(RealtimeAudioMath.resample([0.5], from: 0, to: 24_000).isEmpty)
    }

    // MARK: - Levels

    @Test func rmsOfAlternatingHalfScaleIsHalf() {
        let level = RealtimeAudioMath.rms([0.5, -0.5, 0.5, -0.5])
        #expect(abs(level - 0.5) < 1e-6)
    }

    @Test func rmsOfSilenceAndEmptyIsZero() {
        #expect(RealtimeAudioMath.rms([0, 0, 0]) == 0)
        #expect(RealtimeAudioMath.rms([]) == 0)
    }
}
