import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ConverterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            // Main column
            VStack(spacing: 12) {
                header
                DropZoneView { urls in
                    model.addURLs(urls)
                }
                JobListView()
                footer
            }
            .padding(16)
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

            // Settings sidebar
            SettingsPanel()
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshFFmpegStatus()
        }
        // Back-compat if anything still posts the help notification.
        .onReceive(NotificationCenter.default.publisher(for: .openAudioConverterHelp)) { _ in
            openWindow(id: AudioConverterHelp.windowID)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Converter")
                    .font(.title2.weight(.semibold))
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openWindow(id: AudioConverterHelp.windowID)
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Open Audio Converter Help")

            Button {
                model.openFilePanel()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .disabled(model.isConverting)
        }
    }

    private var convertButtonTitle: String {
        if model.isConverting {
            if model.isM4BCombineMode { return "Building M4B…" }
            if model.isPlainCombineMode { return "Combining…" }
            return "Converting…"
        }
        let n = model.jobs.count
        if model.isM4BCombineMode {
            return n > 0 ? "Create M4B (\(n) ch.)" : "Create M4B"
        }
        if model.isPlainCombineMode {
            let ext = model.settings.outputFormat.fileExtension.uppercased()
            return n > 0 ? "Combine → \(ext) (\(n))" : "Combine"
        }
        return "Convert"
    }

    private var convertButtonIcon: String {
        if model.isM4BCombineMode { return "book.fill" }
        if model.isPlainCombineMode { return "square.stack.3d.up.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var convertHelp: String {
        if model.isM4BCombineMode {
            return "Combine the queue into one chaptered M4B audiobook"
        }
        if model.isPlainCombineMode {
            return "Join the queue into one continuous \(model.settings.outputFormat.displayName) file"
        }
        return "Convert each file to the selected format"
    }

    private var footer: some View {
        HStack {
            Button("Clear Finished") {
                model.clearFinished()
            }
            .disabled(model.isConverting || model.jobs.isEmpty)

            Button("Clear All") {
                model.removeAll()
            }
            .disabled(model.isConverting || model.jobs.isEmpty)

            Spacer()

            if model.isConverting {
                Button(role: .cancel) {
                    model.cancelConversion()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            Button {
                model.startConversion()
            } label: {
                Label(convertButtonTitle, systemImage: convertButtonIcon)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isConverting || model.jobs.isEmpty || !model.ffmpegAvailable)
            .keyboardShortcut(.return, modifiers: .command)
            .help(convertHelp)
        }
    }
}
