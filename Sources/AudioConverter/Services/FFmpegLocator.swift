import Foundation

/// Locates the bundled ffmpeg/ffprobe binaries (preferred) or falls back to PATH/Homebrew.
enum FFmpegLocator {
    static var ffmpegURL: URL? { findBinary(named: "ffmpeg") }
    static var ffprobeURL: URL? { findBinary(named: "ffprobe") }

    static var isBundled: Bool {
        guard let url = ffmpegURL else { return false }
        return url.path.contains(".app/Contents/")
    }

    static var versionLine: String? {
        guard let ffmpeg = ffmpegURL else { return nil }
        let result = run(executable: ffmpeg, arguments: ["-version"])
        return result.stdout.split(separator: "\n").first.map(String.init)
    }

    private static func findBinary(named name: String) -> URL? {
        // 1) Inside the app bundle next to the main executable
        if let exec = Bundle.main.executableURL {
            let sibling = exec.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
            // Contents/MacOS already; also check Resources/bin
            let resources = Bundle.main.resourceURL?
                .appendingPathComponent("bin")
                .appendingPathComponent(name)
            if let resources, FileManager.default.isExecutableFile(atPath: resources.path) {
                return resources
            }
        }

        // 2) Development: relative to #file → project root → vendor/ffmpeg
        let sourceFile = URL(fileURLWithPath: #filePath)
        // Sources/AudioConverter/Services/FFmpegLocator.swift → project root is 4 levels up
        let projectRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vendor = projectRoot.appendingPathComponent("vendor/bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: vendor.path) {
            return vendor
        }

        // 3) Homebrew / PATH
        for path in [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // 4) which
        let which = run(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: [name])
        let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Ensure bundled dylibs are found when running outside the app layout (dev mode).
        var env = ProcessInfo.processInfo.environment
        let frameworks = executable
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.path) {
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = frameworks.path + (existing.isEmpty ? "" : ":" + existing)
            // Also set DYLD_FALLBACK_LIBRARY_PATH for SIP edge cases during dev
            let existingFallback = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = frameworks.path
                + (existingFallback.isEmpty ? "" : ":" + existingFallback)
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return ProcessResult(exitCode: -1, stdout: "", stderr: "Timed out")
            }
        } else {
            process.waitUntilExit()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
