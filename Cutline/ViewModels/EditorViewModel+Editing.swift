import Foundation
import SwiftUI

enum TrimEdge {
    case left, right
}

/// Pure editing operations. Each public method is one undoable step.
extension EditorViewModel {
    // MARK: Generic updates

    func updateClip(_ id: UUID, _ name: String, coalesce: String? = nil, _ change: (inout Clip) -> Void) {
        perform(name, coalesce: coalesce) { p in
            if let i = p.clips.firstIndex(where: { $0.id == id }) {
                change(&p.clips[i])
                p.normalizeMainTrack()
            } else if let i = p.overlayClips.firstIndex(where: { $0.id == id }) {
                change(&p.overlayClips[i])
            }
        }
    }

    func updateSelectedClip(_ name: String, coalesce: String? = nil, _ change: (inout Clip) -> Void) {
        guard let clip = selectedClip else { return }
        updateClip(clip.id, name, coalesce: coalesce.map { "\($0)-\(clip.id)" }, change)
    }

    func updateText(_ id: UUID, _ name: String, coalesce: String? = nil, _ change: (inout TextItem) -> Void) {
        perform(name, coalesce: coalesce.map { "\($0)-\(id)" }) { p in
            if let i = p.texts.firstIndex(where: { $0.id == id }) { change(&p.texts[i]) }
        }
    }

    func updateOverlay(_ id: UUID, _ name: String, coalesce: String? = nil, _ change: (inout OverlayItem) -> Void) {
        perform(name, coalesce: coalesce.map { "\($0)-\(id)" }) { p in
            if let i = p.overlays.firstIndex(where: { $0.id == id }) { change(&p.overlays[i]) }
        }
    }

    func updateAudio(_ id: UUID, _ name: String, coalesce: String? = nil, _ change: (inout AudioClip) -> Void) {
        perform(name, coalesce: coalesce.map { "\($0)-\(id)" }) { p in
            if let i = p.audioClips.firstIndex(where: { $0.id == id }) { change(&p.audioClips[i]) }
        }
    }

    // MARK: Visual transform (clips, overlays, text)

    struct VisualInfo {
        var transform: Transform2D
        var keyframes: [Keyframe]
        var start: Double
        var duration: Double
    }

    var selectedVisual: VisualInfo? {
        switch selection {
        case .some(.clip), .some(.overlayClip):
            guard let c = selectedClip else { return nil }
            return VisualInfo(transform: c.transform, keyframes: c.keyframes, start: c.timelineStart, duration: c.duration)
        case .some(.overlay):
            guard let o = selectedOverlay else { return nil }
            return VisualInfo(transform: o.transform, keyframes: o.keyframes, start: o.start, duration: o.duration)
        case .some(.text):
            guard let t = selectedText else { return nil }
            return VisualInfo(transform: t.transform, keyframes: t.keyframes, start: t.start, duration: t.duration)
        default:
            return nil
        }
    }

    /// Transform shown at the playhead (keyframes resolved).
    var selectedResolvedTransform: Transform2D? {
        guard let v = selectedVisual else { return nil }
        let local = (currentTime - v.start).clamped(0, v.duration)
        return KeyframeMath.transform(base: v.transform, keyframes: v.keyframes, at: local)
    }

    private static func mutateVisual(_ p: inout Project, _ sel: TimelineSelection,
                                     _ body: (inout Transform2D, inout [Keyframe], Double, Double) -> Void) {
        switch sel {
        case .clip(let id):
            if let i = p.clips.firstIndex(where: { $0.id == id }) {
                let c = p.clips[i]
                body(&p.clips[i].transform, &p.clips[i].keyframes, c.timelineStart, c.duration)
            }
        case .overlayClip(let id):
            if let i = p.overlayClips.firstIndex(where: { $0.id == id }) {
                let c = p.overlayClips[i]
                body(&p.overlayClips[i].transform, &p.overlayClips[i].keyframes, c.timelineStart, c.duration)
            }
        case .overlay(let id):
            if let i = p.overlays.firstIndex(where: { $0.id == id }) {
                let o = p.overlays[i]
                body(&p.overlays[i].transform, &p.overlays[i].keyframes, o.start, o.duration)
            }
        case .text(let id):
            if let i = p.texts.firstIndex(where: { $0.id == id }) {
                let t = p.texts[i]
                body(&p.texts[i].transform, &p.texts[i].keyframes, t.start, t.duration)
            }
        default:
            break
        }
    }

    /// Edits the selected item's transform. With keyframes present, edits (or adds) the keyframe at the playhead.
    func editTransform(_ name: String = "Transform", coalesce: String = "transform", _ change: @escaping (inout Transform2D) -> Void) {
        guard let sel = selection else { return }
        let time = currentTime
        perform(name, coalesce: "\(coalesce)-\(sel.id)") { p in
            Self.mutateVisual(&p, sel) { base, keyframes, start, duration in
                let local = (time - start).clamped(0, duration)
                if keyframes.isEmpty {
                    change(&base)
                } else {
                    var resolved = KeyframeMath.transform(base: base, keyframes: keyframes, at: local)
                    change(&resolved)
                    KeyframeMath.upsert(&keyframes, time: local, transform: resolved)
                }
            }
        }
    }

    /// Live transform edit used by preview gestures; `change` receives the transform at gesture start.
    func interactiveTransform(_ change: @escaping (inout Transform2D) -> Void) {
        guard let sel = selection else { return }
        let time = currentTime
        beginInteractive()
        updateInteractive { p, _ in
            Self.mutateVisual(&p, sel) { base, keyframes, start, duration in
                let local = (time - start).clamped(0, duration)
                if keyframes.isEmpty {
                    change(&base)
                } else {
                    var resolved = KeyframeMath.transform(base: base, keyframes: keyframes, at: local)
                    change(&resolved)
                    KeyframeMath.upsert(&keyframes, time: local, transform: resolved)
                }
            }
        }
    }

    var hasKeyframeAtPlayhead: Bool {
        guard let v = selectedVisual else { return false }
        return KeyframeMath.index(near: currentTime - v.start, in: v.keyframes) != nil
    }

    func toggleKeyframe() {
        guard let sel = selection, let v = selectedVisual else { return }
        let local = (currentTime - v.start).clamped(0, v.duration)
        let exists = KeyframeMath.index(near: local, in: v.keyframes) != nil
        perform(exists ? "Remove Keyframe" : "Add Keyframe") { p in
            Self.mutateVisual(&p, sel) { base, keyframes, _, _ in
                if let i = KeyframeMath.index(near: local, in: keyframes) {
                    let removed = keyframes.remove(at: i)
                    if keyframes.isEmpty { base = removed.transform }
                } else {
                    let resolved = KeyframeMath.transform(base: base, keyframes: keyframes, at: local)
                    KeyframeMath.upsert(&keyframes, time: local, transform: resolved)
                }
            }
        }
        Haptics.action()
    }

    func setKeyframeEasing(_ easing: Easing) {
        guard let sel = selection, let v = selectedVisual else { return }
        let local = (currentTime - v.start).clamped(0, v.duration)
        perform("Keyframe Easing") { p in
            Self.mutateVisual(&p, sel) { _, keyframes, _, _ in
                if let i = KeyframeMath.index(near: local, in: keyframes) {
                    keyframes[i].easing = easing
                } else if let i = keyframes.lastIndex(where: { $0.time <= local }) {
                    keyframes[i].easing = easing
                }
            }
        }
    }

    func clearKeyframes() {
        guard let sel = selection else { return }
        perform("Clear Keyframes") { p in
            Self.mutateVisual(&p, sel) { _, keyframes, _, _ in keyframes.removeAll() }
        }
    }

    func resetTransform() {
        guard let sel = selection else { return }
        perform("Reset Transform") { p in
            Self.mutateVisual(&p, sel) { base, keyframes, _, _ in
                let keepOpacity = base.opacity
                base = Transform2D()
                base.opacity = keepOpacity
                keyframes.removeAll()
            }
        }
    }

    // MARK: Split

    /// Splits the selected item (or the main clip under the playhead) at the playhead.
    func splitAtPlayhead() {
        let t = currentTime
        if let sel = selection {
            switch sel {
            case .clip(let id), .overlayClip(let id):
                if let clip = project.clip(id), splitClip(clip, at: t) { return }
            case .text(let id):
                if let item = project.texts.first(where: { $0.id == id }), t > item.start + 0.05, t < item.end - 0.05 {
                    perform("Split") { p in
                        guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return }
                        var b = p.texts[i]
                        b.id = UUID()
                        b.start = t
                        b.duration = item.end - t
                        let (lk, rk) = KeyframeMath.split(item.keyframes, base: item.transform, at: t - item.start)
                        b.keyframes = rk
                        b.animationIn = .none
                        p.texts[i].duration = t - item.start
                        p.texts[i].keyframes = lk
                        p.texts[i].animationOut = .none
                        p.texts.insert(b, at: i + 1)
                    }
                    Haptics.action()
                    return
                }
            case .overlay(let id):
                if let item = project.overlays.first(where: { $0.id == id }), t > item.start + 0.05, t < item.end - 0.05 {
                    perform("Split") { p in
                        guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
                        var b = p.overlays[i]
                        b.id = UUID()
                        b.start = t
                        b.duration = item.end - t
                        let (lk, rk) = KeyframeMath.split(item.keyframes, base: item.transform, at: t - item.start)
                        b.keyframes = rk
                        b.animationIn = .none
                        p.overlays[i].duration = t - item.start
                        p.overlays[i].keyframes = lk
                        p.overlays[i].animationOut = .none
                        p.overlays.insert(b, at: i + 1)
                    }
                    Haptics.action()
                    return
                }
            case .audio(let id):
                if let a = project.audioClips.first(where: { $0.id == id }), t > a.timelineStart + 0.05, t < a.timelineEnd - 0.05 {
                    perform("Split") { p in
                        guard let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
                        let src = a.sourceTime(atLocal: t - a.timelineStart)
                        var b = p.audioClips[i]
                        b.id = UUID()
                        b.timelineStart = t
                        b.sourceStart = src
                        b.fadeIn = 0
                        p.audioClips[i].sourceEnd = src
                        p.audioClips[i].fadeOut = 0
                        p.audioClips.insert(b, at: i + 1)
                    }
                    Haptics.action()
                    return
                }
            case .caption:
                break
            }
        }
        if let clip = project.clips.first(where: { $0.contains(t) }), splitClip(clip, at: t) { return }
        showToast("Move the playhead over a clip to split")
        Haptics.warning()
    }

    @discardableResult
    func splitClip(_ clip: Clip, at t: Double) -> Bool {
        let local = t - clip.timelineStart
        guard local > 0.05, local < clip.duration - 0.05 else { return false }
        var newID = UUID()
        perform("Split") { p in
            newID = Self.split(&p, clipID: clip.id, at: t) ?? newID
        }
        selection = project.clips.contains(where: { $0.id == newID }) ? .clip(newID)
            : (project.overlayClips.contains(where: { $0.id == newID }) ? .overlayClip(newID) : selection)
        Haptics.action()
        return true
    }

    /// Splits a clip in place, returning the id of the right half.
    static func split(_ p: inout Project, clipID: UUID, at t: Double) -> UUID? {
        func doSplit(_ clip: Clip) -> (Clip, Clip)? {
            let local = t - clip.timelineStart
            guard local > 0.02, local < clip.duration - 0.02 else { return nil }
            var a = clip, b = clip
            b.id = UUID()
            let src = clip.sourceTime(atLocal: local)
            if clip.ramp != .none {
                // Bake ramped speed so both halves keep their exact timeline length.
                a.ramp = .none
                b.ramp = .none
                a.speed = ((src - clip.sourceStart) / local).clamped(0.1, 8)
                b.speed = ((clip.sourceEnd - src) / (clip.duration - local)).clamped(0.1, 8)
            }
            a.sourceEnd = src
            b.sourceStart = src
            b.timelineStart = t
            let (lk, rk) = KeyframeMath.split(clip.keyframes, base: clip.transform, at: local)
            a.keyframes = lk
            b.keyframes = rk
            a.animationOut = .none
            b.animationIn = .none
            a.fadeOut = 0
            b.fadeIn = 0
            b.transitionOut = clip.transitionOut
            a.transitionOut = TransitionSettings()
            return (a, b)
        }
        if let i = p.clips.firstIndex(where: { $0.id == clipID }), let pair = doSplit(p.clips[i]) {
            p.clips[i] = pair.0
            p.clips.insert(pair.1, at: i + 1)
            return pair.1.id
        }
        if let i = p.overlayClips.firstIndex(where: { $0.id == clipID }), let pair = doSplit(p.overlayClips[i]) {
            p.overlayClips[i] = pair.0
            p.overlayClips.insert(pair.1, at: i + 1)
            return pair.1.id
        }
        return nil
    }

    // MARK: Delete / duplicate

    func deleteSelection() {
        guard let sel = selection else { return }
        perform("Delete") { p in
            switch sel {
            case .clip(let id):
                p.clips.removeAll { $0.id == id }
                p.normalizeMainTrack()
            case .overlayClip(let id):
                p.overlayClips.removeAll { $0.id == id }
            case .overlay(let id):
                p.overlays.removeAll { $0.id == id }
            case .text(let id):
                p.texts.removeAll { $0.id == id }
            case .audio(let id):
                p.audioClips.removeAll { $0.id == id }
            case .caption(let id):
                p.captions.segments.removeAll { $0.id == id }
            }
        }
        selection = nil
        activePanel = nil
        Haptics.action()
    }

    func duplicateSelection() {
        guard let sel = selection else { return }
        var newSelection: TimelineSelection?
        perform("Duplicate") { p in
            switch sel {
            case .clip(let id):
                guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                var copy = p.clips[i]
                copy.id = UUID()
                let shift = copy.duration
                copy.timelineStart = p.clips[i].timelineEnd
                for j in p.clips.indices where j > i { p.clips[j].timelineStart += shift }
                p.clips.insert(copy, at: i + 1)
                p.normalizeMainTrack()
                newSelection = .clip(copy.id)
            case .overlayClip(let id):
                guard let i = p.overlayClips.firstIndex(where: { $0.id == id }) else { return }
                var copy = p.overlayClips[i]
                copy.id = UUID()
                copy.timelineStart = p.overlayClips[i].timelineEnd
                p.overlayClips.insert(copy, at: i + 1)
                newSelection = .overlayClip(copy.id)
            case .overlay(let id):
                guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
                var copy = p.overlays[i]
                copy.id = UUID()
                copy.start = p.overlays[i].end
                p.overlays.insert(copy, at: i + 1)
                newSelection = .overlay(copy.id)
            case .text(let id):
                guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return }
                var copy = p.texts[i]
                copy.id = UUID()
                copy.start = p.texts[i].end
                p.texts.insert(copy, at: i + 1)
                newSelection = .text(copy.id)
            case .audio(let id):
                guard let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
                var copy = p.audioClips[i]
                copy.id = UUID()
                copy.timelineStart = p.audioClips[i].timelineEnd
                p.audioClips.insert(copy, at: i + 1)
                newSelection = .audio(copy.id)
            case .caption:
                break
            }
        }
        if let newSelection { selection = newSelection }
        Haptics.action()
    }

    // MARK: Trim & move (timeline gestures)

    /// Trims `selection` by `delta` seconds at `edge`, computed from `base`.
    static func trim(_ p: inout Project, _ sel: TimelineSelection, edge: TrimEdge, delta: Double) {
        let minDur = 0.1
        func trimClip(_ c: inout Clip, magnetic: Bool, mediaDuration: Double) {
            let speed = c.effectiveSpeed
            if c.isImage {
                if edge == .left {
                    let d = delta.clamped(-c.timelineStart, c.sourceDuration - minDur)
                    c.sourceEnd = max(minDur, c.sourceEnd - d)
                    if !magnetic { c.timelineStart += d }
                } else {
                    c.sourceEnd = max(c.sourceStart + minDur, min(c.sourceEnd + delta, c.sourceStart + 3600))
                }
                return
            }
            if edge == .left {
                var newStart = c.sourceStart + delta * speed
                newStart = newStart.clamped(0, c.sourceEnd - minDur * speed)
                if !magnetic {
                    let shift = (newStart - c.sourceStart) / speed
                    if c.timelineStart + shift < 0 {
                        newStart = c.sourceStart - c.timelineStart * speed
                    }
                    c.timelineStart = max(0, c.timelineStart + (newStart - c.sourceStart) / speed)
                }
                c.sourceStart = newStart
            } else {
                var newEnd = c.sourceEnd + delta * speed
                newEnd = newEnd.clamped(c.sourceStart + minDur * speed, mediaDuration)
                c.sourceEnd = newEnd
            }
        }
        switch sel {
        case .clip(let id):
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            let d = p.mediaItem(p.clips[i].mediaID)?.duration ?? p.clips[i].sourceEnd
            trimClip(&p.clips[i], magnetic: p.magnetic, mediaDuration: d)
            p.normalizeMainTrack()
        case .overlayClip(let id):
            guard let i = p.overlayClips.firstIndex(where: { $0.id == id }) else { return }
            let d = p.mediaItem(p.overlayClips[i].mediaID)?.duration ?? p.overlayClips[i].sourceEnd
            trimClip(&p.overlayClips[i], magnetic: false, mediaDuration: d)
        case .overlay(let id):
            guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
            if edge == .left {
                let d = delta.clamped(-p.overlays[i].start, p.overlays[i].duration - minDur)
                p.overlays[i].start += d
                p.overlays[i].duration -= d
            } else {
                p.overlays[i].duration = max(minDur, p.overlays[i].duration + delta)
            }
        case .text(let id):
            guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return }
            if edge == .left {
                let d = delta.clamped(-p.texts[i].start, p.texts[i].duration - minDur)
                p.texts[i].start += d
                p.texts[i].duration -= d
            } else {
                p.texts[i].duration = max(minDur, p.texts[i].duration + delta)
            }
        case .audio(let id):
            guard let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
            var a = p.audioClips[i]
            let speed = a.speed.clamped(0.1, 8)
            let mediaDuration = p.mediaItem(a.mediaID)?.duration ?? a.sourceEnd
            if edge == .left {
                var newStart = (a.sourceStart + delta * speed).clamped(0, a.sourceEnd - minDur * speed)
                if a.timelineStart + (newStart - a.sourceStart) / speed < 0 {
                    newStart = a.sourceStart - a.timelineStart * speed
                }
                a.timelineStart += (newStart - a.sourceStart) / speed
                a.sourceStart = newStart
            } else {
                a.sourceEnd = (a.sourceEnd + delta * speed).clamped(a.sourceStart + minDur * speed, mediaDuration)
            }
            p.audioClips[i] = a
        case .caption(let id):
            guard let i = p.captions.segments.firstIndex(where: { $0.id == id }) else { return }
            if edge == .left {
                p.captions.segments[i].start = min(max(0, p.captions.segments[i].start + delta), p.captions.segments[i].end - minDur)
            } else {
                p.captions.segments[i].end = max(p.captions.segments[i].start + minDur, p.captions.segments[i].end + delta)
            }
            let s = p.captions.segments[i]
            var seg = s
            seg.setText(s.text)
            p.captions.segments[i] = seg
        }
    }

    /// Moves a non-main-track item so it starts at `start`.
    static func move(_ p: inout Project, _ sel: TimelineSelection, to start: Double) {
        let s = max(0, start)
        switch sel {
        case .overlayClip(let id):
            if let i = p.overlayClips.firstIndex(where: { $0.id == id }) { p.overlayClips[i].timelineStart = s }
        case .overlay(let id):
            if let i = p.overlays.firstIndex(where: { $0.id == id }) { p.overlays[i].start = s }
        case .text(let id):
            if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].start = s }
        case .audio(let id):
            if let i = p.audioClips.firstIndex(where: { $0.id == id }) { p.audioClips[i].timelineStart = s }
        case .caption(let id):
            if let i = p.captions.segments.firstIndex(where: { $0.id == id }) {
                let shift = s - p.captions.segments[i].start
                p.captions.segments[i].start += shift
                p.captions.segments[i].end += shift
                for w in p.captions.segments[i].words.indices {
                    p.captions.segments[i].words[w].start += shift
                    p.captions.segments[i].words[w].end += shift
                }
            }
        case .clip(let id):
            if let i = p.clips.firstIndex(where: { $0.id == id }) {
                p.clips[i].timelineStart = s
                p.resolveMainTrackOverlaps()
            }
        }
    }

    /// Commits a main-track drag: reorders in magnetic mode, repositions otherwise.
    func commitMainTrackMove(clipID: UUID, dropStart: Double) {
        perform("Move Clip") { p in
            guard let i = p.clips.firstIndex(where: { $0.id == clipID }) else { return }
            if p.magnetic {
                let clip = p.clips.remove(at: i)
                let center = dropStart + clip.duration / 2
                let index = p.clips.filter { $0.timelineStart + $0.duration / 2 < center }.count
                p.clips.insert(clip, at: index)
                var cursor = 0.0
                for j in p.clips.indices {
                    p.clips[j].timelineStart = cursor
                    cursor += p.clips[j].duration
                }
            } else {
                p.clips[i].timelineStart = max(0, dropStart)
                let moved = p.clips.remove(at: i)
                let index = p.clips.filter { $0.timelineStart < moved.timelineStart }.count
                p.clips.insert(moved, at: index)
                var cursor = 0.0
                for j in p.clips.indices {
                    if p.clips[j].timelineStart < cursor { p.clips[j].timelineStart = cursor }
                    cursor = p.clips[j].timelineEnd
                }
            }
        }
        Haptics.action()
    }

    /// Snap targets in timeline seconds: playhead, item edges, beats.
    func snapCandidates(excluding id: UUID?) -> [Double] {
        var c: [Double] = [currentTime, 0]
        for x in project.clips where x.id != id { c.append(x.timelineStart); c.append(x.timelineEnd) }
        for x in project.overlayClips where x.id != id { c.append(x.timelineStart); c.append(x.timelineEnd) }
        for x in project.overlays where x.id != id { c.append(x.start); c.append(x.end) }
        for x in project.texts where x.id != id { c.append(x.start); c.append(x.end) }
        for x in project.audioClips where x.id != id { c.append(x.timelineStart); c.append(x.timelineEnd) }
        c.append(contentsOf: timelineBeats)
        return c
    }

    // MARK: Clip operations

    func setMagnetic(_ on: Bool) {
        perform(on ? "Magnetic On" : "Magnetic Off") { p in
            p.magnetic = on
            p.normalizeMainTrack()
        }
        showToast(on ? "Magnetic timeline on — gaps close automatically" : "Magnetic timeline off")
    }

    func setSpeed(_ speed: Double) {
        updateSelectedClip("Speed", coalesce: "speed") { $0.speed = speed.clamped(0.1, 8) }
    }

    func setRamp(_ ramp: SpeedRamp) {
        updateSelectedClip("Speed Ramp") { $0.ramp = ramp }
    }

    func setTransition(clipID: UUID, type: TransitionType, duration: Double? = nil) {
        updateClip(clipID, "Transition", coalesce: duration == nil ? nil : "transition-\(clipID)") { c in
            c.transitionOut.type = type
            if let duration { c.transitionOut.duration = duration.clamped(0.1, 2) }
        }
    }

    func applyTransitionToAll(from clipID: UUID) {
        guard let source = project.clip(clipID) else { return }
        perform("Transition to All") { p in
            for i in p.clips.indices where i < p.clips.count - 1 {
                p.clips[i].transitionOut = source.transitionOut
            }
        }
        showToast("Applied to all cuts")
    }

    func copyEffects() {
        guard let clip = selectedClip else { return }
        copiedEffects = clip.effectsPayload()
        showToast("Effects copied")
        Haptics.tap()
    }

    func pasteEffects() {
        guard let payload = copiedEffects else { return }
        updateSelectedClip("Paste Effects") { $0.apply(payload) }
        showToast("Effects pasted")
        Haptics.success()
    }

    func applyFilterToAllClips() {
        guard let clip = selectedClip else { return }
        perform("Filter to All") { p in
            for i in p.clips.indices { p.clips[i].filter = clip.filter }
            for i in p.overlayClips.indices { p.overlayClips[i].filter = clip.filter }
        }
        showToast("Look applied to every clip")
    }

    func detachAudio() {
        guard let clip = selectedClip, !clip.isImage, let m = media(clip.mediaID), m.hasAudio else {
            showToast("This clip has no audio")
            return
        }
        guard !clip.audioDetached else { return }
        var newID = UUID()
        perform("Detach Audio") { p in
            let audio = AudioClip(mediaID: clip.mediaID, name: "Audio · \(m.originalName)", kind: .extracted,
                                  timelineStart: clip.timelineStart, sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd,
                                  speed: clip.effectiveSpeed, reversed: clip.reversed, volume: clip.volume, muted: false,
                                  fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, denoise: clip.denoise)
            newID = audio.id
            p.audioClips.append(audio)
            if let i = p.clips.firstIndex(where: { $0.id == clip.id }) { p.clips[i].audioDetached = true }
            if let i = p.overlayClips.firstIndex(where: { $0.id == clip.id }) { p.overlayClips[i].audioDetached = true }
        }
        selection = .audio(newID)
        showToast("Audio detached")
        Haptics.action()
    }

    // MARK: Adding items

    func addText() {
        let start = project.isEmpty ? 0 : min(currentTime, max(project.duration - 0.5, 0))
        var item = TextItem(start: start)
        if project.duration > 0 { item.duration = min(3, max(project.duration - start, 1)) }
        perform("Add Text") { $0.texts.append(item) }
        selection = .text(item.id)
        activePanel = .text
        Haptics.action()
    }

    func addSticker(_ emoji: String) {
        var item = OverlayItem(kind: .sticker, start: currentTime)
        item.sticker = emoji
        perform("Add Sticker") { $0.overlays.append(item) }
        selection = .overlay(item.id)
        Haptics.action()
    }

    func addShape(_ shape: ShapeKind, color: RGBAColor) {
        var item = OverlayItem(kind: .shape, start: currentTime)
        item.shape = shape
        item.color = color
        perform("Add Shape") { $0.overlays.append(item) }
        selection = .overlay(item.id)
        Haptics.action()
    }

    func setCanvasAspect(_ aspect: AspectRatio) {
        perform("Canvas") { $0.canvas.aspect = aspect }
    }
}
