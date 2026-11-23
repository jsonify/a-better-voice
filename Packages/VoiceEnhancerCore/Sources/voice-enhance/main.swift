// Command-line front end for the enhancer, handy for batch work and for trying settings quickly on a Mac:
//
//     swift run -c release voice-enhance [--ai] input.m4a output.m4a [light|balanced|strong] [target LUFS]
//     swift run -c release voice-enhance --check-ai
//
// --ai turns on Apple's on-device AI voice isolation; --check-ai reports whether this Mac has it.
#if canImport(AVFoundation)
import Foundation
import VoiceEnhancerCore

let flags = Set(CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") })
let arguments = CommandLine.arguments.filter { !$0.hasPrefix("--") }
if flags.contains("--check-ai") {
    print("AI voice isolation: \(VoiceIsolator.isAvailable ? "available" : "not available")")
    exit(0)
}
guard arguments.count >= 3 else {
    print("usage: voice-enhance [--ai] <input> <output.m4a|output.wav> [light|balanced|strong] [target LUFS]")
    exit(2)
}

let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
var settings = EnhancementSettings.balanced
if arguments.count >= 4 {
    guard let preset = EnhancementPreset(rawValue: arguments[3]),
          let presetSettings = preset.settings(keepingChoicesOf: settings) else {
        print("unknown preset \(arguments[3]); use light, balanced or strong")
        exit(2)
    }
    settings = presetSettings
}
if arguments.count >= 5 {
    guard let target = Float(arguments[4]) else {
        print("target loudness must be a number, e.g. -16")
        exit(2)
    }
    settings.targetLoudness = target
}
if flags.contains("--ai") {
    settings.voiceIsolation = 1
}
let format: ExportFormat = output.pathExtension.lowercased() == "wav" ? .wav : .m4a

func describe(_ loudness: Float?) -> String {
    loudness.map { String(format: "%.1f LUFS", $0) } ?? "silent"
}

do {
    let audio = try AudioFileIO.readMono(from: input)
    let started = Date()
    let result = try VoiceEnhancer.process(audio.samples, sampleRate: audio.sampleRate, settings: settings)
    try AudioFileIO.write(result.samples, sampleRate: audio.sampleRate, channelCount: audio.channelCount,
                          format: format, to: output)
    let report = result.report
    print(String(format: "%@ → %@ (%.1f s of audio in %.1f s)", input.lastPathComponent, output.lastPathComponent,
                 audio.duration, Date().timeIntervalSince(started)))
    print("loudness: \(describe(report.inputLoudness)) → \(describe(report.outputLoudness))")
    print(String(format: "peak: %.1f dBFS → %.1f dBFS", report.inputPeakDB, report.outputPeakDB))
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
#else
print("voice-enhance needs AVFoundation (macOS).")
#endif
