import Foundation
import CoreImage
import Metal

/// Loads Core Image kernels compiled from Kernels.metal, with pure Core Image fallbacks.
enum MetalKernels {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    private static let library: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()

    static let chromaKeyKernel: CIColorKernel? = {
        guard let data = library else { return nil }
        return try? CIColorKernel(functionName: "chromaKey", fromMetalLibraryData: data)
    }()

    static let channelTintKernel: CIColorKernel? = {
        guard let data = library else { return nil }
        return try? CIColorKernel(functionName: "channelTint", fromMetalLibraryData: data)
    }()

    static func chromaKey(_ image: CIImage, settings: ChromaKeySettings) -> CIImage {
        let key = settings.color
        if let kernel = chromaKeyKernel,
           let out = kernel.apply(extent: image.extent, arguments: [
               image,
               CIVector(x: CGFloat(key.r), y: CGFloat(key.g), z: CGFloat(key.b)),
               Float(settings.tolerance),
               Float(settings.softness)
           ]) {
            return out
        }
        return fallbackChromaKey(image, settings: settings)
    }

    static func tint(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        if let kernel = channelTintKernel,
           let out = kernel.apply(extent: image.extent, arguments: [image, CIVector(x: r, y: g, z: b)]) {
            return out
        }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0)
        ])
    }

    // MARK: Fallback (color cube)

    private static let cubeLock = NSLock()
    private static var cubeCache: (ChromaKeySettings, Data)?

    private static func fallbackChromaKey(_ image: CIImage, settings: ChromaKeySettings) -> CIImage {
        let size = 32
        cubeLock.lock()
        var data: Data
        if let cached = cubeCache, cached.0 == settings {
            data = cached.1
        } else {
            data = makeCube(size: size, settings: settings)
            cubeCache = (settings, data)
        }
        cubeLock.unlock()
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data
        ])
    }

    private static func makeCube(size: Int, settings: ChromaKeySettings) -> Data {
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let key = settings.color
        let kcb = -0.168736 * key.r - 0.331264 * key.g + 0.5 * key.b
        let kcr = 0.5 * key.r - 0.418688 * key.g - 0.081312 * key.b
        let lo = settings.tolerance * 0.45
        let hi = lo + settings.softness * 0.35 + 0.002
        var offset = 0
        for z in 0..<size {
            let b = Double(z) / Double(size - 1)
            for y in 0..<size {
                let g = Double(y) / Double(size - 1)
                for x in 0..<size {
                    let r = Double(x) / Double(size - 1)
                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b
                    let d = sqrt(pow(cb - kcb, 2) + pow(cr - kcr, 2))
                    let t = ((d - lo) / (hi - lo)).clamped(0, 1)
                    let a = t * t * (3 - 2 * t)
                    values[offset] = Float(r * a)
                    values[offset + 1] = Float(g * a)
                    values[offset + 2] = Float(b * a)
                    values[offset + 3] = Float(a)
                    offset += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
