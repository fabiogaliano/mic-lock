import Foundation
import Darwin

// MARK: - Paths

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/mic-lock")
let aliasesFile = configDir.appendingPathComponent("aliases.json")
let pidFile = configDir.appendingPathComponent("daemon.pid")
let lockFile = configDir.appendingPathComponent("current.lock")
let priorityFile = configDir.appendingPathComponent("priority.json")
let settingsFile = configDir.appendingPathComponent("settings.json")

// MARK: - Settings

struct Settings: Codable {
    var silenceTimeout: Double
    var silenceThreshold: Float
    var enableSilenceDetection: Bool

    // Intermittent sampling (energy optimization)
    var sampleInterval: Double  // seconds between sample windows
    var sampleDuration: Double  // seconds each sample runs

    static let defaults = Settings(
        silenceTimeout: 5.0,
        silenceThreshold: 0.00001,
        enableSilenceDetection: true,
        sampleInterval: 10.0,
        sampleDuration: 2.0
    )

    // Handle missing keys when decoding older config files
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        silenceTimeout = try container.decodeIfPresent(Double.self, forKey: .silenceTimeout) ?? Settings.defaults.silenceTimeout
        silenceThreshold = try container.decodeIfPresent(Float.self, forKey: .silenceThreshold) ?? Settings.defaults.silenceThreshold
        enableSilenceDetection = try container.decodeIfPresent(Bool.self, forKey: .enableSilenceDetection) ?? Settings.defaults.enableSilenceDetection
        sampleInterval = try container.decodeIfPresent(Double.self, forKey: .sampleInterval) ?? Settings.defaults.sampleInterval
        sampleDuration = try container.decodeIfPresent(Double.self, forKey: .sampleDuration) ?? Settings.defaults.sampleDuration
    }

    init(silenceTimeout: Double, silenceThreshold: Float, enableSilenceDetection: Bool, sampleInterval: Double = 10.0, sampleDuration: Double = 2.0) {
        self.silenceTimeout = silenceTimeout
        self.silenceThreshold = silenceThreshold
        self.enableSilenceDetection = enableSilenceDetection
        self.sampleInterval = sampleInterval
        self.sampleDuration = sampleDuration
    }
}

func loadSettings() -> Settings {
    guard FileManager.default.fileExists(atPath: settingsFile.path) else {
        return Settings.defaults
    }

    do {
        let data = try Data(contentsOf: settingsFile)
        return try JSONDecoder().decode(Settings.self, from: data)
    } catch {
        logConfigError("Failed to load settings: \(error)")
        return Settings.defaults
    }
}

func saveSettings(_ settings: Settings) {
    guard ensureConfigDir() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted

    do {
        let data = try encoder.encode(settings)
        try data.write(to: settingsFile)
    } catch {
        logConfigError("Failed to save settings: \(error)")
    }
}

// MARK: - Aliases

func loadAliases() -> [String: String] {
    guard FileManager.default.fileExists(atPath: aliasesFile.path) else {
        return [:]
    }

    do {
        let data = try Data(contentsOf: aliasesFile)
        return try JSONDecoder().decode([String: String].self, from: data)
    } catch {
        logConfigError("Failed to load aliases: \(error)")
        return [:]
    }
}

func saveAliases(_ aliases: [String: String]) {
    guard ensureConfigDir() else { return }

    do {
        let data = try JSONEncoder().encode(aliases)
        try data.write(to: aliasesFile)
    } catch {
        logConfigError("Failed to save aliases: \(error)")
    }
}

func resolveAlias(_ query: String) -> String {
    // Not a breaking change in practice; only ambiguous if multiple aliases differ only by case.
    let aliases = loadAliases()
    if let exact = aliases[query] {
        return exact
    }
    if let match = aliases.first(where: { $0.key.caseInsensitiveCompare(query) == .orderedSame }) {
        return match.value
    }
    return query
}

// MARK: - Priority List

func loadPriority() -> [String] {
    guard FileManager.default.fileExists(atPath: priorityFile.path) else {
        return []
    }

    do {
        let data = try Data(contentsOf: priorityFile)
        return try JSONDecoder().decode([String].self, from: data)
    } catch {
        logConfigError("Failed to load priority list: \(error)")
        return []
    }
}

func savePriority(_ list: [String]) {
    guard ensureConfigDir() else { return }

    do {
        let data = try JSONEncoder().encode(list)
        try data.write(to: priorityFile)
    } catch {
        logConfigError("Failed to save priority list: \(error)")
    }
}

// MARK: - Daemon Management

func savePid(_ pid: Int32) {
    guard ensureConfigDir() else { return }

    do {
        try "\(pid)".write(to: pidFile, atomically: true, encoding: .utf8)
    } catch {
        logConfigError("Failed to save pid: \(error)")
    }
}

func loadPid() -> Int32? {
    guard FileManager.default.fileExists(atPath: pidFile.path) else {
        return nil
    }

    do {
        let content = try String(contentsOf: pidFile, encoding: .utf8)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed) else {
            logConfigError("Invalid pid file contents: \(trimmed)")
            return nil
        }
        return pid
    } catch {
        logConfigError("Failed to read pid file: \(error)")
        return nil
    }
}

func clearPid() {
    guard FileManager.default.fileExists(atPath: pidFile.path) else { return }
    do {
        try FileManager.default.removeItem(at: pidFile)
    } catch {
        logConfigError("Failed to clear pid file: \(error)")
    }
}

func saveLock(_ deviceQuery: String) {
    guard ensureConfigDir() else { return }

    do {
        try deviceQuery.write(to: lockFile, atomically: true, encoding: .utf8)
    } catch {
        logConfigError("Failed to save lock: \(error)")
    }
}

func loadLock() -> String? {
    guard FileManager.default.fileExists(atPath: lockFile.path) else {
        return nil
    }

    do {
        let content = try String(contentsOf: lockFile, encoding: .utf8)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        logConfigError("Failed to read lock file: \(error)")
        return nil
    }
}

func clearLock() {
    guard FileManager.default.fileExists(atPath: lockFile.path) else { return }
    do {
        try FileManager.default.removeItem(at: lockFile)
    } catch {
        logConfigError("Failed to clear lock file: \(error)")
    }
}

func isDaemonRunning() -> Bool {
    guard let pid = loadPid() else { return false }
    guard kill(pid, 0) == 0 else { return false }
    guard isPidForCurrentExecutable(pid) else {
        logConfigError("Stale pid \(pid) does not match miclock executable")
        clearPid()
        clearLock()
        return false
    }
    return true
}

func stopDaemon() -> Bool {
    guard let pid = loadPid() else { return false }
    guard isPidForCurrentExecutable(pid) else {
        logConfigError("Refusing to stop pid \(pid) (not miclock)")
        clearPid()
        clearLock()
        return false
    }

    let result = kill(pid, SIGTERM)
    if result == 0 {
        clearPid()
        clearLock()
        return true
    }

    logConfigError("Failed to stop daemon pid \(pid)")
    return false
}

// MARK: - Helpers

private func logConfigError(_ message: String) {
    if let data = "[miclock] \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func processExecutablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
        guard let baseAddress = rawBuffer.baseAddress else { return -1 }
        return proc_pidpath(pid, baseAddress, UInt32(rawBuffer.count))
    }
    guard result > 0 else { return nil }
    let path = String(cString: buffer)
    return path.withCString { realpath($0, nil).map { String(cString: $0) } }
}

private func currentExecutablePath() -> String {
    if let resolvedPath = Bundle.main.executablePath {
        return resolvedPath
    }

    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") {
        return arg0
    }

    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    for dir in pathDirs {
        let candidate = "\(dir)/\(arg0)"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }

    let cwdCandidate = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(arg0)
    if FileManager.default.fileExists(atPath: cwdCandidate) {
        return cwdCandidate
    }

    return arg0
}

private func isPidForCurrentExecutable(_ pid: Int32) -> Bool {
    guard let processPath = processExecutablePath(pid: pid) else {
        return false
    }
    guard let currentPath = currentExecutablePath().withCString({ realpath($0, nil) }).map({ String(cString: $0) }) else { return false }
    return processPath == currentPath
}

@discardableResult
private func ensureConfigDir() -> Bool {
    do {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return true
    } catch {
        logConfigError("Failed to create config dir: \(error)")
        return false
    }
}
