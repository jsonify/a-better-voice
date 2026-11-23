import AVFoundation
import Foundation

/// Plays the original or the enhanced version, and switches between them at the same position for A/B listening.
@MainActor
final class PlaybackController: ObservableObject {
    enum Version: String, CaseIterable, Identifiable {
        case original, enhanced
        var id: String { rawValue }
        var title: String { self == .original ? "Original" : "Enhanced" }
    }

    @Published private(set) var isPlaying = false
    @Published var version: Version = .enhanced {
        didSet {
            if version != oldValue { switchVersion(from: oldValue) }
        }
    }

    private var players: [Version: AVAudioPlayer] = [:]
    private let finishObserver = FinishObserver()

    init() {
        finishObserver.onFinish = { [weak self] in
            Task { @MainActor in self?.playbackFinished() }
        }
    }

    var duration: TimeInterval { activePlayer?.duration ?? 0 }
    var currentTime: TimeInterval { activePlayer?.currentTime ?? 0 }

    /// Playback position from 0 to 1.
    var fraction: Double {
        let total = duration
        return total > 0 ? min(1, currentTime / total) : 0
    }

    var canPlay: Bool { activePlayer != nil }

    private var activePlayer: AVAudioPlayer? { players[version] }

    func setOriginal(_ url: URL) {
        install(url, as: .original)
    }

    /// Replaces the enhanced version, keeping the position and play state if it is the one playing.
    func setEnhanced(_ url: URL) {
        let wasPlaying = isPlaying && version == .enhanced
        let position = players[.enhanced]?.currentTime ?? currentTime
        if wasPlaying { players[.enhanced]?.stop() }
        install(url, as: .enhanced)
        if let player = players[.enhanced] {
            player.currentTime = min(position, player.duration)
            if wasPlaying { player.play() }
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player = activePlayer else { return }
        Self.activateSession()
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
    }

    func pause() {
        activePlayer?.pause()
        isPlaying = false
    }

    func stop() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
        isPlaying = false
    }

    func clear() {
        players = [:]
        version = .enhanced
    }

    func seek(toFraction fraction: Double) {
        let target = max(0, min(1, fraction)) * duration
        for player in players.values { player.currentTime = min(target, player.duration) }
        objectWillChange.send()
    }

    private func install(_ url: URL, as version: Version) {
        players[version]?.stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = finishObserver
            player.prepareToPlay()
            players[version] = player
        } catch {
            players[version] = nil
        }
    }

    private func switchVersion(from previous: Version) {
        let old = players[previous]
        let position = old?.currentTime ?? 0
        old?.pause()
        guard let player = activePlayer else {
            isPlaying = false
            return
        }
        player.currentTime = min(position, player.duration)
        if isPlaying { player.play() }
    }

    private func playbackFinished() {
        if !(activePlayer?.isPlaying ?? false) { isPlaying = false }
    }

    private static func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }
}

/// `AVAudioPlayerDelegate` needs an `NSObject`; this forwards "finished playing" to the controller.
private final class FinishObserver: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
