import Foundation
import CoreGraphics

struct MediaItem: Codable, Identifiable, Hashable {
    var id = UUID()
    /// File name inside the project's media folder.
    var fileName: String
    /// Lower-resolution editing proxy inside the project's cache folder.
    var proxyFileName: String?
    var originalName: String
    var kind: MediaKind
    var duration: Double
    /// Oriented (display) size.
    var width: Double
    var height: Double
    var hasAudio: Bool
    var hasVideo: Bool
    var frameRate: Double = 30
    /// Beat times in source seconds (music only).
    var beats: [Double]?

    var size: CGSize { CGSize(width: width, height: height) }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case black, blur, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .black: return "Black"
        case .blur: return "Blur"
        case .color: return "Color"
        }
    }
}

struct CanvasSettings: Codable, Hashable {
    var aspect: AspectRatio = .portrait9x16
    var background: BackgroundStyle = .blur
    var backgroundColor: RGBAColor = RGBAColor(r: 0.08, g: 0.08, b: 0.1)
    /// 0...1
    var blurAmount: Double = 0.6
}

enum TimelineSelection: Codable, Hashable {
    case clip(UUID)
    case overlayClip(UUID)
    case overlay(UUID)
    case text(UUID)
    case audio(UUID)
    case caption(UUID)

    var id: UUID {
        switch self {
        case .clip(let id), .overlayClip(let id), .overlay(let id), .text(let id), .audio(let id), .caption(let id):
            return id
        }
    }
}

struct EditorState: Codable, Hashable {
    var playhead: Double = 0
    var pixelsPerSecond: Double = 60
    var verticalOffset: Double = 0
    var selection: TimelineSelection?
}

struct Project: Codable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var canvas = CanvasSettings()
    var magnetic = true
    var media: [MediaItem] = []
    var clips: [Clip] = []
    var overlayClips: [Clip] = []
    var overlays: [OverlayItem] = []
    var texts: [TextItem] = []
    var audioClips: [AudioClip] = []
    var captions = CaptionTrack()
    var globalFilter = FilterSettings()
    var editorState = EditorState()

    init(name: String, aspect: AspectRatio) {
        self.name = name
        canvas.aspect = aspect
    }

    var duration: Double {
        var end = 0.0
        for c in clips { end = max(end, c.timelineEnd) }
        for c in overlayClips { end = max(end, c.timelineEnd) }
        for o in overlays { end = max(end, o.end) }
        for t in texts { end = max(end, t.end) }
        for a in audioClips { end = max(end, a.timelineEnd) }
        for s in captions.segments { end = max(end, s.end) }
        return end
    }

    var isEmpty: Bool {
        clips.isEmpty && overlayClips.isEmpty && overlays.isEmpty && texts.isEmpty && audioClips.isEmpty
    }

    func mediaItem(_ id: UUID?) -> MediaItem? {
        guard let id else { return nil }
        return media.first { $0.id == id }
    }

    func clip(_ id: UUID) -> Clip? {
        clips.first { $0.id == id } ?? overlayClips.first { $0.id == id }
    }

    /// Re-packs the main track so clips sit back to back from zero.
    mutating func packMainTrack() {
        clips.sort { $0.timelineStart < $1.timelineStart }
        var cursor = 0.0
        for i in clips.indices {
            clips[i].timelineStart = cursor
            cursor += clips[i].duration
        }
    }

    /// Keeps clips on the main track sorted and non-overlapping (pushes later clips right).
    mutating func resolveMainTrackOverlaps() {
        clips.sort { $0.timelineStart < $1.timelineStart }
        var cursor = 0.0
        for i in clips.indices {
            if clips[i].timelineStart < cursor { clips[i].timelineStart = cursor }
            clips[i].timelineStart = max(clips[i].timelineStart, 0)
            cursor = clips[i].timelineEnd
        }
    }

    mutating func normalizeMainTrack() {
        if magnetic { packMainTrack() } else { resolveMainTrackOverlaps() }
    }

    /// Beat markers converted to timeline time across all music clips.
    var timelineBeats: [Double] {
        var result: [Double] = []
        for a in audioClips {
            guard let beats = mediaItem(a.mediaID)?.beats else { continue }
            for b in beats where b >= a.sourceStart && b <= a.sourceEnd {
                result.append(a.timelineStart + (b - a.sourceStart) / a.speed.clamped(0.1, 8))
            }
        }
        return result.sorted()
    }

    /// Clamps transition durations so neighbouring transitions never overlap.
    func clampedTransitionDuration(after index: Int) -> Double {
        guard index >= 0, index + 1 < clips.count else { return 0 }
        let a = clips[index], b = clips[index + 1]
        guard a.transitionOut.type != .cut, abs(a.timelineEnd - b.timelineStart) < 0.02 else { return 0 }
        return min(a.transitionOut.duration, a.duration / 2, b.duration / 2, 2.0)
    }
}
