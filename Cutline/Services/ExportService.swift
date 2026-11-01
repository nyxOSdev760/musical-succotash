import Foundation
import AVFoundation
import Photos
import UIKit

enum ExportResolution: Int, CaseIterable, Identifiable, Hashable {
    case p720 = 720
    case p1080 = 1080
    case p2160 = 2160

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p2160: return "4K"
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable, Hashable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct ExportSettings: Hashable {
    var resolution: ExportResolution = .p1080
    var frameRate: Int = 30
    var codec: ExportCodec = .h264
    /// 0...1
    var quality: Double = 0.7

    func renderSize(for aspect: AspectRatio) -> CGSize {
        aspect.size(shortSide: CGFloat(resolution.rawValue))
    }

    func videoBitrate(for aspect: AspectRatio) -> Int {
        let size = renderSize(for: aspect)
        let bitsPerPixel = 0.05 + quality * 0.17
        var rate = Double(size.width * size.height) * Double(frameRate) * bitsPerPixel
        if codec == .hevc { rate *= 0.6 }
        return max(1_000_000, Int(rate))
    }

    static let audioBitrate = 192_000

    func estimatedBytes(duration: Double, aspect: AspectRatio) -> Int64 {
        let bits = Double(videoBitrate(for: aspect) + Self.audioBitrate) * duration
        return Int64(bits / 8 * 1.03)
    }
}

/// Renders the timeline at full quality with AVAssetReader → AVAssetWriter.
final class ExportService: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    static func exportsDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanExports() {
        try? FileManager.default.removeItem(at: exportsDirectory())
    }

    static func fileName(for project: Project, ext: String) -> String {
        let safe = project.name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        let base = safe.trimmingCharacters(in: .whitespaces).isEmpty ? "Cutline" : safe.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return "\(base) \(f.string(from: Date())).\(ext)"
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let r = reader, w = writer
        lock.unlock()
        r?.cancelReading()
        w?.cancelWriting()
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    // MARK: Video

    func exportVideo(project: Project, paths: ProjectPaths, settings: ExportSettings,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let duration = project.duration
        guard duration > 0.05 else { throw AppError.exportFailed("The timeline is empty.") }
        try StorageGuard.ensure(settings.estimatedBytes(duration: duration, aspect: project.canvas.aspect))

        let renderSize = settings.renderSize(for: project.canvas.aspect)
        let options = BuildOptions(isExport: true, renderSize: renderSize, frameRate: Int32(settings.frameRate))
        let built = try await CompositionBuilder.build(project: project, paths: paths, options: options)
        let composition = built.composition

        let url = Self.exportsDirectory().appendingPathComponent(Self.fileName(for: project, ext: "mp4"))
        try? FileManager.default.removeItem(at: url)

        let reader = try AVAssetReader(asset: composition)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw AppError.exportFailed("Couldn't read the timeline.") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate(for: project.canvas.aspect),
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw AppError.exportFailed("This device can't encode \(settings.codec.title) at \(settings.resolution.title).") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportSettings.audioBitrate
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let wasCancelled = lock.withLock { () -> Bool in
            self.reader = reader
            self.writer = writer
            return cancelled
        }
        if wasCancelled { throw AppError.cancelled }

        guard reader.startReading() else { throw AppError.exportFailed(reader.error?.localizedDescription ?? "Couldn't read the timeline.") }
        guard writer.startWriting() else { throw AppError.exportFailed(writer.error?.localizedDescription ?? "Couldn't write the file.") }
        writer.startSession(atSourceTime: .zero)

        let total = max(built.duration, 0.001)
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "app.cutline.export.video")
        let audioQueue = DispatchQueue(label: "app.cutline.export.audio")

        group.enter()
        let videoDone = OnceFlag()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).secondsOrZero
                    if !videoInput.append(sample) {
                        reader.cancelReading()
                        videoInput.markAsFinished()
                        if videoDone.set() { group.leave() }
                        return
                    }
                    progress(min(t / total, 0.99))
                } else {
                    videoInput.markAsFinished()
                    if videoDone.set() { group.leave() }
                    return
                }
            }
        }

        if let audioInput, let audioOutput {
            group.enter()
            let audioDone = OnceFlag()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            audioInput.markAsFinished()
                            if audioDone.set() { group.leave() }
                            return
                        }
                    } else {
                        audioInput.markAsFinished()
                        if audioDone.set() { group.leave() }
                        return
                    }
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw AppError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw AppError.exportFailed(reader.error?.localizedDescription ?? "Rendering failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw AppError.exportFailed(writer.error?.localizedDescription ?? "Couldn't finish the file.")
        }
        progress(1)
        return url
    }

    // MARK: Audio only

    func exportAudio(project: Project, paths: ProjectPaths, includeMusic: Bool = true) async throws -> URL {
        guard project.duration > 0.05 else { throw AppError.exportFailed("The timeline is empty.") }
        let options = BuildOptions(isExport: true, renderSize: project.canvas.aspect.size(shortSide: 360), frameRate: 30, includeMusic: includeMusic)
        let built = try await CompositionBuilder.build(project: project, paths: paths, options: options)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw AppError.exportFailed("There's no audio in this project.") }
        try StorageGuard.ensure(Int64(Double(ExportSettings.audioBitrate) * project.duration / 8))
        let url = Self.exportsDirectory().appendingPathComponent(Self.fileName(for: project, ext: "m4a"))
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.exportFailed("Audio export isn't available.")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        if isCancelled { throw AppError.cancelled }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw AppError.exportFailed(session.error?.localizedDescription ?? "Audio export failed.")
        }
        return url
    }

    // MARK: Still frame

    func exportStill(project: Project, paths: ProjectPaths, at time: Double, resolution: ExportResolution) async throws -> URL {
        guard project.duration > 0.01 else { throw AppError.exportFailed("The timeline is empty.") }
        let size = project.canvas.aspect.size(shortSide: CGFloat(resolution.rawValue))
        let options = BuildOptions(isExport: true, renderSize: size, frameRate: 30)
        let built = try await CompositionBuilder.build(project: project, paths: paths, options: options)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size
        let t = min(max(time, 0), max(project.duration - 0.02, 0))
        let result = try await generator.image(at: t.cmTime)
        guard let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.95) else {
            throw AppError.exportFailed("Couldn't encode the frame.")
        }
        let url = Self.exportsDirectory().appendingPathComponent(Self.fileName(for: project, ext: "jpg"))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Saving

    static func saveToPhotos(_ url: URL) async throws {
        guard await Permissions.photosAddOnly() else { throw AppError.permissionDenied(.photos) }
        let ext = url.pathExtension.lowercased()
        try await PHPhotoLibrary.shared().performChanges {
            if ext == "jpg" || ext == "jpeg" || ext == "png" {
                _ = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
            } else {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
