import Foundation

/// Integrated loudness per ITU-R BS.1770-4 / EBU R128 (K-weighting, 400 ms blocks, absolute and relative gating).
public enum Loudness {
    /// Integrated loudness in LUFS, or `nil` for silence.
    ///
    /// A mono signal is measured as it sounds on two speakers (dual-mono, +3 dB over a single channel), so the
    /// usual stereo targets (−16 LUFS for podcasts) apply to mono voice files too.
    public static func integrated(_ samples: [Float], sampleRate: Double, dualMono: Bool = true) -> Float? {
        guard !samples.isEmpty else { return nil }
        var stage1 = shelf(sampleRate: sampleRate)
        var stage2 = highPass(sampleRate: sampleRate)

        // Sum of squares per 100 ms step; a 400 ms block is four consecutive steps.
        let step = max(1, Int((sampleRate * 0.1).rounded()))
        var stepSums = [Double]()
        stepSums.reserveCapacity(samples.count / step + 1)
        var sum = 0.0
        var filled = 0
        for x in samples {
            let y = Double(stage2.process(stage1.process(x)))
            sum += y * y
            filled += 1
            if filled == step {
                stepSums.append(sum)
                sum = 0
                filled = 0
            }
        }

        var blocks = [Double]()
        if stepSums.count >= 4 {
            blocks.reserveCapacity(stepSums.count - 3)
            let blockLength = Double(4 * step)
            for start in 0...(stepSums.count - 4) {
                let total = stepSums[start] + stepSums[start + 1] + stepSums[start + 2] + stepSums[start + 3]
                blocks.append(total / blockLength)
            }
        } else {
            // Shorter than one block: measure the whole clip as a single block.
            let total = stepSums.reduce(0, +) + sum
            blocks.append(total / Double(samples.count))
        }

        let channelWeight = dualMono ? 2.0 : 1.0
        func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(channelWeight * meanSquare) }

        let aboveAbsolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = lufs(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return Float(lufs(gated.reduce(0, +) / Double(gated.count)))
    }

    /// Highest absolute sample value in dBFS (−∞ for silence).
    public static func peakDB(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for x in samples { peak = max(peak, abs(x)) }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    // K-weighting, designed for any sample rate (the same analog prototypes libebur128 uses).

    static func shelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: vh + vb * k / q + k * k, b1: 2 * (k * k - vh), b2: vh - vb * k / q + k * k,
                      a0: a0, a1: 2 * (k * k - 1), a2: 1 - k / q + k * k)
    }

    static func highPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        // BS.1770 leaves the numerator un-normalised ([1, −2, 1]), so pre-scale it by a0.
        return Biquad(b0: a0, b1: -2 * a0, b2: a0, a0: a0, a1: 2 * (k * k - 1), a2: 1 - k / q + k * k)
    }
}
