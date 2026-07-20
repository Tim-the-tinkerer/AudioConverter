import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject var model: ConverterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Output")
                    .font(.headline)

                Picker("Format", selection: $model.settings.outputFormat) {
                    ForEach(AudioOutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: model.settings.outputFormat) { newValue in
                    model.applyFormatDefaults(for: newValue)
                }

                Group {
                    if model.settings.outputFormat.supportsBitrate {
                        if model.settings.outputFormat.supportsVBRQuality {
                            Toggle("Variable bitrate (VBR)", isOn: $model.settings.useVBR)
                        }

                        if model.settings.useVBR && model.settings.outputFormat == .mp3 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Quality: \(vbrLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(
                                    value: Binding(
                                        get: { Double(model.settings.vbrQuality) },
                                        set: { model.settings.vbrQuality = Int($0.rounded()) }
                                    ),
                                    in: 0...9,
                                    step: 1
                                )
                                HStack {
                                    Text("Best").font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Smallest").font(.caption2).foregroundStyle(.secondary)
                                }
                                Toggle("Joint stereo", isOn: $model.settings.mp3JointStereo)
                                    .help("LAME mid/side joint stereo. On is smaller/efficient; off forces independent L/R (simple stereo).")
                                Text(model.settings.mp3JointStereo
                                     ? "Mid/side coding — typical for music VBR"
                                     : "Simple stereo — independent left/right channels")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Bitrate", selection: $model.settings.bitrate) {
                                ForEach(ConversionSettings.commonBitrates, id: \.self) { br in
                                    Text("\(br) kbps").tag(br)
                                }
                            }
                        }
                    }

                    if model.settings.outputFormat == .flac {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Compression: \(model.settings.flacCompression)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(model.settings.flacCompression) },
                                    set: { model.settings.flacCompression = Int($0.rounded()) }
                                ),
                                in: 0...12,
                                step: 1
                            )
                        }
                    }

                    if model.settings.outputFormat == .wav
                        || model.settings.outputFormat == .aiff
                        || model.settings.outputFormat == .caf {
                        Picker("PCM", selection: $model.settings.pcmCodec) {
                            ForEach(ConversionSettings.pcmCodecs, id: \.id) { item in
                                Text(item.label).tag(item.id)
                            }
                        }
                    }
                }

                combineSection

                if model.settings.outputFormat == .m4b && !model.settings.combineQueue {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Toggle("Preserve chapters from source", isOn: $model.settings.preserveChapters)
                        Text("Converts each file to its own .m4b. Existing chapter markers are kept when enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Text("Audio")
                    .font(.headline)

                Picker("Sample rate", selection: Binding(
                    get: { model.settings.sampleRate.map(String.init) ?? "source" },
                    set: { value in
                        model.settings.sampleRate = value == "source" ? nil : Int(value)
                    }
                )) {
                    Text(model.settings.combineQueue ? "44.1 kHz (default when combining)" : "Same as source")
                        .tag("source")
                    ForEach(ConversionSettings.commonSampleRates, id: \.self) { rate in
                        Text("\(rate) Hz").tag(String(rate))
                    }
                }

                Picker("Channels", selection: Binding(
                    get: { model.settings.channels.map(String.init) ?? "source" },
                    set: { value in
                        model.settings.channels = value == "source" ? nil : Int(value)
                    }
                )) {
                    Text(model.settings.combineQueue ? "Stereo (default when combining)" : "Same as source")
                        .tag("source")
                    Text("Mono").tag("1")
                    Text("Stereo").tag("2")
                }

                Divider()

                Text("Destination")
                    .font(.headline)

                Toggle("Save next to original", isOn: $model.settings.outputBesideSource)

                if !model.settings.outputBesideSource {
                    HStack {
                        Text(model.settings.outputDirectoryPath ?? "No folder selected")
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(model.settings.outputDirectoryPath == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            model.chooseOutputDirectory()
                        }
                    }
                }

                Toggle("Overwrite existing files", isOn: $model.settings.overwriteExisting)
                if !model.settings.combineQueue {
                    Toggle("Copy metadata (tags)", isOn: $model.settings.copyMetadata)
                }

                Spacer(minLength: 8)

                ffmpegBadge
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var combineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Combine")
                .font(.headline)

            Toggle(
                model.settings.outputFormat == .m4b
                    ? "Combine queue into one chaptered M4B"
                    : "Combine queue into one file",
                isOn: $model.settings.combineQueue
            )

            if model.settings.combineQueue {
                if model.settings.outputFormat == .m4b {
                    Text("Each file becomes a chapter, in list order. Drag rows or use Move Up/Down to reorder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Files are joined in list order into a single continuous \(model.settings.outputFormat.displayName) — no chapter markers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField(
                    model.settings.outputFormat == .m4b ? "Book title" : "Title (optional)",
                    text: $model.settings.combinedTitle
                )
                .textFieldStyle(.roundedBorder)

                TextField(
                    model.settings.outputFormat == .m4b ? "Author" : "Artist (optional)",
                    text: $model.settings.combinedAuthor
                )
                .textFieldStyle(.roundedBorder)

                TextField("Album (optional)", text: $model.settings.combinedAlbum)
                    .textFieldStyle(.roundedBorder)

                TextField("File name (optional)", text: $model.settings.combinedFileName)
                    .textFieldStyle(.roundedBorder)
                    .help("Without extension. Defaults to title or first file name + Combined.")

                let partCount = model.jobs.count
                let totalDur = model.jobs.compactMap { $0.probe?.durationSeconds }.reduce(0, +)
                let unit = model.settings.outputFormat == .m4b ? "chapter" : "part"
                Text("\(partCount) \(unit)\(partCount == 1 ? "" : "s") · \(formatDuration(totalDur)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.settings.outputFormat == .m4b {
                    Button("Reset chapter titles from file names") {
                        model.resetChapterTitlesFromFilenames()
                    }
                    .font(.caption)
                    .disabled(model.jobs.isEmpty || model.isConverting)
                }
            }
        }
    }

    private var vbrLabel: String {
        let q = model.settings.vbrQuality
        switch q {
        case 0...1: return "Excellent (\(q))"
        case 2...3: return "High (\(q))"
        case 4...6: return "Medium (\(q))"
        default: return "Low (\(q))"
        }
    }

    private var ffmpegBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.ffmpegAvailable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.ffmpegAvailable
                   ? (model.ffmpegBundled ? "FFmpeg embedded" : "FFmpeg (system)")
                   : "FFmpeg missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.ffmpegAvailable {
                Text(model.ffmpegVersion)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
