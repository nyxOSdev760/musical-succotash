import Foundation
import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

/// A movie file received from the Photos picker, copied into a temporary location.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ImportResult {
    var items: [MediaItem] = []
    var failures: [String] = []
}

enum MediaImportService {
    static let proxyThreshold: Double = 1920 * 1088

    // MARK: Photos picker

    static func importPickerItems(_ items: [PhotosPickerItem], into paths: ProjectPaths,
                                  progress: @escaping @MainActor (Int, Int) -> Void) async -> ImportResult {
        var result = ImportResult()
        for (index, item) in items.enumerated() {
            await progress(index, items.count)
            do {
                let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                if isMovie {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw AppError.unsupportedFormat("Video \(index + 1)")
                    }
                    let media = try await importVideo(from: movie.url, originalName: "Video \(index + 1)", into: paths, move: true)
                    result.items.append(media)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AppError.unsupportedFormat("Photo \(index + 1)")
                    }
                    let media = try importImage(data: data, originalName: "Photo \(index + 1)", into: paths)
                    result.items.append(media)
                }
            } catch {
                let message = (error as? AppError)?.errorDescription ?? error.localizedDescription
                result.failures.append(message)
            }
        }
        await progress(items.count, items.count)
        return result
    }

    // MARK: Video

    static func importVideo(from url: URL, originalName: String, into paths: ProjectPaths, move: Bool) async throws -> MediaItem {
        try paths.ensureDirectories()
        try StorageGuard.ensure(StorageGuard.fileSize(url))
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard playable, let track = videoTracks.first else {
            throw AppError.unsupportedFormat(originalName)
        }
        let duration = try await asset.load(.duration).secondsOrZero
        guard duration > 0.05 else { throw AppError.unsupportedFormat(originalName) }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        let oriented = natural.applying(transform)
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty

        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let dest = paths.media(fileName)
        if move {
            try FileManager.default.moveItem(at: url, to: dest)
        } else {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return MediaItem(id: id, fileName: fileName, proxyFileName: nil, originalName: originalName, kind: .video,
                         duration: duration, width: Double(abs(oriented.width)), height: Double(abs(oriented.height)),
                         hasAudio: hasAudio, hasVideo: true, frameRate: Double(fps > 0 ? fps : 30), beats: nil)
    }

    /// Creates a 720p editing proxy for large videos. Returns the proxy file name, or nil if not needed.
    static func makeProxyIfNeeded(for media: MediaItem, paths: ProjectPaths) async -> String? {
        guard media.kind == .video, media.width * media.height > proxyThreshold else { return nil }
        let name = MediaResolver.proxyName(media)
        let dest = paths.cache(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        let asset = AVURLAsset(url: paths.media(media.fileName))
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status == .completed { return name }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    // MARK: Image

    static func importImage(data: Data, originalName: String, into paths: ProjectPaths) throws -> MediaItem {
        try paths.ensureDirectories()
        try StorageGuard.ensure(Int64(data.count))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AppError.unsupportedFormat(originalName)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError.unsupportedFormat(originalName)
        }
        let image = UIImage(cgImage: cg)
        let hasAlpha: Bool = {
            switch cg.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast: return true
            default: return false
            }
        }()
        let id = UUID()
        let fileName: String
        let encoded: Data?
        if hasAlpha {
            fileName = "\(id.uuidString).png"
            encoded = image.pngData()
        } else {
            fileName = "\(id.uuidString).jpg"
            encoded = image.jpegData(compressionQuality: 0.92)
        }
        guard let out = encoded else { throw AppError.importFailed("Couldn't read “\(originalName)”.") }
        try out.write(to: paths.media(fileName), options: .atomic)
        return MediaItem(id: id, fileName: fileName, proxyFileName: nil, originalName: originalName, kind: .image,
                         duration: 3, width: Double(cg.width), height: Double(cg.height),
                         hasAudio: false, hasVideo: true, frameRate: 30, beats: nil)
    }

    static func importImage(cgImage: CGImage, originalName: String, into paths: ProjectPaths) throws -> MediaItem {
        guard let data = UIImage(cgImage: cgImage).pngData() else { throw AppError.importFailed("Couldn't save frame.") }
        return try importImage(data: data, originalName: originalName, into: paths)
    }

    // MARK: Audio

    static func importAudio(from url: URL, into paths: ProjectPaths, move: Bool) async throws -> MediaItem {
        try paths.ensureDirectories()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try StorageGuard.ensure(StorageGuard.fileSize(url))
        let asset = AVURLAsset(url: url)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { throw AppError.unsupportedFormat(url.lastPathComponent) }
        let duration = try await asset.load(.duration).secondsOrZero
        guard duration > 0.05 else { throw AppError.unsupportedFormat(url.lastPathComponent) }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let dest = paths.media(fileName)
        if move {
            try FileManager.default.moveItem(at: url, to: dest)
        } else {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        let name = url.deletingPathExtension().lastPathComponent
        return MediaItem(id: id, fileName: fileName, proxyFileName: nil, originalName: name, kind: .audio,
                         duration: duration, width: 0, height: 0, hasAudio: true, hasVideo: false, frameRate: 0, beats: nil)
    }
}

/// Resolves which file on disk backs a clip, honoring proxies and derived (reversed / denoised) media.
struct MediaResolver {
    let paths: ProjectPaths
    let media: [UUID: MediaItem]
    let preferProxy: Bool

    init(paths: ProjectPaths, media: [MediaItem], preferProxy: Bool) {
        self.paths = paths
        self.preferProxy = preferProxy
        var dict: [UUID: MediaItem] = [:]
        for m in media { dict[m.id] = m }
        self.media = dict
    }

    static func proxyName(_ m: MediaItem) -> String { "proxy_\(m.id.uuidString).mp4" }
    static func reversedVideoName(_ m: MediaItem) -> String { "rev_\(m.id.uuidString).mov" }
    static func reversedProxyName(_ m: MediaItem) -> String { "revproxy_\(m.id.uuidString).mov" }
    static func reversedAudioName(_ m: MediaItem) -> String { "revaudio_\(m.id.uuidString).m4a" }
    static func denoisedName(_ m: MediaItem, reversed: Bool) -> String { "dn_\(reversed ? "rev_" : "")\(m.id.uuidString).m4a" }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func originalURL(_ m: MediaItem) -> URL? {
        let u = paths.media(m.fileName)
        return exists(u) ? u : nil
    }

    func isMissing(_ mediaID: UUID) -> Bool {
        guard let m = media[mediaID] else { return true }
        return originalURL(m) == nil
    }

    func videoURL(for clip: Clip) -> URL? {
        guard let m = media[clip.mediaID], m.kind == .video else { return nil }
        if clip.reversed {
            if preferProxy {
                let rp = paths.cache(Self.reversedProxyName(m))
                if exists(rp) { return rp }
            }
            let r = paths.cache(Self.reversedVideoName(m))
            if exists(r) { return r }
        }
        if preferProxy {
            let pu = paths.cache(Self.proxyName(m))
            if exists(pu) { return pu }
        }
        return originalURL(m)
    }

    /// The best file for thumbnails (proxy when available).
    func thumbnailURL(for mediaID: UUID, reversed: Bool) -> URL? {
        guard let m = media[mediaID] else { return nil }
        if m.kind == .image { return originalURL(m) }
        if reversed {
            let rp = paths.cache(Self.reversedProxyName(m))
            if exists(rp) { return rp }
            let r = paths.cache(Self.reversedVideoName(m))
            if exists(r) { return r }
        }
        let pu = paths.cache(Self.proxyName(m))
        if exists(pu) { return pu }
        return originalURL(m)
    }

    func imageURL(for mediaID: UUID?) -> URL? {
        guard let id = mediaID, let m = media[id] else { return nil }
        return originalURL(m)
    }

    func audioURL(mediaID: UUID, reversed: Bool, denoise: Bool) -> URL? {
        guard let m = media[mediaID], m.hasAudio else { return nil }
        if denoise {
            let d = paths.cache(Self.denoisedName(m, reversed: reversed))
            if exists(d) { return d }
        }
        if reversed {
            let r = paths.cache(Self.reversedAudioName(m))
            if exists(r) { return r }
        }
        return originalURL(m)
    }
}

/// Caches loaded AVURLAssets and their track info.
final class AssetCache: @unchecked Sendable {
    struct Info {
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        let duration: CMTime
        let videoRange: CMTimeRange
        let audioRange: CMTimeRange
        let orientation: CGImagePropertyOrientation
        let frameDuration: CMTime
    }

    static let shared = AssetCache()
    private let lock = NSLock()
    private var cache: [URL: Info] = [:]

    func info(for url: URL) async throws -> Info {
        if let hit = lock.withLock({ cache[url] }) {
            return hit
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var orientation: CGImagePropertyOrientation = .up
        var videoRange = CMTimeRange(start: .zero, duration: duration)
        var frameDuration = CMTime(value: 1, timescale: 30)
        if let v = video {
            let (transform, range, fps) = try await v.load(.preferredTransform, .timeRange, .nominalFrameRate)
            orientation = Self.orientation(from: transform)
            videoRange = range
            if fps > 0 { frameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, (fps * 1000).rounded()))) }
        }
        var audioRange = CMTimeRange(start: .zero, duration: duration)
        if let a = audio {
            audioRange = try await a.load(.timeRange)
        }
        let info = Info(asset: asset, video: video, audio: audio, duration: duration, videoRange: videoRange,
                        audioRange: audioRange, orientation: orientation, frameDuration: frameDuration)
        lock.withLock { cache[url] = info }
        return info
    }

    func invalidate(_ url: URL) {
        lock.lock()
        cache[url] = nil
        lock.unlock()
    }

    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a.rounded(), b = t.b.rounded(), c = t.c.rounded(), d = t.d.rounded()
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }
}

/// Generates a tiny black video used as the composition's timing backbone,
/// so photos, text and gaps always have frames to render on.
actor BlankVideoProvider {
    static let shared = BlankVideoProvider()
    private var cached: URL?

    func url() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("cutline_blank_v2.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
                cached = url
                return url
            }
            try? FileManager.default.removeItem(at: url)
        }
        try await make(url)
        cached = url
        return url
    }

    private func make(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = 64
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        guard writer.startWriting() else { throw AppError.processingFailed("Couldn't prepare the renderer.") }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pb = buffer else { throw AppError.processingFailed("Couldn't prepare the renderer.") }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * size)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        await writer.finishWriting()
        if writer.status != .completed {
            throw AppError.processingFailed("Couldn't prepare the renderer.")
        }
    }
}
