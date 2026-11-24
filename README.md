# Audio Converter for Mac

**Version 1.2.0**

A native **Swift / SwiftUI** macOS app that converts audio between major formats using an **embedded FFmpeg** build. No system FFmpeg install is required once the app is built.

See [CHANGELOG.md](CHANGELOG.md) for full release history.

## Features

- **Drag & drop** files or folders; batch queue with reorder when combining
- **Read** nearly anything FFmpeg understands (MP3, AAC/M4A/M4B, FLAC, WAV, AIFF, Ogg, Opus, WMA, AC-3, CAF, WavPack, APE, DSD containers, and many more)
- **Write** common targets:
  - MP3 (CBR / VBR via LAME, **joint stereo** option)
  - AAC (`.aac` / `.m4a`)
  - **M4B audiobooks with chapters**
  - ALAC (Apple Lossless)
  - FLAC, WAV, AIFF, CAF
  - Ogg (Opus), Opus, WebM (Opus)
  - WMA, AC-3, MP2, WavPack
- **Combine queue** into one file for *any* format (continuous audio, no chapters)
- **Combine → M4B** for a single chaptered audiobook (one chapter per file)
- Bitrate, VBR quality, sample rate, mono/stereo
- Metadata copy, overwrite control, output beside source or to a chosen folder
- **Embedded artwork** preserved when the target supports covers
- **Rip an audio CD** (⌘R): track list, MusicBrainz lookup, tags, and cover art, encoded with the same format settings
- Progress from FFmpeg `time=` output
- In-app **Help** (Help menu, toolbar, Settings, **⇧⌘/**)
- FFmpeg **9.1** + ffprobe **bundled inside the `.app`** with required dylibs

### Combine (any format)

1. Choose an output format  
2. Enable **Combine queue into one file**  
3. Order parts in the queue (drag or Move Up/Down)  
4. Optional title / artist / album / file name  
5. Click **Combine → EXT**  

Mixed codecs and sample rates are normalized before joining. FLAC, ALAC, and WavPack keep the widest source bit depth. Opus, Ogg (Opus), and WebM (Opus) default to 48 kHz.

### Chaptered M4B

1. Choose **M4B Audiobook (chapters)**  
2. Keep **Combine** on (default for M4B)  
3. One file per chapter; edit titles; set book metadata  
4. Click **Create M4B**  

### MP3 options

- **CBR** or **VBR** (LAME quality 0–9)  
- **Joint stereo** (mid/side, default on) or simple stereo when VBR is enabled  

## Requirements

- macOS 13+
- Xcode Command Line Tools / Swift 5.9+
- **FFmpeg 9.1** is built into `vendor/` by `scripts/build-ffmpeg.sh` (Homebrew’s formula is still 9.0.2). The libraries it links, such as LAME and Opus, come from Homebrew:

  ```bash
  brew install ffmpeg
  ./scripts/build-ffmpeg.sh
  ```

## Build

```bash
cd AudioConverter
chmod +x build-app.sh scripts/embed-ffmpeg.sh scripts/build-ffmpeg.sh
./scripts/build-ffmpeg.sh   # FFmpeg 9.1 into vendor/; skip if it is already there
# Optional: regenerate the app icon
# swift scripts/GenerateAppIcon.swift
./build-app.sh
```

This will:

1. `swift build -c release`
2. Assemble `AudioConverter.app`
3. Embed `ffmpeg` / `ffprobe` and non-system dylibs
4. Rewrite install names (`@rpath`) so the app runs without Homebrew
5. Ad-hoc code-sign and launch the app

| Flag | Meaning |
|------|---------|
| `--no-launch` | Build only, do not open the app |
| `--skip-ffmpeg` | Skip embedding (uses system FFmpeg if present) |

## Usage

1. Drop audio files (or folders), or use **Add Files**  
2. Choose **output format** and options in the right panel  
3. Optionally enable **Combine**  
4. Set destination (next to originals, or a folder)  
5. Click **Convert** / **Combine** / **Create M4B**

### Rip an audio CD

Insert a music CD, then click **Rip CD** (or **⌘R**). MusicBrainz fills the artist, album, and track titles when it knows the disc, and the front cover is embedded in each file as album art. Tracks are encoded with the sidebar format and saved under `Music/Audio Converter/Artist - Album/`, not onto the disc. Dropping the CD volume on the window opens the same sheet.

### Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| Add files | **⌘O** |
| Rip audio CD | **⌘R** |
| Start convert / combine | **⌘↩** |
| Cancel | **⌘.** |
| Help | **⇧⌘/** (or Help menu / toolbar / Settings) |

In-app help (`Help.html`) covers formats, combine, M4B chapters, MP3 VBR/joint stereo, artwork, FFmpeg status, and troubleshooting.

## Project layout

```
AudioConverter/
├── Package.swift
├── AppInfo.plist          # version 1.2.0
├── CHANGELOG.md
├── README.md
├── build-app.sh
├── scripts/
│   ├── build-ffmpeg.sh  # FFmpeg 9.1 into vendor/
│   ├── embed-ffmpeg.sh
│   └── GenerateAppIcon.swift
├── Assets/                # AppIcon.icns, preview PNG
├── AppIcon.iconset/
└── Sources/AudioConverter/
    ├── AudioConverterApp.swift
    ├── ContentView.swift
    ├── AudioConverterHelp.swift
    ├── Models/            # formats, settings, jobs
    ├── Services/          # FFmpeg, probe, convert, cover art, M4B, CD rip
    ├── Views/             # drop zone, queue, settings, help window
    └── Resources/Help.html
```

## How FFmpeg is embedded

`scripts/embed-ffmpeg.sh`:

1. Copies `vendor/bin` FFmpeg when that build exists, otherwise Homebrew `ffmpeg` and `ffprobe`, into `Contents/MacOS/`
2. Recursively gathers dependent dylibs into `Contents/Frameworks/`
3. Rewrites install names for `@rpath` / `@executable_path/../Frameworks`
4. Ad-hoc signs nested binaries

At runtime the app prefers bundled tools, then Homebrew/PATH (handy for `swift run`).

## License notes

Provided as source for personal use. **FFmpeg** is LGPL/GPL depending on the build; Homebrew’s formula is typically GPL with third-party encoders (e.g. LAME). Comply with those licenses if you redistribute the app.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| FFmpeg not found | `brew install ffmpeg && ./build-app.sh` |
| Combine fails on mixed formats | Use 1.1.0+ (normalize-before-concat); rebuild if on an older build |
| Conversion fails / unknown encoder | Check `ffmpeg -encoders` for your Homebrew build |
| Slow files on network drives | Probe allows up to 120s; wait for “Ready” before converting |
| Dyld errors after moving the app | Rebuild so rpaths are rewritten |
| Gatekeeper blocks open | Right-click → Open, or `xattr -cr AudioConverter.app` |
| No cover art on WAV/AIFF | Those formats don’t support embedded pictures |
| Rip CD shows no disc | Wait until Finder mounts the music CD, then click Refresh. Data CDs are ordinary files |
| MusicBrainz has no entry | Type the names. Lookup is optional |

## Development

```bash
swift build
swift run   # uses system ffmpeg if not running from .app
.build/debug/AudioConverter --self-test
```
