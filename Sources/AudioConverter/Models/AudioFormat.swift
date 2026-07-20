import Foundation

/// Output formats supported by the embedded FFmpeg build.
enum AudioOutputFormat: String, CaseIterable, Identifiable, Codable, Hashable {
    case mp3
    case aac
    case m4a
    case m4b    // AAC audiobook (supports chapters)
    case alac
    case flac
    case wav
    case aiff
    case ogg
    case opus
    case wma
    case ac3
    case caf
    case mp2
    case wv      // WavPack
    case webm   // Opus in WebM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp3:  return "MP3"
        case .aac:  return "AAC (.aac)"
        case .m4a:  return "AAC (.m4a)"
        case .m4b:  return "M4B Audiobook (chapters)"
        case .alac: return "ALAC (Apple Lossless)"
        case .flac: return "FLAC"
        case .wav:  return "WAV (PCM)"
        case .aiff: return "AIFF"
        case .ogg:  return "Ogg (Opus)"
        case .opus: return "Opus (.opus)"
        case .wma:  return "WMA"
        case .ac3:  return "AC-3"
        case .caf:  return "CAF"
        case .mp2:  return "MP2"
        case .wv:   return "WavPack"
        case .webm: return "WebM (Opus)"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3:  return "mp3"
        case .aac:  return "aac"
        case .m4a:  return "m4a"
        case .m4b:  return "m4b"
        case .alac: return "m4a"
        case .flac: return "flac"
        case .wav:  return "wav"
        case .aiff: return "aiff"
        case .ogg:  return "ogg"
        case .opus: return "opus"
        case .wma:  return "wma"
        case .ac3:  return "ac3"
        case .caf:  return "caf"
        case .mp2:  return "mp2"
        case .wv:   return "wv"
        case .webm: return "webm"
        }
    }

    var isLossless: Bool {
        switch self {
        case .flac, .wav, .aiff, .alac, .wv, .caf:
            return true
        default:
            return false
        }
    }

    var supportsBitrate: Bool { !isLossless }

    var supportsVBRQuality: Bool {
        switch self {
        case .mp3:
            return true
        case .ogg, .opus, .webm:
            // Opus uses -vbr on/off rather than LAME-style quality ladder.
            return true
        default:
            return false
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .mp3, .aac, .m4a: return 192
        case .m4b: return 64   // common audiobook default
        case .ogg: return 160
        case .opus, .webm: return 96
        case .wma: return 192
        case .ac3: return 192
        case .mp2: return 192
        default: return 0
        }
    }

    /// True when this format is the chaptered audiobook workflow.
    var isAudiobook: Bool { self == .m4b }

    /// Containers that can store an attached cover image via FFmpeg.
    var supportsEmbeddedArtwork: Bool {
        switch self {
        case .mp3, .m4a, .m4b, .alac, .flac, .wma, .ogg, .opus, .webm, .wv:
            return true
        case .aac, .wav, .aiff, .ac3, .caf, .mp2:
            // Raw ADTS AAC, PCM WAV/AIFF/CAF, AC-3, MP2 — no practical cover stream.
            return false
        }
    }

    /// Audio codec / container arguments only (no `-vn`, stream maps, or metadata maps).
    /// Stream mapping and cover art are applied by `ConversionEngine`.
    func ffmpegCodecArgs(settings: ConversionSettings) -> [String] {
        var args: [String] = []

        switch self {
        case .mp3:
            args += ["-c:a", "libmp3lame"]
            if settings.useVBR && supportsVBRQuality {
                // LAME VBR quality 0 (best) … 9 (worst). Map our 0–9 scale.
                args += ["-q:a", "\(settings.vbrQuality)"]
            } else {
                args += ["-b:a", "\(settings.bitrate)k"]
            }
            // Joint stereo only applies to stereo (and multi-channel) layouts.
            let isMono = settings.channels == 1
            if !isMono {
                args += ["-joint_stereo", settings.mp3JointStereo ? "1" : "0"]
            }

        case .aac:
            args += ["-c:a", "aac", "-b:a", "\(settings.bitrate)k", "-f", "adts"]

        case .m4a:
            args += ["-c:a", "aac", "-b:a", "\(settings.bitrate)k", "-f", "mp4", "-movflags", "+faststart"]

        case .m4b:
            // M4B is AAC in an MPEG-4 container branded for audiobooks.
            args += ["-c:a", "aac", "-b:a", "\(settings.bitrate)k", "-f", "mp4", "-movflags", "+faststart"]
            // Chapters from the source (single-file path). Multi-file path maps chapters from FFMETADATA instead.
            if settings.preserveChapters {
                args += ["-map_chapters", "0"]
            }

        case .alac:
            args += ["-c:a", "alac", "-f", "mp4"]

        case .flac:
            args += ["-c:a", "flac", "-compression_level", "\(settings.flacCompression)"]

        case .wav:
            args += ["-c:a", settings.pcmCodec, "-f", "wav"]

        case .aiff:
            args += ["-c:a", settings.pcmCodec, "-f", "aiff"]

        case .ogg:
            // Stock Homebrew FFmpeg ships libopus but not libvorbis. Encode Opus in an Ogg container
            // (widely supported; use .opus for a bare Opus bitstream).
            args += ["-c:a", "libopus", "-b:a", "\(settings.bitrate)k", "-f", "ogg"]
            if settings.useVBR {
                args += ["-vbr", "on"]
            }

        case .opus:
            args += ["-c:a", "libopus", "-b:a", "\(settings.bitrate)k", "-f", "opus"]
            if settings.useVBR {
                args += ["-vbr", "on"]
            }

        case .wma:
            args += ["-c:a", "wmav2", "-b:a", "\(settings.bitrate)k"]

        case .ac3:
            args += ["-c:a", "ac3", "-b:a", "\(settings.bitrate)k"]

        case .caf:
            // Core Audio Format — PCM by default
            args += ["-c:a", settings.pcmCodec, "-f", "caf"]

        case .mp2:
            args += ["-c:a", "mp2", "-b:a", "\(settings.bitrate)k"]

        case .wv:
            args += ["-c:a", "wavpack"]

        case .webm:
            args += ["-c:a", "libopus", "-b:a", "\(settings.bitrate)k", "-f", "webm"]
            if settings.useVBR {
                args += ["-vbr", "on"]
            }
        }

        // Shared resampling / channel options
        if let rate = settings.sampleRate {
            args += ["-ar", "\(rate)"]
        }
        if let channels = settings.channels {
            args += ["-ac", "\(channels)"]
        }

        return args
    }
}

/// Known input extensions the UI accepts for drag/drop and open panels.
enum AudioInputSupport {
    static let extensions: Set<String> = [
        "mp3", "aac", "m4a", "m4b", "m4r", "mp4", "alac",
        "flac", "wav", "wave", "aiff", "aif", "aifc",
        "ogg", "oga", "opus", "wma", "ac3", "eac3",
        "caf", "mp2", "mpa", "wv", "ape", "tak",
        "dsf", "dff", "dts", "dtshd", "truehd",
        "amr", "awb", "ra", "rm", "3gp", "3g2",
        "webm", "mkv", "mka", "ts", "m2ts", "mov",
        "au", "snd", "voc", "w64", "rf64", "amb",
        "spx", "gsm", "act", "mmf", "tta", "shn"
    ]

    static func isSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType {
            return type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        return false
    }
}
