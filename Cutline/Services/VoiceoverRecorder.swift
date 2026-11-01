import Foundation
import AVFoundation
import Observation

/// Records voiceovers with AVAudioRecorder while the timeline plays muted.
@MainActor
@Observable
final class VoiceoverRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var elapsed: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var url: URL?

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        try? FileManager.default.removeItem(at: url)
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw AppError.processingFailed("Couldn't start recording. Another app may be using the microphone.")
        }
        self.recorder = recorder
        self.url = url
        startDate = Date()
        elapsed = 0
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                self.level = max(0, min(1, (db + 50) / 50))
                self.elapsed = Date().timeIntervalSince(self.startDate)
            }
        }
    }

    /// Stops recording and returns the file and its duration.
    func stop() -> (URL, Double)? {
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.url = nil
        isRecording = false
        level = 0
        Self.restorePlaybackSession()
        return duration > 0.2 ? (url, duration) : nil
    }

    static func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
