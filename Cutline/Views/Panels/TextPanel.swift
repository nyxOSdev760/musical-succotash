import SwiftUI
import UIKit
import CoreText

struct TextPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var tab = 0
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Text") {
                editing = false
                vm.activePanel = nil
            }
            if let item = vm.selectedText {
                TextField("Type something", text: Binding(
                    get: { item.text },
                    set: { newText in vm.updateText(item.id, "Edit Text", coalesce: "text") { $0.text = newText } }
                ), axis: .vertical)
                .lineLimit(1...4)
                .font(.title3.weight(.semibold))
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .focused($editing)
                .padding(.horizontal)
                .onAppear {
                    if item.text == "Your text" { editing = true }
                }

                Picker("", selection: $tab) {
                    Text("Font").tag(0)
                    Text("Style").tag(1)
                    Text("Background").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case 0: fontTab(item)
                        case 1: styleTab(item)
                        default: boxTab(item)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            } else {
                EmptyPanelMessage(text: "Select a text item, or tap Text to add one.")
            }
        }
    }

    @ViewBuilder
    private func fontTab(_ item: TextItem) -> some View {
        EditSlider(vm: vm, title: "Size", value: vm.textBinding(\.fontSize, default: 72, name: "Text Size"), range: 20...240,
                   format: { String(format: "%.0f", $0) })
        HStack(spacing: 10) {
            toggleChip("Bold", "bold", item.bold) { vm.updateText(item.id, "Bold") { $0.bold.toggle() } }
            toggleChip("Italic", "italic", item.italic) { vm.updateText(item.id, "Italic") { $0.italic.toggle() } }
            Spacer()
            ForEach(TextAlign.allCases) { a in
                Button {
                    Haptics.tap()
                    vm.updateText(item.id, "Alignment") { $0.alignment = a }
                } label: {
                    Image(systemName: a.icon)
                        .frame(width: 40, height: 40)
                        .background(item.alignment == a ? Theme.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Align \(a.rawValue)")
            }
        }
        FontPickerList(selected: item.fontFamily, sample: item.text) { family in
            vm.updateText(item.id, "Font") { $0.fontFamily = family }
        }
        .frame(height: 260)
    }

    @ViewBuilder
    private func styleTab(_ item: TextItem) -> some View {
        ColorRow(title: "Color", color: vm.textBinding(\.color, default: .white, name: "Text Color"))
        EditSlider(vm: vm, title: "Outline", value: vm.textBinding(\.outlineWidth, default: 0, name: "Outline"), range: 0...10,
                   format: { String(format: "%.0f", $0) })
        if item.outlineWidth > 0 {
            ColorRow(title: "Outline color", color: vm.textBinding(\.outlineColor, default: .black, name: "Outline Color"))
        }
        Toggle("Shadow", isOn: vm.textBinding(\.shadow, default: true, name: "Shadow"))
        if item.shadow {
            ColorRow(title: "Shadow color", color: vm.textBinding(\.shadowColor, default: .black, name: "Shadow Color"), supportsOpacity: true)
        }
        EditSlider(vm: vm, title: "Opacity", value: vm.transformBinding(\.opacity, name: "Opacity"), range: 0...1)
        EditSlider(vm: vm, title: "Duration", value: vm.textBinding(\.duration, default: 3, name: "Text Duration"), range: 0.3...30,
                   format: { String(format: "%.1fs", $0) })
    }

    @ViewBuilder
    private func boxTab(_ item: TextItem) -> some View {
        Toggle("Background box", isOn: vm.textBinding(\.backgroundBox, default: false, name: "Text Box"))
        if item.backgroundBox {
            ColorRow(title: "Box color", color: vm.textBinding(\.boxColor, default: .black, name: "Box Color"), supportsOpacity: true)
        }
        Text("Drag the text in the preview to move it. Pinch to resize, twist to rotate.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
    }

    private func toggleChip(_ title: String, _ icon: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .frame(width: 40, height: 40)
                .background(on ? Theme.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }
}

/// Searchable list of system font families, each previewed in its own face.
struct FontPickerList: View {
    let selected: String
    let sample: String
    let onSelect: (String) -> Void
    @State private var query = ""

    private var families: [String] {
        let all = FontResolver.families
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("Search fonts", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(families, id: \.self) { family in
                        Button {
                            Haptics.tap()
                            onSelect(family)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preview)
                                        .font(Font(FontResolver.font(family: family, size: 20, bold: false, italic: false) as CTFont))
                                        .lineLimit(1)
                                    Text(family == "System" ? "System (San Francisco)" : family)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                if family == selected {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.white)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
    }

    private var preview: String {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Your text" ? "The quick brown fox" : String(trimmed.prefix(28))
    }
}
