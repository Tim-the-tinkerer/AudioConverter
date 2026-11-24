import Foundation

enum CDSelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition {
                failures.append(name)
            }
        }

        checkDiscIDs(check)
        checkTOCParsing(check)
        checkNames(check)
        checkTags(check)
        checkMusicBrainzParsing(check)
        checkConversionPolicy(check)

        if failures.isEmpty {
            print("Audio Converter self-test passed (\(checks) checks)")
            return 0
        }
        for name in failures {
            print("FAIL \(name)")
        }
        print("Audio Converter self-test failed (\(failures.count) of \(checks))")
        return 1
    }

    private static func checkDiscIDs(_ check: (String, Bool) -> Void) {
        let first = CDTableOfContents.discID(
            firstTrack: 1,
            lastTrack: 6,
            leadOutFrames: 95462,
            trackFrames: [1: 150, 2: 15363, 3: 32314, 4: 46592, 5: 63414, 6: 80489]
        )
        check("disc id audio CD", first == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")

        let mixed = CDTableOfContents.discID(
            firstTrack: 1,
            lastTrack: 7,
            leadOutFrames: 114574,
            trackFrames: [1: 150, 2: 14109, 3: 33586, 4: 53077, 5: 65781, 6: 77892, 7: 99174]
        )
        check("disc id mixed-mode CD", mixed == "BPnh1KU.hea1C.KMYWLGZkHJr0w-")
        check("disc id rejects a backwards range", CDTableOfContents.discID(
            firstTrack: 5, lastTrack: 1, leadOutFrames: 1000, trackFrames: [:]
        ).isEmpty)
    }

    private static func checkTOCParsing(_ check: (String, Bool) -> Void) {
        let audioFrames = [150, 15363, 32314, 46592, 63414, 80489]
        var descriptors = audioFrames.enumerated().map { index, frames in
            descriptor(point: UInt8(index + 1), control: 0, frames: frames)
        }
        descriptors.append(descriptor(point: 0, control: 0, frames: 0, adr: 2))
        descriptors.append(descriptor(point: 0xA2, control: 0, frames: 95462))
        let audio = CDTableOfContents.parse(tocBytes(descriptors))
        check("toc parses audio CD", audio != nil)
        check("toc disc id", audio?.musicBrainzDiscID() == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
        check("toc ignores non-track descriptors", audio?.audioEntries.count == 6)
        check("toc track 1 length", audio?.lengthFrames(of: 1) == 15213)
        check("toc lead-out", audio?.effectiveLeadOutFrames() == 95462)

        var mixedDescriptors = [150, 14109, 33586, 53077, 65781, 77892, 99174].enumerated().map { index, frames in
            descriptor(point: UInt8(index + 1), control: 0, frames: frames)
        }
        mixedDescriptors.append(descriptor(point: 8, control: 6, frames: 125974))
        mixedDescriptors.append(descriptor(point: 0xA2, control: 6, frames: 188483))
        let mixed = CDTableOfContents.parse(tocBytes(mixedDescriptors))
        check("toc mixed-mode disc id", mixed?.musicBrainzDiscID() == "BPnh1KU.hea1C.KMYWLGZkHJr0w-")
        check("toc drops the data track", mixed?.audioEntries.count == 7)
        check("toc session gap lead-out", mixed?.effectiveLeadOutFrames() == 114574)
        check("toc last audio length", mixed?.lengthFrames(of: 7) == 15400)
        check("toc rejects a short buffer", CDTableOfContents.parse(Data([0x00, 0x01])) == nil)
    }

    private static func checkNames(_ check: (String, Bool) -> Void) {
        let generic = CDNaming.parseTrackFileName("1 Audio Track.aiff")
        check("parse generic track number", generic.number == 1)
        check("generic title becomes Track 01", CDNaming.displayTitle(number: 1, parsed: generic.title) == "Track 01")

        let named = CDNaming.parseTrackFileName("03 - So What.aiff")
        check("parse separated title", named.number == 3 && named.title == "So What")
        check("file base", CDNaming.fileBase(number: 3, title: "So What") == "03 - So What")
        check("file base strips a slash", CDNaming.fileBase(number: 1, title: "A/B") == "01 - A-B")
        check(
            "album folder",
            CDNaming.albumFolder(artist: "AC/DC", album: "Back in Black", volumeName: "Audio CD") == "AC-DC - Back in Black"
        )
        check(
            "generic volume folder",
            CDNaming.albumFolder(artist: "", album: "", volumeName: "Audio CD") == "Audio CD"
        )
        check("volume name can seed the album", CDNaming.initialAlbum(volumeName: "Kind of Blue") == "Kind of Blue")
        check("Audio CD is not an album title", CDNaming.initialAlbum(volumeName: "Audio CD").isEmpty)
    }

    private static func checkTags(_ check: (String, Bool) -> Void) {
        let tags = CDTags.dictionary(
            title: "So What",
            artist: "",
            albumArtist: "Miles Davis",
            album: "Kind of Blue",
            date: "1959",
            track: 1,
            trackCount: 6
        )
        check("tag track number", tags["track"] == "1/6")
        check("tag artist falls back to the album artist", tags["artist"] == "Miles Davis")
        check("tag album artist", tags["album_artist"] == "Miles Davis")
        check("tag disc", tags["disc"] == "1")
        check("tag keeps a distinct track artist", CDTags.dictionary(
            title: "Song",
            artist: "Guest",
            albumArtist: "Various Artists",
            album: "Comp",
            date: "",
            track: 2,
            trackCount: 4
        )["artist"] == "Guest")
        check("empty date is omitted", tags["date"] == "1959")
        let bare = CDTags.dictionary(
            title: "Song", artist: "", albumArtist: "", album: "", date: "  ", track: 1, trackCount: 1
        )
        check("blank date is omitted", bare["date"] == nil)
        check("blank album omits disc", bare["disc"] == nil)
    }

    private static func checkMusicBrainzParsing(_ check: (String, Bool) -> Void) {
        let json = """
        {"releases":[{"id":"11111111-1111-1111-1111-111111111111","title":"Kind of Blue","date":"1959-08-17","artist-credit":[{"name":"Miles Davis","joinphrase":""}],"release-group":{"id":"22222222-2222-2222-2222-222222222222"},"cover-art-archive":{"front":true,"artwork":true},"media":[{"format":"CD","tracks":[{"position":1,"title":"So What","artist-credit":[{"name":"Miles Davis","joinphrase":""}]},{"position":2,"title":"Freddie Freeloader"}]}]}]}
        """.data(using: .utf8)!
        let releases = try? MusicBrainzClient.parseReleases(json)
        check("parse release count", releases?.count == 1)
        check("parse album artist", releases?.first?.artist == "Miles Davis")
        check("parse second title", releases?.first?.tracks.last?.title == "Freddie Freeloader")
        check("missing track artist stays empty", releases?.first?.tracks.last?.artist.isEmpty == true)
        check("menu title includes the year", releases?.first?.menuTitle == "Kind of Blue — Miles Davis (1959)")
        check("parse release group", releases?.first?.releaseGroupID == "22222222-2222-2222-2222-222222222222")
        check("parse front cover flag", releases?.first?.hasFrontCover == true)

        let joined = MusicBrainzClient.artistCredit([
            ["name": "A", "joinphrase": " & "],
            ["name": "B", "joinphrase": ""],
        ])
        check("artist join phrase", joined == "A & B")
        let missing = Data(#"{"error":"Not Found"}"#.utf8)
        check("not found throws", (try? MusicBrainzClient.parseReleases(missing)) == nil)
        check("release id shape", MusicBrainzClient.isReleaseID("11111111-1111-1111-1111-111111111111"))
        check("release id rejects a path", !MusicBrainzClient.isReleaseID("../etc/passwd"))
        check(
            "album search query",
            MusicBrainzClient.releaseSearchQuery(artist: "Miles Davis", album: "Kind of Blue")
                == "release:\"Kind of Blue\" AND artist:\"Miles Davis\" AND format:CD"
        )
        check(
            "album search strips quotes",
            MusicBrainzClient.releaseSearchQuery(artist: "A \"B\"", album: "C")
                == "release:\"C\" AND artist:\"A B\" AND format:CD"
        )

        let coverIndex = """
        {"images":[{"front":false,"image":"https://example.invalid/back.jpg"},{"front":true,"image":"http://coverartarchive.org/release/11111111-1111-1111-1111-111111111111/123.jpg","thumbnails":{"500":"http://coverartarchive.org/release/11111111-1111-1111-1111-111111111111/123-500.jpg","250":"https://example.invalid/small.jpg"}}]}
        """.data(using: .utf8)!
        check(
            "cover index prefers the 500 thumbnail",
            MusicBrainzClient.frontImageURL(in: coverIndex)?.absoluteString
                == "https://coverartarchive.org/release/11111111-1111-1111-1111-111111111111/123-500.jpg"
        )
        let backsOnly = #"{"images":[{"front":false,"image":"https://example.invalid/back.jpg"}]}"#.data(using: .utf8)!
        check("cover index ignores a back image", MusicBrainzClient.frontImageURL(in: backsOnly) == nil)
        check("jpeg magic", MusicBrainzClient.imageExtension(for: Data([0xFF, 0xD8, 0xFF, 0x00])) == "jpg")
        check("png magic", MusicBrainzClient.imageExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "png")
        check("html is not an image", MusicBrainzClient.imageExtension(for: Data("<html>".utf8)) == nil)

        let mp3Art = CoverArtHelper.pictureTagArguments(for: .mp3)
        check("mp3 cover uses id3v2.3", mp3Art.contains("-id3v2_version") && mp3Art.contains("3"))
        check("mp3 cover comment is the front picture", mp3Art.contains("comment=Cover (front)"))
        let flacArt = CoverArtHelper.pictureTagArguments(for: .flac)
        check("flac cover is marked front", flacArt.contains("comment=Cover (front)"))
        check("flac cover is not an id3 tag", !flacArt.contains("-id3v2_version"))
    }

    private static func checkConversionPolicy(_ check: (String, Bool) -> Void) {
        let dir = URL(fileURLWithPath: "/tmp/AudioConverterPolicy")
        let master = dir.appendingPathComponent("Master.flac")
        let other = dir.appendingPathComponent("Other.flac")
        let mp3 = dir.appendingPathComponent("Master.mp3")
        let viaPrivate = URL(fileURLWithPath: "/private/tmp/AudioConverterPolicy/Master.flac")

        check(
            "overlap same path",
            OutputPathSafety.firstOverlap(destination: master, sources: [other, master])?.lastPathComponent == "Master.flac"
        )
        check(
            "overlap ignores case",
            OutputPathSafety.firstOverlap(destination: dir.appendingPathComponent("master.FLAC"), sources: [master]) != nil
        )
        check(
            "overlap follows the /tmp symlink",
            OutputPathSafety.firstOverlap(destination: master, sources: [viaPrivate]) != nil
        )
        check("different extension is not an overlap", OutputPathSafety.firstOverlap(destination: mp3, sources: [master]) == nil)
        check("empty queue has no overlap", OutputPathSafety.firstOverlap(destination: master, sources: []) == nil)
        check(
            "overlap message names the file",
            OutputPathSafety.message(for: master).contains("Master.flac")
        )

        check("opus combine defaults to 48 kHz", AudioOutputFormat.opus.combineSampleRate(explicit: nil) == 48000)
        check("ogg combine defaults to 48 kHz", AudioOutputFormat.ogg.combineSampleRate(explicit: nil) == 48000)
        check("webm combine defaults to 48 kHz", AudioOutputFormat.webm.combineSampleRate(explicit: nil) == 48000)
        check("flac combine defaults to 44.1 kHz", AudioOutputFormat.flac.combineSampleRate(explicit: nil) == 44100)
        check("opus combine replaces 44.1 kHz", AudioOutputFormat.opus.combineSampleRate(explicit: 44100) == 48000)
        check("opus combine keeps 24 kHz", AudioOutputFormat.opus.combineSampleRate(explicit: 24000) == 24000)
        check(
            "opus offers only supported rates",
            AudioOutputFormat.opus.offeredSampleRates == [8000, 12000, 16000, 24000, 48000]
        )
        check("ogg offers the opus rates", AudioOutputFormat.ogg.offeredSampleRates == AudioOutputFormat.opusSampleRates)
        check("webm offers the opus rates", AudioOutputFormat.webm.offeredSampleRates == AudioOutputFormat.opusSampleRates)
        check("mp3 still offers 44.1 kHz", AudioOutputFormat.mp3.offeredSampleRates.contains(44100))
        check("opus argument defaults to 48 kHz", AudioOutputFormat.opus.sampleRateArgument(nil) == 48000)
        check("flac argument keeps the source rate", AudioOutputFormat.flac.sampleRateArgument(nil) == nil)

        var opus = ConversionSettings()
        opus.outputFormat = .opus
        opus.sampleRate = nil
        let opusArgs = AudioOutputFormat.opus.ffmpegCodecArgs(settings: opus)
        check("opus encoder args request 48 kHz", opusArgs.contains("48000") && !opusArgs.contains("44100"))
        var flac = ConversionSettings()
        flac.outputFormat = .flac
        let flacArgs = AudioOutputFormat.flac.ffmpegCodecArgs(settings: flac)
        check("flac encoder args omit a sample rate", !flacArgs.contains("-ar"))

        let deep = CombinePCM.Source(bitsPerSample: 24, floatingPoint: false)
        let cd = CombinePCM.Source(bitsPerSample: 16, floatingPoint: false)
        let unknown = CombinePCM.Source(bitsPerSample: nil, floatingPoint: false)
        check(
            "flac combine keeps 24-bit",
            CombinePCM.intermediateCodec(format: .flac, pcmCodec: "pcm_s16le", sources: [deep]) == "pcm_s24le"
        )
        check(
            "flac combine stays 16-bit",
            CombinePCM.intermediateCodec(format: .flac, pcmCodec: "pcm_s16le", sources: [cd]) == "pcm_s16le"
        )
        check(
            "flac combine uses the widest depth",
            CombinePCM.intermediateCodec(format: .flac, pcmCodec: "pcm_s16le", sources: [cd, deep]) == "pcm_s24le"
        )
        check(
            "flac combine treats an unknown depth as 16-bit",
            CombinePCM.intermediateCodec(format: .flac, pcmCodec: "pcm_s16le", sources: [unknown]) == "pcm_s16le"
        )
        check(
            "20-bit flac uses 24-bit pcm",
            CombinePCM.intermediateCodec(
                format: .flac,
                pcmCodec: "pcm_s16le",
                sources: [CombinePCM.Source(bitsPerSample: 20, floatingPoint: false)]
            ) == "pcm_s24le"
        )
        check(
            "alac combine keeps 32-bit",
            CombinePCM.intermediateCodec(
                format: .alac,
                pcmCodec: "pcm_s16le",
                sources: [CombinePCM.Source(bitsPerSample: 32, floatingPoint: false)]
            ) == "pcm_s32le"
        )
        check(
            "mp3 combine stays 16-bit",
            CombinePCM.intermediateCodec(format: .mp3, pcmCodec: "pcm_s24le", sources: [deep]) == "pcm_s16le"
        )
        check(
            "wav combine honors the 24-bit picker",
            CombinePCM.intermediateCodec(format: .wav, pcmCodec: "pcm_s24le", sources: [cd]) == "pcm_s24le"
        )
        check(
            "aiff combine normalizes big-endian pcm",
            CombinePCM.intermediateCodec(format: .aiff, pcmCodec: "pcm_s16be", sources: [deep]) == "pcm_s16le"
        )
        check(
            "wavpack combine keeps float",
            CombinePCM.intermediateCodec(
                format: .wv,
                pcmCodec: "pcm_s16le",
                sources: [CombinePCM.Source(bitsPerSample: 32, floatingPoint: true)]
            ) == "pcm_f32le"
        )

        let flac24 = AudioBitDepth.interpret(bitsPerRawSample: 24, bitsPerSample: 0, sampleFormat: "s32")
        check("flac probe prefers the raw sample depth", flac24.bitsPerSample == 24 && !flac24.floatingPoint)
        let wav16 = AudioBitDepth.interpret(bitsPerRawSample: nil, bitsPerSample: 16, sampleFormat: "s16")
        check("wav probe reads 16-bit", wav16.bitsPerSample == 16 && !wav16.floatingPoint)
        let floatPCM = AudioBitDepth.interpret(bitsPerRawSample: nil, bitsPerSample: nil, sampleFormat: "fltp")
        check("float probe is marked floating point", floatPCM.floatingPoint && floatPCM.bitsPerSample == 32)
    }

    /// One packed `CDTOC` descriptor. `p` holds the absolute MSF.
    private static func descriptor(point: UInt8, control: UInt8, frames: Int, adr: UInt8 = 1) -> [UInt8] {
        let minute = frames / 4500
        let second = (frames % 4500) / 75
        let frame = frames % 75
        let adrControl = (adr << 4) | control
        return [1, adrControl, 0, point, 0, 0, 0, 0, UInt8(minute), UInt8(second), UInt8(frame)]
    }

    private static func tocBytes(_ descriptors: [[UInt8]]) -> Data {
        let length = 2 + 11 * descriptors.count
        var bytes = [UInt8(length >> 8), UInt8(length & 0xFF), 1, 1]
        for descriptor in descriptors {
            bytes.append(contentsOf: descriptor)
        }
        return Data(bytes)
    }
}
