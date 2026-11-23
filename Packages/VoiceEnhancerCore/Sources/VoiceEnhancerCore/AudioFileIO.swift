#if canImport(AVFoundation)
import AVFoundation

/// A decoded recording, mixed down to mono.
public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Channel count of the source file; exports keep it.
    public var channelCount: Int

    public init(samples: [Float], sampleRate: Double, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV (24-bit)"
        }
    }
}

public enum AudioFileError: LocalizedError {
    case empty
    case unreadable(String)
    case unsupportedForExport(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The file contains no audio."
        case .unreadable(let detail): return "The file couldn’t be read as audio. \(detail)"
        case .unsupportedForExport(let detail): return detail
        }
    }
}

public enum AudioFileIO {
    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Reads any format Core Audio can decode (WAV, AIFF, CAF, M4A/AAC, ALAC, MP3, FLAC…) and mixes it to mono.
    public static func readMono(from url: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard file.length > 0, channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioFileError.empty
        }
        var mono = [Float]()
        mono.reserveCapacity(Int(file.length))
        let scale = 1 / Float(channels)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let start = mono.count
            mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            if channels > 1 {
                for channel in 1..<channels {
                    let samples = data[channel]
                    for i in 0..<frames { mono[start + i] += samples[i] }
                }
                for i in start..<(start + frames) { mono[i] *= scale }
            }
        }
        guard !mono.isEmpty else { throw AudioFileError.empty }
        return DecodedAudio(samples: mono, sampleRate: format.sampleRate, channelCount: channels)
    }

    /// Writes mono `samples` to `url`, copied to each of `channelCount` channels.
    public static func write(_ samples: [Float], sampleRate: Double, channelCount: Int, format: ExportFormat,
                             to url: URL) throws {
        let channels = max(1, min(2, channelCount))
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .m4a:
            guard sampleRate <= 48_000 else {
                throw AudioFileError.unsupportedForExport(
                    "AAC supports sample rates up to 48 kHz; export this \(Int(sampleRate / 1000)) kHz recording as WAV.")
            }
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // Let the encoder pick a bit rate that suits the sample rate.
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        }
        try? FileManager.default.removeItem(at: url)
        try writeFile(samples, settings: settings, channels: channels, to: url)
    }

    /// Kept separate so the `AVAudioFile` is released, and the file closed, before `write` returns.
    private static func writeFile(_ samples: [Float], settings: [String: Any], channels: Int, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
              let data = buffer.floatChannelData else {
            throw AudioFileError.unsupportedForExport("Couldn’t prepare the audio for writing.")
        }
        var position = 0
        while position < samples.count {
            let frames = min(Int(chunkFrames), samples.count - position)
            samples.withUnsafeBufferPointer { source in
                for channel in 0..<channels {
                    data[channel].update(from: source.baseAddress! + position, count: frames)
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            position += frames
        }
    }
}
#endif
