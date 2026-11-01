import Foundation
import AVFoundation
import CoreImage
import Accelerate

/// PCM decode/encode helpers.
enum PCMIO {
    static func readInterleaved(url: URL, sampleRate: Double = 44100, channels: Int = 2) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AppError.processingFailed("This clip has no audio.")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.processingFailed("Couldn't read audio.") }
        var samples: [Float] = []
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            chunk.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                }
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? AppError.processingFailed("Couldn't read audio.") }
        return samples
    }

    static func writeAAC(interleaved: [Float], sampleRate: Double = 44100, channels: Int = 2, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw AppError.processingFailed("Unsupported audio format.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = interleaved.count / channels
        let chunk = 32768
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            for ch in 0..<channels {
                let dst = data[ch]
                for i in 0..<count {
                    dst[i] = interleaved[(offset + i) * channels + ch]
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}

enum DerivedMediaService {
    // MARK: Reverse

    /// Writes a reversed (video-only) copy of `source`.
    static func reverseVideo(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.processingFailed("This clip has no video to reverse.")
        }
        let duration = try await asset.load(.duration)
        let (natural, transform, nominalFPS) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let fps = Double(nominalFPS > 0 ? min(nominalFPS, 60) : 30)
        let width = Int(natural.width), height = Int(natural.height)
        try StorageGuard.ensure(Int64(Double(width * height) * fps * 0.15 / 8 * duration.secondsOrZero))

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let bitrate = max(2_000_000, Int(Double(width * height) * fps * 0.15))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.processingFailed("Couldn't reverse clip.") }
        writer.startSession(atSourceTime: .zero)

        let total = duration.secondsOrZero
        let frameDuration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        let chunkLength = 12.0 / fps
        var chunkEnd = total
        var lastWritten = CMTime.negativeInfinity

        while chunkEnd > 0.0001 {
            try Task.checkCancellation()
            let chunkStart = max(0, chunkEnd - chunkLength)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 60000),
                                           end: CMTime(seconds: chunkEnd, preferredTimescale: 60000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? AppError.processingFailed("Couldn't reverse clip.") }
            var frames: [(CVPixelBuffer, CMTime)] = []
            while let sb = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let s = pts.secondsOrZero
                if s >= chunkStart - 0.0001 && s < chunkEnd - 0.0001 {
                    frames.append((pb, pts))
                }
            }
            reader.cancelReading()
            for (pb, pts) in frames.reversed() {
                var newTime = CMTimeSubtract(duration, CMTimeAdd(pts, frameDuration))
                if newTime < .zero { newTime = .zero }
                if newTime <= lastWritten { continue }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                if !adaptor.append(pb, withPresentationTime: newTime) {
                    throw writer.error ?? AppError.processingFailed("Couldn't reverse clip.")
                }
                lastWritten = newTime
            }
            chunkEnd = chunkStart
            progress(total > 0 ? 1 - chunkEnd / total : 1)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? AppError.processingFailed("Couldn't reverse clip.")
        }
    }

    static func reverseAudio(source: URL, destination: URL) async throws {
        var samples = try await PCMIO.readInterleaved(url: source)
        let channels = 2
        let frames = samples.count / channels
        var i = 0, j = frames - 1
        while i < j {
            for c in 0..<channels {
                samples.swapAt(i * channels + c, j * channels + c)
            }
            i += 1
            j -= 1
        }
        try PCMIO.writeAAC(interleaved: samples, to: destination)
    }

    // MARK: Noise reduction

    /// Basic noise reduction: 80 Hz high-pass, then a smoothed spectral-floor noise gate.
    static func denoise(source: URL, destination: URL) async throws {
        let channels = 2
        let sampleRate = 44100.0
        var samples = try await PCMIO.readInterleaved(url: source, sampleRate: sampleRate, channels: channels)
        let frames = samples.count / channels
        guard frames > 2048 else {
            try PCMIO.writeAAC(interleaved: samples, to: destination)
            return
        }

        // High-pass biquad (RBJ cookbook), per channel.
        let f0 = 80.0, q = 0.707
        let w0 = 2 * Double.pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        let b0 = Float(((1 + cw) / 2) / a0), b1 = Float(-(1 + cw) / a0), b2 = Float(((1 + cw) / 2) / a0)
        let a1 = Float((-2 * cw) / a0), a2 = Float((1 - alpha) / a0)
        for c in 0..<channels {
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            for n in 0..<frames {
                let idx = n * channels + c
                let x0 = samples[idx]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0
                y2 = y1; y1 = y0
                samples[idx] = y0
            }
        }

        // Noise gate driven by block RMS relative to the estimated noise floor.
        let block = 1024
        let blocks = frames / block
        var rms = [Float](repeating: 0, count: max(blocks, 1))
        for b in 0..<blocks {
            var sum: Float = 0
            for n in (b * block)..<((b + 1) * block) {
                for c in 0..<channels {
                    let v = samples[n * channels + c]
                    sum += v * v
                }
            }
            rms[b] = sqrt(sum / Float(block * channels))
        }
        let sorted = rms.sorted()
        let floor = max(sorted[Int(Double(sorted.count) * 0.1)], 1e-5)
        let threshold = floor * 2.5
        var gains = [Float](repeating: 1, count: max(blocks, 1))
        for b in 0..<blocks {
            let r = rms[b]
            gains[b] = r >= threshold ? 1 : max(0.12, pow(r / threshold, 2))
        }
        // Attack/release smoothing between blocks.
        for b in 1..<max(blocks, 1) {
            if gains[b] < gains[b - 1] {
                gains[b] = gains[b - 1] * 0.7 + gains[b] * 0.3
            }
        }
        for n in 0..<frames {
            let pos = Double(n) / Double(block) - 0.5
            let b0i = Int(Swift.max(0, Swift.min(Double(blocks - 1), pos.rounded(.down))))
            let b1i = Swift.min(blocks - 1, b0i + 1)
            let t = Float((pos - Double(b0i)).clamped(0, 1))
            let g = blocks > 0 ? gains[b0i] * (1 - t) + gains[b1i] * t : 1
            for c in 0..<channels {
                samples[n * channels + c] *= g
            }
        }
        try PCMIO.writeAAC(interleaved: samples, sampleRate: sampleRate, channels: channels, to: destination)
    }

    // MARK: Frames

    /// Full-resolution, correctly oriented frame grab.
    static func frame(url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: time.cmTime)
        return result.image
    }
}
