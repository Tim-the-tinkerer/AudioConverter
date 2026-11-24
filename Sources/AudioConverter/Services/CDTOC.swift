import Foundation
import CryptoKit

/// One audio CD macOS has mounted, plus the tracks we can rip from it.
struct AudioCD: Identifiable, Equatable {
    var volumeURL: URL
    var volumeName: String
    var deviceModel: String
    var bsdName: String
    var discID: String?
    var tracks: [AudioCDTrack]

    var id: String { volumeURL.standardizedFileURL.path }

    /// Changes when the mounted files or the table of contents change, not when the user edits titles.
    var identity: String {
        let files = tracks.map { "\($0.number)=\($0.sourceURL?.path ?? "-")" }.joined(separator: ";")
        return "\(id)|\(discID ?? "")|\(files)"
    }

    var ripableTrackCount: Int {
        tracks.filter { $0.sourceURL != nil }.count
    }
}

struct AudioCDTrack: Identifiable, Equatable {
    var number: Int
    var durationSeconds: Double?
    var fileTitle: String
    var sourceURL: URL?

    var id: Int { number }
}

/// What the rip sheet asks the queue to encode.
struct CDRipRequest {
    var tracks: [CDRipTrack]
    var albumArtist: String
    var album: String
    var date: String
    var volumeName: String
    var discTrackCount: Int
    var destinationRoot: URL
    var coverFileURL: URL?
    /// Set only when this rip should eject after every file in the batch succeeds.
    var ejectVolumeURL: URL?
}

struct CDRipTrack {
    var number: Int
    var title: String
    var artist: String
    var durationSeconds: Double?
    var sourceURL: URL?
    var included: Bool
}

/// Table of contents from an `IOCDMedia` `TOC` property.
///
/// The property is Apple's in-memory `CDTOC`: the length field is big-endian, and on this
/// platform the ADR/control byte stores control in the low nibble and ADR in the high nibble.
/// Track starts are absolute CD frames (75 per second), including the 150-frame lead-in.
struct CDTableOfContents: Equatable {
    struct Entry: Equatable {
        var number: Int
        var offsetFrames: Int
        var isData: Bool
    }

    var entries: [Entry]
    /// Point 0xA2, the disc lead-out. A mixed-mode disc uses a different end for the audio session.
    var leadOutFrames: Int?

    var audioEntries: [Entry] {
        entries.filter { !$0.isData }.sorted { $0.number < $1.number }
    }

    /// Lead-out MusicBrainz uses. A data track after the audio session replaces the disc lead-out
    /// with that track's start minus the 11400-frame session gap (11250 + the 150-frame pregap).
    func effectiveLeadOutFrames() -> Int? {
        let audio = audioEntries
        guard let last = audio.last else { return nil }
        if let data = entries
            .filter(\.isData)
            .sorted(by: { $0.number < $1.number })
            .first(where: { $0.number > last.number }) {
            let adjusted = data.offsetFrames - 11_400
            if adjusted > last.offsetFrames {
                return adjusted
            }
        }
        return leadOutFrames
    }

    func lengthFrames(of number: Int) -> Int? {
        let audio = audioEntries
        guard let index = audio.firstIndex(where: { $0.number == number }) else { return nil }
        let start = audio[index].offsetFrames
        let end: Int
        if index + 1 < audio.count {
            end = audio[index + 1].offsetFrames
        } else if let lead = effectiveLeadOutFrames() {
            end = lead
        } else {
            return nil
        }
        let delta = end - start
        guard delta > 0 else { return nil }
        return delta
    }

    func musicBrainzDiscID() -> String? {
        let audio = audioEntries
        guard let first = audio.first, let last = audio.last else { return nil }
        guard let lead = effectiveLeadOutFrames(), lead > last.offsetFrames else { return nil }
        var map: [Int: Int] = [:]
        for entry in audio where (1...99).contains(entry.number) {
            map[entry.number] = entry.offsetFrames
        }
        let id = Self.discID(
            firstTrack: first.number,
            lastTrack: last.number,
            leadOutFrames: lead,
            trackFrames: map
        )
        return id.isEmpty ? nil : id
    }

    /// MusicBrainz disc ID. Offsets are absolute frames; index 0 of the hashed list is the lead-out.
    static func discID(firstTrack: Int, lastTrack: Int, leadOutFrames: Int, trackFrames: [Int: Int]) -> String {
        guard (0...99).contains(firstTrack), (0...99).contains(lastTrack), lastTrack >= firstTrack else {
            return ""
        }
        var frames = [Int](repeating: 0, count: 100)
        frames[0] = leadOutFrames
        for (number, offset) in trackFrames where (1...99).contains(number) {
            frames[number] = offset
        }
        var text = String(format: "%02X%02X", firstTrack, lastTrack)
        for value in frames {
            text += String(format: "%08X", value)
        }
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    static func parse(_ data: Data) -> CDTableOfContents? {
        guard data.count >= 4 else { return nil }
        let lengthField = (Int(data[0]) << 8) | Int(data[1])
        let tocSize = lengthField + 2
        guard tocSize >= 4, tocSize <= data.count else { return nil }
        let count = (tocSize - 4) / 11
        guard count >= 0, 4 + count * 11 <= tocSize else { return nil }

        var entries: [Entry] = []
        var leadOut: Int?
        let bytes = [UInt8](data)
        for index in 0..<count {
            let base = 4 + index * 11
            let adr = Int(bytes[base + 1] >> 4) & 0x0F
            let control = Int(bytes[base + 1]) & 0x0F
            let point = Int(bytes[base + 3])
            guard adr == 1 else { continue }
            let frames = absoluteFrames(bytes[base + 8], bytes[base + 9], bytes[base + 10])
            if point == 0xA2 {
                leadOut = frames
                continue
            }
            guard (1...99).contains(point) else { continue }
            if entries.contains(where: { $0.number == point }) { continue }
            entries.append(Entry(number: point, offsetFrames: frames, isData: (control & 0x04) != 0))
        }
        return CDTableOfContents(entries: entries, leadOutFrames: leadOut)
    }

    private static func absoluteFrames(_ minute: UInt8, _ second: UInt8, _ frame: UInt8) -> Int {
        Int(minute) * 60 * 75 + Int(second) * 75 + Int(frame)
    }
}

enum CDNaming {
    static var defaultRoot: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("Audio Converter", isDirectory: true)
    }

    static func initialAlbum(volumeName: String) -> String {
        let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isGenericVolume(trimmed) { return "" }
        return trimmed
    }

    static func parseTrackFileName(_ fileName: String) -> (number: Int?, title: String) {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let pattern = #"^(\d{1,3})(?:\s*[-._)]\s*|\s+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (nil, stem)
        }
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = regex.firstMatch(in: stem, range: range),
              match.numberOfRanges >= 3,
              let numberRange = Range(match.range(at: 1), in: stem),
              let titleRange = Range(match.range(at: 2), in: stem),
              let number = Int(stem[numberRange]),
              (1...99).contains(number) else {
            return (nil, stem)
        }
        return (number, String(stem[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func displayTitle(number: Int, parsed: String) -> String {
        let title = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || isGenericTitle(title) {
            return String(format: "Track %02d", number)
        }
        return title
    }

    static func fileBase(number: Int, title: String) -> String {
        var name = sanitized(title)
        if name.isEmpty || isGenericTitle(name) {
            name = String(format: "Track %02d", number)
        }
        if name.count > 120 {
            name = String(name.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(format: "%02d - ", number) + name
    }

    static func albumFolder(artist: String, album: String, volumeName: String) -> String {
        let artist = sanitized(artist)
        let album = sanitized(album)
        let folder: String
        if !artist.isEmpty, !album.isEmpty {
            folder = "\(artist) - \(album)"
        } else if !album.isEmpty {
            folder = album
        } else if !artist.isEmpty {
            folder = artist
        } else {
            let volume = sanitized(volumeName)
            folder = (volume.isEmpty || isGenericVolume(volume)) ? "Audio CD" : volume
        }
        if folder.count > 180 {
            return String(folder.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return folder
    }

    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        return name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func isGenericTitle(_ title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "audio track" || name == "track" || name == "untitled" { return true }
        if name.range(of: #"^(audio track|track) \d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func isGenericVolume(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "audio cd" || value.hasPrefix("audio cd ") || value == "untitled" || value == "untitled cd"
    }
}

enum CDTags {
    static func dictionary(
        title: String,
        artist: String,
        albumArtist: String,
        album: String,
        date: String,
        track: Int,
        trackCount: Int
    ) -> [String: String] {
        var tags: [String: String] = [:]
        func put(_ key: String, _ value: String) {
            let cleaned = value
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                tags[key] = cleaned
            }
        }

        put("title", title)
        let trackArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        put("artist", trackArtist.isEmpty ? albumName : trackArtist)
        put("album_artist", albumName)
        put("album", album)
        put("date", date)
        if track > 0, trackCount > 0 {
            tags["track"] = "\(track)/\(trackCount)"
        }
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags["disc"] = "1"
        }
        return tags
    }
}
