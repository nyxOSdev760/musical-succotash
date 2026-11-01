import Foundation
import UIKit

/// Debounced, ordered, crash-safe project saving.
@MainActor
final class AutosaveService {
    private var pending: Task<Void, Never>?
    private let queue = DispatchQueue(label: "app.cutline.autosave", qos: .utility)
    private let paths: ProjectPaths
    private let provider: () -> Project
    var onSaved: (() -> Void)?

    init(paths: ProjectPaths, provider: @escaping () -> Project) {
        self.paths = paths
        self.provider = provider
    }

    /// Saves after `delay` seconds of inactivity (always under one second).
    func schedule(delay: Double = 0.6) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pending?.cancel()
        pending = nil
        var project = provider()
        project.modifiedAt = Date()
        guard let data = try? ProjectFileIO.encode(project) else { return }
        let paths = self.paths
        queue.async { [weak self] in
            try? ProjectFileIO.write(data, to: paths)
            Task { @MainActor in self?.onSaved?() }
        }
    }

    /// Writes synchronously; used when the app is backgrounding or the editor closes.
    func flush() {
        pending?.cancel()
        pending = nil
        var project = provider()
        project.modifiedAt = Date()
        guard let data = try? ProjectFileIO.encode(project) else { return }
        let paths = self.paths
        let app = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "Cutline autosave") {
            app.endBackgroundTask(taskID)
        }
        queue.sync {
            try? ProjectFileIO.write(data, to: paths)
        }
        if taskID != .invalid { app.endBackgroundTask(taskID) }
    }
}
