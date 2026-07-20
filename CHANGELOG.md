# Changelog

All notable changes to **Audio Converter** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [1.1.2] - 2026-07-20

### Fixed

- Finish/cancel status messages no longer overwritten by FFmpeg status refresh
- Convert during probe no longer skips files still reading metadata
- Duplicate paths in a single drop/add batch no longer enqueue twice
- Incomplete output files removed after cancel or encode failure (existing files refused by overwrite are kept)
- Thread-safe URL collection in the drop zone
- AIFF defaults to big-endian PCM; joint stereo omitted for mono MP3
- Batch finish counts report this run only (not all historical queue results)
- Concurrent probes for the same job are coalesced (no double `ffprobe`)
- `currentProcess` cleared if ffmpeg fails to start
- Help opens via `openWindow` from the menu and Settings (not only the main window)
- Longer `ffprobe` timeout (120s) for slow/network volumes
- Safer concat file list escaping for paths with newlines

### Changed

- Probe work captures file URLs for safer concurrent execution
- Log tails use bounded `String` suffixes instead of `Substring.description`

## [1.1.1] - 2026-07-19

### Added

- MP3 VBR **Joint stereo** toggle (LAME mid/side vs simple stereo; default on)
- In-app Help documents the joint stereo setting

### Changed

- LAME `-joint_stereo` is applied for all MP3 encodes so CBR and VBR stay consistent with the setting

## [1.1.0] - 2026-07-19

### Added

- **Combine queue into one file** for every output format (MP3, FLAC, M4A, WAV, and others), not only M4B
- Continuous multi-file join without chapter markers (queue order; drag or Move Up/Down)
- Optional title, artist, album, and custom file name for combined outputs
- **M4B audiobook** output with chapter markers (one chapter per queue file)
- Editable chapter titles, book title/author/album metadata, and `media_type` audiobook tagging
- **Embedded artwork** preserved on conversion when the destination supports covers (extract + re-attach as album art)
- Cover art from the first source that has art when combining files
- In-app **Help** window (`Help.html`) with light/dark styling, Help menu, toolbar button, and **⇧⌘/**
- App icon (waveform / convert design) and `.icns` / iconset generation script
- Queue badges for detected cover art (`Art`) and existing chapters

### Fixed

- Combining mixed sources (e.g. AAC M4A + MP3, 16 kHz mono + 44.1 kHz stereo) no longer fails at concat
- Multi-file join now **normalizes each part to PCM** before concat, then encodes the chosen format
- Clearer FFmpeg error messages surfaced in the queue when a conversion fails
- Ogg output uses Opus-in-Ogg on Homebrew FFmpeg builds that lack `libvorbis`

### Changed

- M4B combine path shares the same normalize → join → encode pipeline as other formats (chapters optional only for M4B)
- Settings panel: shared **Combine** section for all formats; M4B-specific chapter options when M4B is selected
- Convert button label reflects mode: **Convert**, **Combine → EXT**, or **Create M4B**
- Help documents combine mode, M4B chapters, artwork, formats, shortcuts, and troubleshooting

## [1.0.0] - 2026-07-19

### Added

- Initial release: native SwiftUI macOS app
- Batch convert via drag-and-drop or file picker; folder import
- Output formats: MP3, AAC, M4A, ALAC, FLAC, WAV, AIFF, Ogg (Opus), Opus, WebM, WMA, AC-3, CAF, MP2, WavPack
- Bitrate, VBR (MP3), sample rate, channels, FLAC compression, PCM depth
- Destination next to source or to a chosen folder; overwrite and metadata copy options
- **Embedded FFmpeg** (`ffmpeg` + `ffprobe` + dylibs) via `build-app.sh` / `scripts/embed-ffmpeg.sh`
- Progress reporting from FFmpeg `time=` output
- System / embedded FFmpeg status in the UI and Settings
