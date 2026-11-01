import SwiftUI

/// In/out animations plus transform keyframes (position, scale, rotation, opacity) with easing.
struct AnimatePanel: View {
    @Bindable var vm: EditorViewModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Animate") { vm.activePanel = nil }
            Picker("", selection: $tab) {
                Text("In & Out").tag(0)
                Text("Keyframes").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 { inOut } else { keyframes }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: In & Out

    @ViewBuilder
    private var inOut: some View {
        if let text = vm.selectedText {
            Text("In").font(.subheadline.weight(.semibold))
            textChips(selected: text.animationIn) { a in vm.updateText(text.id, "Text Animation") { $0.animationIn = a } }
            Text("Out").font(.subheadline.weight(.semibold))
            textChips(selected: text.animationOut) { a in vm.updateText(text.id, "Text Animation") { $0.animationOut = a } }
            EditSlider(vm: vm, title: "Animation length", value: vm.textBinding(\.animationDuration, default: 0.4, name: "Animation Length"),
                       range: 0.1...2, format: { String(format: "%.1fs", $0) })
        } else if let clip = vm.selectedClip {
            Text("In").font(.subheadline.weight(.semibold))
            motionChips(selected: clip.animationIn) { m in vm.updateSelectedClip("Animation") { $0.animationIn = m } }
            Text("Out").font(.subheadline.weight(.semibold))
            motionChips(selected: clip.animationOut) { m in vm.updateSelectedClip("Animation") { $0.animationOut = m } }
            EditSlider(vm: vm, title: "Animation length", value: vm.clipBinding(\.animationDuration, default: 0.5, name: "Animation Length"),
                       range: 0.1...3, format: { String(format: "%.1fs", $0) })
        } else if let overlay = vm.selectedOverlay {
            Text("In").font(.subheadline.weight(.semibold))
            motionChips(selected: overlay.animationIn) { m in vm.updateOverlay(overlay.id, "Animation") { $0.animationIn = m } }
            Text("Out").font(.subheadline.weight(.semibold))
            motionChips(selected: overlay.animationOut) { m in vm.updateOverlay(overlay.id, "Animation") { $0.animationOut = m } }
            EditSlider(vm: vm, title: "Animation length", value: vm.overlayBinding(\.animationDuration, default: 0.35, name: "Animation Length"),
                       range: 0.1...3, format: { String(format: "%.1fs", $0) })
        } else {
            EmptyPanelMessage(text: "Select a clip, sticker or text to animate it.")
        }
    }

    private func motionChips(selected: MotionPreset, onSelect: @escaping (MotionPreset) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(MotionPreset.allCases) { m in
                    ChipButton(title: m.title, icon: m.icon, isSelected: selected == m) { onSelect(m) }
                }
            }
        }
    }

    private func textChips(selected: TextAnimation, onSelect: @escaping (TextAnimation) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(TextAnimation.allCases) { a in
                    ChipButton(title: a.title, icon: a.icon, isSelected: selected == a) { onSelect(a) }
                }
            }
        }
    }

    // MARK: Keyframes

    @ViewBuilder
    private var keyframes: some View {
        if let visual = vm.selectedVisual {
            HStack(spacing: 10) {
                Button {
                    vm.toggleKeyframe()
                } label: {
                    Label(vm.hasKeyframeAtPlayhead ? "Remove keyframe" : "Add keyframe here",
                          systemImage: vm.hasKeyframeAtPlayhead ? "diamond.fill" : "diamond")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.hasKeyframeAtPlayhead ? .gray : Theme.accent)
                if !visual.keyframes.isEmpty {
                    Button(role: .destructive) {
                        vm.clearKeyframes()
                    } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Clear all keyframes")
                }
            }
            Text(visual.keyframes.isEmpty
                 ? "Set the look below, add a keyframe, move the playhead, then change it again. Cutline animates between keyframes."
                 : "\(visual.keyframes.count) keyframe\(visual.keyframes.count == 1 ? "" : "s"). Changes below edit the keyframe at the playhead.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)

            if !visual.keyframes.isEmpty {
                Text("Easing to next keyframe").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Easing.allCases) { e in
                            ChipButton(title: e.title, isSelected: currentEasing(visual) == e) { vm.setKeyframeEasing(e) }
                        }
                    }
                }
            }

            EditSlider(vm: vm, title: "Position X", value: vm.transformBinding(\.x, name: "Position"), range: -1...1,
                       format: { String(format: "%.0f", $0 * 100) })
            EditSlider(vm: vm, title: "Position Y", value: vm.transformBinding(\.y, name: "Position"), range: -1...1,
                       format: { String(format: "%.0f", $0 * 100) })
            EditSlider(vm: vm, title: "Scale", value: vm.transformBinding(\.scale, name: "Scale"), range: 0.05...4,
                       format: { String(format: "%.0f%%", $0 * 100) })
            EditSlider(vm: vm, title: "Rotation", value: vm.transformBinding(\.rotation, name: "Rotation"), range: -180...180,
                       format: { String(format: "%.0f°", $0) })
            EditSlider(vm: vm, title: "Opacity", value: vm.transformBinding(\.opacity, name: "Opacity"), range: 0...1)
            Button("Reset position, scale and rotation") { vm.resetTransform() }
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            EmptyPanelMessage(text: "Select a clip, sticker or text to add keyframes.")
        }
    }

    private func currentEasing(_ visual: EditorViewModel.VisualInfo) -> Easing? {
        let local = vm.currentTime - visual.start
        if let i = KeyframeMath.index(near: local, in: visual.keyframes) { return visual.keyframes[i].easing }
        return visual.keyframes.sorted { $0.time < $1.time }.last { $0.time <= local }?.easing
    }
}
