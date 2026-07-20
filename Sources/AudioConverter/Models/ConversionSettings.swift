import Foundation

struct ConversionSettings: Equatable, Codable {
    var outputFormat: AudioOutputFormat = .mp3
    var bitrate: Int = 192
    var useVBR: Bool = false
    /// LAME-style 0 (best) … 9 (worst). Used for MP3/Vorbis when VBR is on.
    var vbrQuality: Int = 2
    /// LAME joint stereo for MP3 (libmp3lame `-joint_stereo`). Default on; useful with VBR.
    var mp3JointStereo: Bool = true
    var sampleRate: Int? = nil          // nil = keep source (per-file) or 44100 when combining
    var channels: Int? = nil            // nil = keep source; when combining defaults to stereo
    var pcmCodec: String = "pcm_s16le"  // for WAV/AIFF/CAF
    var flacCompression: Int = 5        // 0–12
    var copyMetadata: Bool = true
    var overwriteExisting: Bool = false
    /// When true, write next to the source file; otherwise use outputDirectory.
    var outputBesideSource: Bool = true
    var outputDirectoryPath: String? = nil

    // MARK: Combine queue (all formats)

    /// Join every file in the queue into one output (queue order).
    /// M4B also writes chapter markers; other formats produce a single continuous track.
    var combineQueue: Bool = false
    /// Copy chapter markers from a single source file (M4B, per-file only).
    var preserveChapters: Bool = true
    /// Title / book name used for combined output tags and default file name.
    var combinedTitle: String = ""
    var combinedAuthor: String = ""
    var combinedAlbum: String = ""
    /// Optional explicit filename (without path/extension).
    var combinedFileName: String = ""

    // Back-compat aliases used by existing M4B UI bindings
    var audiobookTitle: String {
        get { combinedTitle }
        set { combinedTitle = newValue }
    }
    var audiobookAuthor: String {
        get { combinedAuthor }
        set { combinedAuthor = newValue }
    }
    var audiobookAlbum: String {
        get { combinedAlbum }
        set { combinedAlbum = newValue }
    }
    var audiobookFileName: String {
        get { combinedFileName }
        set { combinedFileName = newValue }
    }
    var m4bCombineQueue: Bool {
        get { combineQueue }
        set { combineQueue = newValue }
    }

    static let commonBitrates = [64, 96, 128, 160, 192, 256, 320]
    static let commonSampleRates = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000]
    static let pcmCodecs: [(id: String, label: String)] = [
        ("pcm_s16le", "16-bit PCM"),
        ("pcm_s24le", "24-bit PCM"),
        ("pcm_s32le", "32-bit PCM"),
        ("pcm_f32le", "32-bit Float"),
        ("pcm_s16be", "16-bit PCM (BE)"),
    ]

    var outputDirectoryURL: URL? {
        guard let path = outputDirectoryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func outputURL(for source: URL) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let fileName = "\(baseName).\(outputFormat.fileExtension)"
        if outputBesideSource {
            return source.deletingLastPathComponent().appendingPathComponent(fileName)
        }
        if let dir = outputDirectoryURL {
            return dir.appendingPathComponent(fileName)
        }
        return source.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Destination for a multi-file combined output (any format).
    func combinedOutputURL(sources: [URL]) -> URL {
        let base: String = {
            let custom = combinedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                return (custom as NSString).deletingPathExtension
            }
            let title = combinedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return Self.sanitizedFileName(title)
            }
            if let first = sources.first {
                let stem = first.deletingPathExtension().lastPathComponent
                if outputFormat == .m4b {
                    return stem + " Audiobook"
                }
                return stem + " Combined"
            }
            return outputFormat == .m4b ? "Audiobook" : "Combined"
        }()

        let fileName = "\(base).\(outputFormat.fileExtension)"
        if !outputBesideSource, let dir = outputDirectoryURL {
            return dir.appendingPathComponent(fileName)
        }
        if let first = sources.first {
            return first.deletingLastPathComponent().appendingPathComponent(fileName)
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent(fileName)
    }

    /// Destination for a multi-file chaptered M4B (alias).
    func audiobookOutputURL(sources: [URL]) -> URL {
        combinedOutputURL(sources: sources)
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Combined" : cleaned
    }

    /// Default chapter title derived from a source file name.
    static func defaultChapterTitle(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        let patterns = [
            #"^\d{1,3}\s*[-._)]\s*"#,
            #"^(?i)(track|disc|cd|chapter|ch|pt|part)\s*\d{1,3}\s*[-.:)]\s*"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(name.startIndex..., in: name)
                name = regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}
