import Foundation
import AVFoundation
import Observation

/// Owns the AVPlayer, keeps `currentTime` in sync at 60 Hz and performs
/// coalesced ("chase") seeks for instant, smooth scrubbing.
@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var hasItem = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var videoComposition: AVVideoComposition?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var lastRefresh = Date.distantPast
    /// Called whenever playback stops by itself (end reached).
    @ObservationIgnored var onStop: (() -> Void)?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isSeeking else { return }
                self.currentTime = min(time.secondsOrZero, self.duration)
            }
        }
        VoiceoverRecorder.restorePlaybackSession()
    }

    func load(_ built: BuiltComposition, keepTime: Double) {
        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        item.seekingWaitsForVideoCompositionRendering = true
        videoComposition = built.videoComposition

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
                self.onStop?()
            }
        }

        player.replaceCurrentItem(with: item)
        duration = built.duration
        hasItem = true
        let target = min(max(keepTime, 0), max(duration - 0.001, 0))
        currentTime = target
        isSeeking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            self.isSeeking = false
            if wasPlaying {
                self.player.play()
            }
        }
    }

    func clear() {
        player.replaceCurrentItem(with: nil)
        hasItem = false
        duration = 0
        isPlaying = false
        currentTime = 0
    }

    func play() {
        guard hasItem, duration > 0 else { return }
        if currentTime >= duration - 0.05 {
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        let t = player.currentTime().secondsOrZero
        if t.isFinite { currentTime = min(max(t, 0), duration) }
        onStop?()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// Instant UI update plus coalesced precise seek.
    func scrub(to time: Double) {
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        currentTime = min(max(time, 0), max(duration, 0))
        pendingSeek = currentTime
        if !isSeeking { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let target = pendingSeek else {
            isSeeking = false
            return
        }
        pendingSeek = nil
        isSeeking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            self.performPendingSeek()
        }
    }

    /// Re-renders the current frame after a visual-only change (throttled to ~30 Hz).
    func refreshFrame() {
        guard hasItem, !isPlaying else { return }
        let elapsed = Date().timeIntervalSince(lastRefresh)
        if elapsed >= 1.0 / 30.0 {
            applyRefresh()
        } else if !refreshScheduled {
            refreshScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((1.0 / 30.0 - elapsed) * 1_000_000_000))
                guard let self else { return }
                self.refreshScheduled = false
                self.applyRefresh()
            }
        }
    }

    private func applyRefresh() {
        lastRefresh = Date()
        guard let item = player.currentItem, let vc = videoComposition,
              let copy = vc.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = copy
        videoComposition = copy
    }
}
