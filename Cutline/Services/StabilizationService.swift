import Foundation
import AVFoundation
import Vision
import CoreImage

/// Estimates camera shake with Vision image registration and produces smoothing offsets.
enum StabilizationService {
    static func analyze(url: URL, sourceStart: Double, sourceEnd: Double,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> StabilizationData {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.processingFailed("This clip has no video to stabilize.")
        }
        let (transform, nominalFPS) = try await track.load(.preferredTransform, .nominalFrameRate)
        let orientation = AssetCache.orientation(from: transform)
        let fps = Double(nominalFPS > 0 ? nominalFPS : 30)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: sourceStart, preferredTimescale: 60000),
                                       end: CMTime(seconds: sourceEnd, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.processingFailed("Couldn't analyze clip.") }

        var times: [Double] = []
        var pathX: [Double] = []
        var pathY: [Double] = []
        var previous: CIImage?
        var accX = 0.0, accY = 0.0
        var analysisWidth: CGFloat = 320
        var analysisHeight: CGFloat = 320
        let span = max(sourceEnd - sourceStart, 0.01)

        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).secondsOrZero
            var image = CIImage(cvPixelBuffer: pb).oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scale = 320 / max(image.extent.width, 1)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            analysisWidth = small.extent.width
            analysisHeight = small.extent.height

            if let prev = previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
                let handler = VNImageRequestHandler(ciImage: prev, options: [:])
                try? handler.perform([request])
                if let obs = request.results?.first {
                    // The transform aligns the current frame onto the previous one,
                    // i.e. it is the negative of the content's motion.
                    accX -= Double(obs.alignmentTransform.tx)
                    accY -= Double(obs.alignmentTransform.ty)
                }
            }
            previous = small
            times.append(t)
            pathX.append(accX)
            pathY.append(accY)
            progress(((t - sourceStart) / span).clamped(0, 1))
        }
        guard !times.isEmpty else { throw AppError.processingFailed("Couldn't analyze clip.") }

        // Smooth the camera path with a centered moving average and correct toward it.
        let radius = max(5, Int(fps * 0.5))
        let n = pathX.count
        var dx = [Float](repeating: 0, count: n)
        var dy = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            var sx = 0.0, sy = 0.0
            for j in lo...hi {
                sx += pathX[j]
                sy += pathY[j]
            }
            let count = Double(hi - lo + 1)
            let smoothX = sx / count, smoothY = sy / count
            let maxShift = 0.06
            dx[i] = Float(((smoothX - pathX[i]) / Double(analysisWidth)).clamped(-maxShift, maxShift))
            dy[i] = Float(((smoothY - pathY[i]) / Double(analysisHeight)).clamped(-maxShift, maxShift))
        }
        return StabilizationData(frameRate: fps, sourceStart: times[0], dx: dx, dy: dy)
    }
}
