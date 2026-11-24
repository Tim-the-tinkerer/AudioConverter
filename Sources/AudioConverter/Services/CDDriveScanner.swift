import Foundation
import DiskArbitration
import IOKit

/// Watches for audio CDs and republishes the mounted discs.
final class CDMonitor {
    private let queue = DispatchQueue(label: "com.audioconverter.cd")
    private var session: DASession?
    private var pending: DispatchWorkItem?
    var onUpdate: (([AudioCD]) -> Void)?

    func start() {
        let session = DASessionCreate(kCFAllocatorDefault)
        self.session = session
        if let session {
            let context = Unmanaged.passUnretained(self).toOpaque()
            DASessionSetDispatchQueue(session, queue)
            DARegisterDiskAppearedCallback(session, nil, { _, context in
                guard let context else { return }
                let monitor = Unmanaged<CDMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.debounceOnQueue()
            }, context)
            DARegisterDiskDisappearedCallback(session, nil, { _, context in
                guard let context else { return }
                let monitor = Unmanaged<CDMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.debounceOnQueue()
            }, context)
        }
        rescanSoon()
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            if let session {
                DASessionSetDispatchQueue(session, nil)
            }
            session = nil
        }
    }

    func rescanSoon() {
        queue.async { [weak self] in
            self?.debounceOnQueue()
        }
    }

    private func debounceOnQueue() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let discs = CDDriveScanner.scan(session: self.session)
            let callback = self.onUpdate
            DispatchQueue.main.async {
                callback?(discs)
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}

enum CDDriveScanner {
    /// True when `url` is the root of a mounted audio CD (`cddafs`), not a file inside one.
    static func isAudioCDVolume(_ url: URL) -> Bool {
        guard isCDDAFileSystem(url) else { return false }
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeURLKey])
        if values?.isVolume == true { return true }
        if let volume = values?.volume?.standardizedFileURL,
           volume.path == url.standardizedFileURL.path {
            return true
        }
        return false
    }

    static func scan(session: DASession?) -> [AudioCD] {
        let tocs = readTOCs()
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .isVolumeKey],
            options: []
        ) ?? []
        let cds = volumes.filter { isCDDAFileSystem($0) }
        return cds.map { volume in
            let info = description(session: session, volume: volume)
            let bsd = info?.bsdName ?? ""
            let toc = tocData(for: bsd, map: tocs, soleVolume: cds.count == 1).flatMap(CDTableOfContents.parse)
            let files = trackFiles(in: volume)
            let name = (info?.volumeName.isEmpty == false ? info?.volumeName : nil) ?? volume.lastPathComponent
            return AudioCD(
                volumeURL: volume,
                volumeName: name,
                deviceModel: info?.model ?? "",
                bsdName: bsd,
                discID: toc?.musicBrainzDiscID(),
                tracks: pair(toc: toc, files: files)
            )
        }
        .sorted { $0.volumeName.localizedStandardCompare($1.volumeName) == .orderedAscending }
    }

    static func isCDDAFileSystem(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        let name = withUnsafeBytes(of: st.f_fstypename) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return name == "cddafs"
    }

    private struct DiscDescription {
        var volumeName: String
        var bsdName: String
        var model: String
    }

    private static func description(session: DASession?, volume: URL) -> DiscDescription? {
        let session = session ?? DASessionCreate(kCFAllocatorDefault)
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let raw = DADiskCopyDescription(disk) else {
            return nil
        }
        let desc = raw as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            (desc[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return DiscDescription(
            volumeName: text("DAVolumeName"),
            bsdName: text("DAMediaBSDName"),
            model: text("DADeviceModel")
        )
    }

    private static func trackFiles(in volume: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: volume,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "aiff" || ext == "aif" || ext == "aifc" || ext == "cdda"
        }
        .sorted { lhs, rhs in
            let left = CDNaming.parseTrackFileName(lhs.lastPathComponent).number ?? 999
            let right = CDNaming.parseTrackFileName(rhs.lastPathComponent).number ?? 999
            if left != right { return left < right }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private static func pair(toc: CDTableOfContents?, files: [URL]) -> [AudioCDTrack] {
        var byNumber: [Int: URL] = [:]
        var leftovers: [URL] = []
        for file in files {
            let parsed = CDNaming.parseTrackFileName(file.lastPathComponent)
            if let number = parsed.number, byNumber[number] == nil {
                byNumber[number] = file
            } else {
                leftovers.append(file)
            }
        }

        guard let toc else {
            return files.enumerated().map { index, file in
                let parsed = CDNaming.parseTrackFileName(file.lastPathComponent)
                let number = parsed.number ?? (index + 1)
                return AudioCDTrack(
                    number: number,
                    durationSeconds: nil,
                    fileTitle: CDNaming.displayTitle(number: number, parsed: parsed.title),
                    sourceURL: file
                )
            }
            .sorted { $0.number < $1.number }
        }

        var tracks: [AudioCDTrack] = []
        for entry in toc.audioEntries {
            let file = byNumber.removeValue(forKey: entry.number)
            let parsed = file.map { CDNaming.parseTrackFileName($0.lastPathComponent).title } ?? ""
            let frames = toc.lengthFrames(of: entry.number)
            tracks.append(AudioCDTrack(
                number: entry.number,
                durationSeconds: frames.map { Double($0) / 75.0 },
                fileTitle: CDNaming.displayTitle(number: entry.number, parsed: parsed),
                sourceURL: file
            ))
        }

        let extras = byNumber.sorted { $0.key < $1.key }.map(\.value) + leftovers.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var used = Set(tracks.map(\.number))
        var next = (used.max() ?? 0) + 1
        for file in extras {
            let parsed = CDNaming.parseTrackFileName(file.lastPathComponent)
            var number = parsed.number ?? next
            if used.contains(number) {
                number = next
            }
            while used.contains(number) {
                number += 1
            }
            used.insert(number)
            next = number + 1
            tracks.append(AudioCDTrack(
                number: number,
                durationSeconds: nil,
                fileTitle: CDNaming.displayTitle(number: number, parsed: parsed.title),
                sourceURL: file
            ))
        }
        return tracks.sorted { $0.number < $1.number }
    }

    private static func tocData(for bsd: String, map: [String: Data], soleVolume: Bool) -> Data? {
        if let data = map[bsd] { return data }
        if let range = bsd.range(of: #"s\d+$"#, options: .regularExpression) {
            let whole = String(bsd[..<range.lowerBound])
            if let data = map[whole] { return data }
        }
        if soleVolume, map.count == 1 {
            return map.values.first
        }
        return nil
    }

    private static func readTOCs() -> [String: Data] {
        guard let matching = IOServiceMatching("IOCDMedia") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var map: [String: Data] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let bsd = registryString(service, "BSD Name"), !bsd.isEmpty else { continue }
            if let toc = registryData(service, "TOC") {
                map[bsd] = toc
            }
        }
        return map
    }

    private static func registryString(_ service: io_object_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }

    private static func registryData(_ service: io_object_t, _ key: String) -> Data? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? Data
    }
}
