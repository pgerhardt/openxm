import Foundation

enum CodecDriverInstaller {
    /// Stage outside Documents: macOS's privileged shell cannot necessarily read
    /// the user's protected Documents folder. Verify the exact bundled signature
    /// again in the privileged installer before touching HAL.
    static func install() -> String? {
        guard let driver = Bundle.main.url(forResource: "OpenXMCodec", withExtension: "driver"),
              let script = Bundle.main.url(forResource: "install-codec-driver", withExtension: "sh"),
              let hashURL = Bundle.main.url(forResource: "CodecDriverCDHash", withExtension: "txt"),
              let contents = try? String(contentsOf: hashURL, encoding: .utf8) else {
            return "The driver is missing from this build. Rebuild OpenXM using scripts/build.sh."
        }
        let hash = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.count == 40, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return "The bundled driver's signature information is invalid."
        }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("OpenXM-codec-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let driverCopy = stage.appendingPathComponent("OpenXMCodec.driver")
            let scriptCopy = stage.appendingPathComponent("install-codec-driver.sh")
            try FileManager.default.copyItem(at: driver, to: driverCopy)
            try FileManager.default.copyItem(at: script, to: scriptCopy)
            let task = Process(), errors = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // All variable values are arguments, and AppleScript quotes them for
            // the shell. No source interpolation or filesystem path as code.
            task.arguments = ["-e", """
                on run argv
                    set commandText to (quoted form of item 1 of argv) & " " & (quoted form of item 2 of argv) & " " & (quoted form of item 3 of argv)
                    do shell script commandText with administrator privileges
                end run
                """, scriptCopy.path, driverCopy.path, hash]
            task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = errors
            try task.run(); try? errors.fileHandleForWriting.close()
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                if text.contains("-128") { return "Driver installation was cancelled." }
                return "Driver installation failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        } catch { return "Driver installation failed: \(error.localizedDescription)" }
    }
}
