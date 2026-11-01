import Foundation
import AVFoundation
import Observation

/// Decodes audio to a compact amplitude envelope (100 values per second, 0...1).
enum WaveformGenerator {
    static let envelopeRate: Double = 100

    static func envelope(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 8000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.processingFailed("Couldn't read audio.") }

        let binSize = Int(sampleRate / envelopeRate)
        var envelope: [Float] = []
        var binPeak: Float = 0
        var binCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var floats = [Float](repeating: 0, count: count)
            floats.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            for v in floats {
                let a = abs(v)
                if a > binPeak { binPeak = a }
                binCount += 1
                if binCount >= binSize {
                    envelope.append(binPeak)
                    binPeak = 0
                    binCount = 0
                }
            }
        }
        if binCount > 0 { envelope.append(binPeak) }
        if reader.status == .failed { throw reader.error ?? AppError.processingFailed("Couldn't read audio.") }
        let maxValue = envelope.max() ?? 0
        if maxValue > 0 {
            for i in envelope.indices { envelope[i] /= maxValue }
        }
        return envelope
    }
}

/// Caches envelopes in memory and on disk; notifies the timeline when new ones arrive.
@Observable
final class WaveformStore: @unchecked Sendable {
    private(set) var version = 0
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var envelopes: [URL: [Float]] = [:]
    @ObservationIgnored private var inflight = Set<URL>()

    func envelope(for url: URL, cacheFile: URL) -> [Float]? {
        lock.lock()
        if let e = envelopes[url] {
            lock.unlock()
            return e
        }
        if inflight.contains(url) {
            lock.unlock()
            return nil
        }
        inflight.insert(url)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            var result: [Float] = []
            if let data = try? Data(contentsOf: cacheFile), !data.isEmpty {
                result = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else if let env = try? await WaveformGenerator.envelope(url: url) {
                result = env
                let data = env.withUnsafeBufferPointer { Data(buffer: $0) }
                try? data.write(to: cacheFile, options: .atomic)
            }
            guard let self else { return }
            self.lock.lock()
            self.envelopes[url] = result
            self.inflight.remove(url)
            self.lock.unlock()
            DispatchQueue.main.async { self.version += 1 }
        }
        return nil
    }
}

/// Finds musical beats from an amplitude envelope using onset strength + tempo autocorrelation.
enum BeatDetector {
    static func detect(envelope: [Float], rate: Double = WaveformGenerator.envelopeRate) -> [Double] {
        let n = envelope.count
        guard n > Int(rate * 3) else { return [] }

        // Onset strength: positive change in log-amplitude, lightly smoothed.
        var onset = [Float](repeating: 0, count: n)
        var prev = log(Float(1e-3) + envelope[0])
        for i in 1..<n {
            let cur = log(Float(1e-3) + envelope[i])
            onset[i] = max(0, cur - prev)
            prev = cur
        }
        var smooth = onset
        for i in 1..<(n - 1) {
            smooth[i] = (onset[i - 1] + 2 * onset[i] + onset[i + 1]) / 4
        }

        // Tempo: autocorrelation over 60...180 BPM, biased toward ~120 BPM.
        let analysisLength = min(n, Int(rate * 60))
        let minLag = Int(rate * 60 / 180)
        let maxLag = Int(rate * 60 / 60)
        var bestLag = Int(rate * 0.5)
        var bestScore: Float = -1
        for lag in minLag...maxLag where lag < analysisLength {
            var score: Float = 0
            var i = lag
            while i < analysisLength {
                score += smooth[i] * smooth[i - lag]
                i += 1
            }
            let bpm = 60 * rate / Double(lag)
            let weight = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            score *= weight
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return [] }

        // Phase: offset whose comb best aligns with onsets.
        var bestPhase = 0
        var bestPhaseScore: Float = -1
        for phase in 0..<bestLag {
            var s: Float = 0
            var i = phase
            while i < n {
                s += smooth[i]
                i += bestLag
            }
            if s > bestPhaseScore {
                bestPhaseScore = s
                bestPhase = phase
            }
        }

        // Place beats on the grid, snapping each to the strongest nearby onset.
        var beats: [Double] = []
        var i = bestPhase
        let window = max(2, bestLag / 8)
        while i < n {
            var bestIndex = i
            var bestValue: Float = -1
            for j in max(0, i - window)...min(n - 1, i + window) where smooth[j] > bestValue {
                bestValue = smooth[j]
                bestIndex = j
            }
            beats.append(Double(bestIndex) / rate)
            i += bestLag
        }
        return beats
    }
}
