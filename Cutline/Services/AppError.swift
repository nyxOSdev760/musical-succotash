import Foundation
import UIKit

enum PermissionKind: String {
    case microphone = "Microphone"
    case speech = "Speech Recognition"
    case photos = "Photos"
}

enum AppError: LocalizedError {
    case unsupportedFormat(String)
    case lowStorage(needed: Int64, available: Int64)
    case missingMedia(String)
    case permissionDenied(PermissionKind)
    case importFailed(String)
    case exportFailed(String)
    case speechUnavailable(String)
    case corruptedProject
    case processingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            return "“\(name)” isn't a supported video, photo or audio format."
        case .lowStorage(let needed, let available):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "Not enough storage. This needs about \(f.string(fromByteCount: needed)) but only \(f.string(fromByteCount: max(available, 0))) is free."
        case .missingMedia(let name):
            return "The media file “\(name)” can't be found."
        case .permissionDenied(let kind):
            return "Cutline doesn't have access to \(kind.rawValue)."
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .speechUnavailable(let reason):
            return reason
        case .corruptedProject:
            return "This project file is damaged and couldn't be opened."
        case .processingFailed(let reason):
            return reason
        case .cancelled:
            return "Cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat:
            return "Try a different file, or convert it to MP4, MOV, JPEG, PNG, HEIC, M4A, MP3 or WAV."
        case .lowStorage:
            return "Free up space in Settings › General › iPhone Storage, then try again."
        case .missingMedia:
            return "Re-import the media or delete the clip."
        case .permissionDenied:
            return "You can turn access on in Settings."
        case .speechUnavailable:
            return "Captions are created on your device. Download the language in Settings › General › Keyboard › Dictation, then try again."
        case .corruptedProject:
            return "A backup copy was not available. You can delete this project."
        default:
            return nil
        }
    }

    var opensSettings: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var showsSettings = false

    init(title: String = "Something went wrong", message: String, showsSettings: Bool = false) {
        self.title = title
        self.message = message
        self.showsSettings = showsSettings
    }

    init(error: Error) {
        if let app = error as? AppError {
            title = "Can't complete that"
            message = [app.errorDescription, app.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
            showsSettings = app.opensSettings
        } else {
            title = "Something went wrong"
            message = error.localizedDescription
        }
    }
}

enum Haptics {
    static func snap() {
        let g = UISelectionFeedbackGenerator()
        g.selectionChanged()
    }

    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    static func action() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
    }

    static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.warning)
    }
}

enum StorageGuard {
    static func availableBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        return Int64.max
    }

    /// Throws `lowStorage` unless `bytes` plus a 150 MB safety margin is available.
    static func ensure(_ bytes: Int64) throws {
        let available = availableBytes()
        let margin: Int64 = 150 * 1024 * 1024
        if available < bytes + margin {
            throw AppError.lowStorage(needed: bytes + margin, available: available)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
