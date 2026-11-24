import SwiftUI

@main
enum AudioConverterMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            print("""
            Audio Converter

              --self-test   Check CD disc IDs, TOC parsing, rip names, and conversion rules
              --help        Show this help
            """)
            exit(0)
        }
        if args.contains("--self-test") {
            exit(CDSelfTest.run())
        }
        AudioConverterApp.main()
    }
}

struct AudioConverterApp: App {
    @StateObject private var model = ConverterModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") {
                    model.openFilePanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Convert") {
                Button("Rip Audio CD…") {
                    model.presentCDRipSheet = true
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Start Conversion") {
                    model.startConversion()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isConverting || model.jobs.isEmpty)

                Button("Cancel") {
                    model.cancelConversion()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isConverting)

                Divider()

                Button("Clear Queue") {
                    model.removeAll()
                }
                .disabled(model.isConverting || model.jobs.isEmpty)

                Button("Clear Finished") {
                    model.clearFinished()
                }
            }
            HelpCommands()
        }

        Window("Audio Converter Help", id: AudioConverterHelp.windowID) {
            HelpWindowView()
        }
        .defaultSize(width: 560, height: 680)

        Settings {
            SettingsHelpView()
                .environmentObject(model)
                .frame(width: 420, height: 320)
        }
    }
}

/// Help menu uses `openWindow` so it works even when only Settings is focused.
private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Audio Converter Help") {
                openWindow(id: AudioConverterHelp.windowID)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

struct SettingsHelpView: View {
    @EnvironmentObject var model: ConverterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("FFmpeg") {
                LabeledContent("Status") {
                    Text(model.ffmpegAvailable ? (model.ffmpegBundled ? "Embedded" : "System") : "Missing")
                }
                LabeledContent("Version") {
                    Text(model.ffmpegVersion)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Button("Recheck") { model.refreshFFmpegStatus() }
            }
            Section("Help") {
                Text("Open the full in-app guide for formats, settings, shortcuts, and troubleshooting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Help…") {
                    openWindow(id: AudioConverterHelp.windowID)
                }
            }
            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0")
                }
                Text("Audio Converter embeds FFmpeg to read and write major audio formats including MP3, AAC/M4A, M4B, ALAC, FLAC, WAV, AIFF, Ogg (Opus), Opus, WMA, AC-3, CAF, and more. It also rips audio CDs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
