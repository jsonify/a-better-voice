import SwiftUI
import UniformTypeIdentifiers
import VoiceEnhancerCore

struct ContentView: View {
    @ObservedObject var model: EnhancerModel
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.hasRecording || model.phase == .loading {
                EditorView(model: model, player: model.player, chooseFile: chooseFile)
            } else {
                DropZoneView(isTargeted: isDropTargeted, chooseFile: chooseFile)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .fileExporter(isPresented: $model.isExporterPresented, document: model.exportDocument,
                      contentType: model.exportFormat.contentType, defaultFilename: model.exportFilename) { result in
            model.exportFinished(result)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func chooseFile() {
        isImporterPresented = true
    }
}

// MARK: - Empty state

struct DropZoneView: View {
    let isTargeted: Bool
    let chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Drop a voice recording here")
                    .font(.title2.weight(.semibold))
                Text("Voice memos, podcasts, interviews, voice-overs: M4A, WAV, MP3, AIFF, CAF and more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Choose a File…", action: chooseFile)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Everything is processed on this device. Nothing is uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .padding(16)
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var model: EnhancerModel
    @ObservedObject var player: PlaybackController
    let chooseFile: () -> Void
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                listeningCard
                if let report = model.report { LoudnessSummary(report: report) }
                presetSection
                exportSection
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let audio = model.original {
                    Text("\(formatTime(audio.duration)) · \(Int(audio.sampleRate)) Hz · "
                         + (audio.channelCount == 1 ? "mono" : "\(audio.channelCount) channels"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open Another…", action: chooseFile)
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close recording")
        }
    }

    private var listeningCard: some View {
        VStack(spacing: 14) {
            Picker("Listen to", selection: $player.version) {
                ForEach(PlaybackController.Version.allCases) { version in
                    Text(version.title).tag(version)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                WaveformView(peaks: activePeaks, progress: player.fraction,
                             tint: player.version == .enhanced ? .accentColor : .gray) { fraction in
                    player.seek(toFraction: fraction)
                }
                .frame(height: 110)
                .overlay { statusOverlay }
            }

            HStack {
                Button {
                    player.togglePlayback()
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play",
                          systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(!player.canPlay)

                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Switch between Original and Enhanced while playing to compare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    private var activePeaks: [Float] {
        player.version == .enhanced && !model.enhancedPeaks.isEmpty ? model.enhancedPeaks : model.originalPeaks
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading…")
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .processing(let fraction):
            ProgressView(value: fraction) {
                Text("Enhancing… \(Int(fraction * 100))%")
            }
            .frame(maxWidth: 220)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        default:
            EmptyView()
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enhancement").font(.headline)
            Picker("Preset", selection: $model.preset) {
                ForEach(EnhancementPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Loudness", selection: $model.settings.targetLoudness) {
                ForEach(LoudnessTarget.allCases) { target in
                    Text(target.title).tag(target.rawValue)
                }
            }
            .disabled(!model.settings.normalize)

            DisclosureGroup("Fine-tune", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    AmountSlider(title: "Noise reduction", detail: "Hiss, hum and room tone",
                                 value: $model.settings.noiseReduction)
                    AmountSlider(title: "Clarity", detail: "Less mud, more presence",
                                 value: $model.settings.clarity)
                    AmountSlider(title: "De-ess", detail: "Softer “s” and “sh” sounds",
                                 value: $model.settings.deEss)
                    AmountSlider(title: "Leveling", detail: "Evens out loud and quiet parts",
                                 value: $model.settings.leveling)
                    Toggle("Remove rumble below 80 Hz", isOn: $model.settings.rumbleFilter)
                    Toggle("Normalize loudness", isOn: $model.settings.normalize)
                }
                .padding(.top, 10)
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)
            HStack(spacing: 12) {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .fixedSize()
                Spacer()
                if let url = model.exportedFileURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    model.export()
                } label: {
                    if model.isPreparingExport {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || model.isPreparingExport)
            }
        }
    }
}

struct AmountSlider: View {
    let title: String
    let detail: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value == 0 ? "Off" : "\(Int((value * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LoudnessSummary: View {
    let report: EnhancementReport

    var body: some View {
        HStack(spacing: 24) {
            metric("Before", loudness: report.inputLoudness, peak: report.inputPeakDB)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            metric("After", loudness: report.outputLoudness, peak: report.outputPeakDB)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, loudness: Float?, peak: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(loudness.map { String(format: "%.1f LUFS", $0) } ?? "Silent")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(peak.isFinite ? String(format: "peak %.1f dBFS", peak) : "peak –")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
