import Foundation

enum FilterPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case none, vivid, warm, cool, mono, noir, fade, chrome, instant, process, transfer, sepia,
         cinematic, vintage, dramatic, film, pastel, teal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .instant: return "Instant"
        case .process: return "Process"
        case .transfer: return "Transfer"
        case .sepia: return "Sepia"
        case .cinematic: return "Cinematic"
        case .vintage: return "Vintage"
        case .dramatic: return "Dramatic"
        case .film: return "Film"
        case .pastel: return "Pastel"
        case .teal: return "Teal Pop"
        }
    }
}

struct Adjustments: Codable, Hashable {
    /// -1...1
    var brightness: Double = 0
    /// -1...1
    var contrast: Double = 0
    /// -1...1
    var saturation: Double = 0
    /// -1...1
    var warmth: Double = 0
    /// -1...1
    var tint: Double = 0
    /// 0...1
    var sharpen: Double = 0
    /// 0...1
    var vignette: Double = 0
    /// 0...1
    var grain: Double = 0
    /// 0...1
    var blur: Double = 0

    var isIdentity: Bool { self == Adjustments() }
}

struct FilterSettings: Codable, Hashable {
    var preset: FilterPreset = .none
    var intensity: Double = 1
    var adjustments = Adjustments()

    var isIdentity: Bool { (preset == .none || intensity <= 0.001) && adjustments.isIdentity }
}

struct ChromaKeySettings: Codable, Hashable {
    var enabled = false
    var color: RGBAColor = .green
    /// 0...1
    var tolerance: Double = 0.35
    /// 0...1
    var softness: Double = 0.1
}

/// Per-frame stabilization offsets, normalized to the oriented source frame size.
struct StabilizationData: Codable, Hashable {
    var frameRate: Double
    var sourceStart: Double
    var dx: [Float]
    var dy: [Float]

    func offset(atSource time: Double) -> (Double, Double) {
        guard !dx.isEmpty else { return (0, 0) }
        let idx = Int(((time - sourceStart) * frameRate).rounded()).clamped(0, dx.count - 1)
        return (Double(dx[idx]), Double(dy[idx]))
    }
}

struct EffectSettings: Codable, Hashable {
    var chromaKey = ChromaKeySettings()
    var removeBackground = false
    var stabilize = false
    var stabilization: StabilizationData?
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
