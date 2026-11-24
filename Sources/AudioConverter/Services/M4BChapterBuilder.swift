import Foundation

/// One chapter segment for a multi-file M4B.
struct M4BChapterSource: Sendable {
    var url: URL
    var title: String
    var durationSeconds: Double
    /// Probed integer depth. Nil when the file was not probed or the depth is unknown.
    var bitsPerSample: Int?
    var floatingPoint: Bool

    init(
        url: URL,
        title: String,
        durationSeconds: Double,
        bitsPerSample: Int? = nil,
        floatingPoint: Bool = false
    ) {
        self.url = url
        self.title = title
        self.durationSeconds = durationSeconds
        self.bitsPerSample = bitsPerSample
        self.floatingPoint = floatingPoint
    }
}

enum M4BChapterBuilder {
    /// Build FFMETADATA1 text with global tags and chapter markers.
    /// Times are milliseconds on TIMEBASE=1/1000.
    static func ffmetadata(
        chapters: [M4BChapterSource],
        title: String?,
        artist: String?,
        album: String?
    ) -> String {
        var lines: [String] = [";FFMETADATA1"]

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("title=\(escape(title))")
        }
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("artist=\(escape(artist))")
            lines.append("album_artist=\(escape(artist))")
        }
        if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("album=\(escape(album))")
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Many players show album as the book name.
            lines.append("album=\(escape(title))")
        }
        lines.append("media_type=2") // Audio book (iTunes)

        var cursorMs: Int64 = 0
        for (index, chapter) in chapters.enumerated() {
            let durationMs = max(1, Int64((chapter.durationSeconds * 1000.0).rounded()))
            let start = cursorMs
            let end = cursorMs + durationMs
            let name = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = name.isEmpty ? "Chapter \(index + 1)" : name

            lines.append("")
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(start)")
            lines.append("END=\(end)")
            lines.append("title=\(escape(display))")

            cursorMs = end
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Concat demuxer list for ffmpeg `-f concat -safe 0 -i …`.
    static func concatList(urls: [URL]) -> String {
        urls.map { url in
            // Escape single quotes for the demuxer; strip CR/LF that would break the list format.
            var path = url.path
            path = path.replacingOccurrences(of: "\r", with: "")
            path = path.replacingOccurrences(of: "\n", with: "")
            path = path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(path)'"
        }.joined(separator: "\n") + "\n"
    }

    /// Escape special characters for FFMETADATA values.
    static func escape(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\", "=", ";", "#":
                out.append("\\")
                out.append(ch)
            case "\n":
                out.append("\\n")
            case "\r":
                out.append("\\r")
            default:
                out.append(ch)
            }
        }
        return out
    }

    static func totalDuration(_ chapters: [M4BChapterSource]) -> Double {
        chapters.reduce(0) { $0 + max(0, $1.durationSeconds) }
    }
}
