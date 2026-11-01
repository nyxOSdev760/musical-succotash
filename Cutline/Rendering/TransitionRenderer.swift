import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

enum TransitionRenderer {
    static func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        if alpha >= 0.999 { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(alpha, 0)))
        ])
    }

    private static func around(_ canvas: CGRect, scale: CGFloat, rotation: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
    }

    /// Blends two fully placed layer images (transparent outside their content) for a transition.
    /// `background` is what shows behind both (canvas background).
    static func blend(type: TransitionType, progress raw: Double, from a: CIImage, to b: CIImage,
                      background: CIImage, canvas: CGRect, seed: Int) -> CIImage {
        let p = raw.clamped(0, 1)
        let black = CIImage(color: .black).cropped(to: canvas)
        switch type {
        case .cut:
            return (p < 0.5 ? a : b).composited(over: background)
        case .fade:
            if p < 0.5 {
                return withAlpha(a.composited(over: background), 1 - p * 2).composited(over: black)
            } else {
                return withAlpha(b.composited(over: background), p * 2 - 1).composited(over: black)
            }
        case .dissolve:
            let f = CIFilter.dissolveTransition()
            f.inputImage = a.composited(over: background)
            f.targetImage = b.composited(over: background)
            f.time = Float(Easing.easeInOut.apply(p))
            return f.outputImage?.cropped(to: canvas) ?? b
        case .slide:
            let e = CGFloat(Easing.easeInOut.apply(p))
            let w = canvas.width
            let movedA = a.composited(over: background).cropped(to: canvas)
                .transformed(by: CGAffineTransform(translationX: -e * w, y: 0))
            let movedB = b.composited(over: background).cropped(to: canvas)
                .transformed(by: CGAffineTransform(translationX: (1 - e) * w, y: 0))
            return movedB.composited(over: movedA).composited(over: black).cropped(to: canvas)
        case .zoom:
            let e = CGFloat(Easing.easeInOut.apply(p))
            let za = a.composited(over: background).cropped(to: canvas)
                .transformed(by: around(canvas, scale: 1 + e * 0.6, rotation: 0))
            let zb = b.composited(over: background).cropped(to: canvas)
                .transformed(by: around(canvas, scale: 0.7 + 0.3 * e, rotation: 0))
            return withAlpha(zb, Double(e)).composited(over: withAlpha(za, Double(1 - e))).composited(over: black).cropped(to: canvas)
        case .spin:
            let e = CGFloat(Easing.easeInOut.apply(p))
            if e < 0.5 {
                let k = e * 2
                let sa = a.composited(over: background).cropped(to: canvas)
                    .transformed(by: around(canvas, scale: 1 - k * 0.9, rotation: -k * .pi))
                return sa.composited(over: black).cropped(to: canvas)
            } else {
                let k = (1 - e) * 2
                let sb = b.composited(over: background).cropped(to: canvas)
                    .transformed(by: around(canvas, scale: 1 - k * 0.9, rotation: k * .pi))
                return sb.composited(over: black).cropped(to: canvas)
            }
        case .glitch:
            return glitch(p: p, a: a.composited(over: background).cropped(to: canvas),
                          b: b.composited(over: background).cropped(to: canvas), canvas: canvas, seed: seed)
        }
    }

    private static func glitch(p: Double, a: CIImage, b: CIImage, canvas: CGRect, seed: Int) -> CIImage {
        var rng = SeededRandom(seed: UInt64(seed &* 7919 &+ 17))
        let flicker = rng.next() < 0.25
        let base = (p < 0.5) != flicker ? a : b
        let strength = CGFloat(sin(p * .pi))
        let shift = strength * canvas.width * 0.025

        let red = MetalKernels.tint(base, r: 1, g: 0, b: 0)
            .transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let green = MetalKernels.tint(base, r: 0, g: 1, b: 0)
        let blue = MetalKernels.tint(base, r: 0, g: 0, b: 1)
            .transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        let add = CIFilter.additionCompositing()
        add.inputImage = red
        add.backgroundImage = green
        let rg = add.outputImage ?? base
        let add2 = CIFilter.additionCompositing()
        add2.inputImage = blue
        add2.backgroundImage = rg
        var result = (add2.outputImage ?? base).cropped(to: canvas)

        // Displaced horizontal slices.
        let slices = Int(3 + strength * 6)
        for _ in 0..<slices {
            let h = canvas.height * CGFloat(0.02 + rng.next() * 0.08)
            let y = canvas.minY + CGFloat(rng.next()) * (canvas.height - h)
            let dx = (CGFloat(rng.next()) - 0.5) * canvas.width * 0.15 * strength
            let band = base.cropped(to: CGRect(x: canvas.minX, y: y, width: canvas.width, height: h))
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            result = band.composited(over: result)
        }
        return result.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
