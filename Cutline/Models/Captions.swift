import Foundation

struct CaptionWord: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

struct CaptionSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var words: [CaptionWord]

    var text: String { words.map(\.text).joined(separator: " ") }

    func contains(_ time: Double) -> Bool { time >= start && time < end }

    /// Replaces the text, spreading new words evenly across the segment.
    mutating func setText(_ newText: String) {
        let tokens = newText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !tokens.isEmpty else { words = []; return }
        let span = max(end - start, 0.1)
        let totalChars = tokens.reduce(0) { $0 + max($1.count, 1) }
        var cursor = start
        words = tokens.map { token in
            let d = span * Double(max(token.count, 1)) / Double(totalChars)
            defer { cursor += d }
            return CaptionWord(text: token, start: cursor, end: cursor + d)
        }
    }

    func activeWordIndex(at time: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        if let i = words.firstIndex(where: { time >= $0.start && time < $0.end }) { return i }
        return words.lastIndex(where: { $0.start <= time })
    }
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case boldCenter, karaoke, minimalBottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .boldCenter: return "Bold Center"
        case .karaoke: return "Karaoke"
        case .minimalBottom: return "Minimal"
        }
    }

    var defaultVerticalPosition: Double {
        switch self {
        case .boldCenter: return 0.5
        case .karaoke: return 0.72
        case .minimalBottom: return 0.86
        }
    }
}

struct CaptionTrack: Codable, Hashable {
    var style: CaptionStyle = .boldCenter
    /// 0 = top, 1 = bottom of the canvas (center of the caption block).
    var verticalPosition: Double = 0.5
    var fontScale: Double = 1
    var highlightColor: RGBAColor = .yellow
    var textColor: RGBAColor = .white
    var segments: [CaptionSegment] = []

    func segment(at time: Double) -> CaptionSegment? {
        segments.first { $0.contains(time) }
    }
}
