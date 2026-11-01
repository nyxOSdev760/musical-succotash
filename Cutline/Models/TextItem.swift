import Foundation
import UIKit

enum TextAlign: String, Codable, CaseIterable, Identifiable, Hashable {
    case left, center, right
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum TextAnimation: String, Codable, CaseIterable, Identifiable, Hashable {
    case none, fade, pop, slide, typewriter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slide: return "Slide"
        case .typewriter: return "Typewriter"
        }
    }
    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .fade: return "circle.lefthalf.filled"
        case .pop: return "sparkle"
        case .slide: return "arrow.up"
        case .typewriter: return "keyboard"
        }
    }
}

struct TextItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String = "Your text"
    var start: Double
    var duration: Double = 3

    /// "System" uses the system font; otherwise a font family name from `UIFont.familyNames`.
    var fontFamily: String = "System"
    /// Point size relative to a 1080-pixel-wide canvas.
    var fontSize: Double = 72
    var bold = true
    var italic = false
    var color: RGBAColor = .white
    var outlineWidth: Double = 0
    var outlineColor: RGBAColor = .black
    var shadow = true
    var shadowColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
    var backgroundBox = false
    var boxColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
    var alignment: TextAlign = .center

    var animationIn: TextAnimation = .fade
    var animationOut: TextAnimation = .fade
    var animationDuration: Double = 0.4

    var transform = Transform2D()
    var keyframes: [Keyframe] = []

    var end: Double { start + duration }

    func contains(_ time: Double) -> Bool { time >= start && time < end }

    /// Fingerprint of everything that affects the rendered glyph image.
    var styleSignature: String {
        "\(text)|\(fontFamily)|\(fontSize)|\(bold)|\(italic)|\(color)|\(outlineWidth)|\(outlineColor)|\(shadow)|\(shadowColor)|\(backgroundBox)|\(boxColor)|\(alignment.rawValue)"
    }
}

enum FontResolver {
    static func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        var base: UIFont
        if family == "System" || family.isEmpty {
            base = UIFont.systemFont(ofSize: size, weight: bold ? .heavy : .regular)
        } else {
            let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
            base = UIFont(descriptor: descriptor, size: size)
            if bold, let d = base.fontDescriptor.withSymbolicTraits(.traitBold) {
                base = UIFont(descriptor: d, size: size)
            }
        }
        if italic {
            var traits = base.fontDescriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                base = UIFont(descriptor: d, size: size)
            }
        }
        return base
    }

    static let families: [String] = ["System"] + UIFont.familyNames.sorted()
}
