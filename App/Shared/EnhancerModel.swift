import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VoiceEnhancerCore

/// Everything the window shows: the loaded recording, the enhanced version, settings, playback and export.
@MainActor
final class EnhancerModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case loading
        case processing(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var sourceName = ""
    @Published private(set) var original: DecodedAudio?
    @Published private(set) var originalPeaks: [Float] = []
    @Published private(set) var enhancedPeaks: [Float] = []
    @Published private(set) var report: EnhancementReport?
    @Published var settings = EnhancementSettings.balanced {
        didSet {
            if settings != oldValue { scheduleEnhancement() }
        }
    }
    @Published var exportFormat: ExportFormat = .m4a
    @Published var isExporterPresented = false
    @Published private(set) var exportDocument: AudioFileDocument?
    @Published private(set) var exportedFileURL: URL?
    @Published private(set) var isPreparingExport = false
    @Published var errorMessage: String?

    let player = PlaybackController()

    private var sourceURL: URL?
    private var enhanced: [Float]?
    private var processingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private static let waveformBuckets = 900

    var hasRecording: Bool { original != nil }

    /// Whether Apple's on-device AI voice isolation exists on this device.
    let isVoiceIsolationAvailable = VoiceIsolator.isAvailable

    var preset: EnhancementPreset {
        get { EnhancementPreset.matching(settings) }
        set {
            if let presetSettings = newValue.settings(keepingChoicesOf: settings) { settings = presetSettings }
        }
    }

    var exportFilename: String {
        let base = (sourceName as NSString).deletingPathExtension
        return "\(base.isEmpty ? "Recording" : base) (enhanced)"
    }

    // MARK: - Loading

    /// Opens a file from the file picker, a drop, or "Open with". The file is copied into the app's own temporary
    /// folder first, so access to the original isn't needed afterwards.
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            load(try Workspace.importCopy(of: url))
        } catch {
            fail("Couldn’t open “\(url.lastPathComponent)”. \(error.localizedDescription)")
        }
    }

    /// Accepts the first audio file from a drag and drop.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, error in
                // The provided file is deleted when this handler returns, so copy it right here.
                let copy = Result { () throws -> URL in
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    return try Workspace.importCopy(of: url)
                }
                Task { @MainActor in self?.finishDrop(copy) }
            }
        } else {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.open(url) }
            }
        }
        return true
    }

    private func finishDrop(_ copy: Result<URL, Error>) {
        switch copy {
        case .success(let url): load(url)
        case .failure(let error): fail("Couldn’t open the dropped file. \(error.localizedDescription)")
        }
    }

    private func load(_ url: URL) {
        processingTask?.cancel()
        debounceTask?.cancel()
        player.stop()
        generation += 1
        let loadGeneration = generation
        sourceURL = url
        sourceName = url.lastPathComponent
        original = nil
        enhanced = nil
        report = nil
        originalPeaks = []
        enhancedPeaks = []
        exportedFileURL = nil
        phase = .loading
        let buckets = Self.waveformBuckets

        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = Result { () throws -> (DecodedAudio, [Float]) in
                let audio = try AudioFileIO.readMono(from: url)
                return (audio, Waveform.peaks(audio.samples, buckets: buckets))
            }
            await self?.finishLoading(decoded, url: url, generation: loadGeneration)
        }
    }

    private func finishLoading(_ decoded: Result<(DecodedAudio, [Float]), Error>, url: URL, generation: Int) {
        guard generation == self.generation else { return }
        switch decoded {
        case .success(let (audio, peaks)):
            original = audio
            originalPeaks = peaks
            player.setOriginal(url)
            startEnhancement()
        case .failure(let error):
            fail(error.localizedDescription)
            phase = .empty
        }
    }

    func close() {
        processingTask?.cancel()
        debounceTask?.cancel()
        player.stop()
        player.clear()
        generation += 1
        original = nil
        enhanced = nil
        report = nil
        originalPeaks = []
        enhancedPeaks = []
        sourceName = ""
        sourceURL = nil
        exportedFileURL = nil
        phase = .empty
    }

    // MARK: - Enhancing

    private func scheduleEnhancement() {
        guard original != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.startEnhancement()
        }
    }

    private func startEnhancement() {
        guard let audio = original else { return }
        processingTask?.cancel()
        generation += 1
        let runGeneration = generation
        let settings = self.settings
        let buckets = Self.waveformBuckets
        exportedFileURL = nil
        phase = .processing(0)

        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.updateProgress(value, generation: runGeneration) }
        }
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { () throws -> (EnhancementResult, [Float], URL) in
                var lastReported = -1.0
                let result = try VoiceEnhancer.process(audio.samples, sampleRate: audio.sampleRate,
                                                       settings: settings) { value in
                    if value - lastReported >= 0.01 || value >= 1 {
                        lastReported = value
                        progress(value)
                    }
                }
                let preview = try Workspace.previewURL()
                try AudioFileIO.write(result.samples, sampleRate: audio.sampleRate, channelCount: 1, format: .wav,
                                      to: preview)
                return (result, Waveform.peaks(result.samples, buckets: buckets), preview)
            }
            await self?.finishEnhancement(outcome, generation: runGeneration)
        }
    }

    private func updateProgress(_ value: Double, generation: Int) {
        guard generation == self.generation, case .processing = phase else { return }
        phase = .processing(value)
    }

    private func finishEnhancement(_ outcome: Result<(EnhancementResult, [Float], URL), Error>, generation: Int) {
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let (result, peaks, preview)):
            enhanced = result.samples
            enhancedPeaks = peaks
            report = result.report
            player.setEnhanced(preview)
            phase = .ready
        case .failure(let error):
            if error is CancellationError { return }
            fail("Enhancing failed. \(error.localizedDescription)")
            phase = .ready
        }
    }

    // MARK: - Export

    func export() {
        guard let samples = enhanced, let audio = original, !isPreparingExport else { return }
        let format = exportFormat
        let name = exportFilename
        isPreparingExport = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let written = Result { () throws -> URL in
                let url = try Workspace.exportURL(named: name, extension: format.fileExtension)
                try AudioFileIO.write(samples, sampleRate: audio.sampleRate, channelCount: audio.channelCount,
                                      format: format, to: url)
                return url
            }
            await self?.finishExport(written)
        }
    }

    private func finishExport(_ written: Result<URL, Error>) {
        isPreparingExport = false
        switch written {
        case .success(let url):
            exportedFileURL = url
            exportDocument = AudioFileDocument(url: url)
            isExporterPresented = true
        case .failure(let error):
            fail("Export failed. \(error.localizedDescription)")
        }
    }

    func exportFinished(_ result: Result<URL, Error>) {
        if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
            fail("Saving failed. \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
    }
}

/// Files the app owns: imported copies of recordings, the playback preview and exports, all in temporary storage.
enum Workspace {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ABetterVoice", isDirectory: true)
    }

    private static func freshFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func importCopy(of url: URL) throws -> URL {
        let destination = try freshFolder("Import-\(UUID().uuidString)").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func previewURL() throws -> URL {
        // A new name each time, so the player never reads a file that is being rewritten.
        try freshFolder("Preview-\(UUID().uuidString)").appendingPathComponent("preview.wav")
    }

    static func exportURL(named name: String, extension fileExtension: String) throws -> URL {
        try freshFolder("Export").appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    /// Clears what earlier launches left behind.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
