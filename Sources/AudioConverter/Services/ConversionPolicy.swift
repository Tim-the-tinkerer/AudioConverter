import Foundation

/// Path checks for destinations that would replace a file the queue still needs to read.
enum OutputPathSafety {
    /// Resolve symlinks in the longest prefix that already exists.
    /// `resolvingSymlinksInPath` leaves `/tmp/...` untouched when the file is not there yet,
    /// which would miss a queued source reached through `/private/tmp`.
    static func canonical(_ url: URL) -> String {
        let fm = FileManager.default
        var probe = url.standardizedFileURL.path
        var suffix: [String] = []
        while probe != "/" && !fm.fileExists(atPath: probe) {
            suffix.append((probe as NSString).lastPathComponent)
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe { break }
            probe = parent
        }
        var resolved = URL(fileURLWithPath: probe).resolvingSymlinksInPath().standardizedFileURL.path
        for component in suffix.reversed() {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        return resolved
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        canonical(a).caseInsensitiveCompare(canonical(b)) == .orderedSame
    }

    /// The first queued source whose path is the destination, if any.
    static func firstOverlap(destination: URL, sources: [URL]) -> URL? {
        sources.first { sameFile(destination, $0) }
    }

    static func message(for source: URL) -> String {
        "Destination matches a queued file (\(source.lastPathComponent)). Choose another name or folder."
    }

    static func rejectOverlap(destination: URL, sources: [URL]) throws {
        if let hit = firstOverlap(destination: destination, sources: sources) {
            throw ConversionError.destinationOverlapsSource(hit.lastPathComponent)
        }
    }
}

/// Sample-rate choices the encoder will actually accept.
extension AudioOutputFormat {
    /// libopus rejects every rate outside this list, including 44.1 kHz.
    static let opusSampleRates = [8000, 12000, 16000, 24000, 48000]

    var restrictsSampleRate: Bool {
        switch self {
        case .opus, .ogg, .webm: return true
        default: return false
        }
    }

    /// Rates shown in the sidebar for this format.
    var offeredSampleRates: [Int] {
        restrictsSampleRate ? Self.opusSampleRates : ConversionSettings.commonSampleRates
    }

    /// Rate used when Combine has no explicit selection.
    var defaultCombineSampleRate: Int {
        restrictsSampleRate ? 48000 : 44100
    }

    /// Formats whose Combine path keeps the sources' bit depth.
    /// WAV, AIFF, and CAF follow the PCM picker instead.
    var preservesSourceBitDepth: Bool {
        switch self {
        case .flac, .alac, .wv: return true
        default: return false
        }
    }

    /// Rate passed while joining. An unsupported explicit rate uses the format default.
    func combineSampleRate(explicit: Int?) -> Int {
        guard let explicit else { return defaultCombineSampleRate }
        if restrictsSampleRate && !Self.opusSampleRates.contains(explicit) {
            return defaultCombineSampleRate
        }
        return explicit
    }

    /// `-ar` value. Opus-family formats always receive a supported rate.
    /// Other formats return nil to keep the source rate.
    func sampleRateArgument(_ selected: Int?) -> Int? {
        if restrictsSampleRate {
            guard let selected, Self.opusSampleRates.contains(selected) else {
                return defaultCombineSampleRate
            }
            return selected
        }
        return selected
    }
}

/// PCM codec for the temporary WAV files Combine concatenates.
enum CombinePCM {
    struct Source: Equatable {
        var bitsPerSample: Int?
        var floatingPoint: Bool
    }

    static func intermediateCodec(format: AudioOutputFormat, pcmCodec: String, sources: [Source]) -> String {
        switch format {
        case .wav, .aiff, .caf:
            return littleEndianWAVCodec(pcmCodec)
        case .flac, .alac, .wv:
            if format == .wv, sources.contains(where: \.floatingPoint) {
                return "pcm_f32le"
            }
            let widest = sources.compactMap(\.bitsPerSample).max() ?? 16
            return integerCodec(widestBits: widest)
        default:
            return "pcm_s16le"
        }
    }

    /// The concat demuxer reads little-endian WAV. The final encode applies AIFF endianness.
    static func littleEndianWAVCodec(_ codec: String) -> String {
        switch codec {
        case "pcm_s16be": return "pcm_s16le"
        case "pcm_s24be": return "pcm_s24le"
        case "pcm_s32be": return "pcm_s32le"
        case "pcm_f32be": return "pcm_f32le"
        default: return codec
        }
    }

    static func integerCodec(widestBits bits: Int) -> String {
        if bits > 24 { return "pcm_s32le" }
        if bits > 16 { return "pcm_s24le" }
        return "pcm_s16le"
    }
}

/// Bit depth reported by ffprobe, including FLAC's raw-sample field.
enum AudioBitDepth {
    struct Reading: Equatable {
        var bitsPerSample: Int?
        var floatingPoint: Bool
    }

    static func interpret(bitsPerRawSample: Int?, bitsPerSample: Int?, sampleFormat: String?) -> Reading {
        let floating = sampleFormat.map { fmt in
            let lower = fmt.lowercased()
            return lower.hasPrefix("flt") || lower.hasPrefix("dbl")
        } ?? false
        let bits = positive(bitsPerRawSample) ?? positive(bitsPerSample) ?? bits(from: sampleFormat)
        return Reading(bitsPerSample: bits, floatingPoint: floating)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func bits(from sampleFormat: String?) -> Int? {
        guard var fmt = sampleFormat?.lowercased() else { return nil }
        if fmt.hasSuffix("p") { fmt.removeLast() }
        switch fmt {
        case "u8": return 8
        case "s16": return 16
        case "s32": return 32
        case "s64": return 64
        case "flt": return 32
        case "dbl": return 64
        default: return nil
        }
    }
}
