import AppKit
import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class Playback {
    static let shared = Playback()

    var currentSeconds = 0.0
    var durationSeconds = 0.0
    /// Last load/play error (empty when healthy).
    var lastError: String?

    private var audio: AVPlayer?
    private var video: AVPlayer?
    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var ended: (() -> Void)?
    private var activeURL: URL?

    var progress: Double {
        guard durationSeconds > 0, durationSeconds.isFinite else { return 0 }
        guard currentSeconds.isFinite else { return 0 }
        return min(1, max(0, currentSeconds / durationSeconds))
    }

    func onEnded(_ handler: @escaping () -> Void) {
        ended = handler
    }

    func stop() {
        removeObservers()
        audio?.pause()
        video?.pause()
        audio = nil
        video = nil
        activeURL = nil
        currentSeconds = 0
        durationSeconds = 0
        lastError = nil
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
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Audio file not found"
            return
        }
        durationSeconds = durationHint.isFinite ? max(0, durationHint) : 0
        let player = AVPlayer(url: url)
        audio = player
        activeURL = url
        attach(player)
        player.play()
    }

    @discardableResult
    func playVideo(url: URL) -> AVPlayer? {
        stop()
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            lastError = "Video file not found"
            return nil
        }
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
        guard durationSeconds > 0, durationSeconds.isFinite else {
            currentSeconds = 0
            return
        }
        currentSeconds = f * durationSeconds
        let time = CMTime(seconds: currentSeconds, preferredTimescale: 600)
        guard time.isValid, time.seconds.isFinite else { return }
        (audio ?? video)?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attach(_ player: AVPlayer) {
        removeObservers()
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentSeconds = max(0, seconds) }
                if let item = player.currentItem {
                    let loaded = item.duration.seconds
                    if loaded.isFinite, loaded > 0 {
                        self.durationSeconds = loaded
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ended?()
            }
        }
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed {
                    self.lastError = item.error?.localizedDescription ?? "Playback failed"
                    player.pause()
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverPlayer = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    /// Grab a JPEG poster next to the video in the lesson media folder.
    static func generatePoster(for videoURL: URL) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let cgImage = try await generator.image(at: time).image
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
            else { return nil }
            let dest = videoURL.deletingPathExtension().appendingPathExtension("poster.jpg")
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}
