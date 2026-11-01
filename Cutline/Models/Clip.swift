import Foundation
import CoreGraphics

enum FitMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

/// Normalized crop rectangle in the oriented source frame (origin top-left).
struct CropRect: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    static let full = CropRect()
    var isFull: Bool { x <= 0.0001 && y <= 0.0001 && width >= 0.9999 && height >= 0.9999 }

    /// Largest centered crop of the given aspect (w/h) for a source of `sourceSize`.
    static func centered(aspect: Double, sourceSize: CGSize) -> CropRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .full }
        let srcAspect = Double(sourceSize.width / sourceSize.height)
        if srcAspect > aspect {
            let w = aspect / srcAspect
            return CropRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = srcAspect / aspect
            return CropRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }
}

enum SpeedRamp: String, Codable, CaseIterable, Identifiable, Hashable {
    case none, montage, hero, bullet, flashIn, flashOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .montage: return "Montage"
        case .hero: return "Hero"
        case .bullet: return "Bullet"
        case .flashIn: return "Flash In"
        case .flashOut: return "Flash Out"
        }
    }

    /// Speed multiplier at normalized source progress `u` (0...1).
    func multiplier(at u: Double) -> Double {
        switch self {
        case .none:
            return 1
        case .montage:
            return 1.25 + 0.75 * sin(u * .pi * 4)
        case .hero:
            let g = exp(-pow((u - 0.5) / 0.15, 2))
            return 2.0 - 1.7 * g
        case .bullet:
            let g = exp(-pow((u - 0.5) / 0.2, 2))
            return 1.0 - 0.85 * g
        case .flashIn:
            return 1 + 3 * pow(1 - u, 2)
        case .flashOut:
            return 1 + 3 * u * u
        }
    }
}

struct SpeedSegment: Hashable {
    var sourceStart: Double
    var sourceDuration: Double
    var speed: Double
    var duration: Double { sourceDuration / speed }
}

enum TransitionType: String, Codable, CaseIterable, Identifiable, Hashable {
    case cut, fade, dissolve, slide, zoom, spin, glitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .dissolve: return "Dissolve"
        case .slide: return "Slide"
        case .zoom: return "Zoom"
        case .spin: return "Spin"
        case .glitch: return "Glitch"
        }
    }

    var icon: String {
        switch self {
        case .cut: return "scissors"
        case .fade: return "circle.lefthalf.filled"
        case .dissolve: return "square.on.square.dashed"
        case .slide: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .spin: return "arrow.triangle.2.circlepath"
        case .glitch: return "waveform.path.ecg"
        }
    }
}

struct TransitionSettings: Codable, Hashable {
    var type: TransitionType = .cut
    var duration: Double = 0.5
}

/// A video or photo placed on the main track or on the overlay track.
struct Clip: Codable, Identifiable, Hashable {
    var id = UUID()
    var mediaID: UUID
    var kind: MediaKind
    var timelineStart: Double
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    var ramp: SpeedRamp = .none
    var reversed = false

    var volume: Double = 1
    var muted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var audioDetached = false
    var denoise = false

    var crop: CropRect = .full
    var quarterTurns: Int = 0
    var flipH = false
    var flipV = false
    var fit: FitMode = .fit

    var transform = Transform2D()
    var keyframes: [Keyframe] = []
    var animationIn: MotionPreset = .none
    var animationOut: MotionPreset = .none
    var animationDuration: Double = 0.5

    var filter = FilterSettings()
    var effects = EffectSettings()
    var transitionOut = TransitionSettings()

    init(media: MediaItem, at start: Double, imageDuration: Double = 3) {
        mediaID = media.id
        kind = media.kind == .image ? .image : .video
        timelineStart = start
        sourceStart = 0
        sourceEnd = media.kind == .image ? imageDuration : max(media.duration, 0.1)
    }

    var sourceDuration: Double { max(sourceEnd - sourceStart, 0.01) }

    var isImage: Bool { kind == .image }

    func segments() -> [SpeedSegment] {
        if isImage {
            return [SpeedSegment(sourceStart: sourceStart, sourceDuration: sourceDuration, speed: 1)]
        }
        let base = speed.clamped(0.1, 8)
        if ramp == .none {
            return [SpeedSegment(sourceStart: sourceStart, sourceDuration: sourceDuration, speed: base)]
        }
        let n = 12
        let segLen = sourceDuration / Double(n)
        return (0..<n).map { i in
            let u = (Double(i) + 0.5) / Double(n)
            let s = (base * ramp.multiplier(at: u)).clamped(0.1, 8)
            return SpeedSegment(sourceStart: sourceStart + Double(i) * segLen, sourceDuration: segLen, speed: s)
        }
    }

    /// Duration on the timeline (after speed changes).
    var duration: Double {
        segments().reduce(0) { $0 + $1.duration }
    }

    var timelineEnd: Double { timelineStart + duration }

    /// Average playback speed across the clip.
    var effectiveSpeed: Double { sourceDuration / max(duration, 0.0001) }

    /// Source-media time shown at `local` seconds after the clip starts on the timeline.
    func sourceTime(atLocal local: Double) -> Double {
        if isImage { return sourceStart + local }
        var acc = 0.0
        for seg in segments() {
            let d = seg.duration
            if local <= acc + d {
                return seg.sourceStart + max(local - acc, 0) * seg.speed
            }
            acc += d
        }
        return sourceEnd
    }

    /// Timeline-local time for a source time (inverse of `sourceTime(atLocal:)`).
    func localTime(forSource source: Double) -> Double {
        if isImage { return source - sourceStart }
        var acc = 0.0
        for seg in segments() {
            if source <= seg.sourceStart + seg.sourceDuration {
                return acc + max(source - seg.sourceStart, 0) / seg.speed
            }
            acc += seg.duration
        }
        return acc
    }

    func contains(_ time: Double) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    /// Copies "look" settings (effects, filters, speed, audio and motion) onto another clip.
    func effectsPayload() -> ClipEffectsPayload {
        ClipEffectsPayload(filter: filter, chromaKey: effects.chromaKey, removeBackground: effects.removeBackground,
                           speed: speed, ramp: ramp, volume: volume, fadeIn: fadeIn, fadeOut: fadeOut,
                           animationIn: animationIn, animationOut: animationOut, animationDuration: animationDuration,
                           fit: fit, flipH: flipH, flipV: flipV, quarterTurns: quarterTurns, denoise: denoise)
    }

    mutating func apply(_ p: ClipEffectsPayload) {
        filter = p.filter
        effects.chromaKey = p.chromaKey
        effects.removeBackground = p.removeBackground
        if !isImage {
            speed = p.speed
            ramp = p.ramp
            volume = p.volume
            fadeIn = p.fadeIn
            fadeOut = p.fadeOut
            denoise = p.denoise
        }
        animationIn = p.animationIn
        animationOut = p.animationOut
        animationDuration = p.animationDuration
        fit = p.fit
        flipH = p.flipH
        flipV = p.flipV
        quarterTurns = p.quarterTurns
    }
}

struct ClipEffectsPayload: Codable, Hashable {
    var filter: FilterSettings
    var chromaKey: ChromaKeySettings
    var removeBackground: Bool
    var speed: Double
    var ramp: SpeedRamp
    var volume: Double
    var fadeIn: Double
    var fadeOut: Double
    var animationIn: MotionPreset
    var animationOut: MotionPreset
    var animationDuration: Double
    var fit: FitMode
    var flipH: Bool
    var flipV: Bool
    var quarterTurns: Int
    var denoise: Bool
}
