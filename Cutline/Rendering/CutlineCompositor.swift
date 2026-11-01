import Foundation
import AVFoundation
import CoreImage

/// Custom AVVideoCompositing renderer: applies effects, transitions, keyframes, text and captions.
final class CutlineCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "app.cutline.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    private let renderer = FrameRenderer()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    override required init() {
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let requestGeneration = currentGeneration
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            if requestGeneration != self.currentGeneration {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: AppError.processingFailed("Missing render instruction."))
                    return
                }
                let size = request.renderContext.size
                let time = request.compositionTime.secondsOrZero
                let image = self.renderer.render(time: time, instruction: instruction, canvasSize: size) { trackID in
                    request.sourceFrame(byTrackID: trackID)
                }
                FrameRenderer.context.render(image, to: output,
                                             bounds: CGRect(origin: .zero, size: size),
                                             colorSpace: FrameRenderer.colorSpace)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}
