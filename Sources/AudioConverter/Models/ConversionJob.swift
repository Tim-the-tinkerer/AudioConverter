import Foundation

enum JobStatus: Equatable {
    case pending
    case probing
    case ready
    case converting
    case succeeded
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .probing: return "Reading…"
        case .ready: return "Ready"
        case .converting: return "Converting…"
        case .succeeded: return "Done"
        case .failed(let msg): return "Failed: \(msg)"
        case .cancelled: return "Cancelled"
        }
    }
}

struct ChapterMarker: Equatable, Identifiable {
    var id: String { "\(startSeconds)-\(title)" }
    var startSeconds: Double
    var endSeconds: Double?
    var title: String
}

struct AudioProbeInfo: Equatable {
    var formatName: String
    var durationSeconds: Double?
    var bitrate: Int?
    var sampleRate: Int?
    var channels: Int?
    var codecName: String?
    var tags: [String: String]
    var chapters: [ChapterMarker]
    /// Absolute stream index of an attached cover image, if any.
    var coverStreamIndex: Int?
    var hasCoverArt: Bool { coverStreamIndex != nil }

    var durationDisplay: String {
        guard let d = durationSeconds, d.isFinite, d >= 0 else { return "—" }
        let total = Int(d.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var summary: String {
        var parts: [String] = []
        if let codec = codecName { parts.append(codec.uppercased()) }
        if let sr = sampleRate { parts.append("\(sr) Hz") }
        if let ch = channels {
            parts.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch")
        }
        if let br = bitrate, br > 0 { parts.append("\(br / 1000) kbps") }
        if !chapters.isEmpty {
            parts.append("\(chapters.count) ch.")
        }
        if hasCoverArt {
            parts.append("Art")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class ConversionJob: Identifiable, ObservableObject {
    let id: UUID
    let sourceURL: URL
    @Published var status: JobStatus = .pending
    @Published var progress: Double = 0          // 0…1
    @Published var probe: AudioProbeInfo?
    @Published var outputURL: URL?
    @Published var logTail: String = ""
    /// Chapter title used when combining into a chaptered M4B (queue order).
    @Published var chapterTitle: String

    var fileName: String { sourceURL.lastPathComponent }

    init(sourceURL: URL) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.chapterTitle = ConversionSettings.defaultChapterTitle(from: sourceURL)
    }
}
