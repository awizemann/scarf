import Foundation

/// Pure DSP helpers for the realtime voice path: PCM16 ↔ Float32,
/// channel mixdown, and rate conversion. No AVFoundation types — the
/// app-target audio engine adapts `AVAudioPCMBuffer` to arrays and
/// calls into these, which keeps every sample-touching operation
/// unit-testable in the package.
public enum RealtimeAudioMath {
    /// The realtime API's fixed audio rate, both directions.
    public static let sampleRate: Double = 24_000

    // MARK: - PCM16 ↔ Float32 (explicit little-endian)

    /// Decode raw little-endian PCM16 bytes to normalized floats
    /// (-1…~1). A trailing odd byte (torn frame) is dropped.
    public static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let bytes = [UInt8](data)
        let sampleCount = bytes.count / 2
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let lo = UInt16(bytes[index * 2])
            let hi = UInt16(bytes[index * 2 + 1])
            let raw = Int16(bitPattern: (hi << 8) | lo)
            samples.append(Float(raw) / 32_768.0)
        }
        return samples
    }

    /// Encode normalized floats to raw little-endian PCM16. Values are
    /// clamped to full scale before quantization.
    public static func pcm16Data(fromFloatSamples samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = min(1.0, max(-1.0, sample))
            let raw = Int16(clamped * 32_767.0)
            let bits = UInt16(bitPattern: raw)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    // MARK: - Channel mixdown

    /// Average planar (deinterleaved) channel data — one array per
    /// channel, all of equal frame count — to a single mono array.
    public static func monoFromPlanar(channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        var mono = [Float](repeating: 0, count: first.count)
        for channel in channels {
            for (index, value) in channel.enumerated() where index < mono.count {
                mono[index] += value
            }
        }
        let gain = 1.0 / Float(channels.count)
        for index in mono.indices {
            mono[index] *= gain
        }
        return mono
    }

    /// Average interleaved multi-channel samples (`[L0, R0, L1, R1, …]`)
    /// down to mono. A trailing incomplete frame is dropped.
    public static func monoFromInterleaved(_ samples: [Float], channelCount: Int) -> [Float] {
        guard channelCount > 1 else { return samples }
        let frameCount = samples.count / channelCount
        var mono = [Float]()
        mono.reserveCapacity(frameCount)
        let gain = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += samples[frame * channelCount + channel]
            }
            mono.append(sum * gain)
        }
        return mono
    }

    // MARK: - Rate conversion

    /// Linear-interpolation resampler. Exact (pure sample selection)
    /// whenever `sourceRate / targetRate` is an integer, which covers
    /// the common 48 kHz → 24 kHz Mac input path; fractional ratios
    /// interpolate. Equal rates return the input untouched.
    public static func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard sourceRate > 0, targetRate > 0, !samples.isEmpty else { return [] }
        guard sourceRate != targetRate else { return samples }

        let ratio = sourceRate / targetRate
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return [] }
        guard ratio != round(ratio) || ratio < 1 else {
            // Integer downsample: straight selection, no filtering.
            let step = Int(ratio)
            return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        }

        var output = [Float]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let upper = min(lower + 1, samples.count - 1)
            let base = samples[lower]
            let next = samples[upper]
            output.append(base + (next - base) * fraction)
        }
        return output
    }

    // MARK: - Levels

    /// Root-mean-square of a window, 0…1 (full-scale sine ≈ 0.707).
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return Float(sqrt(sum / Double(samples.count)))
    }
}
