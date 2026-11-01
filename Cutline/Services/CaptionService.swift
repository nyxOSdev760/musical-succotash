import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text with word-level timing.
enum CaptionService {
    /// Languages that can be transcribed without a network connection on this device.
    static func onDeviceLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { $0.identifier < $1.identifier }
    }

    static func defaultLocale() -> Locale {
        let current = Locale.current
        let available = onDeviceLocales()
        if available.contains(where: { $0.identifier == current.identifier }) { return current }
        if let lang = current.language.languageCode?.identifier,
           let match = available.first(where: { $0.language.languageCode?.identifier == lang }) {
            return match
        }
        return available.first ?? Locale(identifier: "en-US")
    }

    static func transcribe(audioURL: URL, locale: Locale) async throws -> [CaptionWord] {
        guard await Permissions.speech() else { throw AppError.permissionDenied(.speech) }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppError.speechUnavailable("Speech recognition isn't available for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppError.speechUnavailable("On-device captions aren't available for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) on this device.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let box = ResumeOnce()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CaptionWord], Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map {
                            CaptionWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + max($0.duration, 0.05))
                        }
                        if box.claim() { continuation.resume(returning: words) }
                    } else if let error {
                        let ns = error as NSError
                        // 1110 = no speech detected
                        if ns.code == 1110 || ns.code == 203 {
                            if box.claim() { continuation.resume(returning: []) }
                        } else if box.claim() {
                            continuation.resume(throwing: AppError.speechUnavailable("Couldn't transcribe the audio: \(error.localizedDescription)"))
                        }
                    }
                }
                box.task = task
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Groups words into readable caption lines.
    static func segments(from words: [CaptionWord], maxWords: Int = 5, maxDuration: Double = 2.6) -> [CaptionSegment] {
        var result: [CaptionSegment] = []
        var current: [CaptionWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            result.append(CaptionSegment(start: first.start, end: last.end, words: current))
            current.removeAll()
        }
        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let first = current.first {
                let gap = word.start - (current.last?.end ?? word.start)
                if current.count >= maxWords || word.end - first.start > maxDuration || gap > 0.8 {
                    flush()
                }
            }
            current.append(CaptionWord(text: trimmed, start: word.start, end: word.end))
            if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
                flush()
            }
        }
        flush()
        // Close tiny gaps so captions don't flicker between lines.
        for i in 0..<max(0, result.count - 1) where result[i + 1].start - result[i].end < 0.3 {
            result[i].end = result[i + 1].start
        }
        return result
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var task: SFSpeechRecognitionTask?

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
