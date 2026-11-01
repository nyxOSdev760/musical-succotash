import SwiftUI

/// Slider that groups a whole drag into one undo step and keeps the preview live.
struct EditSlider: View {
    let vm: EditorViewModel
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        ValueSlider(title: title, value: $value, range: range, format: format) { editing in
            if editing {
                vm.beginInteractive()
            } else {
                vm.endInteractive(title)
            }
        }
    }
}

// MARK: - Speed

struct SpeedPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Speed") { vm.activePanel = nil }
            if let clip = vm.selectedClip, !clip.isImage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        EditSlider(vm: vm, title: "Speed",
                                   value: Binding(get: { log2(clip.speed) }, set: { vm.setSpeed(pow(2, $0)) }),
                                   range: log2(0.1)...log2(8),
                                   format: { String(format: "%.2fx", pow(2, $0)) })
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach([0.1, 0.25, 0.5, 1, 1.5, 2, 4, 8], id: \.self) { s in
                                    ChipButton(title: s < 1 ? String(format: "%.2gx", s) : String(format: "%gx", s),
                                               isSelected: abs(clip.speed - s) < 0.01) { vm.setSpeed(s) }
                                }
                            }
                        }
                        Text("Speed ramps").font(.subheadline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(SpeedRamp.allCases) { r in
                                    ChipButton(title: r.title, icon: r == .none ? "circle.slash" : "chart.xyaxis.line",
                                               isSelected: clip.ramp == r) { vm.setRamp(r) }
                                }
                            }
                        }
                        Text("Duration \(String(format: "%.1fs", clip.sourceDuration)) → \(String(format: "%.1fs", clip.duration)). Audio keeps its pitch.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal)
                }
            } else {
                EmptyPanelMessage(text: "Select a video clip to change its speed.")
            }
        }
    }
}

// MARK: - Volume

struct VolumePanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Audio") { vm.activePanel = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let audio = vm.selectedAudio {
                        EditSlider(vm: vm, title: "Volume", value: vm.audioBinding(\.volume, default: 1, name: "Volume"), range: 0...1)
                        Toggle("Mute", isOn: vm.audioBinding(\.muted, default: false, name: "Mute"))
                        EditSlider(vm: vm, title: "Fade in", value: vm.audioBinding(\.fadeIn, default: 0, name: "Fade In"),
                                   range: 0...min(5, audio.duration / 2), format: { String(format: "%.1fs", $0) })
                        EditSlider(vm: vm, title: "Fade out", value: vm.audioBinding(\.fadeOut, default: 0, name: "Fade Out"),
                                   range: 0...min(5, audio.duration / 2), format: { String(format: "%.1fs", $0) })
                        denoiseButton(active: audio.denoise)
                    } else if let clip = vm.selectedClip, !clip.isImage {
                        if clip.audioDetached {
                            Label("Audio is detached to its own track. Select it on the audio track to edit.", systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        EditSlider(vm: vm, title: "Volume", value: vm.clipBinding(\.volume, default: 1, name: "Volume"), range: 0...1)
                        Toggle("Mute", isOn: vm.clipBinding(\.muted, default: false, name: "Mute"))
                        EditSlider(vm: vm, title: "Fade in", value: vm.clipBinding(\.fadeIn, default: 0, name: "Fade In"),
                                   range: 0...min(5, clip.duration / 2), format: { String(format: "%.1fs", $0) })
                        EditSlider(vm: vm, title: "Fade out", value: vm.clipBinding(\.fadeOut, default: 0, name: "Fade Out"),
                                   range: 0...min(5, clip.duration / 2), format: { String(format: "%.1fs", $0) })
                        HStack {
                            denoiseButton(active: clip.denoise)
                            Button {
                                vm.detachAudio()
                            } label: {
                                Label("Detach audio", systemImage: "rectangle.and.arrow.up.right.and.arrow.down.left")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(clip.audioDetached)
                        }
                    } else {
                        EmptyPanelMessage(text: "Select a video or audio clip.")
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func denoiseButton(active: Bool) -> some View {
        Button {
            vm.toggleDenoise()
        } label: {
            Label(active ? "Noise reduction on" : "Reduce noise", systemImage: "waveform.badge.minus")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(active ? Theme.accent : .white)
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Bindable var vm: EditorViewModel

    private let presets: [(String, Double?)] = [("Original", nil), ("9:16", 9.0 / 16.0), ("1:1", 1), ("4:5", 0.8), ("16:9", 16.0 / 9.0), ("4:3", 4.0 / 3.0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Crop & Rotate") { vm.activePanel = nil }
            if let clip = vm.selectedClip, let media = vm.media(clip.mediaID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(presets, id: \.0) { preset in
                                    ChipButton(title: preset.0, isSelected: isPreset(clip.crop, preset.1, media.size)) {
                                        vm.updateSelectedClip("Crop") { c in
                                            c.crop = preset.1.map { CropRect.centered(aspect: $0, sourceSize: media.size) } ?? .full
                                        }
                                    }
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            actionButton("Rotate", "rotate.right") { vm.updateSelectedClip("Rotate") { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } }
                            actionButton("Flip H", "arrow.left.and.right.righttriangle.left.righttriangle.right") { vm.updateSelectedClip("Flip") { $0.flipH.toggle() } }
                            actionButton("Flip V", "arrow.up.and.down.righttriangle.up.righttriangle.down") { vm.updateSelectedClip("Flip") { $0.flipV.toggle() } }
                        }
                        Picker("Fit", selection: vm.clipBinding(\.fit, default: .fit, name: "Fit")) {
                            Text("Fit (show all)").tag(FitMode.fit)
                            Text("Fill (no bars)").tag(FitMode.fill)
                        }
                        .pickerStyle(.segmented)
                        EditSlider(vm: vm, title: "Zoom", value: vm.transformBinding(\.scale, name: "Zoom"), range: 0.2...4,
                                   format: { String(format: "%.0f%%", $0 * 100) })
                        EditSlider(vm: vm, title: "Pan horizontal", value: vm.transformBinding(\.x, name: "Pan"), range: -1...1,
                                   format: { String(format: "%.0f", $0 * 100) })
                        EditSlider(vm: vm, title: "Pan vertical", value: vm.transformBinding(\.y, name: "Pan"), range: -1...1,
                                   format: { String(format: "%.0f", $0 * 100) })
                        Text("Crop edges").font(.subheadline.weight(.semibold))
                        EditSlider(vm: vm, title: "Left", value: cropBinding(.left), range: 0...0.45)
                        EditSlider(vm: vm, title: "Right", value: cropBinding(.right), range: 0...0.45)
                        EditSlider(vm: vm, title: "Top", value: cropBinding(.top), range: 0...0.45)
                        EditSlider(vm: vm, title: "Bottom", value: cropBinding(.bottom), range: 0...0.45)
                        Button("Reset crop & position") {
                            vm.updateSelectedClip("Reset Crop") { c in
                                c.crop = .full
                                c.quarterTurns = 0
                                c.flipH = false
                                c.flipV = false
                            }
                            vm.resetTransform()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.horizontal)
                }
            } else {
                EmptyPanelMessage(text: "Select a clip to crop it.")
            }
        }
    }

    private enum Edge { case left, right, top, bottom }

    private func cropBinding(_ edge: Edge) -> Binding<Double> {
        Binding(
            get: {
                let c = vm.selectedClip?.crop ?? .full
                switch edge {
                case .left: return c.x
                case .right: return 1 - c.x - c.width
                case .top: return c.y
                case .bottom: return 1 - c.y - c.height
                }
            },
            set: { v in
                vm.updateSelectedClip("Crop", coalesce: "crop") { clip in
                    var c = clip.crop
                    var l = c.x, r = 1 - c.x - c.width, t = c.y, b = 1 - c.y - c.height
                    switch edge {
                    case .left: l = v
                    case .right: r = v
                    case .top: t = v
                    case .bottom: b = v
                    }
                    c.x = l
                    c.width = max(0.05, 1 - l - r)
                    c.y = t
                    c.height = max(0.05, 1 - t - b)
                    clip.crop = c
                }
            }
        )
    }

    private func isPreset(_ crop: CropRect, _ aspect: Double?, _ size: CGSize) -> Bool {
        guard let aspect else { return crop.isFull }
        let target = CropRect.centered(aspect: aspect, sourceSize: size)
        return abs(target.width - crop.width) < 0.005 && abs(target.height - crop.height) < 0.005
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }
}

// MARK: - Trim

struct TrimPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Trim") { vm.activePanel = nil }
            if let clip = vm.selectedClip {
                VStack(alignment: .leading, spacing: 14) {
                    if clip.isImage {
                        EditSlider(vm: vm, title: "Duration",
                                   value: Binding(get: { clip.sourceDuration }, set: { v in
                                       vm.updateSelectedClip("Duration", coalesce: "duration") { $0.sourceEnd = $0.sourceStart + max(0.2, v) }
                                   }),
                                   range: 0.2...30, format: { String(format: "%.1fs", $0) })
                    } else {
                        let total = vm.media(clip.mediaID)?.duration ?? clip.sourceEnd
                        EditSlider(vm: vm, title: "Start",
                                   value: Binding(get: { clip.sourceStart }, set: { v in
                                       vm.updateSelectedClip("Trim", coalesce: "trim-start") { $0.sourceStart = min(v, $0.sourceEnd - 0.1) }
                                   }),
                                   range: 0...max(total, 0.2), format: { TimeFormat.short($0) })
                        EditSlider(vm: vm, title: "End",
                                   value: Binding(get: { clip.sourceEnd }, set: { v in
                                       vm.updateSelectedClip("Trim", coalesce: "trim-end") { $0.sourceEnd = max(v, $0.sourceStart + 0.1) }
                                   }),
                                   range: 0...max(total, 0.2), format: { TimeFormat.short($0) })
                    }
                    Text("Clip length \(String(format: "%.1fs", clip.duration)). Tip: drag the white handles on the timeline to trim, and double-tap a clip to split it at the playhead.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal)
                Spacer()
            } else {
                EmptyPanelMessage(text: "Select a clip to trim it.")
            }
        }
    }
}

// MARK: - Transition

struct TransitionPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Transition") { vm.activePanel = nil }
            if let id = vm.transitionTargetClipID, let clip = vm.project.clip(id) {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(TransitionType.allCases) { type in
                            Button {
                                Haptics.tap()
                                vm.setTransition(clipID: id, type: type)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: type.icon).font(.system(size: 20))
                                    Text(type.title).font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 62)
                                .background(clip.transitionOut.type == type ? Theme.accent : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.white)
                        }
                    }
                    if clip.transitionOut.type != .cut {
                        EditSlider(vm: vm, title: "Duration",
                                   value: Binding(get: { clip.transitionOut.duration },
                                                  set: { vm.setTransition(clipID: id, type: clip.transitionOut.type, duration: $0) }),
                                   range: 0.1...2, format: { String(format: "%.1fs", $0) })
                    }
                    Button {
                        vm.applyTransitionToAll(from: id)
                    } label: {
                        Label("Apply to all cuts", systemImage: "square.stack.3d.down.right")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                Spacer()
            } else {
                EmptyPanelMessage(text: "Tap the square between two clips to add a transition.")
            }
        }
    }
}
