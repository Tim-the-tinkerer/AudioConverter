import Foundation

enum AudioProbeError: LocalizedError {
    case ffprobeMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ffprobeMissing: return "ffprobe not found. Rebuild the app to embed FFmpeg."
        case .failed(let s): return s
        }
    }
}

enum AudioProbe {
    /// Probe a media file with ffprobe JSON output (format, streams, chapters, cover).
    static func probe(url: URL) throws -> AudioProbeInfo {
        guard let ffprobe = FFmpegLocator.ffprobeURL else {
            throw AudioProbeError.ffprobeMissing
        }

        // Do not use -select_streams so video/attached_pic streams are visible.
        let args = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-show_chapters",
            url.path
        ]

        // Network volumes (e.g. Synology Drive) can be slow — allow a longer probe budget.
        let result = FFmpegLocator.run(executable: ffprobe, arguments: args, timeout: 120)
        guard result.exitCode == 0 else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioProbeError.failed(msg.isEmpty ? "Unable to read file" : msg)
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw AudioProbeError.failed("Invalid probe output")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioProbeError.failed("Invalid probe JSON")
        }

        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) ?? [:]

        let formatName = (format["format_long_name"] as? String)
            ?? (format["format_name"] as? String)
            ?? "Unknown"

        var duration: Double?
        if let ds = format["duration"] as? String { duration = Double(ds) }
        else if let dn = format["duration"] as? Double { duration = dn }
        else if let ds = audio["duration"] as? String { duration = Double(ds) }

        var bitrate: Int?
        if let bs = format["bit_rate"] as? String { bitrate = Int(bs) }
        else if let bn = format["bit_rate"] as? Int { bitrate = bn }
        else if let bs = audio["bit_rate"] as? String { bitrate = Int(bs) }

        var sampleRate: Int?
        if let s = audio["sample_rate"] as? String { sampleRate = Int(s) }
        else if let n = audio["sample_rate"] as? Int { sampleRate = n }

        var channels: Int?
        if let n = audio["channels"] as? Int { channels = n }
        else if let s = audio["channels"] as? String { channels = Int(s) }

        let codec = audio["codec_name"] as? String

        var tags: [String: String] = [:]
        if let formatTags = format["tags"] as? [String: Any] {
            for (k, v) in formatTags {
                tags[k.lowercased()] = "\(v)"
            }
        }
        if let streamTags = audio["tags"] as? [String: Any] {
            for (k, v) in streamTags where tags[k.lowercased()] == nil {
                tags[k.lowercased()] = "\(v)"
            }
        }

        var chapters: [ChapterMarker] = []
        if let rawChapters = json["chapters"] as? [[String: Any]] {
            for ch in rawChapters {
                let start = doubleValue(ch["start_time"]) ?? 0
                let end = doubleValue(ch["end_time"])
                var title = "Chapter"
                if let tags = ch["tags"] as? [String: Any] {
                    if let t = tags["title"] as? String { title = t }
                    else if let t = tags["TITLE"] as? String { title = t }
                }
                chapters.append(ChapterMarker(startSeconds: start, endSeconds: end, title: title))
            }
            chapters.sort { $0.startSeconds < $1.startSeconds }
        }

        // Prefer streams marked as attached pictures (album art), not full movie video.
        var coverStreamIndex: Int?
        for stream in streams {
            guard (stream["codec_type"] as? String) == "video" else { continue }
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            let attached: Bool = {
                if let n = disposition["attached_pic"] as? Int { return n == 1 }
                if let n = disposition["attached_pic"] as? Bool { return n }
                if let s = disposition["attached_pic"] as? String { return s == "1" }
                return false
            }()
            if attached {
                coverStreamIndex = stream["index"] as? Int
                break
            }
        }

        return AudioProbeInfo(
            formatName: formatName,
            durationSeconds: duration,
            bitrate: bitrate,
            sampleRate: sampleRate,
            channels: channels,
            codecName: codec,
            tags: tags,
            chapters: chapters,
            coverStreamIndex: coverStreamIndex
        )
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let s = any as? String { return Double(s) }
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
