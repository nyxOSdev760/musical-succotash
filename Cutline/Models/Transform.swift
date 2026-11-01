import Foundation

/// Placement of a visual layer on the canvas.
/// `x`/`y` are offsets from the canvas center as a fraction of canvas width/height (y grows downward).
/// `rotation` is in degrees (clockwise), `opacity` 0...1.
struct Transform2D: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
    var rotation: Double = 0
    var opacity: Double = 1

    static let identity = Transform2D()

    static func lerp(_ a: Transform2D, _ b: Transform2D, _ t: Double) -> Transform2D {
        Transform2D(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            scale: a.scale + (b.scale - a.scale) * t,
            rotation: a.rotation + (b.rotation - a.rotation) * t,
            opacity: a.opacity + (b.opacity - a.opacity) * t
        )
    }
}

enum Easing: String, Codable, CaseIterable, Identifiable, Hashable {
    case linear, easeIn, easeOut, easeInOut, smooth, back

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In-Out"
        case .smooth: return "Smooth"
        case .back: return "Overshoot"
        }
    }

    func apply(_ t: Double) -> Double {
        let x = t.clamped(0, 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: let p = 1 - x; return 1 - p * p * p
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .smooth: return x * x * x * (x * (x * 6 - 15) + 10)
        case .back:
            let c1 = 1.70158
            let c3 = c1 + 1
            return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        }
    }
}

struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Seconds relative to the item's start on the timeline.
    var time: Double
    var transform: Transform2D
    /// Easing used from this keyframe to the next one.
    var easing: Easing = .easeInOut
}

enum KeyframeMath {
    static func transform(base: Transform2D, keyframes: [Keyframe], at time: Double) -> Transform2D {
        guard !keyframes.isEmpty else { return base }
        let sorted = keyframes.sorted { $0.time < $1.time }
        if time <= sorted[0].time { return sorted[0].transform }
        if let last = sorted.last, time >= last.time { return last.transform }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if time >= a.time && time <= b.time {
                let span = max(b.time - a.time, 0.0001)
                let t = a.easing.apply((time - a.time) / span)
                return Transform2D.lerp(a.transform, b.transform, t)
            }
        }
        return base
    }

    static func index(near time: Double, in keyframes: [Keyframe], tolerance: Double = 1.0 / 30.0) -> Int? {
        keyframes.firstIndex { abs($0.time - time) <= tolerance }
    }

    /// Inserts or updates a keyframe at `time`.
    static func upsert(_ keyframes: inout [Keyframe], time: Double, transform: Transform2D) {
        if let i = index(near: time, in: keyframes) {
            keyframes[i].transform = transform
        } else {
            keyframes.append(Keyframe(time: time, transform: transform))
            keyframes.sort { $0.time < $1.time }
        }
    }

    /// Splits keyframes at `time`, returning (left, right) where right is re-based to start at 0.
    static func split(_ keyframes: [Keyframe], base: Transform2D, at time: Double) -> ([Keyframe], [Keyframe]) {
        guard !keyframes.isEmpty else { return ([], []) }
        let boundary = transform(base: base, keyframes: keyframes, at: time)
        var left = keyframes.filter { $0.time < time }
        var right = keyframes.filter { $0.time > time }.map { k -> Keyframe in
            var c = k
            c.id = UUID()
            c.time -= time
            return c
        }
        left.append(Keyframe(time: time, transform: boundary))
        right.insert(Keyframe(time: 0, transform: boundary), at: 0)
        return (left, right)
    }
}

/// Entrance / exit motion presets for clips, overlays and text.
enum MotionPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case none, fade, zoomIn, zoomOut, slideLeft, slideRight, slideUp, slideDown, spin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .spin: return "Spin"
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .fade: return "circle.lefthalf.filled"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .slideLeft: return "arrow.left"
        case .slideRight: return "arrow.right"
        case .slideUp: return "arrow.up"
        case .slideDown: return "arrow.down"
        case .spin: return "arrow.triangle.2.circlepath"
        }
    }
}

enum MotionMath {
    /// Applies in/out motion to a transform at `local` seconds into an item of `duration`.
    static func apply(inPreset: MotionPreset, outPreset: MotionPreset, animationDuration: Double,
                      itemDuration: Double, local: Double, to base: Transform2D) -> Transform2D {
        var t = base
        let maxAnim = (inPreset != .none && outPreset != .none) ? itemDuration / 2 : itemDuration
        let ad = min(max(animationDuration, 0.05), max(maxAnim, 0.05))
        if inPreset != .none && local < ad {
            let p = Easing.easeOut.apply(local / ad)
            t = adjust(inPreset, progress: p, entering: true, t)
        }
        let remaining = itemDuration - local
        if outPreset != .none && remaining < ad {
            let p = Easing.easeIn.apply(max(remaining, 0) / ad)
            t = adjust(outPreset, progress: p, entering: false, t)
        }
        return t
    }

    /// `progress` 0 = fully hidden, 1 = fully visible.
    static func adjust(_ preset: MotionPreset, progress p: Double, entering: Bool, _ input: Transform2D) -> Transform2D {
        var t = input
        let dir: Double = entering ? 1 : -1
        switch preset {
        case .none:
            break
        case .fade:
            t.opacity *= p
        case .zoomIn:
            t.scale *= 0.5 + 0.5 * p
            t.opacity *= p
        case .zoomOut:
            t.scale *= 1.5 - 0.5 * p
            t.opacity *= p
        case .slideLeft:
            t.x += (1 - p) * dir
        case .slideRight:
            t.x -= (1 - p) * dir
        case .slideUp:
            t.y += (1 - p) * dir
        case .slideDown:
            t.y -= (1 - p) * dir
        case .spin:
            t.rotation += (1 - p) * 360 * -dir
            t.scale *= max(p, 0.01)
        }
        return t
    }
}
