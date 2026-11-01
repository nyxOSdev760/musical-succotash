import Foundation
import SwiftUI
import UIKit

/// Translates touches on the timeline into scrubbing, trimming, moving, zooming and selection.
@MainActor
final class TimelineInteraction: NSObject {
    private weak var vm: EditorViewModel?
    var viewSize: CGSize = .zero

    private enum PanMode {
        case none
        case scrub(startTime: Double)
        case vertical(startOffset: CGFloat)
        case trim(selection: TimelineSelection, edge: TrimEdge, edgeTime: Double, entryID: UUID)
    }

    private var panMode: PanMode = .none
    private var pinchBase: Double = 60
    private var moveState: (selection: TimelineSelection, kind: TrackKind, grab: Double, duration: Double, id: UUID)?
    private var lastSnap: Double?

    // Momentum scrolling
    private var displayLink: CADisplayLink?
    private var velocity: Double = 0
    private var lastTimestamp: CFTimeInterval = 0

    init(viewModel: EditorViewModel) {
        self.vm = viewModel
        super.init()
    }

    // MARK: Geometry

    private var geometry: TimelineGeometry? {
        guard let vm else { return nil }
        return TimelineGeometry(width: viewSize.width, currentTime: vm.playback.currentTime, pixelsPerSecond: vm.pixelsPerSecond)
    }

    private func contentY(_ point: CGPoint) -> CGFloat {
        point.y - TimelineLayout.rulerHeight + (vm?.verticalOffset ?? 0)
    }

    private var layout: TimelineLayout? {
        guard let vm else { return nil }
        return TimelineLayout(project: vm.project)
    }

    private func maxVerticalOffset(_ layout: TimelineLayout) -> CGFloat {
        max(0, layout.contentHeight - (viewSize.height - TimelineLayout.rulerHeight))
    }

    // MARK: Tap

    func tap(at point: CGPoint) {
        guard let vm, let geo = geometry, let layout else { return }
        stopMomentum()
        let time = geo.time(for: point.x)
        if point.y < TimelineLayout.rulerHeight {
            vm.playback.scrub(to: time)
            Haptics.tap()
            return
        }
        let y = contentY(point)

        // Transition junctions on the main track
        if let videoRow = layout.rows.first(where: { $0.kind == .video }), videoRow.contains(y: y) {
            let clips = vm.project.clips
            for i in 0..<max(0, clips.count - 1) where abs(clips[i].timelineEnd - clips[i + 1].timelineStart) < 0.02 {
                let jx = geo.x(for: clips[i].timelineEnd)
                if abs(point.x - jx) < 14 {
                    vm.transitionTargetClipID = clips[i].id
                    vm.activePanel = .transition
                    Haptics.tap()
                    return
                }
            }
            // "+" button after the last clip
            let endX = geo.x(for: clips.last?.timelineEnd ?? 0)
            if point.x > endX + 6 && point.x < endX + 56 {
                vm.presentPicker(.mainTrack)
                return
            }
        }

        let slop = 6 / vm.pixelsPerSecond
        if let entry = layout.entry(atContentY: y, time: time, slop: slop) {
            vm.select(entry.selection)
            return
        }
        if let row = layout.row(atContentY: y), layout.entries(in: row.kind).isEmpty {
            switch row.kind {
            case .video: vm.presentPicker(.mainTrack)
            case .overlay: vm.activePanel = .overlay
            case .text: vm.addText()
            case .audio: vm.activePanel = .audio
            case .caption: break
            }
            return
        }
        vm.select(nil)
    }

    func doubleTap(at point: CGPoint) {
        guard let vm, let geo = geometry, let layout else { return }
        let time = geo.time(for: point.x)
        let y = contentY(point)
        if let entry = layout.entry(atContentY: y, time: time, slop: 4 / vm.pixelsPerSecond) {
            vm.select(entry.selection)
            vm.splitAtPlayhead()
        } else {
            vm.splitAtPlayhead()
        }
    }

    // MARK: Pan

    func panBegan(at point: CGPoint, velocity v: CGPoint) {
        guard let vm, let geo = geometry, let layout else { return }
        stopMomentum()
        let y = contentY(point)

        // Trim handles of the selected item
        if point.y >= TimelineLayout.rulerHeight, let entry = layout.entry(for: vm.selection), entry.row.contains(y: y) || abs(y - (entry.row.y + entry.row.height / 2)) < entry.row.height {
            let sx = geo.x(for: entry.start), ex = geo.x(for: entry.end)
            if point.x > sx - 26 && point.x < sx + 12 {
                beginTrim(entry, edge: .left, edgeTime: entry.start)
                return
            }
            if point.x > ex - 12 && point.x < ex + 26 {
                beginTrim(entry, edge: .right, edgeTime: entry.end)
                return
            }
        }

        if abs(v.y) > abs(v.x) * 1.3 && maxVerticalOffset(layout) > 0 && point.y >= TimelineLayout.rulerHeight {
            panMode = .vertical(startOffset: vm.verticalOffset)
            return
        }
        if vm.playback.isPlaying { vm.playback.pause() }
        panMode = .scrub(startTime: vm.playback.currentTime)
    }

    private func beginTrim(_ entry: TimelineEntry, edge: TrimEdge, edgeTime: Double) {
        guard let vm else { return }
        if vm.playback.isPlaying { vm.playback.pause() }
        vm.beginInteractive()
        panMode = .trim(selection: entry.selection, edge: edge, edgeTime: edgeTime, entryID: entry.id)
        lastSnap = nil
        Haptics.tap()
    }

    func panChanged(translation: CGPoint) {
        guard let vm else { return }
        switch panMode {
        case .none:
            break
        case .scrub(let start):
            let t = start - Double(translation.x) / vm.pixelsPerSecond
            vm.playback.scrub(to: t)
        case .vertical(let startOffset):
            guard let layout else { return }
            vm.verticalOffset = (startOffset - translation.y).clamped(0, maxVerticalOffset(layout))
        case .trim(let selection, let edge, let edgeTime, let entryID):
            var delta = Double(translation.x) / vm.pixelsPerSecond
            let target = edgeTime + delta
            if let snapped = snap(target, excluding: entryID) {
                delta = snapped - edgeTime
                vm.snapTime = snapped
            } else {
                vm.snapTime = nil
            }
            vm.updateInteractive { p, _ in
                EditorViewModel.trim(&p, selection, edge: edge, delta: delta)
            }
        }
    }

    func panEnded(velocity v: CGPoint) {
        guard let vm else { return }
        switch panMode {
        case .scrub:
            let vx = Double(v.x)
            if abs(vx) > 250 {
                startMomentum(velocity: -vx / vm.pixelsPerSecond)
            }
        case .trim:
            vm.endInteractive("Trim")
            vm.snapTime = nil
        default:
            break
        }
        panMode = .none
    }

    // MARK: Snapping

    private func snap(_ time: Double, excluding id: UUID?) -> Double? {
        guard let vm else { return nil }
        let threshold = 10 / vm.pixelsPerSecond
        let candidates = vm.snapCandidates(excluding: id)
        guard let best = candidates.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) <= threshold else {
            lastSnap = nil
            return nil
        }
        if lastSnap == nil || abs(lastSnap! - best) > 0.0001 {
            Haptics.snap()
        }
        lastSnap = best
        return best
    }

    // MARK: Pinch zoom

    func pinch(scale: CGFloat, state: UIGestureRecognizer.State) {
        guard let vm else { return }
        switch state {
        case .began:
            stopMomentum()
            pinchBase = vm.pixelsPerSecond
        case .changed:
            let newValue = (pinchBase * Double(scale)).clamped(5, 800)
            if (newValue == 5 || newValue == 800) && vm.pixelsPerSecond != newValue { Haptics.snap() }
            vm.pixelsPerSecond = newValue
        default:
            vm.scheduleStateSave()
        }
    }

    // MARK: Long-press move

    func longPressBegan(at point: CGPoint) {
        guard let vm, let geo = geometry, let layout else { return }
        stopMomentum()
        let time = geo.time(for: point.x)
        guard let entry = layout.entry(atContentY: contentY(point), time: time, slop: 0) else { return }
        if vm.playback.isPlaying { vm.playback.pause() }
        vm.select(entry.selection)
        moveState = (entry.selection, entry.kind, time - entry.start, entry.end - entry.start, entry.id)
        lastSnap = nil
        Haptics.action()
        if entry.kind == .video {
            vm.dragGhost = DragGhost(selection: entry.selection, kind: .video, start: entry.start, duration: entry.end - entry.start)
        } else {
            vm.beginInteractive()
        }
    }

    func longPressChanged(at point: CGPoint) {
        guard let vm, let geo = geometry, let state = moveState else { return }
        let fingerTime = geo.time(for: point.x)
        var start = max(0, fingerTime - state.grab)
        if let s = snap(start, excluding: state.id) {
            start = s
            vm.snapTime = s
        } else if let e = snap(start + state.duration, excluding: state.id) {
            start = max(0, e - state.duration)
            vm.snapTime = e
        } else {
            vm.snapTime = nil
        }
        if state.kind == .video {
            vm.dragGhost?.start = start
        } else {
            let selection = state.selection
            vm.updateInteractive { p, _ in
                EditorViewModel.move(&p, selection, to: start)
            }
        }
    }

    func longPressEnded(cancelled: Bool) {
        guard let vm, let state = moveState else { return }
        moveState = nil
        vm.snapTime = nil
        if state.kind == .video {
            let ghost = vm.dragGhost
            vm.dragGhost = nil
            if !cancelled, let ghost, case .clip(let id) = state.selection {
                vm.commitMainTrackMove(clipID: id, dropStart: ghost.start)
            }
        } else if cancelled {
            vm.cancelInteractive()
        } else {
            vm.endInteractive("Move")
        }
    }

    // MARK: Momentum

    private func startMomentum(velocity v: Double) {
        velocity = v
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        velocity = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let vm else {
            stopMomentum()
            return
        }
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let next = vm.playback.currentTime + velocity * dt
        vm.playback.scrub(to: next)
        velocity *= pow(0.998, dt * 1000)
        if abs(velocity * vm.pixelsPerSecond) < 20 || next <= 0 || next >= vm.playback.duration {
            stopMomentum()
        }
    }
}

/// Transparent UIKit layer that recognizes timeline gestures precisely and simultaneously.
struct TimelineGestureLayer: UIViewRepresentable {
    let interaction: TimelineInteraction

    func makeCoordinator() -> Coordinator { Coordinator(interaction: interaction) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = c
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: doubleTap)
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        long.minimumPressDuration = 0.35
        long.delegate = c
        pan.require(toFail: long)

        [pan, pinch, doubleTap, tap, long].forEach { view.addGestureRecognizer($0) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.interaction = interaction
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var interaction: TimelineInteraction

        init(interaction: TimelineInteraction) {
            self.interaction = interaction
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            interaction.tap(at: g.location(in: g.view))
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            interaction.doubleTap(at: g.location(in: g.view))
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                let t = g.translation(in: g.view)
                let start = CGPoint(x: g.location(in: g.view).x - t.x, y: g.location(in: g.view).y - t.y)
                interaction.panBegan(at: start, velocity: g.velocity(in: g.view))
                interaction.panChanged(translation: t)
            case .changed:
                interaction.panChanged(translation: g.translation(in: g.view))
            case .ended, .cancelled, .failed:
                interaction.panEnded(velocity: g.velocity(in: g.view))
            default:
                break
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            interaction.pinch(scale: g.scale, state: g.state)
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                interaction.longPressBegan(at: g.location(in: g.view))
            case .changed:
                interaction.longPressChanged(at: g.location(in: g.view))
            case .ended:
                interaction.longPressEnded(cancelled: false)
            case .cancelled, .failed:
                interaction.longPressEnded(cancelled: true)
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer is UIPinchGestureRecognizer) || (other is UIPinchGestureRecognizer)
        }
    }
}
