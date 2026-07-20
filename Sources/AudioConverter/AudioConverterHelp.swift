import Foundation

extension Notification.Name {
    static let openAudioConverterHelp = Notification.Name("openAudioConverterHelp")
}

enum AudioConverterHelp {
    static let windowID = "audio-converter-help"

    static func open() {
        NotificationCenter.default.post(name: .openAudioConverterHelp, object: nil)
    }

    /// Resolve Help.html from the SPM resource bundle, main bundle, or source tree (dev).
    static var helpURL: URL? {
        if let bundled = Bundle.module.url(forResource: "Help", withExtension: "html") {
            return bundled
        }

        if let main = Bundle.main.url(forResource: "Help", withExtension: "html") {
            return main
        }

        // Inside AudioConverter_AudioConverter.bundle when copied into the .app Resources
        if let resourceURL = Bundle.main.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent("Help.html"),
                resourceURL.appendingPathComponent("AudioConverter_AudioConverter.bundle/Contents/Resources/Help.html"),
                resourceURL.appendingPathComponent("AudioConverter_AudioConverter.bundle/Help.html"),
            ]
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Development: next to this source file
        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Help.html")
        if FileManager.default.fileExists(atPath: projectPath.path) {
            return projectPath
        }

        return nil
    }
}
