import SwiftUI

/// Bottom toolbar whose tools change with the timeline selection.
struct ContextToolbar: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                if vm.selection != nil {
                    Button {
                        vm.select(nil)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 60)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Back to main tools")
                    Divider().frame(height: 36).overlay(Color.white.opacity(0.15))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        tools
                    }
                    .padding(.horizontal, 6)
                }
            }
            .frame(height: 70)
        }
        .background(Color(white: 0.05))
        .animation(.easeInOut(duration: 0.18), value: vm.selection)
    }

    @ViewBuilder
    private var tools: some View {
        switch vm.selection {
        case nil:
            ToolButton(title: "Add Media", icon: "photo.on.rectangle.angled") { vm.presentPicker(.mainTrack) }
            ToolButton(title: "Text", icon: "textformat") { vm.addText() }
            ToolButton(title: "Audio", icon: "music.note") { vm.activePanel = .audio }
            ToolButton(title: "Overlay", icon: "square.on.square") { vm.activePanel = .overlay }
            ToolButton(title: "Captions", icon: "captions.bubble") { vm.activePanel = .captions }
            ToolButton(title: "Filters", icon: "camera.filters") { vm.activePanel = .filters }
            ToolButton(title: "Canvas", icon: "aspectratio") { vm.activePanel = .canvas }
            ToolButton(title: "Export", icon: "square.and.arrow.up", tint: Theme.accent, isEnabled: vm.project.duration > 0.05) {
                vm.playback.pause()
                vm.showExport = true
            }
        case .some(.clip), .some(.overlayClip):
            clipTools
        case .some(.text):
            ToolButton(title: "Edit", icon: "character.cursor.ibeam") { vm.activePanel = .text }
            ToolButton(title: "Animate", icon: "sparkles") { vm.activePanel = .animate }
            ToolButton(title: "Split", icon: "scissors") { vm.splitAtPlayhead() }
            ToolButton(title: "Duplicate", icon: "plus.square.on.square") { vm.duplicateSelection() }
            ToolButton(title: "Delete", icon: "trash", tint: .red) { vm.deleteSelection() }
        case .some(.overlay):
            ToolButton(title: "Style", icon: "paintpalette") { vm.activePanel = .overlayStyle }
            ToolButton(title: "Animate", icon: "sparkles") { vm.activePanel = .animate }
            ToolButton(title: "Split", icon: "scissors") { vm.splitAtPlayhead() }
            ToolButton(title: "Duplicate", icon: "plus.square.on.square") { vm.duplicateSelection() }
            ToolButton(title: "Delete", icon: "trash", tint: .red) { vm.deleteSelection() }
        case .some(.audio):
            ToolButton(title: "Volume", icon: "speaker.wave.2") { vm.activePanel = .volume }
            ToolButton(title: "Split", icon: "scissors") { vm.splitAtPlayhead() }
            ToolButton(title: "Beat Cuts", icon: "metronome") { vm.cutToBeats() }
            ToolButton(title: "Denoise", icon: "waveform.badge.minus", isActive: vm.selectedAudio?.denoise == true) { vm.toggleDenoise() }
            ToolButton(title: "Duplicate", icon: "plus.square.on.square") { vm.duplicateSelection() }
            ToolButton(title: "Delete", icon: "trash", tint: .red) { vm.deleteSelection() }
        case .some(.caption):
            ToolButton(title: "Edit", icon: "character.cursor.ibeam") { vm.activePanel = .captions }
            ToolButton(title: "Delete", icon: "trash", tint: .red) { vm.deleteSelection() }
            ToolButton(title: "Delete All", icon: "trash.slash", tint: .red) { vm.removeAllCaptions() }
        }
    }

    @ViewBuilder
    private var clipTools: some View {
        let clip = vm.selectedClip
        let isVideo = clip?.isImage == false
        ToolButton(title: "Split", icon: "scissors") { vm.splitAtPlayhead() }
        ToolButton(title: "Trim", icon: "timeline.selection") { vm.activePanel = .trim }
        ToolButton(title: "Speed", icon: "speedometer", isEnabled: isVideo) { vm.activePanel = .speed }
        ToolButton(title: "Volume", icon: "speaker.wave.2", isEnabled: isVideo) { vm.activePanel = .volume }
        ToolButton(title: "Crop", icon: "crop.rotate") { vm.activePanel = .crop }
        ToolButton(title: "Animate", icon: "sparkles") { vm.activePanel = .animate }
        ToolButton(title: "Effects", icon: "wand.and.stars") { vm.activePanel = .effects }
        ToolButton(title: "Duplicate", icon: "plus.square.on.square") { vm.duplicateSelection() }
        ToolButton(title: "Delete", icon: "trash", tint: .red) { vm.deleteSelection() }
        ToolButton(title: "Freeze", icon: "snowflake", isEnabled: isVideo) { vm.freezeFrame() }
        ToolButton(title: "Reverse", icon: "arrow.uturn.backward", isActive: clip?.reversed == true, isEnabled: isVideo) { vm.toggleReverse() }
        ToolButton(title: "Detach", icon: "rectangle.and.arrow.up.right.and.arrow.down.left", isEnabled: isVideo && clip?.audioDetached == false) { vm.detachAudio() }
        ToolButton(title: "Copy FX", icon: "doc.on.doc") { vm.copyEffects() }
        ToolButton(title: "Paste FX", icon: "doc.on.clipboard", isEnabled: vm.copiedEffects != nil) { vm.pasteEffects() }
    }
}
