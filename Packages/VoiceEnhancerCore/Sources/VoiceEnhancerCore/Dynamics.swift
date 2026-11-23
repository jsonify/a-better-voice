import Foundation

@inline(__always)
func decibels(fromPower power: Float) -> Float { 10 * log10(max(power, 1e-12)) }

@inline(__always)
func decibels(fromAmplitude amplitude: Float) -> Float { 20 * log10(max(amplitude, 1e-9)) }

@inline(__always)
func amplitude(fromDecibels db: Float) -> Float { pow(10, db / 20) }

/// Coefficient of a one-pole smoother with the given time constant.
@inline(__always)
func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Float {
    Float(exp(-1 / (max(seconds, 1e-5) * sampleRate)))
}

/// Feed-forward RMS compressor with a soft knee, so loud and quiet passages end up closer together.
struct Compressor {
    var thresholdDB: Float
    var ratio: Float
    var kneeDB: Float = 8
    var attack: Double = 0.008
    var release: Double = 0.15

    /// Static curve: how many dB of gain change an input level (dB) gets. Always ≤ 0.
    func gainChange(forLevel level: Float) -> Float {
        let over = level - thresholdDB
        let slope = 1 / ratio - 1
        if 2 * over < -kneeDB {
            return 0
        } else if kneeDB > 0 && 2 * abs(over) <= kneeDB {
            let x = over + kneeDB / 2
            return slope * x * x / (2 * kneeDB)
        } else {
            return slope * over
        }
    }

    func process(_ buffer: inout [Float], sampleRate: Double) {
        guard ratio > 1 else { return }
        let detector = smoothingCoefficient(seconds: 0.005, sampleRate: sampleRate)
        let attackCoefficient = smoothingCoefficient(seconds: attack, sampleRate: sampleRate)
        let releaseCoefficient = smoothingCoefficient(seconds: release, sampleRate: sampleRate)
        var meanSquare: Float = 0
        var smoothedGain: Float = 0
        for i in buffer.indices {
            let x = buffer[i]
            meanSquare = detector * meanSquare + (1 - detector) * x * x
            let target = gainChange(forLevel: decibels(fromPower: meanSquare))
            let coefficient = target < smoothedGain ? attackCoefficient : releaseCoefficient
            smoothedGain = coefficient * smoothedGain + (1 - coefficient) * target
            buffer[i] = x * amplitude(fromDecibels: smoothedGain)
        }
    }
}

/// Dynamic de-esser: turns down the 5–9 kHz band only while a sibilant ("s", "sh", "t") dominates the voice.
struct DeEsser {
    /// 0 = off, 1 = strongest.
    var amount: Float
    static let centreFrequency = 6_500.0

    static func isAvailable(sampleRate: Double) -> Bool {
        Biquad.canDesign(frequency: centreFrequency * 1.3, sampleRate: sampleRate)
    }

    func process(_ buffer: inout [Float], sampleRate: Double) {
        guard amount > 0, Self.isAvailable(sampleRate: sampleRate) else { return }
        var band = Biquad.bandPass(frequency: Self.centreFrequency, q: 1.2, sampleRate: sampleRate)
        let detector = smoothingCoefficient(seconds: 0.004, sampleRate: sampleRate)
        let attackCoefficient = smoothingCoefficient(seconds: 0.001, sampleRate: sampleRate)
        let releaseCoefficient = smoothingCoefficient(seconds: 0.06, sampleRate: sampleRate)
        let maxReduction = 4 + 8 * amount
        // How far below the full-band level the sibilant band may sit before it is reduced.
        let margin = 4 + 6 * amount
        var bandPower: Float = 0
        var fullPower: Float = 0
        var reduction: Float = 0
        for i in buffer.indices {
            let x = buffer[i]
            let sibilant = band.process(x)
            bandPower = detector * bandPower + (1 - detector) * sibilant * sibilant
            fullPower = detector * fullPower + (1 - detector) * x * x
            let bandDB = decibels(fromPower: bandPower)
            var target: Float = 0
            if bandDB > -60 {
                let excess = bandDB - (decibels(fromPower: fullPower) - margin)
                target = min(maxReduction, max(0, excess * 0.8))
            }
            let coefficient = target > reduction ? attackCoefficient : releaseCoefficient
            reduction = coefficient * reduction + (1 - coefficient) * target
            let gain = amplitude(fromDecibels: -reduction)
            buffer[i] = x + (gain - 1) * sibilant
        }
    }
}

/// Look-ahead brick-wall peak limiter. Processing is offline, so the look-ahead is simply a centred window.
struct Limiter {
    var ceilingDB: Float = -1.5
    var lookahead: Double = 0.005
    var release: Double = 0.08

    func process(_ buffer: inout [Float], sampleRate: Double) {
        let count = buffer.count
        guard count > 0 else { return }
        let ceiling = amplitude(fromDecibels: ceilingDB)
        // Gain each sample needs on its own.
        var required = [Float](repeating: 1, count: count)
        var needsLimiting = false
        for i in 0..<count {
            let peak = abs(buffer[i])
            if peak > ceiling {
                required[i] = ceiling / peak
                needsLimiting = true
            }
        }
        guard needsLimiting else { return }
        let radius = max(1, Int(lookahead * sampleRate))
        // Taking the minimum over ±radius and then averaging over ±radius/2 keeps every sample at or under the
        // ceiling while turning the gain changes into smooth ramps.
        var gain = Self.slidingMinimum(required, radius: radius)
        let releaseCoefficient = smoothingCoefficient(seconds: release, sampleRate: sampleRate)
        for i in 1..<count {
            let recovered = gain[i - 1] + (1 - gain[i - 1]) * (1 - releaseCoefficient)
            gain[i] = min(gain[i], recovered)
        }
        gain = Self.movingAverage(gain, radius: radius / 2)
        for i in 0..<count {
            buffer[i] = max(-ceiling, min(ceiling, buffer[i] * gain[i]))
        }
    }

    /// Minimum of `values[i - radius ... i + radius]` for every `i`, in O(n) with a monotonic queue.
    static func slidingMinimum(_ values: [Float], radius: Int) -> [Float] {
        let count = values.count
        var result = [Float](repeating: 0, count: count)
        var queue = [Int](repeating: 0, count: count)
        var head = 0
        var tail = 0
        for j in 0..<(count + radius) {
            if j < count {
                while tail > head && values[queue[tail - 1]] >= values[j] { tail -= 1 }
                queue[tail] = j
                tail += 1
            }
            let i = j - radius
            if i >= 0 {
                while queue[head] < i - radius { head += 1 }
                result[i] = values[queue[head]]
            }
        }
        return result
    }

    /// Mean of `values[i - radius ... i + radius]` (clipped at the edges).
    static func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0 else { return values }
        let count = values.count
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + Double(values[i]) }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let low = max(0, i - radius)
            let high = min(count - 1, i + radius)
            result[i] = Float((prefix[high + 1] - prefix[low]) / Double(high - low + 1))
        }
        return result
    }
}
