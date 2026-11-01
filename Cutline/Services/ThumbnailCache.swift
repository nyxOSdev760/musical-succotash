import Foundation
import AVFoundation
import UIKit
import ImageIO
import Observation

/// Asynchronous, deduplicated, memory-bounded thumbnail cache for the timeline.
/// Reads are cheap and synchronous; misses are queued and generated off the main thread.
@Observable
final class ThumbnailCache: @unchecked Sendable {
    /// Bumped (on the main thread) whenever new thumbnails arrive so the timeline redraws.
    private(set) var version = 0

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var inflight = Set<String>()
    @ObservationIgnored private var queue: [(key: String, url: URL, time: Double, isImage: Bool)] = []
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var generators: [URL: AVAssetImageGenerator] = [:]
    @ObservationIgnored private var bumpScheduled = false
    @ObservationIgnored private let maxImages = 500
    @ObservationIgnored private let maxConcurrent = 3

    static func key(_ url: URL, _ time: Double) -> String {
        "\(url.lastPathComponent)@\(Int((time * 100).rounded()))"
    }

    /// Returns a cached thumbnail, or nil after queueing generation.
    func image(url: URL, time: Double, isImage: Bool) -> UIImage? {
        let t = isImage ? 0 : time
        let key = Self.key(url, t)
        lock.lock()
        if let img = images[key] {
            lock.unlock()
            return img
        }
        if !inflight.contains(key) {
            inflight.insert(key)
            queue.append((key, url, t, isImage))
            if queue.count > 120 {
                let dropped = queue.removeFirst()
                inflight.remove(dropped.key)
            }
        }
        lock.unlock()
        pump()
        return nil
    }

    /// Returns any cached frame for the URL near `time` to avoid blank tiles while generating.
    func nearest(url: URL, time: Double) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        let prefix = url.lastPathComponent + "@"
        var best: (Double, UIImage)?
        for (k, img) in images where k.hasPrefix(prefix) {
            if let v = Double(k.dropFirst(prefix.count)) {
                let d = abs(v / 100 - time)
                if best == nil || d < best!.0 { best = (d, img) }
            }
        }
        return best?.1
    }

    func clearMemory() {
        lock.lock()
        images.removeAll()
        order.removeAll()
        generators.removeAll()
        lock.unlock()
    }

    private func pump() {
        while true {
            lock.lock()
            guard active < maxConcurrent, !queue.isEmpty else {
                lock.unlock()
                return
            }
            // Most recent requests first: they're what's on screen now.
            let req = queue.removeLast()
            active += 1
            let generator: AVAssetImageGenerator?
            if req.isImage {
                generator = nil
            } else if let g = generators[req.url] {
                generator = g
            } else {
                let asset = AVURLAsset(url: req.url)
                let g = AVAssetImageGenerator(asset: asset)
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 180, height: 180)
                g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
                g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
                generators[req.url] = g
                generator = g
            }
            lock.unlock()

            Task.detached(priority: .userInitiated) { [weak self] in
                var result: UIImage?
                if req.isImage {
                    result = Self.downsample(url: req.url, maxPixel: 180)
                } else if let generator {
                    if let grabbed = try? await generator.image(at: req.time.cmTime) {
                        result = UIImage(cgImage: grabbed.image)
                    }
                }
                self?.finish(key: req.key, image: result)
            }
        }
    }

    private func finish(key: String, image: UIImage?) {
        lock.lock()
        active -= 1
        inflight.remove(key)
        if let image {
            images[key] = image
            order.append(key)
            if order.count > maxImages {
                let overflow = order.count - maxImages
                for k in order.prefix(overflow) { images[k] = nil }
                order.removeFirst(overflow)
            }
        }
        let shouldBump = !bumpScheduled && image != nil
        if shouldBump { bumpScheduled = true }
        lock.unlock()
        if shouldBump {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.bumpScheduled = false
                self.lock.unlock()
                self.version += 1
            }
        }
        pump()
    }

    static func downsample(url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// One-off frame grab for project cards.
    static func posterFrame(url: URL, time: Double, isImage: Bool, maxPixel: CGFloat = 480) async -> UIImage? {
        if isImage { return downsample(url: url, maxPixel: Int(maxPixel)) }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let grabbed = try? await g.image(at: time.cmTime) else { return nil }
        return UIImage(cgImage: grabbed.image)
    }
}
