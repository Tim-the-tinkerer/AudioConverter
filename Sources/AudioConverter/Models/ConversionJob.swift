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
    /// Integer bit depth from the audio stream. Nil when the probe could not tell.
    var bitsPerSample: Int?
    /// True for floating-point PCM (`fltp`, `flt`, `dbl`).
    var floatingPoint: Bool
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
        if floatingPoint {
            if let bits = bitsPerSample, bits > 0 {
                parts.append("\(bits)-bit float")
            } else {
                parts.append("float")
            }
        } else if let bits = bitsPerSample, bits > 0 {
            parts.append("\(bits)-bit")
        }
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
    /// Folder for a CD rip. The format extension is added when conversion starts.
    var outputDirectoryOverride: URL?
    /// File name without an extension. Shown in the queue in place of the CD track's AIFF name.
    var outputBaseNameOverride: String?
    /// Tags written with `-metadata`, after any tags copied from the source.
    var metadataOverrides: [String: String] = [:]
    /// JPEG or PNG to embed when the destination format can hold a picture.
    var coverFileURL: URL?
    /// Audio CD tracks have no embedded picture. Skip the probe that would spin the disc to look.
    var skipSourceCoverScan = false
    /// When the table of contents already supplied a duration, don't open the disc again to probe it.
    var skipSourceProbe = false

    var fileName: String {
        if let base = outputBaseNameOverride, !base.isEmpty {
            return base
        }
        return sourceURL.lastPathComponent
    }

    /// Probe line for the queue. A looked-up cover is not a stream on the CD, so it is added here.
    var queueDetail: String {
        let base = probe?.summary ?? ""
        guard coverFileURL != nil, probe?.hasCoverArt != true else { return base }
        return base.isEmpty ? "Art" : base + " · Art"
    }

    init(sourceURL: URL) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.chapterTitle = ConversionSettings.defaultChapterTitle(from: sourceURL)
    }
}
