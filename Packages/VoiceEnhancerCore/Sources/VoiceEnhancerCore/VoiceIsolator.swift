import Foundation

public enum VoiceIsolationError: LocalizedError {
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AI voice isolation isn’t available on this device."
        case .failed(let detail):
            return "AI voice isolation failed. \(detail)"
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// Apple's on-device machine-learning voice isolation: the AUSoundIsolation audio unit, the technology behind the
/// "Voice Isolation" microphone mode. It keeps the voice and removes everything else, including changing noise
/// (traffic, keyboards, dogs), music and room echo, which the classic noise reducer can't. It runs on the device,
/// using the Neural Engine where there is one; nothing is uploaded and there is no usage cost.
public enum VoiceIsolator {
    /// The unit works at 48 kHz; other rates are converted there and back.
    static let processingRate = 48_000.0
    private static let chunk: AVAudioFrameCount = 4_096

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    /// Whether this device has the voice isolation unit.
    public static var isAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// Isolates the voice in mono `samples`. `mix` blends the isolated voice (1) with the original (0).
    static func process(_ samples: [Float], sampleRate: Double, mix: Float,
                        progress: (Double) -> Void) throws -> [Float] {
        guard isAvailable else { throw VoiceIsolationError.unavailable }
        guard !samples.isEmpty else { return samples }
        let needsResampling = sampleRate != processingRate
        let input = needsResampling ? try Resampler.convert(samples, from: sampleRate, to: processingRate) : samples
        let rendered = try render(input) { progress(0.9 * $0) }
        var isolated = needsResampling ? try Resampler.convert(rendered, from: processingRate, to: sampleRate) : rendered
        isolated = Alignment.fit(isolated, count: samples.count)

        // Line the result up with the original in case the unit's delay isn't reported exactly, so blending with
        // the original can't cause comb filtering.
        let lag = Alignment.estimateLag(reference: samples, signal: isolated, sampleRate: sampleRate)
        if lag != 0 { isolated = Alignment.shift(isolated, by: lag) }
        progress(1)

        let wet = max(0, min(1, mix))
        guard wet < 1 else { return isolated }
        var blended = isolated
        for i in blended.indices { blended[i] = wet * isolated[i] + (1 - wet) * samples[i] }
        return blended
    }

    private static func render(_ samples: [Float], progress: (Double) -> Void) throws -> [Float] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: processingRate, channels: 1) else {
            throw VoiceIsolationError.failed("Couldn’t create the audio format.")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        preferHighQualityVoice(effect.auAudioUnit)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
            try engine.start()
        } catch {
            throw VoiceIsolationError.failed(error.localizedDescription)
        }
        defer { engine.stop() }
        player.play()

        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw VoiceIsolationError.failed("Couldn’t allocate audio buffers.")
        }
        let latency = max(0, Int((effect.auAudioUnit.latency * processingRate).rounded()))
        let total = samples.count + latency
        var output = [Float]()
        output.reserveCapacity(total)
        var scheduled = 0
        var stalls = 0

        while output.count < total {
            try Task.checkCancellation()
            // Keep a few chunks queued ahead of the render position rather than copying the whole file at once.
            while scheduled < samples.count && scheduled < output.count + 4 * Int(chunk) {
                let frames = min(Int(chunk), samples.count - scheduled)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let data = buffer.floatChannelData else {
                    throw VoiceIsolationError.failed("Couldn’t allocate audio buffers.")
                }
                let start = scheduled
                samples.withUnsafeBufferPointer { source in
                    data[0].update(from: source.baseAddress! + start, count: frames)
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                player.scheduleBuffer(buffer, completionHandler: nil)
                scheduled += frames
            }

            let request = AVAudioFrameCount(min(Int(chunk), total - output.count))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(request, to: renderBuffer)
            } catch {
                throw VoiceIsolationError.failed(error.localizedDescription)
            }
            switch status {
            case .success:
                let frames = Int(renderBuffer.frameLength)
                if frames > 0, let data = renderBuffer.floatChannelData {
                    output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
                    stalls = 0
                } else {
                    stalls += 1
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
            case .error:
                throw VoiceIsolationError.failed("The audio unit reported an error.")
            @unknown default:
                throw VoiceIsolationError.failed("The audio unit returned an unexpected status.")
            }
            if stalls > 100 { throw VoiceIsolationError.failed("The audio unit stopped producing audio.") }
            progress(Double(output.count) / Double(total))
        }
        return Array(output.dropFirst(latency))
    }

    /// Picks the unit's high-quality voice mode and full effect, where this OS version offers them. Done by looking
    /// the parameters up at run time, so older systems simply keep their defaults.
    private static func preferHighQualityVoice(_ unit: AUAudioUnit) {
        guard let parameters = unit.parameterTree?.allParameters else { return }
        for parameter in parameters {
            if let names = parameter.valueStrings,
               let index = names.firstIndex(where: { $0.localizedCaseInsensitiveContains("high") }) {
                parameter.value = parameter.minValue + AUValue(index)
            } else if parameter.unit == .percent {
                parameter.value = parameter.maxValue
            }
        }
    }
}

/// Sample-rate conversion with `AVAudioConverter`.
enum Resampler {
    static func convert(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            throw VoiceIsolationError.failed("Couldn’t set up sample-rate conversion.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let feed = SampleFeed(samples: samples, format: inputFormat)
        var result = [Float]()
        result.reserveCapacity(Int(Double(samples.count) * target / source) + 8_192)
        while true {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { count, inputStatus in
                feed.next(count, inputStatus)
            }
            if status == .error {
                throw VoiceIsolationError.failed(error?.localizedDescription ?? "Sample-rate conversion failed.")
            }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let data = outputBuffer.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return result
    }
}

/// Hands the converter its input a slice at a time.
private final class SampleFeed: @unchecked Sendable {
    private let samples: [Float]
    private let format: AVAudioFormat
    private var position = 0

    init(samples: [Float], format: AVAudioFormat) {
        self.samples = samples
        self.format = format
    }

    func next(_ count: AVAudioPacketCount,
              _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = samples.count - position
        guard remaining > 0 else {
            status.pointee = .endOfStream
            return nil
        }
        let frames = min(Int(count), remaining)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            status.pointee = .endOfStream
            return nil
        }
        let start = position
        samples.withUnsafeBufferPointer { source in
            data[0].update(from: source.baseAddress! + start, count: frames)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        position += frames
        status.pointee = .haveData
        return buffer
    }
}
#endif

/// Time alignment between a processed signal and its original.
enum Alignment {
    /// Trims or zero-pads `signal` to `count` samples.
    static func fit(_ signal: [Float], count: Int) -> [Float] {
        if signal.count >= count { return Array(signal.prefix(count)) }
        return signal + [Float](repeating: 0, count: count - signal.count)
    }

    /// `result[i] = signal[i + lag]`, zero where that falls outside.
    static func shift(_ signal: [Float], by lag: Int) -> [Float] {
        var result = [Float](repeating: 0, count: signal.count)
        for i in result.indices {
            let source = i + lag
            if source >= 0 && source < signal.count { result[i] = signal[source] }
        }
        return result
    }

    /// How many samples `signal` lags behind `reference` (positive = later), within ±60 ms, found by
    /// cross-correlation: coarse on a decimated copy, then refined at full rate. Returns 0 when the two don't
    /// correlate clearly.
    static func estimateLag(reference: [Float], signal: [Float], sampleRate: Double) -> Int {
        let count = min(reference.count, signal.count)
        let maxLag = Int(0.06 * sampleRate)
        guard count > 4 * maxLag, maxLag > 0 else { return 0 }
        // Up to 4 s from the middle of the recording.
        let length = min(count - 2 * maxLag, Int(4 * sampleRate))
        let start = maxLag + (count - 2 * maxLag - length) / 2

        let factor = max(1, Int(sampleRate / 8_000))
        let decimatedReference = decimate(reference, factor: factor)
        let decimatedSignal = decimate(signal, factor: factor)
        let coarse = bestLag(decimatedReference, decimatedSignal, start: start / factor, length: length / factor,
                             lags: -(maxLag / factor)...(maxLag / factor))
        guard let coarse, coarse.score > 0.3 else { return 0 }
        let centre = coarse.lag * factor
        let refined = bestLag(reference, signal, start: start, length: length,
                              lags: max(-maxLag, centre - factor)...min(maxLag, centre + factor))
        return refined?.lag ?? centre
    }

    private static func decimate(_ samples: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        let count = samples.count / factor
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0
            for j in 0..<factor { sum += samples[i * factor + j] }
            result[i] = sum / Float(factor)
        }
        return result
    }

    /// The lag with the highest normalised correlation of `signal[start+lag ..< start+lag+length]` against
    /// `reference[start ..< start+length]`.
    private static func bestLag(_ reference: [Float], _ signal: [Float], start: Int, length: Int,
                                lags: ClosedRange<Int>) -> (lag: Int, score: Float)? {
        guard length > 0 else { return nil }
        var best: (lag: Int, score: Float)?
        reference.withUnsafeBufferPointer { ref in
            signal.withUnsafeBufferPointer { sig in
                var referenceEnergy: Float = 0
                for i in start..<(start + length) { referenceEnergy += ref[i] * ref[i] }
                for lag in lags {
                    let from = start + lag
                    guard from >= 0, from + length <= sig.count else { continue }
                    var product: Float = 0
                    var signalEnergy: Float = 0
                    for i in 0..<length {
                        let s = sig[from + i]
                        product += ref[start + i] * s
                        signalEnergy += s * s
                    }
                    let denominator = (referenceEnergy * signalEnergy).squareRoot()
                    guard denominator > 0 else { continue }
                    let score = product / denominator
                    if best == nil || score > best!.score { best = (lag, score) }
                }
            }
        }
        return best
    }
}
