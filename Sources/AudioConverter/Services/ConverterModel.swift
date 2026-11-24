import Foundation
import AppKit
import Combine

@MainActor
final class ConverterModel: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var settings = ConversionSettings()
    @Published var isConverting = false
    @Published var statusMessage: String = ""
    @Published var ffmpegAvailable: Bool = false
    @Published var ffmpegVersion: String = ""
    @Published var ffmpegBundled: Bool = false
    /// Shared progress for multi-file combine builds (0…1).
    @Published var combineProgress: Double = 0
    /// Audio CDs currently mounted by macOS.
    @Published var audioCDs: [AudioCD] = []
    /// Set from the Convert menu. The main window presents the rip sheet.
    @Published var presentCDRipSheet = false

    private let engine = ConversionEngine()
    private let cdMonitor = CDMonitor()
    private var convertTask: Task<Void, Never>?
    /// In-flight probes keyed by job id — avoids double-probe races.
    private var probeTasks: [UUID: Task<Void, Never>] = [:]
    /// Volume to eject after the batch that Rip just started, if every file succeeds.
    private var cdEjectAfterBatch: URL?

    init() {
        refreshFFmpegStatus()
        cdMonitor.onUpdate = { [weak self] discs in
            Task { @MainActor in
                self?.setAudioCDs(discs)
            }
        }
        cdMonitor.start()
    }

    deinit {
        cdMonitor.stop()
    }

    /// Combine queue into one output file (any format).
    var isCombineMode: Bool {
        settings.combineQueue
    }

    /// Combine into a chaptered M4B audiobook.
    var isM4BCombineMode: Bool {
        settings.outputFormat == .m4b && settings.combineQueue
    }

    /// Combine into one continuous file without chapters.
    var isPlainCombineMode: Bool {
        settings.combineQueue && settings.outputFormat != .m4b
    }

    /// Refresh FFmpeg availability. Pass `updateStatus: false` to avoid clobbering a finish/error message.
    func refreshFFmpegStatus(updateStatus: Bool = true) {
        ffmpegAvailable = FFmpegLocator.ffmpegURL != nil && FFmpegLocator.ffprobeURL != nil
        ffmpegBundled = FFmpegLocator.isBundled
        ffmpegVersion = FFmpegLocator.versionLine ?? "Not found"
        guard updateStatus else { return }
        if !ffmpegAvailable {
            statusMessage = "FFmpeg not found. Run ./build-app.sh to embed it."
        } else if ffmpegBundled {
            statusMessage = "Using embedded FFmpeg"
        } else {
            statusMessage = "Using system FFmpeg (not yet embedded in app)"
        }
    }

    // MARK: - Queue management

    func addURLs(_ urls: [URL]) {
        var seen = Set(jobs.map { $0.sourceURL.standardizedFileURL.path })
        var added = 0
        var sawCD = false
        for url in urls {
            let standardized = url.standardizedFileURL
            if CDDriveScanner.isAudioCDVolume(standardized) {
                sawCD = true
                presentCDRipSheet = true
                continue
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue {
                addDirectory(standardized)
                continue
            }
            guard seen.insert(standardized.path).inserted else { continue }
            let ext = standardized.pathExtension.lowercased()
            let looksAudio = AudioInputSupport.extensions.contains(ext)
                || AudioInputSupport.isSupported(url: standardized)
            // Require a known extension or a recognized audio/movie UTI (skip extensionless junk).
            guard looksAudio else { continue }
            let job = ConversionJob(sourceURL: standardized)
            jobs.append(job)
            added += 1
            Task { await probe(job) }
        }
        if added > 0 {
            statusMessage = "Added \(added) file\(added == 1 ? "" : "s")"
            maybeFillCombinedTitle()
        } else if sawCD {
            statusMessage = "Audio CD ready — name the tracks, then rip"
        }
    }

    /// Encode tracks from the rip sheet. `start` begins conversion immediately.
    func addCDRip(_ request: CDRipRequest, start: Bool) {
        guard !isConverting else { return }
        var seen = Set(jobs.map { $0.sourceURL.standardizedFileURL.path })
        let folder = CDNaming.albumFolder(
            artist: request.albumArtist,
            album: request.album,
            volumeName: request.volumeName
        )
        let directory = request.destinationRoot.appendingPathComponent(folder, isDirectory: true)
        var added = 0

        for track in request.tracks where track.included {
            guard let source = track.sourceURL else { continue }
            let standardized = source.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }

            let job = ConversionJob(sourceURL: standardized)
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            job.chapterTitle = title.isEmpty ? String(format: "Track %02d", track.number) : title
            job.outputDirectoryOverride = directory
            job.outputBaseNameOverride = CDNaming.fileBase(number: track.number, title: job.chapterTitle)
            let trackArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            job.metadataOverrides = CDTags.dictionary(
                title: job.chapterTitle,
                artist: trackArtist,
                albumArtist: request.albumArtist,
                album: request.album,
                date: request.date,
                track: track.number,
                trackCount: max(request.discTrackCount, track.number)
            )
            job.coverFileURL = request.coverFileURL
            job.skipSourceCoverScan = true
            job.skipSourceProbe = track.durationSeconds != nil
            if let duration = track.durationSeconds, duration > 0 {
                job.probe = AudioProbeInfo(
                    formatName: "cdda",
                    durationSeconds: duration,
                    bitrate: 1_411_200,
                    sampleRate: 44100,
                    channels: 2,
                    codecName: "pcm_s16be",
                    bitsPerSample: 16,
                    floatingPoint: false,
                    tags: job.metadataOverrides,
                    chapters: [],
                    coverStreamIndex: nil
                )
                job.status = .ready
            }
            jobs.append(job)
            added += 1
        }

        fillCombinedFieldsIfEmpty(artist: request.albumArtist, album: request.album)
        guard added > 0 else {
            statusMessage = "Those CD tracks are already in the queue"
            return
        }
        statusMessage = "Added \(added) CD track\(added == 1 ? "" : "s")"
        guard start else { return }
        cdEjectAfterBatch = request.ejectVolumeURL
        startConversion()
    }

    func rescanAudioCDs() {
        cdMonitor.rescanSoon()
    }

    func ejectVolume(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            statusMessage = "Disc ejected"
        } catch {
            statusMessage = "Could not eject the disc"
        }
    }

    private func setAudioCDs(_ discs: [AudioCD]) {
        guard discs != audioCDs else { return }
        let wasEmpty = audioCDs.isEmpty
        audioCDs = discs
        guard wasEmpty, let first = discs.first, !isConverting else { return }
        let count = first.ripableTrackCount
        guard count > 0 else { return }
        statusMessage = "Audio CD ready — \(count) track\(count == 1 ? "" : "s")"
    }

    /// CD rips name a folder of their own. A combined file must land there too,
    /// because the track files live on a read-only disc.
    private func combinedOutputURL(for jobs: [ConversionJob], settings: ConversionSettings, sources: [URL]) -> URL {
        let proposed = settings.combinedOutputURL(sources: sources)
        guard let directory = jobs.compactMap(\.outputDirectoryOverride).first else {
            return proposed
        }
        return directory.appendingPathComponent(proposed.lastPathComponent)
    }

    private func fillCombinedFieldsIfEmpty(artist: String, album: String) {
        if settings.combinedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.combinedTitle = album
        }
        if settings.combinedAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.combinedAuthor = artist
        }
        if settings.combinedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.combinedAlbum = album
        }
    }

    private func finishCDEject(failed: Int, cancelled: Int) {
        defer { cdEjectAfterBatch = nil }
        guard failed == 0, cancelled == 0, let url = cdEjectAfterBatch else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            statusMessage += " Disc ejected."
        } catch {
            statusMessage += " The disc could not be ejected."
        }
    }

    private func addDirectory(_ dir: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if AudioInputSupport.extensions.contains(ext) {
                urls.append(fileURL)
            }
        }
        // Stable natural-ish sort by path so chapter order follows folder order
        urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        addURLs(urls)
    }

    private func maybeFillCombinedTitle() {
        guard settings.combinedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let first = jobs.first {
            let parent = first.sourceURL.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" {
                settings.combinedTitle = parent
            }
        }
    }

    func removeJobs(ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) && $0.status != .converting }
    }

    func removeAll() {
        guard !isConverting else { return }
        jobs.removeAll()
        statusMessage = "Queue cleared"
    }

    func clearFinished() {
        jobs.removeAll {
            if case .succeeded = $0.status { return true }
            if case .failed = $0.status { return true }
            if case .cancelled = $0.status { return true }
            return false
        }
    }

    func moveJob(id: UUID, direction: Int) {
        guard !isConverting else { return }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + direction
        guard jobs.indices.contains(newIndex) else { return }
        jobs.swapAt(index, newIndex)
    }

    func moveJob(from source: IndexSet, to destination: Int) {
        guard !isConverting else { return }
        jobs.move(fromOffsets: source, toOffset: destination)
    }

    func resetChapterTitlesFromFilenames() {
        for job in jobs {
            job.chapterTitle = ConversionSettings.defaultChapterTitle(from: job.sourceURL)
        }
        statusMessage = "Chapter titles reset from file names"
    }

    // MARK: - Probe

    private func probe(_ job: ConversionJob) async {
        if job.skipSourceProbe, job.probe != nil {
            switch job.status {
            case .failed, .pending, .probing, .cancelled:
                job.status = .ready
            default:
                break
            }
            return
        }
        // Coalesce concurrent probes for the same job (addURLs + Convert).
        if let existing = probeTasks[job.id] {
            await existing.value
            return
        }
        // Already probed successfully — skip (re-probe failed jobs / unprobed only).
        if job.probe != nil {
            switch job.status {
            case .ready, .succeeded, .converting, .cancelled:
                return
            case .failed, .pending, .probing:
                break
            }
        }

        let url = job.sourceURL
        let task = Task { @MainActor in
            job.status = .probing
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try AudioProbe.probe(url: url)
                }.value
                job.probe = info
                // Prefer embedded title tag as chapter title when present and still default-ish
                if let tagTitle = info.tags["title"], !tagTitle.isEmpty {
                    let defaultTitle = ConversionSettings.defaultChapterTitle(from: url)
                    if job.chapterTitle == defaultTitle
                        || job.chapterTitle == url.deletingPathExtension().lastPathComponent {
                        job.chapterTitle = tagTitle
                    }
                }
                job.status = .ready
            } catch {
                job.status = .failed(error.localizedDescription)
            }
        }
        probeTasks[job.id] = task
        await task.value
        probeTasks[job.id] = nil
    }

    // MARK: - Convert

    func startConversion() {
        guard ffmpegAvailable else {
            cdEjectAfterBatch = nil
            statusMessage = "FFmpeg is not available"
            return
        }
        guard !isConverting else { return }

        if isCombineMode {
            startCombinedConversion()
            return
        }

        // Include .probing so "Convert" during probe does not silently skip files.
        let pending = jobs.filter {
            switch $0.status {
            case .ready, .pending, .probing, .failed, .cancelled: return true
            default: return false
            }
        }
        guard !pending.isEmpty else {
            cdEjectAfterBatch = nil
            statusMessage = "Nothing to convert"
            return
        }

        isConverting = true
        engine.resetCancel()
        statusMessage = "Converting \(pending.count) file\(pending.count == 1 ? "" : "s")…"

        let settingsSnapshot = settings
        convertTask = Task { [weak self] in
            guard let self else { return }
            var batchOK = 0
            var batchFail = 0
            var batchCancel = 0
            for job in pending {
                if Task.isCancelled || self.engine.isCancelled { break }
                await self.convertOne(job, settings: settingsSnapshot)
                switch job.status {
                case .succeeded: batchOK += 1
                case .failed: batchFail += 1
                case .cancelled: batchCancel += 1
                default: break
                }
            }
            self.isConverting = false
            if self.engine.isCancelled || Task.isCancelled || batchCancel > 0 {
                self.statusMessage = "Cancelled — \(batchOK) done, \(batchCancel) cancelled"
            } else {
                self.statusMessage = "Finished — \(batchOK) succeeded, \(batchFail) failed"
            }
            let cancelled = batchCancel > 0 || self.engine.isCancelled || Task.isCancelled
            self.finishCDEject(failed: batchFail, cancelled: cancelled ? 1 : 0)
            self.refreshFFmpegStatus(updateStatus: false)
        }
    }

    private func startCombinedConversion() {
        let candidates = jobs.filter {
            switch $0.status {
            case .ready, .pending, .failed, .cancelled, .succeeded, .probing:
                return true
            case .converting:
                return false
            }
        }
        guard !candidates.isEmpty else {
            cdEjectAfterBatch = nil
            statusMessage = "Add audio files to combine"
            return
        }

        let plannedSources = candidates.map(\.sourceURL)
        let plannedOutput = combinedOutputURL(for: candidates, settings: settings, sources: plannedSources)
        if let conflict = OutputPathSafety.firstOverlap(destination: plannedOutput, sources: plannedSources) {
            let message = OutputPathSafety.message(for: conflict)
            for job in candidates {
                job.status = .failed(message)
            }
            cdEjectAfterBatch = nil
            statusMessage = message
            return
        }

        let writeChapters = settings.outputFormat == .m4b
        let formatName = settings.outputFormat.displayName
        let n = candidates.count

        isConverting = true
        combineProgress = 0
        engine.resetCancel()
        if writeChapters {
            statusMessage = "Building chaptered M4B (\(n) chapter\(n == 1 ? "" : "s"))…"
        } else {
            statusMessage = "Combining \(n) file\(n == 1 ? "" : "s") → \(formatName)…"
        }

        let settingsSnapshot = settings
        convertTask = Task { [weak self] in
            guard let self else { return }

            for job in candidates {
                if job.probe?.durationSeconds == nil {
                    await self.probe(job)
                }
            }

            let segments: [M4BChapterSource] = candidates.compactMap { job in
                guard let duration = job.probe?.durationSeconds, duration > 0 else { return nil }
                let title = job.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                return M4BChapterSource(
                    url: job.sourceURL,
                    title: title.isEmpty ? ConversionSettings.defaultChapterTitle(from: job.sourceURL) : title,
                    durationSeconds: duration,
                    bitsPerSample: job.probe?.bitsPerSample,
                    floatingPoint: job.probe?.floatingPoint ?? false
                )
            }

            guard segments.count == candidates.count, !segments.isEmpty else {
                for job in candidates {
                    if job.probe?.durationSeconds == nil {
                        job.status = .failed("Could not read duration")
                    }
                }
                self.isConverting = false
                self.cdEjectAfterBatch = nil
                self.statusMessage = "Every file needs a valid duration — remove unreadable files"
                return
            }

            let output = combinedOutputURL(for: candidates, settings: settingsSnapshot, sources: segments.map(\.url))
            for job in candidates {
                job.status = .converting
                job.progress = 0
                job.outputURL = output
                job.logTail = ""
            }

            let cover = candidates.compactMap(\.coverFileURL).first
            let extractCover = !candidates.allSatisfy(\.skipSourceCoverScan)
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try self.engine.convertCombined(
                                segments: segments,
                                output: output,
                                settings: settingsSnapshot,
                                writeChapters: writeChapters,
                                coverFileURL: cover,
                                extractSourceCover: extractCover,
                                onProgress: { p in
                                    Task { @MainActor in
                                        self.combineProgress = p
                                        for job in candidates {
                                            job.progress = p
                                        }
                                    }
                                },
                                onLog: { chunk in
                                    Task { @MainActor in
                                        if let first = candidates.first {
                                            let merged = first.logTail + chunk
                                            first.logTail = merged.count > 2000
                                                ? String(merged.suffix(2000))
                                                : merged
                                        }
                                    }
                                }
                            )
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                for job in candidates {
                    job.progress = 1
                    job.status = .succeeded
                    job.outputURL = output
                }
                self.combineProgress = 1
                if writeChapters {
                    self.statusMessage = "Created \(output.lastPathComponent) with \(segments.count) chapters"
                } else {
                    self.statusMessage = "Created \(output.lastPathComponent) from \(segments.count) files"
                }
                self.finishCDEject(failed: 0, cancelled: 0)
            } catch let error as ConversionError {
                let message: String
                switch error {
                case .cancelled:
                    message = "Cancelled"
                    for job in candidates { job.status = .cancelled }
                default:
                    message = error.localizedDescription
                    for job in candidates { job.status = .failed(message) }
                }
                self.statusMessage = message
                switch error {
                case .cancelled:
                    self.finishCDEject(failed: 0, cancelled: 1)
                default:
                    self.finishCDEject(failed: 1, cancelled: 0)
                }
            } catch {
                let message = error.localizedDescription
                for job in candidates { job.status = .failed(message) }
                self.statusMessage = message
                self.finishCDEject(failed: 1, cancelled: 0)
            }

            self.isConverting = false
            self.refreshFFmpegStatus(updateStatus: false)
        }
    }

    func cancelConversion() {
        engine.cancel()
        convertTask?.cancel()
        statusMessage = "Cancelling…"
    }

    private func convertOne(_ job: ConversionJob, settings: ConversionSettings) async {
        // Await any in-flight probe (coalesced) so we never double-probe.
        await probe(job)
        if case .failed = job.status { return }
        if Task.isCancelled || engine.isCancelled {
            job.status = .cancelled
            return
        }

        let output: URL
        if let directory = job.outputDirectoryOverride,
           let base = job.outputBaseNameOverride,
           !base.isEmpty {
            output = directory.appendingPathComponent("\(base).\(settings.outputFormat.fileExtension)")
        } else {
            output = settings.outputURL(for: job.sourceURL)
        }
        let queuedSources = jobs.map(\.sourceURL)
        if let conflict = OutputPathSafety.firstOverlap(destination: output, sources: queuedSources) {
            job.status = .failed(OutputPathSafety.message(for: conflict))
            return
        }

        job.status = .converting
        job.progress = 0
        job.outputURL = output
        job.logTail = ""

        let duration = job.probe?.durationSeconds
        let source = job.sourceURL
        let coverIndex = job.probe?.coverStreamIndex
        let coverFile = job.coverFileURL
        let metadata = job.metadataOverrides
        let skipCover = job.skipSourceCoverScan

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.engine.convert(
                            source: source,
                            output: output,
                            settings: settings,
                            durationHint: duration,
                            coverStreamIndex: coverIndex,
                            coverFileURL: coverFile,
                            metadataOverrides: metadata,
                            skipSourceCoverScan: skipCover,
                            queuedSources: queuedSources,
                            onProgress: { p in
                                Task { @MainActor in
                                    job.progress = p
                                }
                            },
                            onLog: { chunk in
                                Task { @MainActor in
                                    let merged = job.logTail + chunk
                                    job.logTail = merged.count > 2000
                                        ? String(merged.suffix(2000))
                                        : merged
                                }
                            }
                        )
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            job.progress = 1
            job.status = .succeeded
        } catch let error as ConversionError {
            switch error {
            case .cancelled:
                job.status = .cancelled
            default:
                job.status = .failed(error.localizedDescription)
            }
        } catch {
            job.status = .failed(error.localizedDescription)
        }
    }

    // MARK: - File pickers

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Choose audio files or folders to convert"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.addURLs(panel.urls)
            }
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose output folder for converted files"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.settings.outputBesideSource = false
                self?.settings.outputDirectoryPath = url.path
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Apply sensible defaults when switching output format (e.g. M4B bitrate).
    func applyFormatDefaults(for format: AudioOutputFormat) {
        if format == .m4b {
            if settings.bitrate == 192 || settings.bitrate == 0 {
                settings.bitrate = format.defaultBitrate
            }
            // Prefer a single chaptered book when using M4B
            settings.combineQueue = true
        }
        // AIFF is big-endian by convention; keep user's choice if they already picked a BE codec.
        if format == .aiff {
            if settings.pcmCodec == "pcm_s16le" || settings.pcmCodec == "pcm_s24le"
                || settings.pcmCodec == "pcm_s32le" || settings.pcmCodec == "pcm_f32le" {
                settings.pcmCodec = "pcm_s16be"
            }
        } else if format == .wav || format == .caf {
            if settings.pcmCodec == "pcm_s16be" {
                settings.pcmCodec = "pcm_s16le"
            }
        }
        if format.restrictsSampleRate {
            let allowed = format.offeredSampleRates
            if let rate = settings.sampleRate, allowed.contains(rate) {
                return
            }
            settings.sampleRate = format.defaultCombineSampleRate
        }
    }
}
