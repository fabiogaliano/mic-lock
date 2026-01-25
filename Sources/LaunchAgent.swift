import Foundation

// MARK: - LaunchAgent (Startup)

let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents")
let launchAgentPath = launchAgentDir.appendingPathComponent("com.miclock.daemon.plist")
let launchAgentLabel = "com.miclock.daemon"

func isStartupEnabled() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentPath.path)
}

func isStartupLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["list", launchAgentLabel]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func enableStartup() -> Bool {
    // Ensure LaunchAgents directory exists
    do {
        try FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
    } catch {
        logError("Failed to create LaunchAgents dir: \(error)")
        return false
    }

    // Get the path to the current executable
    let execPath = currentExecutablePath()
    guard let resolvedPath = execPath.withCString({ realpath($0, nil) }).map({ String(cString: $0) }) else {
        logError("Failed to resolve executable path")
        return false
    }

    // Create the plist content
    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [resolvedPath, "watch", "--silent"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": configDir.appendingPathComponent("daemon.log").path,
        "StandardErrorPath": configDir.appendingPathComponent("daemon.log").path
    ]

    // Write the plist
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentPath)
    } catch {
        logError("Failed to write LaunchAgent plist: \(error)")
        return false
    }

    // Load the agent
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["load", launchAgentPath.path]

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        logError("Failed to load LaunchAgent: \(error)")
        return false
    }
}

func disableStartup() -> Bool {
    var success = true

    // Unload the agent if loaded
    if isStartupLoaded() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", launchAgentPath.path]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logError("Failed to unload LaunchAgent")
                success = false
            }
        } catch {
            logError("Failed to run launchctl unload: \(error)")
            success = false
        }
    }

    // Remove the plist file
    if FileManager.default.fileExists(atPath: launchAgentPath.path) {
        do {
            try FileManager.default.removeItem(at: launchAgentPath)
        } catch {
            logError("Failed to remove LaunchAgent plist: \(error)")
            success = false
        }
    }

    return success
}

// MARK: - Helpers

private func logError(_ message: String) {
    if let data = "[miclock] \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
