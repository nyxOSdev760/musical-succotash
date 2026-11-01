import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Metal

/// Person segmentation for background removal (Vision).
final class PersonSegmenter {
    private let request: VNGeneratePersonSegmentationRequest

    init(accurate: Bool) {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func mask(for image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let sx = image.extent.width / max(mask.extent.width, 1)
        let sy = image.extent.height / max(mask.extent.height, 1)
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }
}

/// Builds the final frame for a moment on the timeline with Core Image.
final class FrameRenderer {
    static let context: CIContext = {
        if let device = MetalKernels.device {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Cutline"])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private var segmenter: PersonSegmenter?

    func render(time t: Double, instruction: CompositionInstruction, canvasSize: CGSize,
                sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let snapshot = instruction.renderBox.snapshot
        let project = snapshot.project
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let black = CIImage(color: .black).cropped(to: canvas)

        // Resolve the source image for a layer (oriented + per-clip effects, in source pixel space).
        var processedCache: [UUID: CIImage] = [:]
        func processed(_ layer: LayerSpec) -> (CIImage, Clip)? {
            guard let clip = snapshot.clips[layer.clipID] else { return nil }
            if let hit = processedCache[layer.clipID] { return (hit, clip) }
            var image: CIImage?
            switch layer.source {
            case .track(let id):
                if let pb = sourceFrame(id) {
                    var img = CIImage(cvPixelBuffer: pb).oriented(layer.orientation)
                    img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                    image = img
                }
            case .image(let url):
                if let img = TextRenderer.photo(url: url, maxPixel: snapshot.isExport ? 4096 : 1600) {
                    image = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                }
            case .missing:
                image = missingPattern()
            }
            guard var img = image else { return nil }
            let local = (t - clip.timelineStart).clamped(0, clip.duration)
            img = applyClipEffects(img, clip: clip, sourceTime: clip.sourceTime(atLocal: local), time: t,
                                   accurate: snapshot.isExport)
            processedCache[layer.clipID] = img
            return (img, clip)
        }

        // Place a processed layer on the canvas with fit/fill, keyframes and motion presets.
        func placed(_ layer: LayerSpec) -> CIImage? {
            guard let pr = processed(layer) else { return nil }
            let img = pr.0, clip = pr.1
            let ext = img.extent
            guard ext.width > 0, ext.height > 0 else { return nil }
            let fitScale = clip.fit == .fit
                ? min(canvas.width / ext.width, canvas.height / ext.height)
                : max(canvas.width / ext.width, canvas.height / ext.height)
            let local = (t - clip.timelineStart).clamped(0, clip.duration)
            var tf = KeyframeMath.transform(base: clip.transform, keyframes: clip.keyframes, at: local)
            tf = MotionMath.apply(inPreset: clip.animationIn, outPreset: clip.animationOut,
                                  animationDuration: clip.animationDuration, itemDuration: clip.duration,
                                  local: t - clip.timelineStart, to: tf)
            return Self.place(img, canvas: canvasSize, transform: tf, baseScale: fitScale)
        }

        let mains = instruction.layers.filter { !$0.isOverlay && $0.isVisible(at: t) }.sorted { $0.order < $1.order }
        let primary = mains.first { t >= $0.coreStart && t < $0.coreEnd } ?? mains.first

        // Background
        var background = black
        switch project.canvas.background {
        case .black:
            break
        case .color:
            background = CIImage(color: project.canvas.backgroundColor.ciColor).cropped(to: canvas)
        case .blur:
            if let primary, let pr = processed(primary), pr.1.fit == .fit {
                background = blurredFill(pr.0, canvas: canvas, amount: project.canvas.blurAmount)
            }
        }

        var output = background
        if mains.count >= 2,
           let outLayer = mains.first(where: { $0.transitionOut?.contains(t) == true }),
           let window = outLayer.transitionOut,
           let inLayer = mains.first(where: { $0.order == outLayer.order + 1 }) {
            let a = placed(outLayer) ?? CIImage.empty()
            let b = placed(inLayer) ?? CIImage.empty()
            output = TransitionRenderer.blend(type: window.type, progress: window.progress(at: t), from: a, to: b,
                                              background: background, canvas: canvas,
                                              seed: Int(t * 30))
        } else if let primary, let img = placed(primary) {
            output = img.composited(over: background)
        }

        // Overlay clips (picture-in-picture), in project order.
        let overlays = instruction.layers.filter { $0.isOverlay && $0.isVisible(at: t) }.sorted { $0.order < $1.order }
        for layer in overlays {
            if let img = placed(layer) { output = img.composited(over: output) }
        }
        output = output.cropped(to: canvas)

        // Whole-timeline look.
        if !project.globalFilter.isIdentity {
            output = FilterEngine.apply(project.globalFilter, to: output, time: t)
        }

        // Photos, stickers and shapes.
        for item in project.overlays where item.contains(t) {
            if let img = overlayImage(item, canvas: canvasSize, resolver: snapshot.resolver, isExport: snapshot.isExport) {
                let local = t - item.start
                var tf = KeyframeMath.transform(base: item.transform, keyframes: item.keyframes, at: local)
                tf = MotionMath.apply(inPreset: item.animationIn, outPreset: item.animationOut,
                                      animationDuration: item.animationDuration, itemDuration: item.duration,
                                      local: local, to: tf)
                output = Self.place(img, canvas: canvasSize, transform: tf, baseScale: 1).composited(over: output)
            }
        }

        // Text.
        for item in project.texts where item.contains(t) {
            if let img = textLayer(item, t: t, canvas: canvasSize) {
                output = img.composited(over: output)
            }
        }

        // Captions.
        if let segment = project.captions.segment(at: t) {
            let highlight = segment.activeWordIndex(at: t)
            if let img = TextRenderer.captionImage(segment, track: project.captions, highlightIndex: highlight, canvasWidth: canvasSize.width) {
                var tf = Transform2D()
                tf.y = project.captions.verticalPosition - 0.5
                output = Self.place(img, canvas: canvasSize, transform: tf, baseScale: 1).composited(over: output)
            }
        }

        return output.cropped(to: canvas)
    }

    // MARK: Pieces

    static func place(_ image: CIImage, canvas: CGSize, transform tf: Transform2D, baseScale: CGFloat) -> CIImage {
        let e = image.extent
        guard e.width.isFinite, e.height.isFinite, e.width > 0, e.height > 0 else { return CIImage.empty() }
        let s = baseScale * CGFloat(max(tf.scale, 0.001))
        let m = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(tf.rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2 + CGFloat(tf.x) * canvas.width,
                                             y: canvas.height / 2 - CGFloat(tf.y) * canvas.height))
        let out = image.transformed(by: m)
        return TransitionRenderer.withAlpha(out, tf.opacity)
    }

    private func applyClipEffects(_ input: CIImage, clip: Clip, sourceTime: Double, time: Double, accurate: Bool) -> CIImage {
        var img = input
        var ext = img.extent

        if clip.effects.stabilize, let data = clip.effects.stabilization, !clip.isImage {
            let (dx, dy) = data.offset(atSource: sourceTime)
            let zoom: CGFloat = 1.12
            let m = CGAffineTransform(translationX: CGFloat(dx) * ext.width, y: CGFloat(dy) * ext.height)
                .concatenating(CGAffineTransform(translationX: -ext.midX, y: -ext.midY))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: ext.midX, y: ext.midY))
            img = img.clampedToExtent().transformed(by: m).cropped(to: ext)
        }

        if clip.effects.chromaKey.enabled {
            img = MetalKernels.chromaKey(img, settings: clip.effects.chromaKey)
        }

        if clip.effects.removeBackground {
            if segmenter == nil { segmenter = PersonSegmenter(accurate: accurate) }
            if let mask = segmenter?.mask(for: img) {
                let f = CIFilter.blendWithMask()
                f.inputImage = img
                f.backgroundImage = CIImage.empty()
                f.maskImage = mask
                img = f.outputImage?.cropped(to: ext) ?? img
            }
        }

        if !clip.filter.isIdentity {
            img = FilterEngine.apply(clip.filter, to: img, time: time)
        }

        if !clip.crop.isFull {
            let c = clip.crop
            let rect = CGRect(x: CGFloat(c.x) * ext.width,
                              y: CGFloat(1 - c.y - c.height) * ext.height,
                              width: CGFloat(c.width) * ext.width,
                              height: CGFloat(c.height) * ext.height).integral
            if rect.width > 2, rect.height > 2 {
                img = img.cropped(to: rect)
                img = img.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                ext = img.extent
            }
        }

        let turns = ((clip.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        if clip.flipH {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: 0))
        }
        if clip.flipV {
            img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            img = img.transformed(by: CGAffineTransform(translationX: 0, y: -img.extent.minY))
        }
        return img
    }

    private func blurredFill(_ source: CIImage, canvas: CGRect, amount: Double) -> CIImage {
        let e = source.extent
        guard e.width > 0, e.height > 0 else { return CIImage(color: .black).cropped(to: canvas) }
        let down: CGFloat = 0.25
        let fill = max(canvas.width / e.width, canvas.height / e.height) * down
        let small = source
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .transformed(by: CGAffineTransform(translationX: canvas.midX * down, y: canvas.midY * down))
        let smallCanvas = CGRect(x: 0, y: 0, width: canvas.width * down, height: canvas.height * down)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = small.clampedToExtent()
        blur.radius = Float(max(canvas.width, canvas.height) * down * CGFloat(0.02 + amount * 0.06))
        let blurred = (blur.outputImage ?? small).cropped(to: smallCanvas)
        let dim = CIFilter.colorControls()
        dim.inputImage = blurred
        dim.brightness = -0.12
        dim.saturation = 1.1
        let up = (dim.outputImage ?? blurred).transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
        return up.cropped(to: canvas)
    }

    private func overlayImage(_ item: OverlayItem, canvas: CGSize, resolver: MediaResolver, isExport: Bool) -> CIImage? {
        switch item.kind {
        case .sticker:
            return TextRenderer.stickerImage(item.sticker, canvasSize: canvas)
        case .shape:
            return TextRenderer.shapeImage(item.shape, color: item.color, filled: item.filled, canvasSize: canvas)
        case .image:
            guard let url = resolver.imageURL(for: item.imageMediaID),
                  let img = TextRenderer.photo(url: url, maxPixel: isExport ? 2048 : 1024) else { return nil }
            let e = img.extent
            let box = min(canvas.width, canvas.height) * 0.45
            let s = min(box / max(e.width, 1), box / max(e.height, 1))
            return img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
    }

    private func textLayer(_ item: TextItem, t: Double, canvas: CGSize) -> CIImage? {
        let local = t - item.start
        let ad = min(max(item.animationDuration, 0.05), item.duration / 2)
        var visibleChars: Int?
        var tf = KeyframeMath.transform(base: item.transform, keyframes: item.keyframes, at: local)
        let count = item.text.count

        if local < ad {
            let p = local / ad
            switch item.animationIn {
            case .none: break
            case .fade: tf.opacity *= Easing.easeOut.apply(p)
            case .pop:
                tf.scale *= max(0.01, Easing.back.apply(p))
                tf.opacity *= min(1, p * 2)
            case .slide:
                tf.y += (1 - Easing.easeOut.apply(p)) * 0.12
                tf.opacity *= Easing.easeOut.apply(p)
            case .typewriter:
                break
            }
        }
        if item.animationIn == .typewriter {
            let typeDuration = min(max(Double(count) * 0.06, 0.3), item.duration * 0.6)
            if local < typeDuration {
                visibleChars = Int((local / typeDuration) * Double(count))
            }
        }
        let remaining = item.duration - local
        if remaining < ad {
            let p = max(remaining, 0) / ad
            switch item.animationOut {
            case .none: break
            case .fade: tf.opacity *= Easing.easeIn.apply(p)
            case .pop:
                tf.scale *= max(0.01, Easing.easeIn.apply(p))
                tf.opacity *= p
            case .slide:
                tf.y += (1 - Easing.easeIn.apply(p)) * 0.12
                tf.opacity *= Easing.easeIn.apply(p)
            case .typewriter:
                break
            }
        }
        if item.animationOut == .typewriter {
            let eraseDuration = min(max(Double(count) * 0.04, 0.25), item.duration * 0.4)
            if remaining < eraseDuration {
                let shown = Int((max(remaining, 0) / eraseDuration) * Double(count))
                visibleChars = min(visibleChars ?? count, shown)
            }
        }
        if let v = visibleChars, v <= 0 { return nil }
        guard let img = TextRenderer.textImage(item, canvasWidth: canvas.width, visibleCharacters: visibleChars) else { return nil }
        return Self.place(img, canvas: canvas, transform: tf, baseScale: 1)
    }

    private func missingPattern() -> CIImage {
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0.35, green: 0.05, blue: 0.08)
        checker.color1 = CIColor(red: 0.15, green: 0.02, blue: 0.04)
        checker.width = 40
        checker.center = .zero
        checker.sharpness = 1
        return (checker.outputImage ?? CIImage(color: .red)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
}
