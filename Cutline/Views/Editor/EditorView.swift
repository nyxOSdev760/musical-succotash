import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Bindable var vm: EditorViewModel
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                if vm.missingMediaCount > 0 { missingBanner }
                PreviewArea(vm: vm)
                    .frame(height: max(200, geo.size.height * 0.42))
                controlRow
                TimelineView(vm: vm)
                    .frame(maxHeight: .infinity)
                ContextToolbar(vm: vm)
            }
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            if let toast = vm.toast {
                ToastView(message: toast)
                    .padding(.top, 54)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let busy = vm.busy {
                BusyOverlay(state: busy) { vm.cancelBusy() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
        .animation(.easeInOut(duration: 0.2), value: vm.busy != nil)
        .sheet(item: $vm.activePanel) { panel in
            PanelHost(vm: vm, panel: panel)
                .presentationDetents([.height(340), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
                .presentationBackground(Theme.panel)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $vm.showMediaPicker, selection: $vm.pickerItems, maxSelectionCount: 50,
                      selectionBehavior: .ordered,
                      matching: .any(of: [.videos, .images]))
        .onChange(of: vm.pickerItems) { _, items in
            if !items.isEmpty { vm.handlePicked(items) }
        }
        .fileImporter(isPresented: $vm.showMusicImporter, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            switch result {
            case .success(let url): vm.importMusic(url)
            case .failure(let error): vm.show(error)
            }
        }
        .fullScreenCover(isPresented: $vm.showExport) {
            ExportView(vm: vm)
        }
        .alert(vm.alert?.title ?? "", isPresented: Binding(get: { vm.alert != nil }, set: { if !$0 { vm.alert = nil } }),
               presenting: vm.alert) { info in
            if info.showsSettings {
                Button("Open Settings") { Permissions.openSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
        .onAppear { vm.onAppear() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                vm.playback.pause()
                vm.flushSave()
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close project")

            Text(vm.project.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker("Safe area guides", selection: $vm.safeGuide) {
                    ForEach(SafeGuide.allCases) { g in
                        Text(g.title).tag(g)
                    }
                }
            } label: {
                Image(systemName: vm.safeGuide == .none ? "rectangle.dashed" : "rectangle.inset.filled")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Safe area guides")

            Button {
                Haptics.action()
                vm.playback.pause()
                vm.showExport = true
            } label: {
                Text("Export")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(vm.project.duration < 0.05)
            .opacity(vm.project.duration < 0.05 ? 0.4 : 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 50)
    }

    private var missingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(vm.missingMediaCount) media file\(vm.missingMediaCount == 1 ? " is" : "s are") missing. Those clips show a placeholder — delete or replace them.")
                .font(.caption)
            Spacer()
        }
        .padding(8)
        .background(Color.red.opacity(0.25))
    }

    // MARK: Controls

    private var controlRow: some View {
        HStack(spacing: 4) {
            Text("\(TimeFormat.short(vm.playback.currentTime)) / \(TimeFormat.short(vm.project.duration))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 110, alignment: .leading)

            Spacer()

            Button {
                Haptics.tap()
                vm.playback.toggle()
            } label: {
                Image(systemName: vm.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel(vm.playback.isPlaying ? "Pause" : "Play")

            Spacer()

            if vm.selectedVisual != nil {
                Button {
                    vm.toggleKeyframe()
                } label: {
                    Image(systemName: vm.hasKeyframeAtPlayhead ? "diamond.fill" : "diamond")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(vm.hasKeyframeAtPlayhead ? Theme.accent : .white)
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel(vm.hasKeyframeAtPlayhead ? "Remove keyframe" : "Add keyframe")
            }

            Button {
                Haptics.tap()
                vm.setMagnetic(!vm.project.magnetic)
            } label: {
                Image(systemName: "magnet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(vm.project.magnetic ? Theme.accent : .white.opacity(0.6))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel(vm.project.magnetic ? "Magnetic timeline on" : "Magnetic timeline off")

            Button { vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 44)
            }
            .disabled(!vm.history.canUndo)
            .opacity(vm.history.canUndo ? 1 : 0.35)
            .accessibilityLabel("Undo")

            Button { vm.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 44)
            }
            .disabled(!vm.history.canRedo)
            .opacity(vm.history.canRedo ? 1 : 0.35)
            .accessibilityLabel("Redo")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}

// MARK: - Preview

struct PreviewArea: View {
    @Bindable var vm: EditorViewModel
    @State private var dragOffset: CGSize = .zero
    @State private var magnification: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var dragging = false
    @State private var pinching = false
    @State private var rotating = false
    @State private var snappedCenter = false

    var body: some View {
        GeometryReader { geo in
            let aspect = vm.project.canvas.aspect.ratio
            let fit = fittedSize(container: geo.size, aspect: aspect)
            ZStack {
                Color.black
                ZStack {
                    PlayerLayerView(player: vm.playback.player)
                    if vm.project.isEmpty {
                        emptyState
                    }
                    SafeAreaGuidesView(guide: vm.safeGuide, aspect: vm.project.canvas.aspect)
                        .allowsHitTesting(false)
                    if snappedCenter {
                        Rectangle().fill(Color.yellow).frame(width: 1).allowsHitTesting(false)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    vm.playback.toggle()
                }
                .gesture(dragGesture(size: fit))
                .simultaneousGesture(magnifyGesture)
                .simultaneousGesture(rotateGesture)
                .accessibilityLabel("Preview")
                .accessibilityHint("Tap to play or pause. Drag, pinch or rotate to move the selected item.")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 36))
            Text("Add videos or photos to start")
                .font(.headline)
            Button {
                vm.presentPicker(.mainTrack)
            } label: {
                Label("Add Media", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    private func fittedSize(container: CGSize, aspect: CGFloat) -> CGSize {
        let padded = CGSize(width: max(container.width - 16, 1), height: max(container.height - 8, 1))
        if padded.width / padded.height > aspect {
            return CGSize(width: padded.height * aspect, height: padded.height)
        }
        return CGSize(width: padded.width, height: padded.width / aspect)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard vm.selectedVisual != nil else { return }
                dragging = true
                dragOffset = value.translation
                applyLive(size: size)
            }
            .onEnded { _ in
                dragging = false
                finishIfIdle()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard vm.selectedVisual != nil else { return }
                pinching = true
                magnification = value.magnification
                applyLive(size: nil)
            }
            .onEnded { _ in
                pinching = false
                finishIfIdle()
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard vm.selectedVisual != nil else { return }
                rotating = true
                rotation = value.rotation
                applyLive(size: nil)
            }
            .onEnded { _ in
                rotating = false
                finishIfIdle()
            }
    }

    @State private var lastSize: CGSize = CGSize(width: 1, height: 1)

    private func applyLive(size: CGSize?) {
        if let size { lastSize = size }
        let dx = Double(dragOffset.width / max(lastSize.width, 1))
        let dy = Double(dragOffset.height / max(lastSize.height, 1))
        let mag = Double(magnification)
        let rot = rotation.degrees
        var didSnap = false
        vm.interactiveTransform { t in
            var nx = t.x + dx
            if abs(nx) < 0.015 {
                nx = 0
                didSnap = true
            }
            t.x = nx
            t.y += dy
            t.scale = (t.scale * mag).clamped(0.05, 10)
            t.rotation += rot
        }
        if didSnap != snappedCenter {
            snappedCenter = didSnap
            if didSnap { Haptics.snap() }
        }
    }

    private func finishIfIdle() {
        guard !dragging && !pinching && !rotating else { return }
        dragOffset = .zero
        magnification = 1
        rotation = .zero
        snappedCenter = false
        if vm.interactiveBase != nil { vm.endInteractive("Transform") }
    }
}

// MARK: - Safe area guides

struct SafeAreaGuidesView: View {
    let guide: SafeGuide
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ForEach(Array(zones(w: w, h: h).enumerated()), id: \.offset) { _, zone in
                Rectangle()
                    .fill(Color.red.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .overlay(alignment: .topLeading) {
                        Text(zone.1).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.85)).padding(3)
                    }
                    .frame(width: zone.0.width, height: zone.0.height)
                    .position(x: zone.0.midX, y: zone.0.midY)
            }
        }
    }

    private func zones(w: CGFloat, h: CGFloat) -> [(CGRect, String)] {
        switch guide {
        case .none:
            return []
        case .tiktok:
            return [
                (CGRect(x: 0, y: 0, width: w, height: h * 0.1), "Top bar"),
                (CGRect(x: w * 0.84, y: h * 0.38, width: w * 0.16, height: h * 0.5), "Buttons"),
                (CGRect(x: 0, y: h * 0.8, width: w * 0.84, height: h * 0.2), "Caption")
            ]
        case .reels:
            return [
                (CGRect(x: 0, y: 0, width: w, height: h * 0.08), "Top bar"),
                (CGRect(x: w * 0.85, y: h * 0.48, width: w * 0.15, height: h * 0.42), "Buttons"),
                (CGRect(x: 0, y: h * 0.82, width: w * 0.85, height: h * 0.18), "Caption")
            ]
        case .shorts:
            return [
                (CGRect(x: 0, y: 0, width: w, height: h * 0.08), "Top bar"),
                (CGRect(x: w * 0.84, y: h * 0.42, width: w * 0.16, height: h * 0.45), "Buttons"),
                (CGRect(x: 0, y: h * 0.8, width: w * 0.84, height: h * 0.2), "Title")
            ]
        case .youtube:
            return [
                (CGRect(x: 0, y: 0, width: w, height: h * 0.12), "Title"),
                (CGRect(x: 0, y: h * 0.86, width: w, height: h * 0.14), "Controls"),
                (CGRect(x: w * 0.72, y: h * 0.7, width: w * 0.28, height: h * 0.16), "End card")
            ]
        }
    }
}
