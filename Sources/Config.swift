import Foundation

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
    guard let data = try? Data(contentsOf: settingsFile),
          let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
        return Settings.defaults
    }
    return settings
}

func saveSettings(_ settings: Settings) {
    ensureConfigDir()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(settings) {
        try? data.write(to: settingsFile)
    }
}

// MARK: - Aliases

func loadAliases() -> [String: String] {
    guard let data = try? Data(contentsOf: aliasesFile),
          let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return dict
}

func saveAliases(_ aliases: [String: String]) {
    ensureConfigDir()
    if let data = try? JSONEncoder().encode(aliases) {
        try? data.write(to: aliasesFile)
    }
}

func resolveAlias(_ query: String) -> String {
    let aliases = loadAliases()
    return aliases[query.lowercased()] ?? query
}

// MARK: - Priority List

func loadPriority() -> [String] {
    guard let data = try? Data(contentsOf: priorityFile),
          let list = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return list
}

func savePriority(_ list: [String]) {
    ensureConfigDir()
    if let data = try? JSONEncoder().encode(list) {
        try? data.write(to: priorityFile)
    }
}

// MARK: - Daemon Management

func savePid(_ pid: Int32) {
    ensureConfigDir()
    try? "\(pid)".write(to: pidFile, atomically: true, encoding: .utf8)
}

func loadPid() -> Int32? {
    guard let content = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    return pid
}

func clearPid() {
    try? FileManager.default.removeItem(at: pidFile)
}

func saveLock(_ deviceQuery: String) {
    ensureConfigDir()
    try? deviceQuery.write(to: lockFile, atomically: true, encoding: .utf8)
}

func loadLock() -> String? {
    guard let content = try? String(contentsOf: lockFile, encoding: .utf8) else {
        return nil
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
}

func clearLock() {
    try? FileManager.default.removeItem(at: lockFile)
}

func isDaemonRunning() -> Bool {
    guard let pid = loadPid() else { return false }
    return kill(pid, 0) == 0
}

func stopDaemon() -> Bool {
    guard let pid = loadPid() else { return false }
    let result = kill(pid, SIGTERM)
    if result == 0 {
        clearPid()
        clearLock()
        return true
    }
    return false
}

// MARK: - Helpers

private func ensureConfigDir() {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
}
