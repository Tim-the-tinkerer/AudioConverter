import Foundation

struct MBRelease: Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var date: String
    var tracks: [MBTrack]
    /// Release group, used when this pressing has no front cover of its own.
    var releaseGroupID: String?
    /// `true` / `false` when MusicBrainz said whether a front image exists. Nil when it did not say.
    var hasFrontCover: Bool?

    var menuTitle: String {
        var text = title.isEmpty ? "Untitled release" : title
        if !artist.isEmpty { text += " — \(artist)" }
        let year = date.prefix(4)
        if year.count == 4, year.allSatisfy(\.isNumber) {
            text += " (\(year))"
        }
        return text
    }
}

struct MBTrack: Equatable {
    var position: Int
    var title: String
    var artist: String
}

enum MusicBrainzError: LocalizedError {
    case badDiscID
    case notFound
    case http(Int)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badDiscID:
            return "This disc has no MusicBrainz ID"
        case .notFound:
            return "MusicBrainz has no entry for this disc"
        case .http(let code):
            return "MusicBrainz returned HTTP \(code)"
        case .badResponse:
            return "MusicBrainz sent a response that could not be read"
        case .network(let message):
            return message
        }
    }
}

enum MusicBrainzClient {
    static let userAgent = "AudioConverter/1.2.0 (macOS audio ripper)"

    static func lookup(discID: String) async throws -> [MBRelease] {
        guard discID.count == 28 else { throw MusicBrainzError.badDiscID }
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/discid/\(discID)") else {
            throw MusicBrainzError.badDiscID
        }
        components.queryItems = [
            URLQueryItem(name: "inc", value: "artists+recordings+release-groups"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { throw MusicBrainzError.badDiscID }
        return try parseReleases(try await fetchJSON(url))
    }

    /// Search for a CD release by album, and artist when we have one.
    static func searchReleases(artist: String, album: String) async throws -> [MBRelease] {
        let albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !albumName.isEmpty else { throw MusicBrainzError.notFound }
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release") else {
            throw MusicBrainzError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: releaseSearchQuery(artist: artist, album: albumName)),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { throw MusicBrainzError.badResponse }
        return try parseReleases(try await fetchJSON(url))
    }

    /// Lucene query for a CD release. Quotes in the names are removed so they cannot break the phrase.
    static func releaseSearchQuery(artist: String, album: String) -> String {
        func phrase(_ value: String) -> String {
            let cleaned = value
                .replacingOccurrences(of: "\\", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\"\(cleaned)\""
        }
        var parts = ["release:\(phrase(album))"]
        let artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artistName.isEmpty {
            parts.append("artist:\(phrase(artistName))")
        }
        parts.append("format:CD")
        return parts.joined(separator: " AND ")
    }

    /// Downloads a front cover for the matched release, then the release group, then other pressings.
    /// Returns nil when the Cover Art Archive has no image.
    static func fetchCover(releases: [MBRelease], preferredID: String) async -> URL? {
        var ordered = releases.filter { isReleaseID($0.id) }
        if let index = ordered.firstIndex(where: { $0.id == preferredID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let preferred = Array(ordered.prefix(1))
        let rest = ordered.dropFirst().sorted { coverRank($0) < coverRank($1) }
        var triedGroups = Set<String>()
        for release in (preferred + rest).prefix(5) {
            if release.hasFrontCover != false,
               let file = await downloadFront(kind: "release", id: release.id) {
                return file
            }
            if let group = release.releaseGroupID, triedGroups.insert(group).inserted,
               let file = await downloadFront(kind: "release-group", id: group) {
                return file
            }
        }
        return nil
    }

    /// Preferred thumbnail from a Cover Art Archive index document. Nil when there is no front image.
    static func frontImageURL(in data: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            return nil
        }
        let fronts = images.filter(isFrontImage)
        guard let image = fronts.first else { return nil }
        let thumbs = image["thumbnails"] as? [String: Any]
        let candidates = [
            thumbs?["500"] as? String,
            thumbs?["large"] as? String,
            thumbs?["1200"] as? String,
            image["image"] as? String,
            thumbs?["small"] as? String,
            thumbs?["250"] as? String,
        ]
        for raw in candidates {
            guard let raw, let url = URL(string: httpsURL(raw)),
                  url.scheme == "https", url.host != nil else { continue }
            return url
        }
        return nil
    }

    static func imageExtension(for data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        return nil
    }

    static func parseReleases(_ data: Data) throws -> [MBRelease] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else { throw MusicBrainzError.badResponse }
        if root["error"] != nil {
            throw MusicBrainzError.notFound
        }
        guard let rawReleases = root["releases"] as? [[String: Any]], !rawReleases.isEmpty else {
            throw MusicBrainzError.notFound
        }
        let releases = rawReleases.compactMap(parseRelease)
        if releases.isEmpty { throw MusicBrainzError.notFound }
        return releases
    }

    static func artistCredit(_ value: Any?) -> String {
        guard let credits = value as? [[String: Any]] else { return "" }
        var text = ""
        for credit in credits {
            let name = (credit["name"] as? String)
                ?? ((credit["artist"] as? [String: Any])?["name"] as? String)
                ?? ""
            let join = credit["joinphrase"] as? String ?? ""
            text += name + join
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isReleaseID(_ id: String) -> Bool {
        id.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func parseRelease(_ raw: [String: Any]) -> MBRelease? {
        guard let id = raw["id"] as? String, isReleaseID(id) else { return nil }
        let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = artistCredit(raw["artist-credit"])
        let date = (raw["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let media = raw["media"] as? [[String: Any]] ?? []
        let chosen = bestMedium(media)
        let rawTracks = chosen?["tracks"] as? [[String: Any]] ?? []
        let tracks = rawTracks.enumerated().map { index, track -> MBTrack in
            let position = (track["position"] as? Int)
                ?? Int(track["number"] as? String ?? "")
                ?? (index + 1)
            let trackTitle = (track["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return MBTrack(position: position, title: trackTitle, artist: artistCredit(track["artist-credit"]))
        }
        let group = (raw["release-group"] as? [String: Any])?["id"] as? String
        let releaseGroupID = group.flatMap { isReleaseID($0) ? $0 : nil }
        return MBRelease(
            id: id,
            title: title,
            artist: artist,
            date: date,
            tracks: tracks,
            releaseGroupID: releaseGroupID,
            hasFrontCover: frontCoverFlag(raw["cover-art-archive"])
        )
    }

    private static func bestMedium(_ media: [[String: Any]]) -> [String: Any]? {
        let withTracks = media.filter { ($0["tracks"] as? [Any])?.isEmpty == false }
        if let cd = withTracks.first(where: { ($0["format"] as? String)?.localizedCaseInsensitiveContains("CD") == true }) {
            return cd
        }
        return withTracks.first ?? media.first
    }

    private static func frontCoverFlag(_ value: Any?) -> Bool? {
        guard let archive = value as? [String: Any] else { return nil }
        if let front = archive["front"] as? Bool { return front }
        if let front = archive["front"] as? Int { return front != 0 }
        return nil
    }

    private static func coverRank(_ release: MBRelease) -> Int {
        switch release.hasFrontCover {
        case true: return 0
        case nil: return 1
        case false: return 2
        }
    }

    private static func isFrontImage(_ image: [String: Any]) -> Bool {
        if let front = image["front"] as? Bool { return front }
        if let front = image["front"] as? Int { return front != 0 }
        return false
    }

    /// Cover Art Archive sometimes publishes `http` links. The image hosts answer on `https`.
    private static func httpsURL(_ raw: String) -> String {
        if raw.hasPrefix("http://") {
            return "https://" + raw.dropFirst("http://".count)
        }
        return raw
    }

    private static func fetchJSON(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MusicBrainzError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw MusicBrainzError.notFound }
        guard code == 200 else { throw MusicBrainzError.http(code) }
        return data
    }

    private static func downloadFront(kind: String, id: String) async -> URL? {
        guard isReleaseID(id) else { return nil }
        if let direct = URL(string: "https://coverartarchive.org/\(kind)/\(id)/front-500"),
           let saved = await saveImage(from: direct, name: id) {
            return saved
        }
        guard let indexURL = URL(string: "https://coverartarchive.org/\(kind)/\(id)"),
              let index = await fetchBytes(indexURL),
              let imageURL = frontImageURL(in: index) else {
            return nil
        }
        return await saveImage(from: imageURL, name: id)
    }

    private static func saveImage(from url: URL, name: String) async -> URL? {
        guard let data = await fetchBytes(url),
              let ext = imageExtension(for: data),
              data.count < 8_000_000 else {
            return nil
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioConverter-cover-\(name).\(ext)")
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    private static func fetchBytes(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
