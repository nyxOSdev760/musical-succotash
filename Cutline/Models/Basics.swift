import Foundation
import SwiftUI
import UIKit
import CoreImage
import CoreMedia

/// A Codable RGBA color stored in sRGB components (0...1).
struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: Color) {
        let ui = UIColor(color)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        if !ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa) {
            var white: CGFloat = 0
            ui.getWhite(&white, alpha: &aa)
            rr = white; gg = white; bb = white
        }
        r = Double(min(max(rr, 0), 1))
        g = Double(min(max(gg, 0), 1))
        b = Double(min(max(bb, 0), 1))
        a = Double(min(max(aa, 0), 1))
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { uiColor.cgColor }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }

    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let yellow = RGBAColor(r: 1, g: 0.86, b: 0.1)
    static let green = RGBAColor(r: 0, g: 1, b: 0)
    static let blue = RGBAColor(r: 0.15, g: 0.5, b: 1)
    static let red = RGBAColor(r: 1, g: 0.25, b: 0.3)
    static let pink = RGBAColor(r: 1, g: 0.35, b: 0.65)
    static let accent = RGBAColor(r: 1, g: 0.32, b: 0.36)

    static let palette: [RGBAColor] = [
        .white, .black, .yellow, .accent, .pink,
        RGBAColor(r: 1, g: 0.55, b: 0.1),
        RGBAColor(r: 0.2, g: 0.85, b: 0.45),
        .blue,
        RGBAColor(r: 0.55, g: 0.35, b: 1),
        RGBAColor(r: 0.3, g: 0.9, b: 0.95)
    ]
}

enum MediaKind: String, Codable, Hashable {
    case video
    case image
    case audio
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable, Hashable {
    case portrait9x16 = "9:16"
    case square1x1 = "1:1"
    case portrait4x5 = "4:5"
    case landscape16x9 = "16:9"

    var id: String { rawValue }

    /// width / height
    var ratio: CGFloat {
        switch self {
        case .portrait9x16: return 9.0 / 16.0
        case .square1x1: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }

    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .portrait9x16: return "TikTok · Reels · Shorts"
        case .square1x1: return "Square"
        case .portrait4x5: return "Portrait post"
        case .landscape16x9: return "YouTube"
        }
    }

    var icon: String {
        switch self {
        case .portrait9x16: return "rectangle.portrait"
        case .square1x1: return "square"
        case .portrait4x5: return "rectangle.portrait"
        case .landscape16x9: return "rectangle"
        }
    }

    /// Size where the shorter side equals `shortSide`, rounded to even pixels.
    func size(shortSide: CGFloat) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int((v / 2).rounded()) * 2) }
        if ratio >= 1 {
            return CGSize(width: even(shortSide * ratio), height: even(shortSide))
        } else {
            return CGSize(width: even(shortSide), height: even(shortSide / ratio))
        }
    }

    static func bestMatch(for size: CGSize) -> AspectRatio {
        guard size.width > 0, size.height > 0 else { return .portrait9x16 }
        let r = size.width / size.height
        return AspectRatio.allCases.min(by: { abs(log($0.ratio) - log(r)) < abs(log($1.ratio) - log(r)) }) ?? .portrait9x16
    }
}

extension Double {
    var cmTime: CMTime { CMTime(value: CMTimeValue((self * 600).rounded()), timescale: 600) }

    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

extension CMTime {
    var secondsOrZero: Double {
        let s = CMTimeGetSeconds(self)
        return s.isFinite ? s : 0
    }
}

enum TimeFormat {
    static func short(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let secs = Int(s) % 60
        let tenths = Int((s - floor(s)) * 10)
        return String(format: "%d:%02d.%d", minutes, secs, tenths)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
