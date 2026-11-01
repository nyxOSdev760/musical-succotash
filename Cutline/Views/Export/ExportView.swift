import SwiftUI
import UIKit

@MainActor
@Observable
final class ExportViewModel {
    enum Phase: Equatable {
        case settings
        case exporting
        case done(URL)
        case failed(String)
    }

    var settings = ExportSettings()
    var phase: Phase = .settings
    var progress: Double = 0
    var shareURL: URL?
    var saving = false
    var savedMessage: String?
    var extraBusy: String?

    @ObservationIgnored private var service: ExportService?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func estimate(for project: Project) -> String {
        let bytes = settings.estimatedBytes(duration: project.duration, aspect: project.canvas.aspect)
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    func start(project: Project, paths: ProjectPaths) {
        let service = ExportService()
        self.service = service
        phase = .exporting
        progress = 0
        beginBackgroundTask()
        let settings = self.settings
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in
            do {
                let url = try await service.exportVideo(project: project, paths: paths, settings: settings) { value in
                    Task { @MainActor [weak self] in self?.progress = value }
                }
                self?.phase = .done(url)
                Haptics.success()
            } catch {
                if let app = error as? AppError, case .cancelled = app {
                    self?.phase = .settings
                } else {
                    self?.phase = .failed(AlertInfo(error: error).message)
                    Haptics.warning()
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            self?.endBackgroundTask()
        }
    }

    func cancel() {
        service?.cancel()
        task?.cancel()
    }

    private func beginBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Cutline export") { [weak self] in
            MainActor.assumeIsolated {
                self?.service?.cancel()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func saveToPhotos(_ url: URL) {
        saving = true
        Task { [weak self] in
            do {
                try await ExportService.saveToPhotos(url)
                self?.savedMessage = "Saved to Photos"
                Haptics.success()
            } catch {
                self?.savedMessage = AlertInfo(error: error).message
                Haptics.warning()
            }
            self?.saving = false
        }
    }

    func exportAudio(project: Project, paths: ProjectPaths) {
        extraBusy = "Exporting audio…"
        Task { [weak self] in
            do {
                let url = try await ExportService().exportAudio(project: project, paths: paths)
                self?.shareURL = url
            } catch {
                self?.savedMessage = AlertInfo(error: error).message
            }
            self?.extraBusy = nil
        }
    }

    func exportStill(project: Project, paths: ProjectPaths, time: Double, share: Bool) {
        extraBusy = "Rendering frame…"
        let resolution = settings.resolution
        Task { [weak self] in
            do {
                let url = try await ExportService().exportStill(project: project, paths: paths, at: time, resolution: resolution)
                if share {
                    self?.shareURL = url
                } else {
                    try await ExportService.saveToPhotos(url)
                    self?.savedMessage = "Frame saved to Photos"
                    Haptics.success()
                }
            } catch {
                self?.savedMessage = AlertInfo(error: error).message
            }
            self?.extraBusy = nil
        }
    }
}

struct ExportView: View {
    @Bindable var vm: EditorViewModel
    @State private var model = ExportViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch model.phase {
                case .settings:
                    settingsView
                case .exporting:
                    progressView
                case .done(let url):
                    doneView(url)
                case .failed(let message):
                    failedView(message)
                }
                if let busy = model.extraBusy {
                    BusyOverlay(state: BusyState(message: busy, progress: nil, cancellable: false)) {}
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.phase != .exporting {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { model.shareURL != nil }, set: { if !$0 { model.shareURL = nil } })) {
                if let url = model.shareURL {
                    ShareSheet(items: [url]).presentationDetents([.medium, .large])
                }
            }
            .alert(model.savedMessage ?? "", isPresented: Binding(get: { model.savedMessage != nil }, set: { if !$0 { model.savedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .interactiveDismissDisabled(model.phase == .exporting)
    }

    // MARK: Settings

    private var settingsView: some View {
        Form {
            Section {
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(ExportResolution.allCases) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.segmented)
                Picker("Frame rate", selection: $model.settings.frameRate) {
                    ForEach([24, 30, 60], id: \.self) { f in Text("\(f) fps").tag(f) }
                }
                .pickerStyle(.segmented)
                Picker("Format", selection: $model.settings.codec) {
                    ForEach(ExportCodec.allCases) { c in Text("MP4 · \(c.title)").tag(c) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text(qualityLabel).foregroundStyle(Theme.secondaryText)
                    }
                    Slider(value: $model.settings.quality, in: 0...1)
                }
            } header: {
                Text("Video")
            } footer: {
                let size = model.settings.renderSize(for: vm.project.canvas.aspect)
                Text("\(Int(size.width))×\(Int(size.height)) · \(TimeFormat.short(vm.project.duration)) · about \(model.estimate(for: vm.project)). No watermark.")
            }

            Section {
                Button {
                    Haptics.action()
                    vm.flushSave()
                    model.start(project: vm.project, paths: vm.paths)
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.up.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }

            Section("More") {
                Button {
                    model.exportAudio(project: vm.project, paths: vm.paths)
                } label: {
                    Label("Export audio only (M4A)", systemImage: "waveform")
                }
                Button {
                    model.exportStill(project: vm.project, paths: vm.paths, time: vm.currentTime, share: false)
                } label: {
                    Label("Save frame at playhead to Photos", systemImage: "photo")
                }
                Button {
                    model.exportStill(project: vm.project, paths: vm.paths, time: vm.currentTime, share: true)
                } label: {
                    Label("Share frame at playhead", systemImage: "square.and.arrow.up")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var qualityLabel: String {
        switch model.settings.quality {
        case ..<0.34: return "Smaller file"
        case ..<0.75: return "Recommended"
        default: return "Best"
        }
    }

    // MARK: Progress

    private var progressView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: model.progress)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
            }
            .frame(width: 170, height: 170)
            Text("Exporting your video…").font(.headline)
            Text("Keep Cutline open for the fastest export. If you switch apps, iOS gives it a little time to finish.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 30)
            Button("Cancel", role: .destructive) { model.cancel() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: Done

    private func doneView(_ url: URL) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Your video is ready").font(.title2.bold())
            Text(fileSize(url)).foregroundStyle(Theme.secondaryText)
            Button {
                model.saveToPhotos(url)
            } label: {
                Label(model.saving ? "Saving…" : "Save to Photos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.saving)
            Button {
                model.shareURL = url
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            Button("Done") { dismiss() }
                .padding(.top, 8)
        }
        .padding(30)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.yellow)
            Text("Export didn't finish").font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
            Button("Try again") { model.phase = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }

    private func fileSize(_ url: URL) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: StorageGuard.fileSize(url))
    }
}
