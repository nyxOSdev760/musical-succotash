import Foundation

enum OverlayKind: String, Codable, Hashable {
    case image, sticker, shape
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case rectangle, roundedRect, circle, triangle, star, heart, arrow, line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .roundedRect: return "Rounded"
        case .circle: return "Circle"
        case .triangle: return "Triangle"
        case .star: return "Star"
        case .heart: return "Heart"
        case .arrow: return "Arrow"
        case .line: return "Line"
        }
    }

    var icon: String {
        switch self {
        case .rectangle: return "rectangle.fill"
        case .roundedRect: return "app.fill"
        case .circle: return "circle.fill"
        case .triangle: return "triangle.fill"
        case .star: return "star.fill"
        case .heart: return "heart.fill"
        case .arrow: return "arrow.right"
        case .line: return "minus"
        }
    }
}

/// Photos, stickers and shapes layered above the video.
struct OverlayItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: OverlayKind
    var imageMediaID: UUID?
    var sticker: String = "😀"
    var shape: ShapeKind = .circle
    var color: RGBAColor = .accent
    var filled = true
    var start: Double
    var duration: Double = 3
    var transform = Transform2D()
    var keyframes: [Keyframe] = []
    var animationIn: MotionPreset = .zoomIn
    var animationOut: MotionPreset = .fade
    var animationDuration: Double = 0.35

    var end: Double { start + duration }

    func contains(_ time: Double) -> Bool { time >= start && time < end }

    var title: String {
        switch kind {
        case .image: return "Photo"
        case .sticker: return sticker
        case .shape: return shape.title
        }
    }

    static let stickerCatalog: [String] = [
        "😀", "😂", "🥹", "😍", "😎", "🤯", "😭", "😡", "🥳", "🤔", "👀", "🙌",
        "👍", "👎", "👏", "🙏", "💪", "🔥", "✨", "⭐️", "💯", "❤️", "💔", "💥",
        "🎉", "🎵", "📍", "✅", "❌", "⚠️", "➡️", "⬆️", "💬", "💡", "📸", "🎬",
        "🌈", "☀️", "🌙", "⚡️", "🍕", "☕️", "🐶", "🐱", "🚀", "🏆", "💰", "🎯"
    ]
}
