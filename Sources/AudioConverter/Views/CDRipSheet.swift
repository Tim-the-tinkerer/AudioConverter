import SwiftUI
import AppKit

struct CDRipSheet: View {
    @EnvironmentObject var model: ConverterModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("AudioConverter.cdRipDirectory") private var ripDirectory = ""
    @AppStorage("AudioConverter.cdEjectAfterRip") private var ejectAfterRip = false

    @State private var selectedID = ""
    @State private var loadedIdentity = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var date = ""
    @State private var tracks: [CDTrackDraft] = []
    @State private var releases: [MBRelease] = []
    @State private var selectedReleaseID = ""
    @State private var coverFetchedForID = ""
    @State private var coverURL: URL?
    @State private var coverGeneration = 0
    @State private var lookupMessage = ""
    @State private var isLookingUp = false
    @State private var isFetchingCover = false
    @State private var isSubmitting = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var coverTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if activeDisc != nil {
                discForm
            } else {
                emptyState
            }
            footer
        }
        .padding(18)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 520)
        .onAppear {
            model.rescanAudioCDs()
            syncFromModel()
        }
        .onChange(of: model.audioCDs) { _ in
            syncFromModel()
        }
        .onChange(of: selectedID) { newID in
            guard let disc = model.audioCDs.first(where: { $0.id == newID }),
                  disc.identity != loadedIdentity else { return }
            load(disc)
        }
        .onChange(of: selectedReleaseID) { newID in
            guard !newID.isEmpty, newID != coverFetchedForID else { return }
            guard let release = releases.first(where: { $0.id == newID }) else { return }
            apply(release, overwrite: true)
            coverFetchedForID = newID
            startCoverFetch(preferredID: newID)
        }
        .onDisappear {
            lookupTask?.cancel()
            coverTask?.cancel()
            submitTask?.cancel()
        }
    }

    private var activeDisc: AudioCD? {
        if let match = model.audioCDs.first(where: { $0.id == selectedID }) {
            return match
        }
        return model.audioCDs.first
    }

    private var selectedTracks: [CDTrackDraft] {
        tracks.filter { $0.included && $0.sourceURL != nil }
    }

    private var destinationRoot: URL {
        let trimmed = ripDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return CDNaming.defaultRoot }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private var folderPreview: String {
        CDNaming.albumFolder(
            artist: artist,
            album: album,
            volumeName: activeDisc?.volumeName ?? ""
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rip Audio CD")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Refresh") {
                model.rescanAudioCDs()
            }
            .disabled(model.isConverting)
        }
    }

    private var subtitle: String {
        guard let disc = activeDisc else {
            return "Insert an audio CD. macOS mounts it, and the tracks show up here."
        }
        var parts = ["\(disc.tracks.count) track\(disc.tracks.count == 1 ? "" : "s")"]
        if !disc.deviceModel.isEmpty { parts.append(disc.deviceModel) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "opticaldisc")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No audio CD")
                .font(.headline)
            Text("A music CD appears here after Finder mounts it. MP3 CDs and other data discs are ordinary files — drop those on the main window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.audioCDs.count > 1 {
                Picker("Disc", selection: $selectedID) {
                    ForEach(model.audioCDs) { disc in
                        Text(disc.volumeName).tag(disc.id)
                    }
                }
            }

            if let discID = activeDisc?.discID {
                Text(discID)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Artist", text: $artist)
                    labeledField("Album", text: $album)
                    labeledField("Date", text: $date)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    coverPreview
                    Button(isLookingUp ? "Looking Up…" : "Look Up Metadata") {
                        lookup(overwrite: true)
                    }
                    .disabled(isLookingUp || model.isConverting || !canLookup)
                    if !lookupMessage.isEmpty {
                        Text(lookupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if releases.count > 1 {
                        Picker("Release", selection: $selectedReleaseID) {
                            ForEach(releases) { release in
                                Text(release.menuTitle).tag(release.id)
                            }
                        }
                        .labelsHidden()
                    }
                    if coverURL != nil, !model.settings.outputFormat.supportsEmbeddedArtwork {
                        Text("\(model.settings.outputFormat.displayName) can’t store a picture. MP3, M4A, FLAC, and ALAC can.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)
            }

            HStack {
                Toggle("All tracks", isOn: allIncluded)
                Spacer()
                Text(selectedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach($tracks) { $track in
                    trackRow($track)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15))
            )

            if tracks.contains(where: { $0.sourceURL == nil }) {
                Text("Some tracks have no audio file on the volume, so they cannot be ripped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationRoot.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Saves \(folderPreview)/01 - Title.\(model.settings.outputFormat.fileExtension)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !ripDirectory.isEmpty {
                    Button("Default") { ripDirectory = "" }
                }
                Button("Choose…") { chooseFolder() }
            }

            Text("Encoded as \(model.settings.outputFormat.displayName), using the settings in the sidebar. Files are not written onto the CD.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isCombineMode {
                Text(model.isM4BCombineMode
                     ? "Combine is on. Rip joins the selected tracks into one chaptered M4B."
                     : "Combine is on. Rip joins the selected tracks into one \(model.settings.outputFormat.displayName) file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("Eject when the rip finishes", isOn: $ejectAfterRip)
                    .disabled(activeDisc == nil)
                    .help("Ejects only after Rip, and only if every file in that batch succeeds.")
                Button("Eject") {
                    if let url = activeDisc?.volumeURL {
                        model.ejectVolume(url)
                    }
                }
                .disabled(activeDisc == nil || model.isConverting)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Add to Queue") {
                    submit(start: false)
                }
                .disabled(selectedTracks.isEmpty || model.isConverting || isSubmitting)

                Button(ripButtonTitle) {
                    submit(start: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTracks.isEmpty || model.isConverting || !model.ffmpegAvailable || isSubmitting)
            }
        }
    }

    private var canLookup: Bool {
        if activeDisc?.discID != nil { return true }
        return canSearch(artist: artist, album: album)
    }

    private var ripButtonTitle: String {
        if isSubmitting && (isLookingUp || isFetchingCover) { return "Looking Up Cover…" }
        if selectedTracks.isEmpty { return "Rip" }
        return "Rip \(selectedTracks.count)"
    }

    private var coverPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if coverURL == nil, isLookingUp || isFetchingCover {
                ProgressView()
                    .controlSize(.small)
            } else if let coverURL, let image = NSImage(contentsOf: coverURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
        .accessibilityLabel(coverURL == nil ? "No album art" : "Album art")
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func trackRow(_ track: Binding<CDTrackDraft>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: track.included)
                .labelsHidden()
                .disabled(track.wrappedValue.sourceURL == nil)
            Text(String(format: "%02d", track.wrappedValue.number))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            TextField("Title", text: track.title)
                .textFieldStyle(.roundedBorder)
                .disabled(track.wrappedValue.sourceURL == nil)
            Text(durationText(track.wrappedValue.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var allIncluded: Binding<Bool> {
        Binding(
            get: {
                let ripable = tracks.filter { $0.sourceURL != nil }
                return !ripable.isEmpty && ripable.allSatisfy(\.included)
            },
            set: { value in
                for index in tracks.indices where tracks[index].sourceURL != nil {
                    tracks[index].included = value
                }
            }
        )
    }

    private var selectedSummary: String {
        let chosen = selectedTracks
        let seconds = chosen.compactMap(\.durationSeconds).reduce(0, +)
        if chosen.isEmpty { return "Nothing selected" }
        return "\(chosen.count) selected · \(durationText(seconds))"
    }

    private func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func syncFromModel() {
        let discs = model.audioCDs
        guard let disc = discs.first(where: { $0.id == selectedID }) ?? discs.first else {
            selectedID = ""
            loadedIdentity = ""
            tracks = []
            releases = []
            selectedReleaseID = ""
            coverFetchedForID = ""
            coverURL = nil
            return
        }
        if disc.identity != loadedIdentity {
            load(disc)
        }
        if selectedID != disc.id {
            selectedID = disc.id
        }
    }

    private func load(_ disc: AudioCD) {
        loadedIdentity = disc.identity
        artist = ""
        album = CDNaming.initialAlbum(volumeName: disc.volumeName)
        date = ""
        releases = []
        selectedReleaseID = ""
        coverFetchedForID = ""
        coverURL = nil
        lookupMessage = ""
        tracks = disc.tracks.map { track in
            CDTrackDraft(
                number: track.number,
                title: track.fileTitle,
                artist: "",
                durationSeconds: track.durationSeconds,
                sourceURL: track.sourceURL,
                included: track.sourceURL != nil
            )
        }
        if disc.discID != nil || canSearch(artist: artist, album: album) {
            lookup(overwrite: false)
        } else if disc.discID == nil {
            lookupMessage = "No table of contents was read, so MusicBrainz lookup is unavailable."
        }
    }

    private func lookup(overwrite: Bool) {
        lookupTask?.cancel()
        coverTask?.cancel()
        let discID = activeDisc?.discID ?? ""
        let artistQuery = artist
        let albumQuery = album
        isLookingUp = true
        lookupMessage = "Asking MusicBrainz…"
        lookupTask = Task {
            var found: [MBRelease] = []
            var failure = ""
            if !discID.isEmpty {
                do {
                    found = try await MusicBrainzClient.lookup(discID: discID)
                } catch {
                    if Task.isCancelled { return }
                    failure = error.localizedDescription
                }
            }
            if Task.isCancelled { return }
            if found.isEmpty, canSearch(artist: artistQuery, album: albumQuery) {
                if !discID.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if Task.isCancelled { return }
                do {
                    found = try await MusicBrainzClient.searchReleases(artist: artistQuery, album: albumQuery)
                    failure = ""
                } catch {
                    if failure.isEmpty {
                        failure = error.localizedDescription
                    }
                }
            }
            if Task.isCancelled { return }
            releases = found
            guard let first = found.first else {
                coverURL = nil
                coverFetchedForID = ""
                isFetchingCover = false
                isLookingUp = false
                lookupMessage = failure.isEmpty ? "MusicBrainz has no entry for this album" : failure
                return
            }
            apply(first, overwrite: overwrite)
            coverFetchedForID = first.id
            selectedReleaseID = first.id
            lookupMessage = found.count == 1 ? "Found 1 release" : "Found \(found.count) releases"
            startCoverFetch(preferredID: first.id)
            await coverTask?.value
            if Task.isCancelled { return }
            isLookingUp = false
        }
    }

    private func apply(_ release: MBRelease, overwrite: Bool) {
        artist = filled(artist, with: release.artist, overwrite: overwrite)
        album = filled(album, with: release.title, overwrite: overwrite)
        date = filled(date, with: release.date, overwrite: overwrite)
        for index in tracks.indices {
            guard let match = release.tracks.first(where: { $0.position == tracks[index].number }),
                  !match.title.isEmpty else { continue }
            let current = tracks[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard overwrite || current.isEmpty || CDNaming.isGenericTitle(current) else { continue }
            tracks[index].title = match.title
            tracks[index].artist = match.artist == release.artist ? "" : match.artist
        }
    }

    private func filled(_ current: String, with incoming: String, overwrite: Bool) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if overwrite || trimmed.isEmpty { return incoming }
        return current
    }

    private func canSearch(artist: String, album: String) -> Bool {
        let name = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !CDNaming.isGenericVolume(name)
    }

    private func startCoverFetch(preferredID: String) {
        coverGeneration += 1
        let generation = coverGeneration
        coverTask?.cancel()
        isFetchingCover = true
        let snapshot = releases
        coverTask = Task {
            let cover = await MusicBrainzClient.fetchCover(releases: snapshot, preferredID: preferredID)
            if Task.isCancelled || generation != coverGeneration { return }
            coverURL = cover
            isFetchingCover = false
            noteCover(found: cover != nil)
        }
    }

    private func noteCover(found: Bool) {
        let base = lookupMessage
            .replacingOccurrences(of: " · cover art", with: "")
            .replacingOccurrences(of: " · no cover art", with: "")
        if found {
            lookupMessage = base.isEmpty ? "Cover art" : base + " · cover art"
        } else if !base.isEmpty {
            lookupMessage = base + " · no cover art"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder for ripped tracks"
        panel.directoryURL = destinationRoot
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            ripDirectory = url.path
        }
    }

    private func submit(start: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let pendingLookup = lookupTask
        submitTask = Task { @MainActor in
            if isLookingUp || isFetchingCover {
                lookupMessage = "Finishing the cover lookup…"
            }
            await pendingLookup?.value
            guard !Task.isCancelled else { return }
            await coverTask?.value
            guard !Task.isCancelled else { return }
            commit(start: start)
            isSubmitting = false
        }
    }

    private func commit(start: Bool) {
        guard let disc = activeDisc else { return }
        guard !selectedTracks.isEmpty else { return }
        let request = CDRipRequest(
            tracks: tracks.map { track in
                CDRipTrack(
                    number: track.number,
                    title: track.title,
                    artist: track.artist,
                    durationSeconds: track.durationSeconds,
                    sourceURL: track.sourceURL,
                    included: track.included
                )
            },
            albumArtist: artist,
            album: album,
            date: date,
            volumeName: disc.volumeName,
            discTrackCount: tracks.count,
            destinationRoot: destinationRoot,
            coverFileURL: coverURL,
            ejectVolumeURL: (start && ejectAfterRip) ? disc.volumeURL : nil
        )
        model.addCDRip(request, start: start)
        dismiss()
    }
}

private struct CDTrackDraft: Identifiable, Equatable {
    var number: Int
    var title: String
    var artist: String
    var durationSeconds: Double?
    var sourceURL: URL?
    var included: Bool

    var id: Int { number }
}
