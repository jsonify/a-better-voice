import Foundation

/// What the enhancer does. Every amount runs from 0 (off) to 1 (strongest).
public struct EnhancementSettings: Equatable, Codable, Sendable {
    /// On-device AI voice isolation (Apple's machine-learning model): removes changing background sounds, music
    /// and echo. 0 = off; otherwise how much of the isolated voice to use versus the original.
    public var voiceIsolation: Float
    /// Removes hiss, hum and room tone learned from the pauses in the recording.
    public var noiseReduction: Float
    /// Removes rumble, handling noise and plosive thumps below about 80 Hz.
    public var rumbleFilter: Bool
    /// Clears mud around 250 Hz and adds presence (4 kHz) and air (10 kHz).
    public var clarity: Float
    /// Tames harsh "s" and "sh" sounds.
    public var deEss: Float
    /// Evens out loud and quiet passages.
    public var leveling: Float
    /// Brings the result to `targetLoudness`; when off, the original loudness is kept.
    public var normalize: Bool
    /// Integrated loudness to aim for, in LUFS.
    public var targetLoudness: Float

    public init(noiseReduction: Float, rumbleFilter: Bool, clarity: Float, deEss: Float, leveling: Float,
                normalize: Bool = true, targetLoudness: Float = -16, voiceIsolation: Float = 0) {
        self.voiceIsolation = voiceIsolation
        self.noiseReduction = noiseReduction
        self.rumbleFilter = rumbleFilter
        self.clarity = clarity
        self.deEss = deEss
        self.leveling = leveling
        self.normalize = normalize
        self.targetLoudness = targetLoudness
    }

    public static let light = EnhancementSettings(noiseReduction: 0.3, rumbleFilter: true, clarity: 0.3,
                                                  deEss: 0.3, leveling: 0.3)
    public static let balanced = EnhancementSettings(noiseReduction: 0.55, rumbleFilter: true, clarity: 0.5,
                                                     deEss: 0.5, leveling: 0.55)
    public static let strong = EnhancementSettings(noiseReduction: 0.85, rumbleFilter: true, clarity: 0.7,
                                                   deEss: 0.7, leveling: 0.8)
}

public enum EnhancementPreset: String, CaseIterable, Identifiable, Sendable {
    case light, balanced, strong, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        case .custom: return "Custom"
        }
    }

    /// The settings for this preset, keeping the loudness and AI voice isolation choices of `current`, which the
    /// presets leave alone. `nil` for `.custom`.
    public func settings(keepingChoicesOf current: EnhancementSettings) -> EnhancementSettings? {
        var settings: EnhancementSettings
        switch self {
        case .light: settings = .light
        case .balanced: settings = .balanced
        case .strong: settings = .strong
        case .custom: return nil
        }
        settings.normalize = current.normalize
        settings.targetLoudness = current.targetLoudness
        settings.voiceIsolation = current.voiceIsolation
        return settings
    }

    /// The preset whose processing matches `settings`, or `.custom`.
    public static func matching(_ settings: EnhancementSettings) -> EnhancementPreset {
        for preset in [EnhancementPreset.light, .balanced, .strong]
        where preset.settings(keepingChoicesOf: settings) == settings {
            return preset
        }
        return .custom
    }
}

/// Common loudness targets.
public enum LoudnessTarget: Float, CaseIterable, Identifiable, Sendable {
    case streaming = -14
    case podcast = -16
    case gentle = -18
    case broadcast = -23

    public var id: Float { rawValue }

    public var title: String {
        switch self {
        case .streaming: return "−14 LUFS · YouTube, Spotify"
        case .podcast: return "−16 LUFS · Podcasts"
        case .gentle: return "−18 LUFS · Audiobooks, gentle"
        case .broadcast: return "−23 LUFS · Broadcast (EBU R128)"
        }
    }
}

public struct EnhancementReport: Equatable, Sendable {
    public var inputLoudness: Float?
    public var outputLoudness: Float?
    public var inputPeakDB: Float
    public var outputPeakDB: Float
}

public struct EnhancementResult: Sendable {
    public var samples: [Float]
    public var report: EnhancementReport
}

/// The voice-enhancement chain:
/// rumble filter → AI voice isolation (optional) → noise reduction → level to a reference → clarity EQ → de-esser → leveling compressor →
/// loudness normalisation → peak limiter.
public enum VoiceEnhancer {
    /// Loudness the level-dependent stages (de-esser, compressor) are tuned for.
    static let referenceLoudness: Float = -23
    /// Sample-peak ceiling; leaves headroom for inter-sample peaks and AAC encoding overshoot.
    public static let peakCeilingDB: Float = -1.5

    /// Processes mono `samples`. Throws `CancellationError` if the surrounding task is cancelled.
    /// `progress` receives values from 0 to 1.
    public static func process(_ samples: [Float], sampleRate: Double, settings: EnhancementSettings,
                               progress: ((Double) -> Void)? = nil) throws -> EnhancementResult {
        var reported = 0.0
        func report(_ value: Double) {
            // Never step backwards, even by a rounding error.
            reported = min(1, max(reported, value))
            progress?(reported)
        }
        let inputLoudness = Loudness.integrated(samples, sampleRate: sampleRate)
        let inputPeak = Loudness.peakDB(samples)
        var x = samples
        report(0.02)

        if settings.rumbleFilter {
            // Fourth-order Butterworth high-pass at 80 Hz.
            for q in [0.5412, 1.3066] {
                var filter = Biquad.highPass(frequency: 80, q: q, sampleRate: sampleRate)
                filter.process(&x)
            }
        }
        try Task.checkCancellation()
        report(0.05)

        var noiseStageStart = 0.05
        if settings.voiceIsolation > 0 {
            #if canImport(AVFoundation)
            x = try VoiceIsolator.process(x, sampleRate: sampleRate, mix: settings.voiceIsolation) {
                report(0.05 + 0.4 * $0)
            }
            noiseStageStart = 0.45
            #else
            throw VoiceIsolationError.unavailable
            #endif
        }

        if settings.noiseReduction > 0 {
            let reducer = NoiseReducer(amount: min(1, settings.noiseReduction))
            let span = 0.7 - noiseStageStart
            x = try reducer.process(x, sampleRate: sampleRate) { report(noiseStageStart + span * $0) }
        }
        report(0.7)

        if let level = Loudness.integrated(x, sampleRate: sampleRate) {
            applyGain(&x, db: min(40, referenceLoudness - level))
        }
        try Task.checkCancellation()

        if settings.clarity > 0 {
            let c = Double(min(1, settings.clarity))
            var filters = [
                Biquad.peaking(frequency: 250, q: 1.0, gainDB: -3 * c, sampleRate: sampleRate),
                Biquad.peaking(frequency: 4_000, q: 0.8, gainDB: 4 * c, sampleRate: sampleRate),
                Biquad.highShelf(frequency: 10_000, gainDB: 3 * c, sampleRate: sampleRate),
            ]
            for index in filters.indices { filters[index].process(&x) }
        }
        report(0.75)

        if settings.deEss > 0 {
            DeEsser(amount: min(1, settings.deEss)).process(&x, sampleRate: sampleRate)
        }
        try Task.checkCancellation()
        report(0.82)

        if settings.leveling > 0 {
            let l = min(1, settings.leveling)
            Compressor(thresholdDB: -20 - 10 * l, ratio: 1.5 + 3 * l).process(&x, sampleRate: sampleRate)
        }
        try Task.checkCancellation()
        report(0.88)

        let target = settings.normalize ? settings.targetLoudness : (inputLoudness ?? referenceLoudness)
        let limiter = Limiter(ceilingDB: peakCeilingDB)
        // Limiting lowers the loudness a little; a second pass makes up most of the difference.
        for _ in 0..<2 {
            guard let level = Loudness.integrated(x, sampleRate: sampleRate) else { break }
            let correction = target - level
            if abs(correction) < 0.2 { break }
            applyGain(&x, db: min(40, correction))
            limiter.process(&x, sampleRate: sampleRate)
            try Task.checkCancellation()
        }
        limiter.process(&x, sampleRate: sampleRate)
        report(1)

        return EnhancementResult(
            samples: x,
            report: EnhancementReport(inputLoudness: inputLoudness,
                                      outputLoudness: Loudness.integrated(x, sampleRate: sampleRate),
                                      inputPeakDB: inputPeak,
                                      outputPeakDB: Loudness.peakDB(x)))
    }

    static func applyGain(_ buffer: inout [Float], db: Float) {
        guard db != 0, db.isFinite else { return }
        let gain = amplitude(fromDecibels: db)
        for index in buffer.indices { buffer[index] *= gain }
    }
}

public enum Waveform {
    /// Peak absolute value of each of `buckets` equal slices of `samples`, for drawing.
    public static func peaks(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        let perBucket = Double(samples.count) / Double(buckets)
        for bucket in 0..<buckets {
            let start = Int(Double(bucket) * perBucket)
            let end = min(samples.count, max(start + 1, Int(Double(bucket + 1) * perBucket)))
            var peak: Float = 0
            if start < end {
                for i in start..<end { peak = max(peak, abs(samples[i])) }
            }
            result[bucket] = peak
        }
        return result
    }
}
