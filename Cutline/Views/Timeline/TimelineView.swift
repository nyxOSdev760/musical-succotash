import SwiftUI
import UIKit

/// Multi-track timeline with a fixed center playhead, drawn with Canvas for 60 fps scrolling.
struct TimelineView: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            let snapshot = TimelineSnapshot(vm: vm, size: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    snapshot.draw(in: &context, size: size)
                }
                TimelineGestureLayer(interaction: vm.interaction)
                PlayheadOverlay(height: geo.size.height)
                    .allowsHitTesting(false)
            }
            .onAppear { vm.interaction.viewSize = geo.size }
            .onChange(of: geo.size) { _, newSize in vm.interaction.viewSize = newSize }
        }
        .background(Color(white: 0.06))
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("Playhead at \(TimeFormat.short(vm.playback.currentTime)) of \(TimeFormat.short(vm.project.duration))")
    }
}

private struct PlayheadOverlay: View {
    let height: CGFloat
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: geo.size.width / 2, y: 2))
                p.addLine(to: CGPoint(x: geo.size.width / 2, y: height))
            }
            .stroke(Color.white, lineWidth: 2)
            .shadow(color: .black.opacity(0.6), radius: 2)
            Path { p in
                let x = geo.size.width / 2
                p.move(to: CGPoint(x: x - 7, y: 0))
                p.addLine(to: CGPoint(x: x + 7, y: 0))
                p.addLine(to: CGPoint(x: x, y: 9))
                p.closeSubpath()
            }
            .fill(Color.white)
        }
    }
}

/// Everything the Canvas needs, captured during `body` so SwiftUI observation tracks it.
struct TimelineSnapshot {
    let project: Project
    let layout: TimelineLayout
    let geometry: TimelineGeometry
    let selection: TimelineSelection?
    let verticalOffset: CGFloat
    let thumbnails: ThumbnailCache
    let waveforms: WaveformStore
    let resolver: MediaResolver
    let paths: ProjectPaths
    let beats: [Double]
    let snapTime: Double?
    let ghost: DragGhost?
    let thumbVersion: Int
    let waveVersion: Int

    @MainActor
    init(vm: EditorViewModel, size: CGSize) {
        project = vm.project
        layout = TimelineLayout(project: vm.project)
        geometry = TimelineGeometry(width: size.width, currentTime: vm.playback.currentTime, pixelsPerSecond: vm.pixelsPerSecond)
        selection = vm.selection
        verticalOffset = vm.verticalOffset
        thumbnails = vm.thumbnails
        waveforms = vm.waveforms
        resolver = vm.resolver
        paths = vm.paths
        beats = vm.timelineBeats
        snapTime = vm.snapTime
        ghost = vm.dragGhost
        thumbVersion = vm.thumbnails.version
        waveVersion = vm.waveforms.version
    }

    private func rowY(_ row: TimelineRow) -> CGFloat {
        TimelineLayout.rulerHeight + row.y - verticalOffset
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let visibleStart = geometry.time(for: -40)
        let visibleEnd = geometry.time(for: width + 40)

        // Tracks area (clipped below the ruler)
        var tracks = context
        tracks.clip(to: Path(CGRect(x: 0, y: TimelineLayout.rulerHeight, width: width, height: size.height - TimelineLayout.rulerHeight)))

        // Row backgrounds + empty hints
        for row in layout.rows {
            let y = rowY(row)
            let rect = CGRect(x: 0, y: y, width: width, height: row.height)
            tracks.fill(Path(rect), with: .color(Color.white.opacity(0.03)))
            if row.lane == 0 && layout.entries(in: row.kind).isEmpty && row.kind != .caption {
                let hint = Text("\(Image(systemName: "plus.circle.fill"))  \(row.kind.hint)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                let startX = max(geometry.x(for: 0) + 10, 46)
                tracks.draw(hint, at: CGPoint(x: startX, y: y + row.height / 2), anchor: .leading)
            }
        }

        // Entries
        for entry in layout.entries where entry.end >= visibleStart && entry.start <= visibleEnd {
            if let ghost, ghost.selection == entry.selection, entry.kind == .video { continue }
            drawEntry(entry, in: &tracks, start: entry.start, row: entry.row, dimmed: false)
        }

        // Main-track transition junctions and "+" button
        if let videoRow = layout.rows.first(where: { $0.kind == .video }) {
            let y = rowY(videoRow)
            let clips = project.clips
            for i in 0..<max(0, clips.count - 1) where abs(clips[i].timelineEnd - clips[i + 1].timelineStart) < 0.02 {
                let x = geometry.x(for: clips[i].timelineEnd)
                guard x > -20 && x < width + 20 else { continue }
                let box = CGRect(x: x - 11, y: y + videoRow.height / 2 - 11, width: 22, height: 22)
                let hasTransition = clips[i].transitionOut.type != .cut
                tracks.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(hasTransition ? Theme.accent : Color.white))
                let icon = Text(Image(systemName: hasTransition ? clips[i].transitionOut.type.icon : "plus"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(hasTransition ? .white : .black)
                tracks.draw(icon, at: CGPoint(x: box.midX, y: box.midY))
            }
            let endX = geometry.x(for: clips.last?.timelineEnd ?? 0)
            if !clips.isEmpty && endX < width + 60 {
                let plus = CGRect(x: endX + 10, y: y + 8, width: videoRow.height - 16, height: videoRow.height - 16)
                tracks.fill(Path(roundedRect: plus, cornerRadius: 8), with: .color(Color.white.opacity(0.9)))
                tracks.draw(Text(Image(systemName: "plus")).font(.system(size: 18, weight: .bold)).foregroundColor(.black),
                            at: CGPoint(x: plus.midX, y: plus.midY))
            }
        }

        // Drag ghost (main track reorder)
        if let ghost, let entry = layout.entry(for: ghost.selection) {
            var lifted = entry.row
            lifted.y -= 4
            drawEntry(entry, in: &tracks, start: ghost.start, row: lifted, dimmed: true)
            if project.magnetic {
                let center = ghost.start + ghost.duration / 2
                let others = project.clips.filter { $0.id != ghost.selection.id }
                let index = others.filter { $0.timelineStart + $0.duration / 2 < center }.count
                var insertTime = 0.0
                for c in others.prefix(index) { insertTime += c.duration }
                let x = geometry.x(for: insertTime)
                let y = rowY(entry.row)
                tracks.fill(Path(roundedRect: CGRect(x: x - 2, y: y - 4, width: 4, height: entry.row.height + 8), cornerRadius: 2),
                            with: .color(Theme.accent))
            }
        }

        // Snap guide
        if let snapTime {
            let x = geometry.x(for: snapTime)
            var p = Path()
            p.move(to: CGPoint(x: x, y: TimelineLayout.rulerHeight))
            p.addLine(to: CGPoint(x: x, y: size.height))
            tracks.stroke(p, with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        drawRuler(in: &context, width: width, visibleStart: visibleStart, visibleEnd: visibleEnd)
        drawTrackIcons(in: &context)
    }

    // MARK: Entries

    private func drawEntry(_ entry: TimelineEntry, in context: inout GraphicsContext, start: Double, row: TimelineRow, dimmed: Bool) {
        let duration = entry.end - entry.start
        let x0 = geometry.x(for: start)
        let x1 = geometry.x(for: start + duration)
        let y = rowY(row)
        let rect = CGRect(x: x0, y: y, width: max(x1 - x0, 2), height: row.height)
        let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 6)
        let isSelected = selection == entry.selection

        var layer = context
        if dimmed {
            layer.opacity = 0.85
            layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 8, y: 4))
        }
        layer.fill(shape, with: .color(entry.kind.color))

        var inner = layer
        inner.clip(to: shape)
        switch entry.kind {
        case .video:
            if let clip = project.clips.first(where: { $0.id == entry.id }) {
                drawThumbnails(clip: clip, rect: rect, in: &inner)
                drawClipBadges(clip: clip, rect: rect, in: &inner)
            }
        case .overlay:
            if let clip = project.overlayClips.first(where: { $0.id == entry.id }) {
                drawThumbnails(clip: clip, rect: rect, in: &inner)
                drawLabel(Text("\(Image(systemName: "pip")) \(clip.isImage ? "Photo" : "Video")"), rect: rect, in: &inner)
            } else if let item = project.overlays.first(where: { $0.id == entry.id }) {
                let icon: String
                switch item.kind {
                case .image: icon = "photo"
                case .sticker: icon = "face.smiling"
                case .shape: icon = item.shape.icon
                }
                drawLabel(Text("\(Image(systemName: icon)) \(item.title)"), rect: rect, in: &inner)
            }
        case .text:
            drawLabel(Text("\(Image(systemName: "textformat")) \(entry.title)"), rect: rect, in: &inner)
        case .caption:
            drawLabel(Text(entry.title).font(.system(size: 10, weight: .semibold)), rect: rect, in: &inner)
        case .audio:
            if let audio = project.audioClips.first(where: { $0.id == entry.id }) {
                drawWaveform(audio: audio, rect: rect, in: &inner)
                drawLabel(Text("\(Image(systemName: audio.kind.icon)) \(audio.name)\(audio.muted ? "  🔇" : "")"), rect: rect, in: &inner)
                drawBeats(audio: audio, rect: rect, in: &inner)
            }
        }

        if isSelected {
            layer.stroke(shape, with: .color(.white), lineWidth: 2.5)
            let handleW: CGFloat = 14
            let left = CGRect(x: rect.minX - handleW, y: rect.minY, width: handleW, height: rect.height)
            let right = CGRect(x: rect.maxX, y: rect.minY, width: handleW, height: rect.height)
            for (h, chevron) in [(left, "chevron.compact.left"), (right, "chevron.compact.right")] {
                layer.fill(Path(roundedRect: h, cornerRadius: 4), with: .color(.white))
                layer.draw(Text(Image(systemName: chevron)).font(.system(size: 13, weight: .bold)).foregroundColor(.black),
                           at: CGPoint(x: h.midX, y: h.midY))
            }
        }
    }

    private func drawLabel(_ text: Text, rect: CGRect, in context: inout GraphicsContext) {
        let styled = text.font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
        // Keep the label visible when the item starts off-screen, without leaving the item.
        let x = min(max(rect.minX + 6, 36), max(rect.maxX - 40, rect.minX + 6))
        context.draw(styled, at: CGPoint(x: x, y: rect.minY + 11), anchor: .leading)
    }

    private func drawThumbnails(clip: Clip, rect: CGRect, in context: inout GraphicsContext) {
        guard let url = resolver.thumbnailURL(for: clip.mediaID, reversed: clip.reversed) else {
            context.fill(Path(rect), with: .color(Color(red: 0.45, green: 0.08, blue: 0.1)))
            context.draw(Text("\(Image(systemName: "exclamationmark.triangle.fill")) Missing media")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: rect.minX + 8, y: rect.midY), anchor: .leading)
            return
        }
        let tileW = rect.height * 0.8
        let tileSeconds = Double(tileW) / geometry.pixelsPerSecond
        let step = max(0.25, pow(2, (log2(tileSeconds * clip.effectiveSpeed)).rounded()))
        let first = max(0, Int((0 - rect.minX) / tileW) - 1)
        let last = Int((geometry.width - rect.minX) / tileW) + 1
        guard last >= first else { return }
        for i in first...last {
            let tx = rect.minX + CGFloat(i) * tileW
            if tx > rect.maxX || tx > geometry.width + tileW { break }
            if tx + tileW < -tileW { continue }
            let local = Double(tx - rect.minX + tileW / 2) / geometry.pixelsPerSecond
            let source = clip.sourceTime(atLocal: min(local, clip.duration))
            let quantized = clip.isImage ? 0 : (source / step).rounded() * step
            let tile = CGRect(x: tx, y: rect.minY, width: tileW, height: rect.height)
            if let img = thumbnails.image(url: url, time: quantized, isImage: clip.isImage) ?? thumbnails.nearest(url: url, time: quantized) {
                let aspect = img.size.width / max(img.size.height, 1)
                var drawRect = tile
                let fitW = tile.height * aspect
                if fitW > tile.width {
                    drawRect = CGRect(x: tile.midX - fitW / 2, y: tile.minY, width: fitW, height: tile.height)
                } else {
                    let fitH = tile.width / max(aspect, 0.01)
                    drawRect = CGRect(x: tile.minX, y: tile.midY - fitH / 2, width: tile.width, height: fitH)
                }
                var tileContext = context
                tileContext.clip(to: Path(tile))
                tileContext.draw(Image(uiImage: img), in: drawRect)
            }
        }
    }

    private func drawClipBadges(clip: Clip, rect: CGRect, in context: inout GraphicsContext) {
        var parts: [String] = []
        if clip.reversed { parts.append("arrow.uturn.backward") }
        if !clip.filter.isIdentity || clip.effects.chromaKey.enabled || clip.effects.removeBackground { parts.append("wand.and.stars") }
        if clip.effects.stabilize { parts.append("hand.raised.slash") }
        if clip.muted || clip.audioDetached { parts.append("speaker.slash.fill") }
        if !clip.keyframes.isEmpty { parts.append("diamond.fill") }
        var label = Text("")
        for p in parts { label = label + Text(Image(systemName: p)) + Text(" ") }
        let speedText = clip.ramp != .none ? "\(clip.ramp.title) " : (abs(clip.speed - 1) > 0.01 ? String(format: "%.2gx ", clip.speed) : "")
        label = label + Text(speedText) + Text(String(format: "%.1fs", clip.duration))
        let styled = label.font(.system(size: 10, weight: .bold)).foregroundColor(.white)
        let resolved = context.resolve(styled)
        let size = resolved.measure(in: CGSize(width: 400, height: 20))
        let x = max(rect.minX + 4, 4)
        let pill = CGRect(x: x, y: rect.maxY - size.height - 6, width: size.width + 8, height: size.height + 2)
        if pill.maxX < rect.maxX {
            context.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(.black.opacity(0.55)))
            context.draw(resolved, at: CGPoint(x: pill.minX + 4, y: pill.midY), anchor: .leading)
        }
    }

    private func drawWaveform(audio: AudioClip, rect: CGRect, in context: inout GraphicsContext) {
        guard let url = resolver.audioURL(mediaID: audio.mediaID, reversed: audio.reversed, denoise: false) else { return }
        let cacheFile = paths.cache("wave_\(url.lastPathComponent).bin")
        guard let env = waveforms.envelope(for: url, cacheFile: cacheFile), !env.isEmpty else { return }
        var path = Path()
        let mid = rect.midY + 6
        let maxH = (rect.height - 16) / 2
        let startX = max(rect.minX, 0)
        let endX = min(rect.maxX, geometry.width)
        var x = startX
        while x < endX {
            let local = Double(x - rect.minX) / geometry.pixelsPerSecond
            let source = audio.sourceTime(atLocal: local)
            let idx = Int(source * WaveformGenerator.envelopeRate)
            let v = idx >= 0 && idx < env.count ? CGFloat(env[idx]) : 0
            let h = max(1, v * maxH * CGFloat(audio.volume.clamped(0.15, 1)))
            path.addRect(CGRect(x: x, y: mid - h, width: 1.5, height: h * 2))
            x += 3
        }
        context.fill(path, with: .color(.white.opacity(audio.muted ? 0.2 : 0.55)))
    }

    private func drawBeats(audio: AudioClip, rect: CGRect, in context: inout GraphicsContext) {
        for b in beats where b >= audio.timelineStart && b <= audio.timelineEnd {
            let x = geometry.x(for: b)
            guard x >= rect.minX && x <= rect.maxX && x > -4 && x < geometry.width + 4 else { continue }
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: rect.maxY - 7, width: 5, height: 5)), with: .color(.yellow))
        }
    }

    // MARK: Ruler

    private func drawRuler(in context: inout GraphicsContext, width: CGFloat, visibleStart: Double, visibleEnd: Double) {
        let rect = CGRect(x: 0, y: 0, width: width, height: TimelineLayout.rulerHeight)
        context.fill(Path(rect), with: .color(Color(white: 0.06)))
        let pps = geometry.pixelsPerSecond
        let steps: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let major = steps.first { $0 * pps >= 64 } ?? 600
        let minor = major / (major <= 0.5 ? 2 : 5)
        var t = max(0, (visibleStart / minor).rounded(.down) * minor)
        var ticks = Path()
        while t <= visibleEnd {
            let x = geometry.x(for: t)
            let isMajor = abs((t / major).rounded() - t / major) < 0.001
            ticks.move(to: CGPoint(x: x, y: TimelineLayout.rulerHeight - (isMajor ? 9 : 4)))
            ticks.addLine(to: CGPoint(x: x, y: TimelineLayout.rulerHeight))
            if isMajor {
                let label = major < 1 ? String(format: "%.1fs", t) : TimeFormat.clock(t)
                context.draw(Text(label).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.5)),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
            }
            t += minor
        }
        context.stroke(ticks, with: .color(.white.opacity(0.3)), lineWidth: 1)
        for b in beats where b >= visibleStart && b <= visibleEnd {
            let x = geometry.x(for: b)
            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: TimelineLayout.rulerHeight - 5, width: 4, height: 4)), with: .color(.yellow.opacity(0.8)))
        }
        // End-of-timeline marker
        let endX = geometry.x(for: project.duration)
        if endX > 0 && endX < width {
            var p = Path()
            p.move(to: CGPoint(x: endX, y: 0))
            p.addLine(to: CGPoint(x: endX, y: TimelineLayout.rulerHeight))
            context.stroke(p, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
        }
    }

    private func drawTrackIcons(in context: inout GraphicsContext) {
        var seen = Set<TrackKind>()
        for row in layout.rows where !seen.contains(row.kind) {
            seen.insert(row.kind)
            let y = rowY(row)
            guard y + row.height > TimelineLayout.rulerHeight else { continue }
            let box = CGRect(x: 4, y: y + row.height / 2 - 12, width: 26, height: 24)
            context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color.black.opacity(0.65)))
            context.draw(Text(Image(systemName: row.kind.icon)).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.8)),
                         at: CGPoint(x: box.midX, y: box.midY))
        }
    }
}
