import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DropZoneView: View {
    var onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop audio files or folders here")
                    .font(.headline)
                Text("MP3, AAC, M4A/M4B, FLAC, WAV, AIFF, Ogg, Opus, WMA, and many more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Tip: enable Combine to join files, or M4B for chaptered audiobooks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        // Collect URLs on a serial queue — loadItem callbacks may run concurrently.
        let lock = NSLock()
        var collected: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data,
                   let path = String(data: data, encoding: .utf8) {
                    url = URL(string: path) ?? URL(fileURLWithPath: path)
                } else if let u = item as? URL {
                    url = u
                } else if let path = item as? String {
                    url = URL(string: path) ?? URL(fileURLWithPath: path)
                }
                guard let url else { return }
                lock.lock()
                collected.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            onDrop(collected)
        }
    }
}
