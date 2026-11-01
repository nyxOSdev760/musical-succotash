import Foundation
import AVFoundation
import CoreImage

struct TransitionWindow: Hashable {
    var type: TransitionType
    var start: Double
    var end: Double

    func progress(at t: Double) -> Double {
        ((t - start) / max(end - start, 0.0001)).clamped(0, 1)
    }

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Describes one visual clip layer inside the video composition.
struct LayerSpec: Hashable {
    enum Source: Hashable {
        case track(CMPersistentTrackID)
        case image(URL)
        case missing
    }

    var clipID: UUID
    var isOverlay: Bool
    var order: Int
    var source: Source
    var orientation: CGImagePropertyOrientation
    /// Range the layer is present (including transition handles).
    var visibleStart: Double
    var visibleEnd: Double
    /// The clip's own range on the timeline.
    var coreStart: Double
    var coreEnd: Double
    var transitionIn: TransitionWindow?
    var transitionOut: TransitionWindow?

    func isVisible(at t: Double) -> Bool { t >= visibleStart && t < visibleEnd }
}

/// Immutable view of the project used by the renderer for one or more frames.
struct RenderSnapshot {
    let project: Project
    let clips: [UUID: Clip]
    let resolver: MediaResolver
    let isExport: Bool

    init(project: Project, paths: ProjectPaths, isExport: Bool) {
        self.project = project
        var dict: [UUID: Clip] = [:]
        for c in project.clips { dict[c.id] = c }
        for c in project.overlayClips { dict[c.id] = c }
        clips = dict
        resolver = MediaResolver(paths: paths, media: project.media, preferProxy: !isExport)
        self.isExport = isExport
    }
}

/// Thread-safe holder of the latest snapshot, shared between the editor and the compositor.
/// Visual-only edits (filters, text, transforms) update this without rebuilding the composition.
final class RenderStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RenderSnapshot
    let paths: ProjectPaths
    let isExport: Bool

    init(project: Project, paths: ProjectPaths, isExport: Bool) {
        self.paths = paths
        self.isExport = isExport
        _snapshot = RenderSnapshot(project: project, paths: paths, isExport: isExport)
    }

    var snapshot: RenderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    func update(_ project: Project) {
        let s = RenderSnapshot(project: project, paths: paths, isExport: isExport)
        lock.lock()
        _snapshot = s
        lock.unlock()
    }
}

final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [LayerSpec]
    let renderBox: RenderStateBox

    init(timeRange: CMTimeRange, layers: [LayerSpec], trackIDs: [CMPersistentTrackID], renderBox: RenderStateBox) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderBox = renderBox
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}
