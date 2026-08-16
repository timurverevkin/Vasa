import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class Playback {
    static let shared = Playback()

    var currentSeconds = 0.0
    var durationSeconds = 0.0

    private var audio: AVPlayer?
    private var video: AVPlayer?
    private var timeObserver: Any?
    private var ended: (() -> Void)?
    private var activeURL: URL?

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, currentSeconds / durationSeconds))
    }

    func onEnded(_ handler: @escaping () -> Void) {
        ended = handler
    }

    func stop() {
        removeObserver()
        audio?.pause()
        video?.pause()
        audio = nil
        video = nil
        activeURL = nil
        currentSeconds = 0
        durationSeconds = 0
    }

    func pause() {
        audio?.pause()
        video?.pause()
    }

    func resume() {
        audio?.play()
        video?.play()
    }

    var videoPlayer: AVPlayer? { video }

    func playAudio(url: URL, durationHint: Double = 0) {
        if activeURL == url, audio != nil {
            resume()
            return
        }
        stop()
        durationSeconds = durationHint
        let player = AVPlayer(url: url)
        audio = player
        activeURL = url
        attach(player)
        player.play()
    }

    func playVideo(url: URL) -> AVPlayer {
        stop()
        let player = AVPlayer(url: url)
        video = player
        activeURL = url
        attach(player)
        player.isMuted = false
        player.play()
        return player
    }

    func seek(fraction: Double) {
        let f = min(1, max(0, fraction))
        if durationSeconds <= 0, let item = (audio ?? video)?.currentItem {
            let loaded = item.duration.seconds
            if loaded.isFinite, loaded > 0 { durationSeconds = loaded }
        }
        guard durationSeconds > 0 else {
            currentSeconds = 0
            return
        }
        currentSeconds = f * durationSeconds
        let time = CMTime(seconds: currentSeconds, preferredTimescale: 600)
        (audio ?? video)?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attach(_ player: AVPlayer) {
        removeObserver()
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentSeconds = time.seconds
                if let item = player.currentItem {
                    let loaded = item.duration.seconds
                    if loaded.isFinite, loaded > 0 {
                        self.durationSeconds = loaded
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ended?()
            }
        }
    }

    private func removeObserver() {
        if let timeObserver, let player = audio ?? video {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}
