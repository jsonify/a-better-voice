import SwiftUI

/// Mirrored peak waveform with a playhead; tap or drag to seek.
struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    let tint: Color
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let loudest = max(peaks.max() ?? 1, 0.001)
                let barWidth = size.width / CGFloat(peaks.count)
                let middle = size.height / 2
                var played = Path()
                var remaining = Path()
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak / loudest) * size.height * 0.95)
                    let rect = CGRect(x: CGFloat(index) * barWidth, y: middle - height / 2,
                                      width: max(1, barWidth * 0.8), height: height)
                    if Double(index) / Double(peaks.count) < progress {
                        played.addRect(rect)
                    } else {
                        remaining.addRect(rect)
                    }
                }
                context.fill(played, with: .color(tint))
                context.fill(remaining, with: .color(tint.opacity(0.35)))
                let x = CGFloat(progress) * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        onSeek(Double(value.location.x / geometry.size.width))
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int(progress * 100)) percent played")
    }
}
