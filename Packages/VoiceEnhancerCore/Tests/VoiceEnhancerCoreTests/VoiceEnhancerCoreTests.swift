import XCTest
@testable import VoiceEnhancerCore

/// Deterministic noise so tests never flake.
struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Roughly Gaussian (sum of uniforms), unit variance.
    mutating func next() -> Float {
        var sum: Float = 0
        for _ in 0..<12 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            sum += Float(state >> 40) / Float(1 << 24)
        }
        return sum - 6
    }
}

func sine(frequency: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

func rmsDB(_ samples: ArraySlice<Float>) -> Float {
    var sum: Double = 0
    for x in samples { sum += Double(x) * Double(x) }
    return Float(10 * log10(max(sum / Double(max(1, samples.count)), 1e-20)))
}

/// A crude "voice": harmonic bursts of 0.4 s separated by 0.3 s pauses, plus steady hiss.
func syntheticRecording(sampleRate: Double, seconds: Double, hiss: Float) -> (mixed: [Float], voice: [Float]) {
    var noise = SeededNoise(seed: 7)
    let count = Int(seconds * sampleRate)
    var voice = [Float](repeating: 0, count: count)
    var mixed = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let t = Double(i) / sampleRate
        var v = 0.0
        if t.truncatingRemainder(dividingBy: 0.7) < 0.4 {
            for harmonic in 1...14 { v += sin(2 * Double.pi * 140 * Double(harmonic) * t) / Double(harmonic) }
        }
        voice[i] = Float(0.2 * v)
        mixed[i] = voice[i] + hiss * noise.next()
    }
    return (mixed, voice)
}

/// Indices of samples well inside the pauses of `syntheticRecording`.
func pauseIndices(count: Int, sampleRate: Double) -> [Int] {
    (0..<count).filter {
        let phase = (Double($0) / sampleRate).truncatingRemainder(dividingBy: 0.7)
        return phase > 0.5 && phase < 0.65
    }
}

final class BiquadTests: XCTestCase {
    func testHighPassAttenuatesBelowCutoff() {
        let filter = Biquad.highPass(frequency: 80, q: 0.7071, sampleRate: 48_000)
        XCTAssertLessThan(filter.magnitude(at: 20, sampleRate: 48_000), 0.1)
        XCTAssertEqual(filter.magnitude(at: 1_000, sampleRate: 48_000), 1, accuracy: 0.01)
        XCTAssertEqual(filter.magnitude(at: 80, sampleRate: 48_000), 0.7071, accuracy: 0.01)
    }

    func testPeakingGainAtCentre() {
        let filter = Biquad.peaking(frequency: 4_000, q: 0.8, gainDB: 4, sampleRate: 48_000)
        let db = 20 * log10(filter.magnitude(at: 4_000, sampleRate: 48_000))
        XCTAssertEqual(db, 4, accuracy: 0.05)
    }

    func testHighShelfGain() {
        let filter = Biquad.highShelf(frequency: 10_000, gainDB: 3, sampleRate: 48_000)
        XCTAssertEqual(20 * log10(filter.magnitude(at: 20_000, sampleRate: 48_000)), 3, accuracy: 0.3)
        XCTAssertEqual(20 * log10(filter.magnitude(at: 200, sampleRate: 48_000)), 0, accuracy: 0.05)
    }

    func testUnrealisableFrequencyIsIdentity() {
        let filter = Biquad.highShelf(frequency: 10_000, gainDB: 3, sampleRate: 16_000)
        XCTAssertEqual(filter.magnitude(at: 7_000, sampleRate: 16_000), 1, accuracy: 1e-9)
    }
}

final class FFTTests: XCTestCase {
    func testRoundTrip() {
        let fft = FFT(size: 64)
        var noise = SeededNoise(seed: 1)
        let original = (0..<64).map { _ in noise.next() }
        var real = original
        var imag = [Float](repeating: 0, count: 64)
        fft.forward(real: &real, imag: &imag)
        fft.inverse(real: &real, imag: &imag)
        for i in 0..<64 {
            XCTAssertEqual(real[i], original[i], accuracy: 1e-4)
            XCTAssertEqual(imag[i], 0, accuracy: 1e-4)
        }
    }

    func testSineLandsInItsBin() {
        let fft = FFT(size: 256)
        var real = (0..<256).map { Float(cos(2 * Double.pi * 8 * Double($0) / 256)) }
        var imag = [Float](repeating: 0, count: 256)
        fft.forward(real: &real, imag: &imag)
        XCTAssertEqual(real[8], 128, accuracy: 1e-2)
        XCTAssertEqual(real[248], 128, accuracy: 1e-2)
        XCTAssertEqual(abs(real[7]) + abs(imag[7]), 0, accuracy: 1e-2)
    }
}

final class LoudnessTests: XCTestCase {
    func testSineReadsAtItsLevelAsDualMono() throws {
        // BS.1770: a 997 Hz sine at 0 dBFS on one channel reads −3.01 LUFS, so −20 dBFS dual-mono reads −20.
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 3, sampleRate: 48_000)
        let dual = try XCTUnwrap(Loudness.integrated(tone, sampleRate: 48_000))
        XCTAssertEqual(dual, -20, accuracy: 0.1)
        let single = try XCTUnwrap(Loudness.integrated(tone, sampleRate: 48_000, dualMono: false))
        XCTAssertEqual(single, -23.01, accuracy: 0.1)
    }

    func testOtherSampleRates() throws {
        for rate in [16_000.0, 44_100.0] {
            let tone = sine(frequency: 997, amplitude: 0.1, seconds: 2, sampleRate: rate)
            XCTAssertEqual(try XCTUnwrap(Loudness.integrated(tone, sampleRate: rate)), -20, accuracy: 0.15)
        }
    }

    func testSilenceHasNoLoudness() {
        XCTAssertNil(Loudness.integrated([Float](repeating: 0, count: 48_000), sampleRate: 48_000))
        XCTAssertNil(Loudness.integrated([], sampleRate: 48_000))
    }

    func testGatingIgnoresSilentStretches() throws {
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 2, sampleRate: 48_000)
        let withSilence = tone + [Float](repeating: 0, count: 96_000)
        // The silent blocks are gated out. Of the 20 blocks that pass, 17 are all tone and the three straddling
        // the end hold ¾, ½ and ¼ of it, so the mean power is 18.5 / 20 of the tone's.
        let expected = -20 + 10 * log10(Float(18.5 / 20))
        XCTAssertEqual(try XCTUnwrap(Loudness.integrated(withSilence, sampleRate: 48_000)), expected, accuracy: 0.05)
    }
}

final class DynamicsTests: XCTestCase {
    func testLimiterHoldsCeiling() {
        var noise = SeededNoise(seed: 3)
        var samples = (0..<48_000).map { _ in 0.5 * noise.next() }
        Limiter(ceilingDB: -1.5).process(&samples, sampleRate: 48_000)
        XCTAssertLessThanOrEqual(Loudness.peakDB(samples), -1.5 + 1e-3)
    }

    func testLimiterLeavesQuietAudioAlone() {
        let original = sine(frequency: 440, amplitude: 0.5, seconds: 0.5, sampleRate: 48_000)
        var samples = original
        Limiter(ceilingDB: -1.5).process(&samples, sampleRate: 48_000)
        XCTAssertEqual(samples, original)
    }

    func testSlidingMinimum() {
        let values: [Float] = [5, 3, 8, 1, 9, 9, 7, 2, 6]
        let expected: [Float] = [3, 1, 1, 1, 1, 1, 2, 2, 2]
        XCTAssertEqual(Limiter.slidingMinimum(values, radius: 2), expected)
    }

    func testCompressorCurve() {
        let compressor = Compressor(thresholdDB: -20, ratio: 4, kneeDB: 0)
        XCTAssertEqual(compressor.gainChange(forLevel: -30), 0)
        XCTAssertEqual(compressor.gainChange(forLevel: -8), -9, accuracy: 1e-4)
    }

    func testCompressorNarrowsLevelDifference() {
        let loud = sine(frequency: 300, amplitude: 0.5, seconds: 1, sampleRate: 48_000)
        let quiet = sine(frequency: 300, amplitude: 0.05, seconds: 1, sampleRate: 48_000)
        var samples = loud + quiet
        let before = rmsDB(samples[24_000..<48_000]) - rmsDB(samples[72_000..<96_000])
        Compressor(thresholdDB: -30, ratio: 3).process(&samples, sampleRate: 48_000)
        let after = rmsDB(samples[24_000..<48_000]) - rmsDB(samples[72_000..<96_000])
        XCTAssertLessThan(after, before - 6)
    }

    func testDeEsserReducesSibilanceButNotVowels() {
        let rate = 48_000.0
        var sibilant = sine(frequency: 6_500, amplitude: 0.3, seconds: 0.5, sampleRate: rate)
        var vowel = sine(frequency: 300, amplitude: 0.3, seconds: 0.5, sampleRate: rate)
        let sibilantBefore = rmsDB(sibilant[12_000...])
        let vowelBefore = rmsDB(vowel[12_000...])
        DeEsser(amount: 0.6).process(&sibilant, sampleRate: rate)
        DeEsser(amount: 0.6).process(&vowel, sampleRate: rate)
        XCTAssertLessThan(rmsDB(sibilant[12_000...]), sibilantBefore - 3)
        XCTAssertEqual(rmsDB(vowel[12_000...]), vowelBefore, accuracy: 0.5)
    }
}

final class NoiseReducerTests: XCTestCase {
    func testReducesHissInPausesAndKeepsVoice() throws {
        let rate = 16_000.0
        let (mixed, voice) = syntheticRecording(sampleRate: rate, seconds: 4, hiss: 0.003)
        let cleaned = try NoiseReducer(amount: 0.55).process(mixed, sampleRate: rate) { _ in }
        XCTAssertEqual(cleaned.count, mixed.count)

        let pauses = pauseIndices(count: mixed.count, sampleRate: rate)
        let before = rmsDB(ArraySlice(pauses.map { mixed[$0] }))
        let after = rmsDB(ArraySlice(pauses.map { cleaned[$0] }))
        XCTAssertLessThan(after, before - 8, "hiss in the pauses should drop clearly")

        let errorBefore = rmsDB(ArraySlice(zip(mixed, voice).map { $0 - $1 }))
        let errorAfter = rmsDB(ArraySlice(zip(cleaned, voice).map { $0 - $1 }))
        XCTAssertLessThan(errorAfter, errorBefore, "the result should be closer to the clean voice")
    }

    func testSilenceStaysSilent() throws {
        let silence = [Float](repeating: 0, count: 8_000)
        XCTAssertEqual(try NoiseReducer(amount: 1).process(silence, sampleRate: 16_000) { _ in }, silence)
    }
}

final class PipelineTests: XCTestCase {
    func testBalancedPresetHitsTargetAndCeiling() throws {
        let rate = 16_000.0
        let (mixed, _) = syntheticRecording(sampleRate: rate, seconds: 4, hiss: 0.003)
        let quietInput = mixed.map { $0 * 0.2 }
        var lastProgress = 0.0
        let result = try VoiceEnhancer.process(quietInput, sampleRate: rate, settings: .balanced) { value in
            XCTAssertGreaterThanOrEqual(value, lastProgress)
            lastProgress = value
        }
        XCTAssertEqual(lastProgress, 1)
        XCTAssertEqual(result.samples.count, quietInput.count)
        XCTAssertEqual(try XCTUnwrap(result.report.outputLoudness), -16, accuracy: 1)
        XCTAssertLessThanOrEqual(result.report.outputPeakDB, VoiceEnhancer.peakCeilingDB + 1e-3)
        XCTAssertFalse(result.samples.contains { !$0.isFinite })
    }

    func testNormalizeOffKeepsOriginalLoudness() throws {
        let rate = 16_000.0
        let (mixed, _) = syntheticRecording(sampleRate: rate, seconds: 3, hiss: 0.002)
        var settings = EnhancementSettings.light
        settings.normalize = false
        let result = try VoiceEnhancer.process(mixed, sampleRate: rate, settings: settings)
        let input = try XCTUnwrap(result.report.inputLoudness)
        XCTAssertEqual(try XCTUnwrap(result.report.outputLoudness), input, accuracy: 1)
    }

    func testSilentInputDoesNotBlowUp() throws {
        let result = try VoiceEnhancer.process([Float](repeating: 0, count: 16_000), sampleRate: 16_000,
                                               settings: .strong)
        XCTAssertNil(result.report.outputLoudness)
        XCTAssertFalse(result.samples.contains { $0 != 0 })
    }

    func testPresetMatching() {
        XCTAssertEqual(EnhancementPreset.matching(.balanced), .balanced)
        var custom = EnhancementSettings.balanced
        custom.targetLoudness = -14
        XCTAssertEqual(EnhancementPreset.matching(custom), .balanced, "loudness isn't part of the preset")
        custom.clarity = 0.123
        XCTAssertEqual(EnhancementPreset.matching(custom), .custom)
    }

    func testWaveformPeaks() {
        let peaks = Waveform.peaks([0, 0.5, -1, 0.25], buckets: 2)
        XCTAssertEqual(peaks, [0.5, 1])
        XCTAssertEqual(Waveform.peaks([0.3], buckets: 3).count, 3)
    }
}
