import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies preset looks and manual adjustments with Core Image.
enum FilterEngine {
    static func apply(_ settings: FilterSettings, to input: CIImage, time: Double) -> CIImage {
        guard !settings.isIdentity else { return input }
        let extent = input.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else { return input }
        var image = input

        if settings.preset != .none && settings.intensity > 0.001 {
            let looked = preset(settings.preset, image: image, time: time).cropped(to: extent)
            if settings.intensity >= 0.999 {
                image = looked
            } else {
                let dissolve = CIFilter.dissolveTransition()
                dissolve.inputImage = image
                dissolve.targetImage = looked
                dissolve.time = Float(settings.intensity)
                image = dissolve.outputImage?.cropped(to: extent) ?? looked
            }
        }
        image = adjust(settings.adjustments, image: image, time: time)
        return image.cropped(to: extent)
    }

    static func adjust(_ a: Adjustments, image input: CIImage, time: Double) -> CIImage {
        guard !a.isIdentity else { return input }
        let extent = input.extent
        var image = input
        let minSide = min(extent.width, extent.height)

        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(a.brightness * 0.3)
            f.contrast = Float(1 + a.contrast * 0.5)
            f.saturation = Float(1 + a.saturation)
            image = f.outputImage ?? image
        }
        if a.warmth != 0 || a.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: CGFloat(6500 + a.warmth * 3000), y: CGFloat(a.tint * 60))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            image = f.outputImage ?? image
        }
        if a.sharpen > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(a.sharpen * 1.5)
            f.radius = Float(max(1, minSide / 600))
            image = f.outputImage ?? image
        }
        if a.blur > 0 {
            let f = CIFilter.gaussianBlur()
            f.inputImage = image.clampedToExtent()
            f.radius = Float(a.blur * 0.03 * minSide)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        if a.vignette > 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(max(extent.width, extent.height) * 0.55)
            f.intensity = Float(a.vignette)
            f.falloff = 0.6
            image = f.outputImage ?? image
        }
        if a.grain > 0 {
            image = addGrain(image, amount: a.grain, time: time)
        }
        return image.cropped(to: extent)
    }

    static func addGrain(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let extent = image.extent
        guard let noiseBase = CIFilter.randomGenerator().outputImage else { return image }
        let frame = Int(time * 24)
        let offset = CGFloat((frame * 97) % 997)
        let grainScale = max(1, min(extent.width, extent.height) / 900)
        let noise = noiseBase
            .transformed(by: CGAffineTransform(translationX: offset, y: offset * 0.7))
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0
        mono.contrast = 1.2
        guard let monoNoise = mono.outputImage else { return image }
        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = monoNoise
        blend.backgroundImage = image
        guard let grained = blend.outputImage?.cropped(to: extent) else { return image }
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = grained
        dissolve.time = Float(amount * 0.45)
        return dissolve.outputImage?.cropped(to: extent) ?? image
    }

    static func preset(_ p: FilterPreset, image: CIImage, time: Double) -> CIImage {
        switch p {
        case .none:
            return image
        case .vivid:
            return controls(image, saturation: 1.35, contrast: 1.1, brightness: 0.02)
        case .warm:
            return temperature(controls(image, saturation: 1.1, contrast: 1.03, brightness: 0.01), warmth: 0.55, tint: 0.1)
        case .cool:
            return temperature(controls(image, saturation: 1.0, contrast: 1.05, brightness: 0), warmth: -0.55, tint: -0.05)
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .process:
            return image.applyingFilter("CIPhotoEffectProcess")
        case .transfer:
            return image.applyingFilter("CIPhotoEffectTransfer")
        case .sepia:
            let f = CIFilter.sepiaTone()
            f.inputImage = image
            f.intensity = 0.85
            return f.outputImage ?? image
        case .cinematic:
            let base = controls(image, saturation: 1.1, contrast: 1.18, brightness: -0.02)
            return colorMatrix(temperature(base, warmth: 0.2, tint: 0),
                               r: (1.05, 0, 0), g: (0, 1.0, 0.02), b: (0, 0.04, 1.08), bias: (0, 0.01, 0.04))
        case .vintage:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.35
            let s = sepia.outputImage ?? image
            let faded = controls(s, saturation: 0.85, contrast: 0.9, brightness: 0.03)
            return adjust(Adjustments(vignette: 0.6), image: faded.cropped(to: image.extent), time: time)
        case .dramatic:
            let c = controls(image, saturation: 0.8, contrast: 1.4, brightness: -0.03)
            return adjust(Adjustments(vignette: 0.7), image: c.cropped(to: image.extent), time: time)
        case .film:
            let f = image.applyingFilter("CIPhotoEffectFade")
            let warm = temperature(f, warmth: 0.15, tint: 0)
            return addGrain(warm.cropped(to: image.extent), amount: 0.6, time: time)
        case .pastel:
            return controls(image, saturation: 0.7, contrast: 0.85, brightness: 0.06)
        case .teal:
            let base = controls(image, saturation: 1.25, contrast: 1.1, brightness: 0)
            return colorMatrix(base, r: (1.0, 0, 0), g: (0, 1.02, 0.05), b: (0, 0.08, 1.1), bias: (-0.02, 0.02, 0.05))
        }
    }

    private static func controls(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return f.outputImage ?? image
    }

    private static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: CGFloat(6500 + warmth * 3000), y: CGFloat(tint * 60))
        f.targetNeutral = CIVector(x: 6500, y: 0)
        return f.outputImage ?? image
    }

    private static func colorMatrix(_ image: CIImage, r: (CGFloat, CGFloat, CGFloat), g: (CGFloat, CGFloat, CGFloat),
                                    b: (CGFloat, CGFloat, CGFloat), bias: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: r.0, y: r.1, z: r.2, w: 0)
        f.gVector = CIVector(x: g.0, y: g.1, z: g.2, w: 0)
        f.bVector = CIVector(x: b.0, y: b.1, z: b.2, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
        return f.outputImage ?? image
    }
}
