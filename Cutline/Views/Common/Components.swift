import SwiftUI
import UIKit
import AVFoundation

enum Theme {
    static let accent = Color(red: 1, green: 0.32, blue: 0.36)
    static let panel = Color(white: 0.11)
    static let card = Color(white: 0.15)
    static let secondaryText = Color.white.opacity(0.6)
}

/// Large icon + label button used in the editor's bottom toolbar.
struct ToolButton: View {
    let title: String
    let icon: String
    var tint: Color = .white
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Theme.accent : tint)
            .frame(width: 66, height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Chip used for presets (speeds, filters, styles).
struct ChipButton: View {
    let title: String
    var icon: String?
    var isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Labeled slider row with a value readout.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0 * 100) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .tint(Theme.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Header used at the top of every editor panel.
struct PanelHeader: View {
    let title: String
    var trailing: AnyView?
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { trailing }
            Button("Done") {
                Haptics.tap()
                onDone()
            }
            .font(.headline)
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
}

/// Shows an AVPlayer through an AVPlayerLayer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// UIKit share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct BusyOverlay: View {
    let state: BusyState
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                if let p = state.progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 180)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
                Text(state.message).font(.headline)
                if state.cancellable {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .transition(.opacity)
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Small color row with presets and a full ColorPicker.
struct ColorRow: View {
    let title: String
    @Binding var color: RGBAColor
    var supportsOpacity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ColorPicker("", selection: Binding(get: { color.color }, set: { color = RGBAColor($0) }),
                                supportsOpacity: supportsOpacity)
                        .labelsHidden()
                        .frame(width: 34, height: 34)
                    ForEach(RGBAColor.palette, id: \.self) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.white.opacity(sameColor(c) ? 1 : 0.25), lineWidth: sameColor(c) ? 3 : 1))
                            .onTapGesture {
                                Haptics.tap()
                                color = RGBAColor(r: c.r, g: c.g, b: c.b, a: supportsOpacity ? color.a : 1)
                            }
                            .accessibilityLabel("Color")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func sameColor(_ c: RGBAColor) -> Bool {
        abs(c.r - color.r) < 0.01 && abs(c.g - color.g) < 0.01 && abs(c.b - color.b) < 0.01
    }
}
