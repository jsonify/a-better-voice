import Foundation

/// A second-order IIR filter (transposed direct form II) with the RBJ "Audio EQ Cookbook" designs.
public struct Biquad: Sendable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    /// Coefficients are normalised by `a0`.
    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// A filter that passes the signal through unchanged.
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let input = Double(x)
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return Float(output)
    }

    public mutating func process(_ buffer: inout [Float]) {
        for index in buffer.indices {
            buffer[index] = process(buffer[index])
        }
    }

    /// Linear magnitude response at `frequency`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        return sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
    }

    // MARK: - Designs

    /// Whether a filter centred on `frequency` can be realised at `sampleRate`.
    public static func canDesign(frequency: Double, sampleRate: Double) -> Bool {
        frequency > 0 && frequency < 0.45 * sampleRate
    }

    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        guard canDesign(frequency: frequency, sampleRate: sampleRate) else { return .identity }
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        return Biquad(b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
                      a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        guard canDesign(frequency: frequency, sampleRate: sampleRate) else { return .identity }
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        return Biquad(b0: (1 - cosw) / 2, b1: 1 - cosw, b2: (1 - cosw) / 2,
                      a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    /// Band-pass with 0 dB gain at the centre frequency.
    public static func bandPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        guard canDesign(frequency: frequency, sampleRate: sampleRate) else {
            return Biquad(b0: 0, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)
        }
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        return Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        guard canDesign(frequency: frequency, sampleRate: sampleRate), gainDB != 0 else { return .identity }
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        let a = pow(10, gainDB / 40)
        return Biquad(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    /// High shelf with a shelf slope of 1.
    public static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        guard canDesign(frequency: frequency, sampleRate: sampleRate), gainDB != 0 else { return .identity }
        let w = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w)
        let a = pow(10, gainDB / 40)
        let alpha = sin(w) / 2 * sqrt(2.0)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha),
                      b1: -2 * a * ((a - 1) + (a + 1) * cosw),
                      b2: a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha),
                      a0: (a + 1) - (a - 1) * cosw + twoSqrtAAlpha,
                      a1: 2 * ((a - 1) - (a + 1) * cosw),
                      a2: (a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
    }

    private static func terms(_ frequency: Double, _ q: Double, _ sampleRate: Double) -> (cosw: Double, alpha: Double) {
        let w = 2 * Double.pi * frequency / sampleRate
        return (cos(w), sin(w) / (2 * q))
    }
}
