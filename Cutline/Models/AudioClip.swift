import Foundation

enum AudioKind: String, Codable, Hashable {
    case music, voiceover, extracted

    var icon: String {
        switch self {
        case .music: return "music.note"
        case .voiceover: return "mic.fill"
        case .extracted: return "waveform"
        }
    }
}

struct AudioClip: Codable, Identifiable, Hashable {
    var id = UUID()
    var mediaID: UUID
    var name: String
    var kind: AudioKind
    var timelineStart: Double
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    /// True when the audio comes from the reversed version of a video.
    var reversed = false
    var volume: Double = 1
    var muted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var denoise = false

    var sourceDuration: Double { max(sourceEnd - sourceStart, 0.01) }
    var duration: Double { sourceDuration / speed.clamped(0.1, 8) }
    var timelineEnd: Double { timelineStart + duration }

    func contains(_ time: Double) -> Bool { time >= timelineStart && time < timelineEnd }

    func sourceTime(atLocal local: Double) -> Double { sourceStart + local * speed.clamped(0.1, 8) }
}
