import Foundation
import UIKit
import CoreImage
import ImageIO

/// Rasterizes text, captions, stickers, shapes and photos into cached CIImages.
enum TextRenderer {
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 300
        return c
    }()

    private static func render(size: CGSize, _ draw: (CGContext) -> Void) -> CIImage? {
        guard size.width >= 1, size.height >= 1, size.width < 8192, size.height < 8192 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: Text

    static func attributes(for item: TextItem, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = FontResolver.font(family: item.fontFamily, size: CGFloat(item.fontSize) * scale, bold: item.bold, italic: item.italic)
        let para = NSMutableParagraphStyle()
        para.alignment = item.alignment.nsAlignment
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.color.uiColor,
            .paragraphStyle: para
        ]
        if item.outlineWidth > 0 {
            attrs[.strokeColor] = item.outlineColor.uiColor
            attrs[.strokeWidth] = -item.outlineWidth * 1.6
        }
        if item.shadow {
            let s = NSShadow()
            s.shadowColor = item.shadowColor.uiColor
            s.shadowBlurRadius = 8 * scale
            s.shadowOffset = CGSize(width: 0, height: 3 * scale)
            attrs[.shadow] = s
        }
        return attrs
    }

    static func textImage(_ item: TextItem, canvasWidth: CGFloat, visibleCharacters: Int?) -> CIImage? {
        let key = "t|\(item.styleSignature)|\(Int(canvasWidth))|\(visibleCharacters ?? -1)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = canvasWidth / 1080
        let attrs = attributes(for: item, scale: scale)
        let font = (attrs[.font] as? UIFont) ?? UIFont.systemFont(ofSize: 40)
        let fullText = item.text.isEmpty ? " " : item.text
        let shown: String
        if let n = visibleCharacters { shown = String(fullText.prefix(max(n, 0))) } else { shown = fullText }

        let full = NSAttributedString(string: fullText, attributes: attrs)
        let maxWidth = canvasWidth * 0.9
        let bounds = full.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let pad = item.backgroundBox ? font.pointSize * 0.35 : font.pointSize * 0.2 + CGFloat(item.outlineWidth) * scale
        let size = CGSize(width: ceil(bounds.width + pad * 2), height: ceil(bounds.height + pad * 2))
        let drawn = NSAttributedString(string: shown.isEmpty ? " " : shown, attributes: attrs)
        let image = render(size: size) { ctx in
            if item.backgroundBox {
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: font.pointSize * 0.3)
                ctx.setFillColor(item.boxColor.cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
            }
            drawn.draw(with: CGRect(x: pad, y: pad, width: bounds.width + 1, height: bounds.height + 1),
                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    // MARK: Captions

    static func captionImage(_ segment: CaptionSegment, track: CaptionTrack, highlightIndex: Int?, canvasWidth: CGFloat) -> CIImage? {
        let key = "c|\(segment.id)|\(segment.text)|\(track.style.rawValue)|\(track.fontScale)|\(track.textColor)|\(track.highlightColor)|\(highlightIndex ?? -1)|\(Int(canvasWidth))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = canvasWidth / 1080 * CGFloat(track.fontScale)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping

        let font: UIFont
        var base: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .foregroundColor: track.textColor.uiColor]
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 10 * scale
        shadow.shadowOffset = CGSize(width: 0, height: 3 * scale)
        var drawBox = false
        switch track.style {
        case .boldCenter:
            font = UIFont.systemFont(ofSize: 76 * scale, weight: .black)
            base[.strokeColor] = UIColor.black
            base[.strokeWidth] = -7.0
            base[.shadow] = shadow
        case .karaoke:
            font = UIFont.systemFont(ofSize: 62 * scale, weight: .heavy)
            base[.strokeColor] = UIColor.black
            base[.strokeWidth] = -4.0
            drawBox = true
        case .minimalBottom:
            font = UIFont.systemFont(ofSize: 46 * scale, weight: .semibold)
            base[.shadow] = shadow
        }
        base[.font] = font

        let result = NSMutableAttributedString()
        for (i, word) in segment.words.enumerated() {
            var attrs = base
            var text = word.text
            if track.style == .boldCenter { text = text.uppercased() }
            if let h = highlightIndex {
                if track.style == .karaoke && i == h {
                    attrs[.foregroundColor] = track.highlightColor.uiColor
                } else if track.style == .boldCenter && i == h {
                    attrs[.foregroundColor] = track.highlightColor.uiColor
                }
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
            if i < segment.words.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: base))
            }
        }
        if result.length == 0 { return nil }
        let maxWidth = canvasWidth * 0.84
        let bounds = result.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let pad = font.pointSize * (drawBox ? 0.4 : 0.25)
        let size = CGSize(width: ceil(bounds.width + pad * 2), height: ceil(bounds.height + pad * 2))
        let image = render(size: size) { ctx in
            if drawBox {
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: font.pointSize * 0.3)
                ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
            }
            result.draw(with: CGRect(x: pad, y: pad, width: bounds.width + 1, height: bounds.height + 1),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    // MARK: Stickers & shapes

    static func stickerImage(_ emoji: String, canvasSize: CGSize) -> CIImage? {
        let side = min(canvasSize.width, canvasSize.height) * 0.28
        let key = "s|\(emoji)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let font = UIFont.systemFont(ofSize: side * 0.8)
        let str = NSAttributedString(string: emoji, attributes: [.font: font])
        let b = str.boundingRect(with: CGSize(width: side * 4, height: side * 4), options: [.usesLineFragmentOrigin], context: nil).integral
        let size = CGSize(width: max(b.width, 1) + 8, height: max(b.height, 1) + 8)
        let image = render(size: size) { _ in
            str.draw(at: CGPoint(x: 4, y: 4))
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func shapePath(_ kind: ShapeKind, in rect: CGRect) -> UIBezierPath {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        switch kind {
        case .rectangle:
            return UIBezierPath(rect: rect)
        case .roundedRect:
            return UIBezierPath(roundedRect: rect, cornerRadius: min(w, h) * 0.2)
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .triangle:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x + w / 2, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + h))
            p.addLine(to: CGPoint(x: x, y: y + h))
            p.close()
            return p
        case .star:
            let p = UIBezierPath()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(w, h) / 2
            let inner = outer * 0.42
            for i in 0..<10 {
                let r = i % 2 == 0 ? outer : inner
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.close()
            return p
        case .heart:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.92))
            p.addCurve(to: CGPoint(x: x + w * 0.04, y: y + h * 0.36),
                       controlPoint1: CGPoint(x: x + w * 0.22, y: y + h * 0.76),
                       controlPoint2: CGPoint(x: x + w * 0.04, y: y + h * 0.58))
            p.addArc(withCenter: CGPoint(x: x + w * 0.27, y: y + h * 0.32), radius: w * 0.23,
                     startAngle: .pi * 1.05, endAngle: 0, clockwise: true)
            p.addArc(withCenter: CGPoint(x: x + w * 0.73, y: y + h * 0.32), radius: w * 0.23,
                     startAngle: .pi, endAngle: -.pi * 0.05, clockwise: true)
            p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.92),
                       controlPoint1: CGPoint(x: x + w * 0.96, y: y + h * 0.58),
                       controlPoint2: CGPoint(x: x + w * 0.78, y: y + h * 0.76))
            p.close()
            return p
        case .arrow:
            let p = UIBezierPath()
            let shaft = h * 0.3
            p.move(to: CGPoint(x: x, y: y + h / 2 - shaft / 2))
            p.addLine(to: CGPoint(x: x + w * 0.6, y: y + h / 2 - shaft / 2))
            p.addLine(to: CGPoint(x: x + w * 0.6, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + h / 2))
            p.addLine(to: CGPoint(x: x + w * 0.6, y: y + h))
            p.addLine(to: CGPoint(x: x + w * 0.6, y: y + h / 2 + shaft / 2))
            p.addLine(to: CGPoint(x: x, y: y + h / 2 + shaft / 2))
            p.close()
            return p
        case .line:
            return UIBezierPath(roundedRect: rect, cornerRadius: h / 2)
        }
    }

    static func shapeSize(_ kind: ShapeKind, side: CGFloat) -> CGSize {
        switch kind {
        case .rectangle: return CGSize(width: side * 1.5, height: side)
        case .arrow: return CGSize(width: side * 1.4, height: side * 0.8)
        case .line: return CGSize(width: side * 1.6, height: max(side * 0.06, 4))
        default: return CGSize(width: side, height: side)
        }
    }

    static func shapeImage(_ kind: ShapeKind, color: RGBAColor, filled: Bool, canvasSize: CGSize) -> CIImage? {
        let side = min(canvasSize.width, canvasSize.height) * 0.3
        let key = "p|\(kind.rawValue)|\(color)|\(filled)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let shapeSize = shapeSize(kind, side: side)
        let lineWidth = max(side * 0.05, 3)
        let inset = filled ? 1 : lineWidth
        let size = CGSize(width: shapeSize.width + inset * 2, height: shapeSize.height + inset * 2)
        let image = render(size: size) { ctx in
            let path = shapePath(kind, in: CGRect(x: inset, y: inset, width: shapeSize.width, height: shapeSize.height))
            if filled || kind == .line {
                ctx.setFillColor(color.cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.setLineJoin(.round)
                ctx.addPath(path.cgPath)
                ctx.strokePath()
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    // MARK: Photos

    /// Decoded, oriented photo limited to `maxPixel`.
    static func photo(url: URL, maxPixel: Int = 2048) -> CIImage? {
        let key = "i|\(url.path)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}
