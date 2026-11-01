import Foundation
import AVFoundation
import CoreImage

struct BuildOptions {
    var isExport: Bool
    var renderSize: CGSize
    var frameRate: Int32
    var includeMusic = true

    static func preview(for project: Project) -> BuildOptions {
        BuildOptions(isExport: false, renderSize: project.canvas.aspect.size(shortSide: 720), frameRate: 30)
    }
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let renderBox: RenderStateBox
    let duration: Double
    let missingMediaCount: Int
}

/// Tracks the end time of each composition track so clips can be packed onto free tracks.
private final class TrackPool {
    let composition: AVMutableComposition
    let mediaType: AVMediaType
    private(set) var tracks: [AVMutableCompositionTrack] = []

    init(composition: AVMutableComposition, mediaType: AVMediaType) {
        self.composition = composition
        self.mediaType = mediaType
    }

    static func end(of track: AVMutableCompositionTrack) -> CMTime {
        track.segments.last?.timeMapping.target.end ?? .zero
    }

    /// A track whose content ends at or before `start`, creating one if necessary.
    func track(availableAt start: CMTime) -> AVMutableCompositionTrack? {
        if let t = tracks.first(where: { Self.end(of: $0) <= start }) { return t }
        guard let t = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        tracks.append(t)
        return t
    }

    func pad(_ track: AVMutableCompositionTrack, to time: CMTime) {
        let end = Self.end(of: track)
        if time > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: time))
        }
    }
}

enum CompositionBuilder {
    static func build(project: Project, paths: ProjectPaths, options: BuildOptions,
                      renderBox existingBox: RenderStateBox? = nil) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        let resolver = MediaResolver(paths: paths, media: project.media, preferProxy: !options.isExport)
        let totalSeconds = max(project.duration, 0.1)
        let total = totalSeconds.cmTime
        var missing = 0

        // Timing backbone: black video stretched over the whole timeline.
        let blankURL = try await BlankVideoProvider.shared.url()
        let blank = try await AssetCache.shared.info(for: blankURL)
        guard let blankTrack = blank.video,
              let baseTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.processingFailed("Couldn't prepare the timeline.")
        }
        let blankRange = CMTimeRange(start: .zero, duration: blank.videoRange.duration)
        try baseTrack.insertTimeRange(blankRange, of: blankTrack, at: .zero)
        baseTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: blankRange.duration), toDuration: total)

        let videoPool = TrackPool(composition: composition, mediaType: .video)
        let overlayPool = TrackPool(composition: composition, mediaType: .video)
        let audioPool = TrackPool(composition: composition, mediaType: .audio)
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var layers: [LayerSpec] = []

        func params(for track: AVMutableCompositionTrack) -> AVMutableAudioMixInputParameters {
            if let p = audioParams[track.trackID] { return p }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            audioParams[track.trackID] = p
            return p
        }

        func applyVolume(_ p: AVMutableAudioMixInputParameters, start: Double, end: Double, volume: Double, fadeIn: Double, fadeOut: Double) {
            let v = Float(volume.clamped(0, 1))
            let length = max(end - start, 0)
            let fi = min(fadeIn, length / 2)
            let fo = min(fadeOut, length / 2)
            if fi > 0.01 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: start.cmTime, duration: fi.cmTime))
            } else {
                p.setVolume(v, at: start.cmTime)
            }
            if fo > 0.01 {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: (end - fo).cmTime, duration: fo.cmTime))
            }
        }

        /// Inserts speed segments of `source` onto `track` starting at `cursor`; returns the new cursor.
        func insertSegments(_ segments: [SpeedSegment], of source: AVAssetTrack, available: CMTimeRange,
                            into track: AVMutableCompositionTrack, at start: CMTime) throws -> CMTime {
            var cursor = start
            for seg in segments {
                var srcStart = seg.sourceStart.cmTime
                var srcDuration = seg.sourceDuration.cmTime
                if srcStart < available.start { srcStart = available.start }
                if srcStart + srcDuration > available.end { srcDuration = available.end - srcStart }
                guard srcDuration > .zero else { continue }
                try track.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDuration), of: source, at: cursor)
                if abs(seg.speed - 1) > 0.0001 {
                    let scaled = CMTimeMultiplyByFloat64(srcDuration, multiplier: 1 / seg.speed)
                    track.scaleTimeRange(CMTimeRange(start: cursor, duration: srcDuration), toDuration: scaled)
                    cursor = cursor + scaled
                } else {
                    cursor = cursor + srcDuration
                }
            }
            return cursor
        }

        /// Inserts a transition handle: real footage if available, otherwise a held frame.
        func insertHandle(length: Double, sourceTime: Double, before: Bool, speed: Double, info: AssetCache.Info,
                          source: AVAssetTrack, into track: AVMutableCompositionTrack, at cursor: CMTime) throws -> CMTime {
            guard length > 0.001 else { return cursor }
            let target = length.cmTime
            let need = length * speed
            let available = info.videoRange
            let srcRange: CMTimeRange
            if before, sourceTime - need >= available.start.secondsOrZero {
                srcRange = CMTimeRange(start: (sourceTime - need).cmTime, duration: need.cmTime)
            } else if !before, sourceTime + need <= available.end.secondsOrZero {
                srcRange = CMTimeRange(start: sourceTime.cmTime, duration: need.cmTime)
            } else {
                let frame = info.frameDuration
                var frameStart = before ? sourceTime.cmTime : sourceTime.cmTime - frame
                if frameStart < available.start { frameStart = available.start }
                if frameStart + frame > available.end { frameStart = available.end - frame }
                srcRange = CMTimeRange(start: frameStart, duration: frame)
            }
            guard srcRange.duration > .zero else { return cursor }
            try track.insertTimeRange(srcRange, of: source, at: cursor)
            track.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration), toDuration: target)
            return cursor + target
        }

        // MARK: Main track
        let clips = project.clips
        for (index, clip) in clips.enumerated() {
            let dIn = index > 0 ? project.clampedTransitionDuration(after: index - 1) : 0
            let dOut = project.clampedTransitionDuration(after: index)
            let hIn = dIn / 2, hOut = dOut / 2
            let coreStart = clip.timelineStart, coreEnd = clip.timelineEnd
            var spec = LayerSpec(clipID: clip.id, isOverlay: false, order: index, source: .missing, orientation: .up,
                                 visibleStart: coreStart - hIn, visibleEnd: coreEnd + hOut,
                                 coreStart: coreStart, coreEnd: coreEnd,
                                 transitionIn: dIn > 0 ? TransitionWindow(type: clips[index - 1].transitionOut.type, start: coreStart - hIn, end: coreStart + hIn) : nil,
                                 transitionOut: dOut > 0 ? TransitionWindow(type: clip.transitionOut.type, start: coreEnd - hOut, end: coreEnd + hOut) : nil)

            if clip.isImage {
                if let url = resolver.imageURL(for: clip.mediaID) {
                    spec.source = .image(url)
                } else {
                    missing += 1
                }
            } else if let url = resolver.videoURL(for: clip),
                      let info = try? await AssetCache.shared.info(for: url),
                      let source = info.video {
                let start = (coreStart - hIn).cmTime
                if let track = videoPool.track(availableAt: start) {
                    videoPool.pad(track, to: start)
                    let segs = clip.segments()
                    var cursor = start
                    cursor = try insertHandle(length: hIn, sourceTime: clip.sourceStart, before: true,
                                              speed: segs.first?.speed ?? 1, info: info, source: source, into: track, at: cursor)
                    cursor = try insertSegments(segs, of: source, available: info.videoRange, into: track, at: cursor)
                    _ = try insertHandle(length: hOut, sourceTime: clip.sourceEnd, before: false,
                                         speed: segs.last?.speed ?? 1, info: info, source: source, into: track, at: cursor)
                    spec.source = .track(track.trackID)
                    spec.orientation = info.orientation
                }
            } else {
                missing += 1
            }
            layers.append(spec)

            // Clip audio
            if !clip.isImage, !clip.muted, !clip.audioDetached, clip.volume > 0.001,
               let audioURL = resolver.audioURL(mediaID: clip.mediaID, reversed: clip.reversed, denoise: clip.denoise),
               let info = try? await AssetCache.shared.info(for: audioURL),
               let source = info.audio {
                let start = coreStart.cmTime
                if let track = audioPool.track(availableAt: start) {
                    audioPool.pad(track, to: start)
                    _ = try insertSegments(clip.segments(), of: source, available: info.audioRange, into: track, at: start)
                    applyVolume(params(for: track), start: coreStart, end: coreEnd, volume: clip.volume,
                                fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                }
            }
        }

        // MARK: Overlay clips (picture in picture)
        for (index, clip) in project.overlayClips.enumerated() {
            var spec = LayerSpec(clipID: clip.id, isOverlay: true, order: index, source: .missing, orientation: .up,
                                 visibleStart: clip.timelineStart, visibleEnd: clip.timelineEnd,
                                 coreStart: clip.timelineStart, coreEnd: clip.timelineEnd,
                                 transitionIn: nil, transitionOut: nil)
            if clip.isImage {
                if let url = resolver.imageURL(for: clip.mediaID) { spec.source = .image(url) } else { missing += 1 }
            } else if let url = resolver.videoURL(for: clip),
                      let info = try? await AssetCache.shared.info(for: url),
                      let source = info.video {
                let start = clip.timelineStart.cmTime
                if let track = overlayPool.track(availableAt: start) {
                    overlayPool.pad(track, to: start)
                    _ = try insertSegments(clip.segments(), of: source, available: info.videoRange, into: track, at: start)
                    spec.source = .track(track.trackID)
                    spec.orientation = info.orientation
                }
            } else {
                missing += 1
            }
            layers.append(spec)

            if !clip.isImage, !clip.muted, !clip.audioDetached, clip.volume > 0.001,
               let audioURL = resolver.audioURL(mediaID: clip.mediaID, reversed: clip.reversed, denoise: clip.denoise),
               let info = try? await AssetCache.shared.info(for: audioURL),
               let source = info.audio {
                let start = clip.timelineStart.cmTime
                if let track = audioPool.track(availableAt: start) {
                    audioPool.pad(track, to: start)
                    _ = try insertSegments(clip.segments(), of: source, available: info.audioRange, into: track, at: start)
                    applyVolume(params(for: track), start: clip.timelineStart, end: clip.timelineEnd, volume: clip.volume,
                                fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                }
            }
        }

        // MARK: Audio clips (music, voiceover, detached audio)
        for audio in project.audioClips where !audio.muted && audio.volume > 0.001 {
            if !options.includeMusic && audio.kind == .music { continue }
            guard let url = resolver.audioURL(mediaID: audio.mediaID, reversed: audio.reversed, denoise: audio.denoise),
                  let info = try? await AssetCache.shared.info(for: url),
                  let source = info.audio else {
                missing += 1
                continue
            }
            let start = audio.timelineStart.cmTime
            guard let track = audioPool.track(availableAt: start) else { continue }
            audioPool.pad(track, to: start)
            let seg = SpeedSegment(sourceStart: audio.sourceStart, sourceDuration: audio.sourceDuration, speed: audio.speed.clamped(0.1, 8))
            _ = try insertSegments([seg], of: source, available: info.audioRange, into: track, at: start)
            applyVolume(params(for: track), start: audio.timelineStart, end: audio.timelineEnd, volume: audio.volume,
                        fadeIn: audio.fadeIn, fadeOut: audio.fadeOut)
        }

        // MARK: Video composition
        let renderBox = existingBox ?? RenderStateBox(project: project, paths: paths, isExport: options.isExport)
        if existingBox != nil { renderBox.update(project) }

        let compDuration = composition.duration
        var ticks = Set<Int64>([0])
        let scale: Double = 600
        let endTicks = Int64((compDuration.secondsOrZero * scale).rounded(.down))
        for l in layers {
            for v in [l.visibleStart, l.visibleEnd] {
                let tk = Int64((v * scale).rounded())
                if tk > 0 && tk < endTicks { ticks.insert(tk) }
            }
        }
        let sortedTicks = ticks.sorted()
        var instructions: [CompositionInstruction] = []
        for (i, startTick) in sortedTicks.enumerated() {
            let start = CMTime(value: startTick, timescale: 600)
            let end = i + 1 < sortedTicks.count ? CMTime(value: sortedTicks[i + 1], timescale: 600) : compDuration
            guard end > start else { continue }
            let mid = (start.secondsOrZero + end.secondsOrZero) / 2
            let active = layers.filter { $0.visibleStart <= mid && mid < $0.visibleEnd }
            var trackIDs: [CMPersistentTrackID] = [baseTrack.trackID]
            for l in active {
                if case .track(let id) = l.source, !trackIDs.contains(id) { trackIDs.append(id) }
            }
            instructions.append(CompositionInstruction(timeRange: CMTimeRange(start: start, end: end), layers: active,
                                                       trackIDs: trackIDs, renderBox: renderBox))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CutlineCompositor.self
        videoComposition.renderSize = options.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: options.frameRate)
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = Array(audioParams.values)

        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                                renderBox: renderBox, duration: compDuration.secondsOrZero, missingMediaCount: missing)
    }
}
