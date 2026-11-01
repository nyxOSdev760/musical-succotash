import SwiftUI

/// Routes an `EditorPanel` to its view.
struct PanelHost: View {
    @Bindable var vm: EditorViewModel
    let panel: EditorPanel

    var body: some View {
        Group {
            switch panel {
            case .audio: AudioPanel(vm: vm)
            case .overlay: OverlayPanel(vm: vm)
            case .captions: CaptionsPanel(vm: vm)
            case .filters: GlobalFiltersPanel(vm: vm)
            case .canvas: CanvasPanel(vm: vm)
            case .speed: SpeedPanel(vm: vm)
            case .volume: VolumePanel(vm: vm)
            case .crop: CropPanel(vm: vm)
            case .animate: AnimatePanel(vm: vm)
            case .effects: EffectsPanel(vm: vm)
            case .trim: TrimPanel(vm: vm)
            case .text: TextPanel(vm: vm)
            case .transition: TransitionPanel(vm: vm)
            case .overlayStyle: OverlayStylePanel(vm: vm)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// Binding helpers that route every change through the undoable edit pipeline.
extension EditorViewModel {
    func clipBinding<T>(_ keyPath: WritableKeyPath<Clip, T>, default value: T, name: String) -> Binding<T> {
        Binding(
            get: { self.selectedClip?[keyPath: keyPath] ?? value },
            set: { newValue in self.updateSelectedClip(name, coalesce: name) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func textBinding<T>(_ keyPath: WritableKeyPath<TextItem, T>, default value: T, name: String) -> Binding<T> {
        Binding(
            get: { self.selectedText?[keyPath: keyPath] ?? value },
            set: { newValue in
                guard let id = self.selectedText?.id else { return }
                self.updateText(id, name, coalesce: name) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    func overlayBinding<T>(_ keyPath: WritableKeyPath<OverlayItem, T>, default value: T, name: String) -> Binding<T> {
        Binding(
            get: { self.selectedOverlay?[keyPath: keyPath] ?? value },
            set: { newValue in
                guard let id = self.selectedOverlay?.id else { return }
                self.updateOverlay(id, name, coalesce: name) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    func audioBinding<T>(_ keyPath: WritableKeyPath<AudioClip, T>, default value: T, name: String) -> Binding<T> {
        Binding(
            get: { self.selectedAudio?[keyPath: keyPath] ?? value },
            set: { newValue in
                guard let id = self.selectedAudio?.id else { return }
                self.updateAudio(id, name, coalesce: name) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    func projectBinding<T>(_ keyPath: WritableKeyPath<Project, T>, name: String) -> Binding<T> {
        Binding(
            get: { self.project[keyPath: keyPath] },
            set: { newValue in self.perform(name, coalesce: name) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Binding for one component of the selected item's transform at the playhead.
    func transformBinding(_ keyPath: WritableKeyPath<Transform2D, Double>, name: String) -> Binding<Double> {
        Binding(
            get: { self.selectedResolvedTransform?[keyPath: keyPath] ?? Transform2D()[keyPath: keyPath] },
            set: { newValue in self.editTransform(name, coalesce: name) { $0[keyPath: keyPath] = newValue } }
        )
    }
}

struct EmptyPanelMessage: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}
