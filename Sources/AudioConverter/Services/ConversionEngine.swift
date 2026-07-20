import Foundation

enum ConversionError: LocalizedError {
    case ffmpegMissing
    case cancelled
    case failed(String)
    case outputExists(URL)
    case noChapters

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing: return "ffmpeg not found. Rebuild the app to embed FFmpeg."
        case .cancelled: return "Cancelled"
        case .failed(let s): return s
        case .outputExists(let u): return "Output already exists: \(u.lastPathComponent)"
        case .noChapters: return "Need at least one ready audio file with a known duration"
        }
    }
}

/// Runs FFmpeg conversions with progress parsing from stderr.
final class ConversionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        currentProcess?.terminate()
        lock.unlock()
    }

    func resetCancel() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Single file

    /// Convert one file. `onProgress` is called on a background queue with 0…1.
    /// Embedded cover art is always preserved when the destination format supports it.
    func convert(
        source: URL,
        output: URL,
        settings: ConversionSettings,
        durationHint: Double?,
        coverStreamIndex: Int? = nil,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) throws {
        guard FFmpegLocator.ffmpegURL != nil else {
            throw ConversionError.ffmpegMissing
        }
        if isCancelled { throw ConversionError.cancelled }

        try prepareOutput(output, settings: settings)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AudioConverter-Art-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let wantArt = settings.outputFormat.supportsEmbeddedArtwork
        var includeCover = false
        var coverPath: String?
        if wantArt {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dest = tempDir.appendingPathComponent("cover.jpg")
            let index = coverStreamIndex ?? CoverArtHelper.coverStreamIndex(in: source)
            if let index, CoverArtHelper.extractCoverArt(from: source, to: dest, streamIndex: index) {
                includeCover = true
                coverPath = dest.path
                onLog("Embedded artwork: extracted cover → re-attaching\n")
            } else if index == nil {
                onLog("Embedded artwork: none found on source\n")
            } else {
                onLog("Embedded artwork: extract failed; converting without cover\n")
            }
        }

        var args: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", source.path
        ]
        if includeCover, let coverPath {
            args += ["-i", coverPath]
        }

        // Stream maps: audio + optional cover (never full movie video)
        args += CoverArtHelper.mappingArgs(includeCover: includeCover, coverInputIndex: 1)

        // Metadata tags (independent of artwork)
        if settings.copyMetadata {
            args += ["-map_metadata", "0"]
        } else {
            args += ["-map_metadata", "-1"]
        }

        args += settings.outputFormat.ffmpegCodecArgs(settings: settings)
        args.append(output.path)

        do {
            try runFFmpeg(arguments: args, durationHint: durationHint, onProgress: onProgress, onLog: onLog)
            try verifyOutput(output)
            onProgress(1.0)
        } catch let error as ConversionError {
            // Never delete a pre-existing file we refused to overwrite.
            if case .outputExists = error { throw error }
            try? FileManager.default.removeItem(at: output)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Multi-file combine (any format)

    /// Join sources into one file for the selected format.
    /// - When `writeChapters` is true (M4B), chapter markers are written from each source’s title/duration.
    /// - Otherwise produces a single continuous track (no chapters).
    ///
    /// Mixed codecs/sample rates are handled by normalizing each source to PCM first.
    func convertCombined(
        segments: [M4BChapterSource],
        output: URL,
        settings: ConversionSettings,
        writeChapters: Bool,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) throws {
        guard FFmpegLocator.ffmpegURL != nil else {
            throw ConversionError.ffmpegMissing
        }
        if isCancelled { throw ConversionError.cancelled }
        guard !segments.isEmpty else { throw ConversionError.noChapters }

        for ch in segments {
            guard ch.durationSeconds.isFinite, ch.durationSeconds > 0 else {
                throw ConversionError.failed("Missing duration for \(ch.url.lastPathComponent) — wait for probing to finish")
            }
        }

        try prepareOutput(output, settings: settings)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AudioConverter-Join-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let concatURL = tempDir.appendingPathComponent("concat.txt")
        let metaURL = tempDir.appendingPathComponent("meta.ffmeta")
        let coverURL = tempDir.appendingPathComponent("cover.jpg")

        let targetRate = settings.sampleRate ?? 44100
        let targetChannels = settings.channels ?? 2
        let estimatedTotal = M4BChapterBuilder.totalDuration(segments)

        onLog("Normalizing \(segments.count) file(s) to PCM (\(targetRate) Hz, \(targetChannels) ch)…\n")

        var normalized: [M4BChapterSource] = []
        var wavURLs: [URL] = []

        for (index, ch) in segments.enumerated() {
            if isCancelled { throw ConversionError.cancelled }

            let wavURL = tempDir.appendingPathComponent(String(format: "part_%03d.wav", index))
            onLog("  [\(index + 1)/\(segments.count)] \(ch.url.lastPathComponent)\n")

            let base = Double(index) / Double(segments.count) * 0.70
            let span = 0.70 / Double(segments.count)

            try normalizeChapterToWAV(
                source: ch.url,
                wavURL: wavURL,
                sampleRate: targetRate,
                channels: targetChannels,
                durationHint: ch.durationSeconds,
                onProgress: { p in onProgress(base + span * p) },
                onLog: onLog
            )

            let actualDuration: Double
            if let probed = try? AudioProbe.probe(url: wavURL).durationSeconds,
               probed.isFinite, probed > 0 {
                actualDuration = probed
            } else {
                actualDuration = ch.durationSeconds
            }

            wavURLs.append(wavURL)
            normalized.append(M4BChapterSource(url: wavURL, title: ch.title, durationSeconds: actualDuration))
        }

        try M4BChapterBuilder.concatList(urls: wavURLs)
            .write(to: concatURL, atomically: true, encoding: .utf8)

        let title = settings.combinedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = settings.combinedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = settings.combinedAlbum.trimmingCharacters(in: .whitespacesAndNewlines)

        if writeChapters {
            let metaText = M4BChapterBuilder.ffmetadata(
                chapters: normalized,
                title: title.isEmpty ? nil : title,
                artist: author.isEmpty ? nil : author,
                album: album.isEmpty ? nil : album
            )
            try metaText.write(to: metaURL, atomically: true, encoding: .utf8)

            onLog("Chapters (\(normalized.count)):\n")
            var t: Double = 0
            for (i, ch) in normalized.enumerated() {
                onLog(String(format: "  %02d  %@  (%.1fs)  start=%.1fs\n", i + 1, ch.title, ch.durationSeconds, t))
                t += ch.durationSeconds
            }
        } else {
            // Global tags only (no [CHAPTER] blocks)
            var lines = [";FFMETADATA1"]
            if !title.isEmpty { lines.append("title=\(M4BChapterBuilder.escape(title))") }
            if !author.isEmpty {
                lines.append("artist=\(M4BChapterBuilder.escape(author))")
                lines.append("album_artist=\(M4BChapterBuilder.escape(author))")
            }
            if !album.isEmpty {
                lines.append("album=\(M4BChapterBuilder.escape(album))")
            } else if !title.isEmpty {
                lines.append("album=\(M4BChapterBuilder.escape(title))")
            }
            lines.append("")
            try lines.joined(separator: "\n").write(to: metaURL, atomically: true, encoding: .utf8)
            onLog("Combining \(normalized.count) file(s) into one \(settings.outputFormat.displayName) (no chapters)\n")
        }

        let hasCover = CoverArtHelper.extractCoverArt(fromSources: segments.map(\.url), to: coverURL)
        if hasCover {
            onLog("Embedded artwork: using cover from sources\n")
        } else {
            onLog("Embedded artwork: none found on sources\n")
        }

        let format = settings.outputFormat
        onLog("Encoding \(format.displayName)…\n")

        // Input 0 = concat WAV, input 1 = metadata, optional 2 = cover
        var args: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", concatURL.path,
            "-i", metaURL.path,
        ]
        if hasCover && format.supportsEmbeddedArtwork {
            args += ["-i", coverURL.path]
        }

        args += ["-map", "0:a:0"]
        if hasCover && format.supportsEmbeddedArtwork {
            args += [
                "-map", "2:v:0",
                "-c:v", "mjpeg",
                "-q:v", "2",
                "-disposition:v:0", "attached_pic",
            ]
        }

        // Apply global metadata from the FFMETADATA input
        args += ["-map_metadata", "1"]
        if writeChapters {
            args += ["-map_chapters", "1"]
        } else {
            args += ["-map_chapters", "-1"]
        }

        // Codec/container for the chosen format. Force rate/channels already baked into WAV
        // but re-assert them after codec args for clarity.
        var encodeSettings = settings
        encodeSettings.sampleRate = targetRate
        encodeSettings.channels = targetChannels
        // Don't double-map chapters via m4b codec args; we already mapped them.
        if format == .m4b {
            encodeSettings.preserveChapters = false
        }
        args += format.ffmpegCodecArgs(settings: encodeSettings)
        args.append(output.path)

        let totalDuration = M4BChapterBuilder.totalDuration(normalized)
        do {
            try runFFmpeg(
                arguments: args,
                durationHint: totalDuration > 0 ? totalDuration : estimatedTotal,
                onProgress: { p in onProgress(0.70 + 0.30 * p) },
                onLog: onLog
            )
            try verifyOutput(output)
            onProgress(1.0)
        } catch let error as ConversionError {
            if case .outputExists = error { throw error }
            try? FileManager.default.removeItem(at: output)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Build a chaptered M4B from mixed sources (convenience wrapper).
    func convertChapteredM4B(
        chapters: [M4BChapterSource],
        output: URL,
        settings: ConversionSettings,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) throws {
        try convertCombined(
            segments: chapters,
            output: output,
            settings: settings,
            writeChapters: true,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    /// Decode one source to a mono/stereo PCM WAV at a fixed sample rate.
    private func normalizeChapterToWAV(
        source: URL,
        wavURL: URL,
        sampleRate: Int,
        channels: Int,
        durationHint: Double?,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) throws {
        let args: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", source.path,
            "-vn",
            "-map", "0:a:0",
            "-ac", "\(channels)",
            "-ar", "\(sampleRate)",
            "-c:a", "pcm_s16le",
            "-f", "wav",
            wavURL.path,
        ]
        try runFFmpeg(arguments: args, durationHint: durationHint, onProgress: onProgress, onLog: onLog)
        try verifyOutput(wavURL)
    }

    // MARK: - Shared process runner

    private func prepareOutput(_ output: URL, settings: ConversionSettings) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            if settings.overwriteExisting {
                try fm.removeItem(at: output)
            } else {
                throw ConversionError.outputExists(output)
            }
        }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func verifyOutput(_ output: URL) throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: output.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0 else {
            throw ConversionError.failed("Output file was not created")
        }
    }

    private func runFFmpeg(
        arguments: [String],
        durationHint: Double?,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) throws {
        guard let ffmpeg = FFmpegLocator.ffmpegURL else {
            throw ConversionError.ffmpegMissing
        }

        onLog("ffmpeg " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let frameworks = ffmpeg
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.path) {
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = frameworks.path + (existing.isEmpty ? "" : ":" + existing)
        }
        process.environment = env

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        lock.lock()
        currentProcess = process
        lock.unlock()

        let progressParser = FFmpegProgressParser(durationHint: durationHint)
        var stderrBuffer = ""
        let stderrLock = NSLock()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            stderrLock.lock()
            stderrBuffer += chunk
            if stderrBuffer.count > 16_000 {
                stderrBuffer = String(stderrBuffer.suffix(12_000))
            }
            stderrLock.unlock()
            onLog(chunk)
            if let p = progressParser.consume(chunk) {
                onProgress(min(1.0, max(0.0, p)))
            }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            currentProcess = nil
            lock.unlock()
            throw ConversionError.failed(error.localizedDescription)
        }

        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil

        let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let chunk = String(data: remaining, encoding: .utf8), !chunk.isEmpty {
            stderrLock.lock()
            stderrBuffer += chunk
            stderrLock.unlock()
            onLog(chunk)
        }

        lock.lock()
        currentProcess = nil
        let wasCancelled = cancelled
        lock.unlock()

        // Prefer cancelled over "signal" exit when the user hit Cancel.
        if wasCancelled {
            throw ConversionError.cancelled
        }
        if process.terminationReason == .uncaughtSignal {
            throw ConversionError.cancelled
        }

        guard process.terminationStatus == 0 else {
            stderrLock.lock()
            let errText = stderrBuffer
            stderrLock.unlock()
            throw ConversionError.failed(Self.summarizeFFmpegError(errText, code: process.terminationStatus))
        }
    }

    private static func summarizeFFmpegError(_ stderr: String, code: Int32) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let priority = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error")
                || lower.contains("unknown encoder")
                || lower.contains("invalid")
                || lower.contains("does not contain")
                || lower.contains("no such file")
                || lower.contains("permission denied")
                || lower.hasPrefix("conversion failed")
        }

        if let last = priority.last {
            return String(last.prefix(240))
        }
        if let last = lines.last {
            return "ffmpeg exited \(code): \(String(last.prefix(200)))"
        }
        return "ffmpeg exited with code \(code)"
    }
}

/// Parses `time=HH:MM:SS.xx` lines from ffmpeg stderr.
final class FFmpegProgressParser: @unchecked Sendable {
    private let durationHint: Double?
    private var buffer = ""
    private let lock = NSLock()

    init(durationHint: Double?) {
        self.durationHint = durationHint
    }

    func consume(_ chunk: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk

        var lastProgress: Double?
        while let range = buffer.range(of: "\n") ?? buffer.range(of: "\r") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            if let p = parseLine(line) {
                lastProgress = p
            }
        }
        if let p = parseLine(buffer) {
            lastProgress = p
        }
        return lastProgress
    }

    private func parseLine(_ line: String) -> Double? {
        guard let duration = durationHint, duration > 0 else { return nil }
        guard let timeRange = line.range(of: "time=") else { return nil }
        let after = line[timeRange.upperBound...]
        let token = after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let seconds = Self.parseTimestamp(token), seconds.isFinite else { return nil }
        return seconds / duration
    }

    static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count == 3,
           let h = Double(parts[0]),
           let m = Double(parts[1]),
           let sec = Double(parts[2]) {
            return h * 3600 + m * 60 + sec
        }
        if parts.count == 2,
           let m = Double(parts[0]),
           let sec = Double(parts[1]) {
            return m * 60 + sec
        }
        return Double(s)
    }
}
