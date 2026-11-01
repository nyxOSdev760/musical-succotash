import SwiftUI

// MARK: - Audio

struct AudioPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Audio") {
                if vm.recorder.isRecording { vm.stopVoiceover() }
                vm.activePanel = nil
            }
            VStack(spacing: 12) {
                if vm.recorder.isRecording {
                    recordingView
                } else {
                    bigButton("Music from Files", subtitle: "MP3, M4A, WAV, AIFF — beats are detected automatically",
                              icon: "music.note.list") {
                        vm.activePanel = nil
                        vm.showMusicImporter = true
                    }
                    bigButton("Record Voiceover", subtitle: "Records from the playhead while your video plays",
                              icon: "mic.fill") {
                        vm.toggleVoiceover()
                    }
                }
            }
            .padding(.horizontal)
            Spacer()
        }
    }

    private var recordingView: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 12, height: 12)
                Text("Recording  \(TimeFormat.short(vm.recorder.elapsed))")
                    .font(.headline.monospacedDigit())
            }
            GeometryReader { geo in
                Capsule().fill(Color.white.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.red).frame(width: geo.size.width * CGFloat(vm.recorder.level))
                    }
            }
            .frame(height: 8)
            Button {
                vm.stopVoiceover()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func bigButton(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .frame(width: 48, height: 48)
                    .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
            }
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
    }
}

// MARK: - Overlay

struct OverlayPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var tab = 0
    @State private var shapeColor: RGBAColor = .accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Overlay") { vm.activePanel = nil }
            Picker("", selection: $tab) {
                Text("Stickers").tag(0)
                Text("Shapes").tag(1)
                Text("Photo / Video").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            ScrollView {
                switch tab {
                case 0:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(OverlayItem.stickerCatalog, id: \.self) { emoji in
                            Button {
                                vm.addSticker(emoji)
                                vm.activePanel = nil
                            } label: {
                                Text(emoji).font(.system(size: 34)).frame(width: 52, height: 52)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal)
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        ColorRow(title: "Color", color: $shapeColor)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                            ForEach(ShapeKind.allCases) { shape in
                                Button {
                                    vm.addShape(shape, color: shapeColor)
                                    vm.activePanel = nil
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: shape.icon).font(.system(size: 26)).foregroundStyle(shapeColor.color)
                                        Text(shape.title).font(.caption2)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(PressableStyle())
                                .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal)
                default:
                    VStack(spacing: 12) {
                        Button {
                            vm.activePanel = nil
                            vm.presentPicker(.overlay)
                        } label: {
                            Label("Choose photo or video", systemImage: "pip.enter")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        Text("Picture-in-picture is added at the playhead. Drag it in the preview, pinch to resize. Use Effects › Keying for green screen.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct OverlayStylePanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Style") { vm.activePanel = nil }
            if let item = vm.selectedOverlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if item.kind == .shape {
                            ColorRow(title: "Color", color: vm.overlayBinding(\.color, default: .accent, name: "Shape Color"))
                            Toggle("Filled", isOn: vm.overlayBinding(\.filled, default: true, name: "Fill"))
                        }
                        EditSlider(vm: vm, title: "Opacity", value: vm.transformBinding(\.opacity, name: "Opacity"), range: 0...1)
                        EditSlider(vm: vm, title: "Size", value: vm.transformBinding(\.scale, name: "Scale"), range: 0.1...4,
                                   format: { String(format: "%.0f%%", $0 * 100) })
                        EditSlider(vm: vm, title: "Rotation", value: vm.transformBinding(\.rotation, name: "Rotation"), range: -180...180,
                                   format: { String(format: "%.0f°", $0) })
                        EditSlider(vm: vm, title: "Duration", value: vm.overlayBinding(\.duration, default: 3, name: "Duration"), range: 0.3...30,
                                   format: { String(format: "%.1fs", $0) })
                    }
                    .padding(.horizontal)
                }
            } else {
                EmptyPanelMessage(text: "Select a sticker, shape or photo.")
            }
        }
    }
}

// MARK: - Captions

struct CaptionsPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var locale: Locale = CaptionService.defaultLocale()
    @State private var locales: [Locale] = []
    @State private var style: CaptionStyle = .boldCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Captions") { vm.activePanel = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if vm.project.captions.segments.isEmpty {
                        generator
                    } else {
                        editor
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .task {
            let found = await Task.detached { CaptionService.onDeviceLocales() }.value
            locales = found
            if !found.contains(where: { $0.identifier == locale.identifier }), let first = found.first {
                locale = first
            }
        }
    }

    private var stylePicker: some View {
        HStack {
            ForEach(CaptionStyle.allCases) { s in
                ChipButton(title: s.title, isSelected: (vm.project.captions.segments.isEmpty ? style : vm.project.captions.style) == s) {
                    if vm.project.captions.segments.isEmpty { style = s } else { vm.setCaptionStyle(s) }
                }
            }
        }
    }

    @ViewBuilder
    private var generator: some View {
        Text("Turn speech into captions with word-by-word timing. Runs fully on your device.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
        if !locales.isEmpty {
            Picker("Language", selection: Binding(get: { locale.identifier }, set: { locale = Locale(identifier: $0) })) {
                ForEach(locales, id: \.identifier) { l in
                    Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                }
            }
            .pickerStyle(.menu)
        }
        Text("Style").font(.subheadline.weight(.semibold))
        stylePicker
        Button {
            vm.activePanel = nil
            vm.generateCaptions(locale: locale, style: style)
        } label: {
            Label("Generate captions", systemImage: "captions.bubble.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var editor: some View {
        Text("Style").font(.subheadline.weight(.semibold))
        stylePicker
        EditSlider(vm: vm, title: "Position", value: vm.projectBinding(\.captions.verticalPosition, name: "Caption Position"),
                   range: 0.08...0.92, format: { String(format: "%.0f%%", $0 * 100) })
        EditSlider(vm: vm, title: "Size", value: vm.projectBinding(\.captions.fontScale, name: "Caption Size"),
                   range: 0.5...2, format: { String(format: "%.0f%%", $0 * 100) })
        ColorRow(title: "Text color", color: vm.projectBinding(\.captions.textColor, name: "Caption Color"))
        if vm.project.captions.style != .minimalBottom {
            ColorRow(title: "Highlight color", color: vm.projectBinding(\.captions.highlightColor, name: "Highlight Color"))
        }
        Text("Edit text").font(.subheadline.weight(.semibold))
        ForEach(vm.project.captions.segments) { segment in
            HStack(alignment: .top, spacing: 8) {
                Button {
                    vm.playback.scrub(to: segment.start + 0.01)
                    vm.select(.caption(segment.id))
                } label: {
                    Text(TimeFormat.short(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, alignment: .leading)
                        .padding(.top, 10)
                }
                TextField("Caption", text: Binding(get: { segment.text }, set: { vm.updateCaptionText(segment.id, text: $0) }), axis: .vertical)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        HStack {
            Button(role: .destructive) {
                vm.removeAllCaptions()
            } label: {
                Label("Remove all", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            Button {
                vm.activePanel = nil
                vm.generateCaptions(locale: locale, style: vm.project.captions.style)
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Canvas

struct CanvasPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Canvas") { vm.activePanel = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Format").font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        ForEach(AspectRatio.allCases) { a in
                            Button {
                                Haptics.tap()
                                vm.setCanvasAspect(a)
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(lineWidth: 2)
                                        .aspectRatio(a.ratio, contentMode: .fit)
                                        .frame(height: 30)
                                    Text(a.title).font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 66)
                                .background(vm.project.canvas.aspect == a ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.white)
                            .accessibilityLabel("\(a.title) \(a.subtitle)")
                        }
                    }
                    Text("Background").font(.subheadline.weight(.semibold))
                    HStack {
                        ForEach(BackgroundStyle.allCases) { b in
                            ChipButton(title: b.title, isSelected: vm.project.canvas.background == b) {
                                vm.perform("Background") { $0.canvas.background = b }
                            }
                        }
                    }
                    if vm.project.canvas.background == .blur {
                        EditSlider(vm: vm, title: "Blur", value: vm.projectBinding(\.canvas.blurAmount, name: "Blur"), range: 0...1)
                    } else if vm.project.canvas.background == .color {
                        ColorRow(title: "Color", color: vm.projectBinding(\.canvas.backgroundColor, name: "Background Color"))
                    }
                    Toggle(isOn: Binding(get: { vm.project.magnetic }, set: { vm.setMagnetic($0) })) {
                        VStack(alignment: .leading) {
                            Text("Magnetic timeline")
                            Text("Clips snap together and gaps close automatically").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Text("Per-clip Fit / Fill is under Crop when a clip is selected.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal)
            }
        }
    }
}
