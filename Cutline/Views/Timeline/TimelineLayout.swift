import Foundation
import SwiftUI

enum TrackKind: Hashable {
    case video, overlay, text, caption, audio

    var icon: String {
        switch self {
        case .video: return "film"
        case .overlay: return "square.on.square"
        case .text: return "textformat"
        case .caption: return "captions.bubble"
        case .audio: return "music.note"
        }
    }

    var hint: String {
        switch self {
        case .video: return "Tap to add videos or photos"
        case .overlay: return "Tap to add a sticker, shape or picture-in-picture"
        case .text: return "Tap to add text"
        case .caption: return "Captions"
        case .audio: return "Tap to add music or a voiceover"
        }
    }

    var color: Color {
        switch self {
        case .video: return Color(red: 0.2, green: 0.2, blue: 0.24)
        case .overlay: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .text: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .caption: return Color(red: 0.15, green: 0.7, blue: 0.7)
        case .audio: return Color(red: 0.15, green: 0.6, blue: 0.35)
        }
    }
}

struct TimelineRow: Hashable {
    var kind: TrackKind
    var lane: Int
    var y: CGFloat
    var height: CGFloat

    func contains(y py: CGFloat) -> Bool { py >= y && py < y + height }
}

struct TimelineEntry: Identifiable {
    var id: UUID
    var selection: TimelineSelection
    var kind: TrackKind
    var start: Double
    var end: Double
    var row: TimelineRow
    var title: String
}

/// Pure layout of rows and items in content coordinates (y from the top of the track area).
struct TimelineLayout {
    static let rulerHeight: CGFloat = 26
    static let videoHeight: CGFloat = 58
    static let overlayHeight: CGFloat = 34
    static let textHeight: CGFloat = 30
    static let captionHeight: CGFloat = 26
    static let audioHeight: CGFloat = 42
    static let gap: CGFloat = 6
    static let topPadding: CGFloat = 6

    var rows: [TimelineRow] = []
    var entries: [TimelineEntry] = []
    var contentHeight: CGFloat = 0

    init(project: Project) {
        var y = Self.topPadding

        func addRow(_ kind: TrackKind, lane: Int, height: CGFloat) -> TimelineRow {
            let r = TimelineRow(kind: kind, lane: lane, y: y, height: height)
            rows.append(r)
            y += height + Self.gap
            return r
        }

        // Video
        let videoRow = addRow(.video, lane: 0, height: Self.videoHeight)
        for c in project.clips {
            entries.append(TimelineEntry(id: c.id, selection: .clip(c.id), kind: .video, start: c.timelineStart,
                                         end: c.timelineEnd, row: videoRow, title: ""))
        }

        // Overlay lanes (picture-in-picture clips, photos, stickers, shapes)
        var overlayItems: [(UUID, TimelineSelection, Double, Double, String)] = []
        for c in project.overlayClips {
            overlayItems.append((c.id, .overlayClip(c.id), c.timelineStart, c.timelineEnd, c.isImage ? "Photo" : "Video"))
        }
        for o in project.overlays {
            overlayItems.append((o.id, .overlay(o.id), o.start, o.end, o.title))
        }
        let overlayLanes = Self.pack(overlayItems.map { ($0.0, $0.2, $0.3) })
        let overlayCount = max(1, (overlayLanes.values.max() ?? -1) + 1)
        var overlayRows: [TimelineRow] = []
        for lane in 0..<overlayCount { overlayRows.append(addRow(.overlay, lane: lane, height: Self.overlayHeight)) }
        for item in overlayItems {
            let lane = overlayLanes[item.0] ?? 0
            entries.append(TimelineEntry(id: item.0, selection: item.1, kind: .overlay, start: item.2, end: item.3,
                                         row: overlayRows[lane], title: item.4))
        }

        // Text lanes
        let textLanes = Self.pack(project.texts.map { ($0.id, $0.start, $0.end) })
        let textCount = max(1, (textLanes.values.max() ?? -1) + 1)
        var textRows: [TimelineRow] = []
        for lane in 0..<textCount { textRows.append(addRow(.text, lane: lane, height: Self.textHeight)) }
        for t in project.texts {
            entries.append(TimelineEntry(id: t.id, selection: .text(t.id), kind: .text, start: t.start, end: t.end,
                                         row: textRows[textLanes[t.id] ?? 0], title: t.text))
        }

        // Captions
        if !project.captions.segments.isEmpty {
            let row = addRow(.caption, lane: 0, height: Self.captionHeight)
            for s in project.captions.segments {
                entries.append(TimelineEntry(id: s.id, selection: .caption(s.id), kind: .caption, start: s.start, end: s.end,
                                             row: row, title: s.text))
            }
        }

        // Audio lanes
        let audioLanes = Self.pack(project.audioClips.map { ($0.id, $0.timelineStart, $0.timelineEnd) })
        let audioCount = max(1, (audioLanes.values.max() ?? -1) + 1)
        var audioRows: [TimelineRow] = []
        for lane in 0..<audioCount { audioRows.append(addRow(.audio, lane: lane, height: Self.audioHeight)) }
        for a in project.audioClips {
            entries.append(TimelineEntry(id: a.id, selection: .audio(a.id), kind: .audio, start: a.timelineStart,
                                         end: a.timelineEnd, row: audioRows[audioLanes[a.id] ?? 0], title: a.name))
        }
        contentHeight = y + 12
    }

    /// Greedy interval packing into lanes.
    static func pack(_ items: [(UUID, Double, Double)]) -> [UUID: Int] {
        var laneEnds: [Double] = []
        var result: [UUID: Int] = [:]
        for item in items.sorted(by: { $0.1 < $1.1 }) {
            if let lane = laneEnds.firstIndex(where: { $0 <= item.1 + 0.0001 }) {
                laneEnds[lane] = item.2
                result[item.0] = lane
            } else {
                laneEnds.append(item.2)
                result[item.0] = laneEnds.count - 1
            }
        }
        return result
    }

    func row(atContentY y: CGFloat) -> TimelineRow? {
        rows.first { $0.contains(y: y) }
    }

    func entries(in kind: TrackKind) -> [TimelineEntry] {
        entries.filter { $0.kind == kind }
    }

    func entry(atContentY y: CGFloat, time: Double, slop: Double) -> TimelineEntry? {
        guard let row = row(atContentY: y) else { return nil }
        let candidates = entries.filter { $0.row == row && time >= $0.start - slop && time <= $0.end + slop }
        return candidates.min { abs(($0.start + $0.end) / 2 - time) < abs(($1.start + $1.end) / 2 - time) }
    }

    func entry(for selection: TimelineSelection?) -> TimelineEntry? {
        guard let selection else { return nil }
        return entries.first { $0.selection == selection }
    }
}

/// Converts between timeline seconds and view x positions with a fixed, centered playhead.
struct TimelineGeometry {
    var width: CGFloat
    var currentTime: Double
    var pixelsPerSecond: Double

    func x(for time: Double) -> CGFloat {
        width / 2 + CGFloat((time - currentTime) * pixelsPerSecond)
    }

    func time(for x: CGFloat) -> Double {
        currentTime + Double(x - width / 2) / pixelsPerSecond
    }
}
