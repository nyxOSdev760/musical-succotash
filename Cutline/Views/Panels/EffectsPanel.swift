import SwiftUI

/// Preset looks + manual adjustments, shared by per-clip and whole-timeline filters.
struct FilterEditor: View {
    let vm: EditorViewModel
    @Binding var filter: FilterSettings
    var showAdjustments = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.allCases) { preset in
                        Button {
                            Haptics.tap()
                            filter.preset = preset
                            if filter.intensity < 0.05 { filter.intensity = 1 }
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(swatch(preset))
                                    .frame(width: 58, height: 58)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(filter.preset == preset ? Theme.accent : Color.clear, lineWidth: 3))
                                Text(preset.title).font(.caption2.weight(.semibold))
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(preset.title) filter")
                    }
                }
            }
            if filter.preset != .none {
                EditSlider(vm: vm, title: "Intensity", value: $filter.intensity, range: 0...1)
            }
            if showAdjustments {
                Text("Adjust").font(.subheadline.weight(.semibold))
                EditSlider(vm: vm, title: "Brightness", value: $filter.adjustments.brightness, range: -1...1, format: signed)
                EditSlider(vm: vm, title: "Contrast", value: $filter.adjustments.contrast, range: -1...1, format: signed)
                EditSlider(vm: vm, title: "Saturation", value: $filter.adjustments.saturation, range: -1...1, format: signed)
                EditSlider(vm: vm, title: "Warmth", value: $filter.adjustments.warmth, range: -1...1, format: signed)
                EditSlider(vm: vm, title: "Tint", value: $filter.adjustments.tint, range: -1...1, format: signed)
                EditSlider(vm: vm, title: "Sharpen", value: $filter.adjustments.sharpen, range: 0...1)
                EditSlider(vm: vm, title: "Vignette", value: $filter.adjustments.vignette, range: 0...1)
                EditSlider(vm: vm, title: "Grain", value: $filter.adjustments.grain, range: 0...1)
                EditSlider(vm: vm, title: "Blur", value: $filter.adjustments.blur, range: 0...1)
                if filter != FilterSettings() {
                    Button("Reset look") { filter = FilterSettings() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func signed(_ v: Double) -> String { String(format: "%+.0f", v * 100) }

    private func swatch(_ p: FilterPreset) -> LinearGradient {
        let colors: [Color]
        switch p {
        case .none: colors = [.gray, .white.opacity(0.7)]
        case .vivid: colors = [.pink, .orange]
        case .warm: colors = [.orange, .yellow]
        case .cool: colors = [.blue, .cyan]
        case .mono, .noir: colors = [.black, .white]
        case .fade: colors = [.gray.opacity(0.6), .white.opacity(0.6)]
        case .chrome: colors = [.red, .blue]
        case .instant: colors = [.yellow.opacity(0.7), .brown]
        case .process: colors = [.teal, .purple]
        case .transfer: colors = [.orange.opacity(0.7), .indigo]
        case .sepia: colors = [.brown, .orange.opacity(0.6)]
        case .cinematic: colors = [.teal, .orange]
        case .vintage: colors = [.brown.opacity(0.8), .yellow.opacity(0.5)]
        case .dramatic: colors = [.black, .gray]
        case .film: colors = [.gray, .orange.opacity(0.5)]
        case .pastel: colors = [.pink.opacity(0.5), .mint.opacity(0.6)]
        case .teal: colors = [.teal, .cyan]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct GlobalFiltersPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Filters · Whole video") { vm.activePanel = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Applies to everything. To filter one clip, select it and tap Effects.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    FilterEditor(vm: vm, filter: vm.projectBinding(\.globalFilter, name: "Filter"))
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
    }
}

struct EffectsPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Effects") { vm.activePanel = nil }
            if let clip = vm.selectedClip {
                Picker("", selection: $tab) {
                    Text("Looks").tag(0)
                    Text("Keying").tag(1)
                    Text("Tools").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case 0:
                            FilterEditor(vm: vm, filter: vm.clipBinding(\.filter, default: FilterSettings(), name: "Filter"))
                            Button {
                                vm.applyFilterToAllClips()
                            } label: {
                                Label("Apply this look to all clips", systemImage: "square.stack.3d.up")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        case 1:
                            keying(clip)
                        default:
                            tools(clip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            } else {
                EmptyPanelMessage(text: "Select a clip to add effects.")
            }
        }
    }

    @ViewBuilder
    private func keying(_ clip: Clip) -> some View {
        Toggle(isOn: vm.clipBinding(\.effects.removeBackground, default: false, name: "Remove Background")) {
            Label("Remove background (people)", systemImage: "person.crop.rectangle")
        }
        Text("Keeps people and removes everything behind them using on-device Vision.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
        Divider()
        Toggle(isOn: vm.clipBinding(\.effects.chromaKey.enabled, default: false, name: "Green Screen")) {
            Label("Green screen (chroma key)", systemImage: "drop.halffull")
        }
        if clip.effects.chromaKey.enabled {
            HStack {
                ChipButton(title: "Green", isSelected: clip.effects.chromaKey.color == .green) {
                    vm.updateSelectedClip("Key Color") { $0.effects.chromaKey.color = .green }
                }
                ChipButton(title: "Blue", isSelected: clip.effects.chromaKey.color == RGBAColor(r: 0, g: 0, b: 1)) {
                    vm.updateSelectedClip("Key Color") { $0.effects.chromaKey.color = RGBAColor(r: 0, g: 0, b: 1) }
                }
                Spacer()
                ColorPicker("Custom", selection: Binding(
                    get: { clip.effects.chromaKey.color.color },
                    set: { c in vm.updateSelectedClip("Key Color", coalesce: "keycolor") { $0.effects.chromaKey.color = RGBAColor(c) } }
                ), supportsOpacity: false)
                .fixedSize()
            }
            EditSlider(vm: vm, title: "Tolerance", value: vm.clipBinding(\.effects.chromaKey.tolerance, default: 0.35, name: "Tolerance"), range: 0...1)
            EditSlider(vm: vm, title: "Edge softness", value: vm.clipBinding(\.effects.chromaKey.softness, default: 0.1, name: "Softness"), range: 0...1)
            Text("Tip: put this clip on the overlay track (Overlay › Video) to key it over another video.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private func tools(_ clip: Clip) -> some View {
        if !clip.isImage {
            Button {
                vm.stabilizeSelected()
            } label: {
                Label(clip.effects.stabilize ? "Stabilized — tap to turn off" : "Stabilize shaky footage",
                      systemImage: "hand.raised.slash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(clip.effects.stabilize ? Theme.accent : .white)
            Button {
                vm.toggleDenoise()
            } label: {
                Label(clip.denoise ? "Noise reduction on" : "Reduce background noise", systemImage: "waveform.badge.minus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(clip.denoise ? Theme.accent : .white)
        }
        HStack {
            Button {
                vm.copyEffects()
            } label: {
                Label("Copy effects", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            Button {
                vm.pasteEffects()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(vm.copiedEffects == nil)
        }
        Text("Copy & paste carries the look, keying, speed, volume and animations to another clip.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
    }
}
