import Foundation

/// Extract and re-attach embedded cover art via the bundled FFmpeg.
enum CoverArtHelper {
    /// Find the stream index of the first attached picture (`disposition.attached_pic == 1`).
    static func coverStreamIndex(in url: URL) -> Int? {
        (try? AudioProbe.probe(url: url))?.coverStreamIndex
    }

    /// Extract cover art from `source` into a JPEG at `destination`.
    /// Returns `true` when a non-empty image file was written.
    @discardableResult
    static func extractCoverArt(from source: URL, to destination: URL, streamIndex: Int?) -> Bool {
        guard let ffmpeg = FFmpegLocator.ffmpegURL else { return false }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Prefer the known attached-pic stream; otherwise try first video stream (only used when probe said cover exists).
        let mapSpec: String
        if let streamIndex {
            mapSpec = "0:\(streamIndex)"
        } else {
            mapSpec = "0:v:0"
        }

        let args = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", source.path,
            "-an",
            "-map", mapSpec,
            "-frames:v", "1",
            "-c:v", "mjpeg",
            "-q:v", "2",
            "-update", "1",
            destination.path
        ]

        let result = FFmpegLocator.run(executable: ffmpeg, arguments: args, timeout: 60)
        guard result.exitCode == 0 else { return false }

        guard let attrs = try? fm.attributesOfItem(atPath: destination.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 32 else {
            try? fm.removeItem(at: destination)
            return false
        }
        return true
    }

    /// Extract cover from the first URL that has an attached-pic stream.
    static func extractCoverArt(fromSources sources: [URL], to destination: URL) -> Bool {
        for url in sources {
            if let index = coverStreamIndex(in: url),
               extractCoverArt(from: url, to: destination, streamIndex: index) {
                return true
            }
        }
        return false
    }

    /// Tags that mark the attached picture as the front cover.
    /// MP3 is written as ID3v2.3 because Finder and Music skip pictures stored in ID3v2.4.
    static func pictureTagArguments(for format: AudioOutputFormat) -> [String] {
        var args = [
            "-metadata:s:v:0", "title=Album cover",
            "-metadata:s:v:0", "comment=Cover (front)",
        ]
        if format == .mp3 {
            args += ["-id3v2_version", "3"]
        }
        return args
    }

    /// FFmpeg args to map audio from input 0 and cover JPEG from input `coverInputIndex`.
    static func mappingArgs(includeCover: Bool, coverInputIndex: Int = 1) -> [String] {
        if includeCover {
            return [
                "-map", "0:a:0",
                "-map", "\(coverInputIndex):v:0",
                "-c:v", "mjpeg",
                "-q:v", "2",
                "-disposition:v:0", "attached_pic",
            ]
        }
        return [
            "-map", "0:a:0",
            "-vn",
        ]
    }
}
