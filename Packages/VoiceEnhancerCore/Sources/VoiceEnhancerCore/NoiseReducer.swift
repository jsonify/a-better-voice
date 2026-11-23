import Foundation

/// Spectral noise reduction for speech.
///
/// The noise profile is learned from the recording itself: the quietest frames (the pauses between words) are
/// averaged into a per-frequency noise power estimate. Each frame is then attenuated bin by bin where its power is
/// close to that estimate, with time and frequency smoothing to avoid the "musical noise" warble of plain spectral
/// subtraction.
struct NoiseReducer {
    /// 0 = off, 1 = strongest.
    var amount: Float

    /// Share of the (non-silent) frames treated as noise-only when learning the profile.
    static let noiseFrameShare = 0.12

    /// Maximum attenuation in dB for a given amount.
    static func maxReductionDB(amount: Float) -> Float { 6 + 18 * amount }

    static func fftSize(sampleRate: Double) -> Int {
        // About 43 ms: long enough to resolve voice harmonics, short enough to follow speech.
        var size = 256
        while Double(size) < sampleRate * 0.043 { size *= 2 }
        return size
    }

    func process(_ input: [Float], sampleRate: Double, progress: (Double) -> Void) throws -> [Float] {
        guard amount > 0, input.count > 0 else { return input }
        let n = Self.fftSize(sampleRate: sampleRate)
        let hop = n / 4
        let bins = n / 2 + 1
        let fft = FFT(size: n)
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }

        // Pad by a full frame on both sides so every input sample is covered by four overlapping frames.
        var padded = [Float](repeating: 0, count: n)
        padded.reserveCapacity(input.count + 2 * n + hop)
        padded.append(contentsOf: input)
        padded.append(contentsOf: [Float](repeating: 0, count: n + hop - (input.count % hop)))
        let frameCount = (padded.count - n) / hop + 1

        // Pass 1: find the quietest non-silent frames and average their power spectra.
        var frameEnergy = [(index: Int, energy: Float)]()
        frameEnergy.reserveCapacity(frameCount)
        padded.withUnsafeBufferPointer { samples in
            for frame in 0..<frameCount {
                let start = frame * hop
                var sum: Float = 0
                for i in 0..<n { sum += samples[start + i] * samples[start + i] }
                frameEnergy.append((index: frame, energy: sum / Float(n)))
            }
        }
        let audible = frameEnergy.filter { $0.energy > 1e-12 }
        guard !audible.isEmpty else { return input }
        let quietest = audible.sorted { $0.energy < $1.energy }
            .prefix(max(1, Int(Double(audible.count) * Self.noiseFrameShare)))

        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        var noise = [Float](repeating: 0, count: bins)
        for entry in quietest {
            let start = entry.index * hop
            for i in 0..<n {
                real[i] = padded[start + i] * window[i]
                imag[i] = 0
            }
            fft.forward(real: &real, imag: &imag)
            for k in 0..<bins { noise[k] += real[k] * real[k] + imag[k] * imag[k] }
        }
        let frames = Float(quietest.count)
        for k in 0..<bins { noise[k] /= frames }
        // Smooth the profile across frequency so a single unlucky bin doesn't punch a hole in the voice.
        noise = Self.smoothAcrossFrequency(noise)

        // Pass 2: attenuate each frame and overlap-add it back.
        let gainFloor: Float = pow(10, -Self.maxReductionDB(amount: amount) / 20)
        let overSubtraction = 1.5 + 3 * amount
        let decay: Float = 0.6 // per hop, how slowly a bin closes again after speech
        var previousGain = [Float](repeating: 1, count: bins)
        var gain = [Float](repeating: 1, count: bins)
        var output = [Float](repeating: 0, count: padded.count)
        var windowSum = [Float](repeating: 0, count: padded.count)

        for frame in 0..<frameCount {
            if frame % 256 == 0 {
                try Task.checkCancellation()
                progress(Double(frame) / Double(frameCount))
            }
            let start = frame * hop
            for i in 0..<n {
                real[i] = padded[start + i] * window[i]
                imag[i] = 0
            }
            fft.forward(real: &real, imag: &imag)

            for k in 0..<bins {
                let power = real[k] * real[k] + imag[k] * imag[k]
                let raw: Float
                if power <= 0 {
                    raw = gainFloor
                } else {
                    raw = max(gainFloor, sqrt(max(0, 1 - overSubtraction * noise[k] / power)))
                }
                // Open instantly for speech onsets, close gradually afterwards.
                gain[k] = raw >= previousGain[k] ? raw : previousGain[k] * decay + raw * (1 - decay)
            }
            previousGain = gain
            let smoothed = Self.smoothAcrossFrequency(gain)

            for k in 0..<bins {
                let g = smoothed[k]
                real[k] *= g
                imag[k] *= g
                if k > 0 && k < n / 2 {
                    real[n - k] *= g
                    imag[n - k] *= g
                }
            }
            fft.inverse(real: &real, imag: &imag)
            for i in 0..<n {
                output[start + i] += real[i] * window[i]
                windowSum[start + i] += window[i] * window[i]
            }
        }

        var result = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            let sum = windowSum[i + n]
            result[i] = sum > 1e-6 ? output[i + n] / sum : 0
        }
        progress(1)
        return result
    }

    /// Three-tap [¼ ½ ¼] smoothing across neighbouring bins.
    static func smoothAcrossFrequency(_ values: [Float]) -> [Float] {
        guard values.count > 2 else { return values }
        var smoothed = values
        for k in 1..<(values.count - 1) {
            smoothed[k] = 0.25 * values[k - 1] + 0.5 * values[k] + 0.25 * values[k + 1]
        }
        return smoothed
    }
}
