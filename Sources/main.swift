import CoreAudio
import Foundation
import AVFoundation
import Accelerate

// MARK: - Config & State

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/mic-lock")
let aliasesFile = configDir.appendingPathComponent("aliases.json")
let pidFile = configDir.appendingPathComponent("daemon.pid")
let lockFile = configDir.appendingPathComponent("current.lock")
let priorityFile = configDir.appendingPathComponent("priority.json")
let settingsFile = configDir.appendingPathComponent("settings.json")

// MARK: - Settings

struct Settings: Codable {
    var silenceTimeout: Double  // seconds of silence before fallback
    var silenceThreshold: Float // RMS below this = silence
    var enableSilenceDetection: Bool

    static let defaults = Settings(
        silenceTimeout: 5.0,
        silenceThreshold: 0.00001,  // 10x lower - transmitter OFF is exactly 0.0
        enableSilenceDetection: true
    )
}

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: settingsFile),
          let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
        return Settings.defaults
    }
    return settings
}

func saveSettings(_ settings: Settings) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(settings) {
        try? data.write(to: settingsFile)
    }
}

func loadAliases() -> [String: String] {
    guard let data = try? Data(contentsOf: aliasesFile),
          let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return dict
}

func saveAliases(_ aliases: [String: String]) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(aliases) {
        try? data.write(to: aliasesFile)
    }
}

// MARK: - Daemon Management

func savePid(_ pid: Int32) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
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
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
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
    // Check if process exists
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
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(list) {
        try? data.write(to: priorityFile)
    }
}

/// Find first available AND alive device from priority list
func findBestAvailableDevice(checkAlive: Bool = true) -> (device: AudioInputDevice, query: String)? {
    let priority = loadPriority()
    if priority.isEmpty { return nil }

    let devices = getInputDevices()

    for query in priority {
        let resolved = resolveAlias(query)
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        if matches.count == 1 {
            let device = matches[0]
            // Check if device is actually alive (connected and working)
            if checkAlive && !isDeviceAlive(device.id) {
                continue  // Skip dead devices
            }
            return (device, query)
        }
    }
    return nil
}

// MARK: - CoreAudio Helpers

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

func getInputDevices() -> [AudioInputDevice] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
        return []
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
        return []
    }

    var inputDevices: [AudioInputDevice] = []

    for id in deviceIDs {
        // Check if device has input channels
        var inputChannelsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &inputChannelsAddress, 0, nil, &inputSize) == noErr else { continue }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inputSize))
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(id, &inputChannelsAddress, 0, nil, &inputSize, bufferListPtr) == noErr else { continue }

        let bufferList = bufferListPtr.pointee
        let hasInput = bufferList.mNumberBuffers > 0 && bufferList.mBuffers.mNumberChannels > 0
        guard hasInput else { continue }

        // Get unique ID
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uidString = uid as String? else { continue }

        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let nameString = name as String? else { continue }

        inputDevices.append(AudioInputDevice(id: id, uid: uidString, name: nameString))
    }

    return inputDevices
}

func getDefaultInputDeviceID() -> AudioDeviceID? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &deviceID) == noErr else {
        return nil
    }
    return deviceID
}

func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var mutableDeviceID = deviceID
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &mutableDeviceID
    )

    return status == noErr
}

/// Check if device is alive (has active input signal)
func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isAlive)
    return status == noErr && isAlive == 1
}

/// Check if device is actually running/streaming
func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunning,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isRunning)
    return status == noErr && isRunning == 1
}

func findDevice(matching query: String) -> AudioInputDevice? {
    let devices = getInputDevices()
    let lowercaseQuery = query.lowercased()
    let matches = devices.filter { $0.name.lowercased().contains(lowercaseQuery) }

    if matches.count == 1 {
        return matches[0]
    }
    return nil
}

// MARK: - Event Listener

enum MicLockState {
    case normal           // On primary device, monitoring for silence
    case fallback         // On fallback device, periodically checking primary
    case checkingPrimary  // Temporarily sampling primary to see if it's back
}

class MicLock {
    let targetQuery: String?  // nil = use priority list
    var targetDevice: AudioInputDevice?
    var currentQuery: String?  // Track which priority device we're using

    // State machine
    var state: MicLockState = .normal
    var primaryQuery: String?  // Remember which device we fell back FROM
    var primaryDevice: AudioInputDevice?

    // Audio monitoring for silence detection
    var audioEngine: AVAudioEngine?
    var silenceStartTime: Date?
    var settings: Settings
    var primaryCheckTimer: Timer?

    init(targetQuery: String? = nil) {
        self.targetQuery = targetQuery
        self.settings = loadSettings()
    }

    func start(silent: Bool = false) {
        // Save PID
        savePid(getpid())

        // Handle SIGTERM gracefully
        signal(SIGTERM) { _ in
            clearPid()
            clearLock()
            exit(0)
        }

        // Save lock info
        if let query = targetQuery {
            saveLock(query)
        } else {
            saveLock("priority")  // Mark as using priority mode
        }

        // Find initial target device
        refreshTargetDevice()

        if !silent {
            if let target = targetDevice {
                if targetQuery != nil {
                    print("🎤 Locked to: \(target.name)")
                } else {
                    print("🎤 Using: \(currentQuery ?? target.name) (priority #\(getPriorityIndex() + 1))")
                }
            } else if targetQuery != nil {
                print("⚠ Device '\(targetQuery!)' not connected - waiting...")
            } else {
                print("⚠ No devices from priority list available")
            }
        }

        enforceTarget()

        // Listen for device list changes (connect/disconnect)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            { (_, _, _, clientData) -> OSStatus in
                guard let clientData = clientData else { return noErr }
                let lock = Unmanaged<MicLock>.fromOpaque(clientData).takeUnretainedValue()
                DispatchQueue.main.async {
                    lock.onDevicesChanged()
                }
                return noErr
            },
            selfPtr
        )

        // Listen for default input changes (apps switching the mic)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            { (_, _, _, clientData) -> OSStatus in
                guard let clientData = clientData else { return noErr }
                let lock = Unmanaged<MicLock>.fromOpaque(clientData).takeUnretainedValue()
                DispatchQueue.main.async {
                    lock.onDefaultInputChanged()
                }
                return noErr
            },
            selfPtr
        )

        // Periodic check for device alive status (every 2 seconds)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDeviceAlive()
        }

        // Start silence detection if enabled (priority mode only)
        if targetQuery == nil && settings.enableSilenceDetection {
            startSilenceMonitoring()
        }

        // Keep running
        RunLoop.main.run()
    }

    func startSilenceMonitoring() {
        guard targetDevice != nil else { return }

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            // Silence detection failed, but daemon continues without it
            audioEngine = nil
        }
    }

    func stopSilenceMonitoring() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        silenceStartTime = nil
    }

    var lastDebugPrint = Date()

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        guard state != .checkingPrimary else { return }  // Don't process while checking

        let frameLength = Int(buffer.frameLength)
        let channelDataPtr = channelData[0]

        // Calculate RMS
        var rms: Float = 0
        vDSP_rmsqv(channelDataPtr, 1, &rms, vDSP_Length(frameLength))

        let isSilent = rms < settings.silenceThreshold

        // Debug output every second
        if Date().timeIntervalSince(lastDebugPrint) >= 1.0 {
            lastDebugPrint = Date()
            let status = isSilent ? "🔇" : "🔊"
            let silenceSecs = silenceStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let stateStr = state == .fallback ? " [fallback]" : ""
            print("\r   \(status) RMS: \(String(format: "%.6f", rms)) | Silent: \(silenceSecs)s/\(Int(settings.silenceTimeout))s\(stateStr)    ", terminator: "")
            fflush(stdout)
        }

        if isSilent {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let start = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(start)
                // Only trigger fallback in normal state
                if silenceDuration >= settings.silenceTimeout && state == .normal {
                    DispatchQueue.main.async { [weak self] in
                        self?.transitionToFallback()
                    }
                }
            }
        } else {
            // Signal detected - reset silence timer
            silenceStartTime = nil
        }
    }

    // MARK: - State Transitions

    var skippedDevices: Set<String> = []  // Track devices that failed validation this session

    func transitionToFallback() {
        guard state == .normal else { return }
        guard targetQuery == nil else { return }
        guard let current = targetDevice else { return }

        print("\n🔇 \(currentQuery ?? current.name) silent for \(Int(settings.silenceTimeout))s - transmitter off?")

        // Remember the primary device we're falling back from
        primaryQuery = currentQuery
        primaryDevice = current

        // Stop monitoring
        stopSilenceMonitoring()

        // Find next available device
        tryNextFallbackDevice(startingAfter: current.id)
    }

    func tryNextFallbackDevice(startingAfter deviceId: AudioDeviceID) {
        let priority = loadPriority()
        let devices = getInputDevices()

        // Find position to start searching from
        var startIdx = 0
        if let pQuery = primaryQuery {
            if let idx = priority.firstIndex(of: pQuery) {
                startIdx = idx + 1
            }
        }

        // Find device by ID to get its index
        for (idx, query) in priority.enumerated() {
            if idx < startIdx { continue }

            let resolved = resolveAlias(query)
            let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }

            if matches.count == 1 {
                let device = matches[0]

                // Skip if we already tried and failed this device
                if skippedDevices.contains(query) {
                    continue
                }

                // Skip the device we just came from
                if device.id == deviceId {
                    continue
                }

                print("⬇ Trying fallback: \(query)")

                // Validate this device has actual signal before committing
                validateAndUseFallback(device: device, query: query, fallbackIndex: idx)
                return
            }
        }

        print("⚠ No valid fallback devices available")
        // Stay on current device, restart monitoring
        state = .normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startSilenceMonitoring()
        }
    }

    func validateAndUseFallback(device: AudioInputDevice, query: String, fallbackIndex: Int) {
        state = .checkingPrimary  // Reuse this state to prevent interference

        // Switch to the candidate device
        _ = setDefaultInputDevice(device.id)

        // Sample it briefly to verify it has signal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sampleFallbackCandidate(device: device, query: query, fallbackIndex: fallbackIndex)
        }
    }

    func sampleFallbackCandidate(device: AudioInputDevice, query: String, fallbackIndex: Int) {
        let testEngine = AVAudioEngine()
        let inputNode = testEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        var hasSignal = false

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

            if rms >= (self?.settings.silenceThreshold ?? 0.0001) {
                hasSignal = true
            }
        }

        do {
            try testEngine.start()

            // Sample for 1.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                testEngine.stop()
                inputNode.removeTap(onBus: 0)

                if hasSignal {
                    // This device works! Use it as fallback
                    print("✓ \(query) has signal, using as fallback")
                    self?.commitToFallback(device: device, query: query)
                } else {
                    // This device is also silent/unavailable, try next
                    print("✗ \(query) is silent/unavailable, trying next...")
                    self?.skippedDevices.insert(query)
                    self?.tryNextFallbackDevice(startingAfter: device.id)
                }
            }
        } catch {
            print("✗ Failed to sample \(query), trying next...")
            skippedDevices.insert(query)
            tryNextFallbackDevice(startingAfter: device.id)
        }
    }

    func commitToFallback(device: AudioInputDevice, query: String) {
        state = .fallback
        targetDevice = device
        currentQuery = query
        enforceTarget()

        // Start periodic check for primary device (every 30s)
        startPrimaryCheckTimer()

        // Restart monitoring on fallback device
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startSilenceMonitoring()
        }
    }

    func startPrimaryCheckTimer() {
        primaryCheckTimer?.invalidate()
        primaryCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkPrimaryDevice()
        }
    }

    func stopPrimaryCheckTimer() {
        primaryCheckTimer?.invalidate()
        primaryCheckTimer = nil
    }

    func checkPrimaryDevice() {
        guard state == .fallback else { return }
        guard let pQuery = primaryQuery else { return }

        // Find primary device
        let resolved = resolveAlias(pQuery)
        let devices = getInputDevices()
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        guard matches.count == 1 else { return }
        let pDevice = matches[0]

        print("\n🔍 Checking if \(pQuery) is back...")

        // Enter checking state
        state = .checkingPrimary

        // Stop current monitoring
        stopSilenceMonitoring()

        // Switch to primary to sample it
        _ = setDefaultInputDevice(pDevice.id)

        // Wait for audio routing to settle (USB devices need more time)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.samplePrimaryDevice(pDevice, query: pQuery)
        }
    }

    func samplePrimaryDevice(_ device: AudioInputDevice, query: String) {
        let testEngine = AVAudioEngine()
        let inputNode = testEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        var hasSignal = false
        var sampleCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

            sampleCount += 1
            if rms >= (self?.settings.silenceThreshold ?? 0.0001) {
                hasSignal = true
            }
        }

        do {
            try testEngine.start()

            // Sample for 2 seconds for reliability
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                testEngine.stop()
                inputNode.removeTap(onBus: 0)

                self?.handlePrimarySampleResult(hasSignal: hasSignal, device: device, query: query)
            }
        } catch {
            print("✗ Failed to sample \(query)")
            returnToFallback()
        }
    }

    func handlePrimarySampleResult(hasSignal: Bool, device: AudioInputDevice, query: String) {
        if hasSignal {
            print("✓ \(query) has signal! Switching back...")

            // Transition back to normal state on primary
            state = .normal
            stopPrimaryCheckTimer()
            targetDevice = device
            currentQuery = query
            primaryQuery = nil
            primaryDevice = nil
            silenceStartTime = nil

            enforceTarget()

            // Restart monitoring on primary
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startSilenceMonitoring()
            }
        } else {
            print("✗ \(query) still silent, staying on fallback")
            returnToFallback()
        }
    }

    func returnToFallback() {
        // Go back to the fallback device we were ALREADY using
        // (targetDevice and currentQuery should still be set correctly)
        state = .fallback

        // Verify our fallback device is still available
        guard let fallback = targetDevice else {
            // No fallback device set, re-search
            print("⚠ No fallback device set, searching...")
            tryNextFallbackDevice(startingAfter: primaryDevice?.id ?? 0)
            return
        }

        let devices = getInputDevices()
        if devices.contains(where: { $0.id == fallback.id }) {
            // Fallback still available, use it
            print("↩ Returning to: \(currentQuery ?? fallback.name)")
            enforceTarget()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startSilenceMonitoring()
            }
        } else {
            // Fallback device was disconnected, find a new one
            print("⚠ Fallback device disconnected, searching...")
            tryNextFallbackDevice(startingAfter: primaryDevice?.id ?? 0)
        }
    }

    func checkDeviceAlive() {
        guard targetQuery == nil else { return }  // Only in priority mode
        guard let current = targetDevice else { return }

        if !isDeviceAlive(current.id) {
            print("⚠ \(currentQuery ?? current.name) went inactive")
            refreshTargetDevice()
            if let newTarget = targetDevice, newTarget.id != current.id {
                print("⬇ Falling back to: \(currentQuery ?? newTarget.name)")
                enforceTarget()
            }
        }
    }

    func getPriorityIndex() -> Int {
        guard let current = currentQuery else { return -1 }
        let priority = loadPriority()
        return priority.firstIndex(of: current) ?? -1
    }

    func refreshTargetDevice() {
        if let query = targetQuery {
            // Single device mode
            targetDevice = findDevice(matching: query)
        } else {
            // Priority mode - find best available
            if let (device, query) = findBestAvailableDevice() {
                targetDevice = device
                currentQuery = query
            } else {
                targetDevice = nil
                currentQuery = nil
            }
        }
    }

    func onDevicesChanged() {
        // In fallback or checking state, only react to device disconnection
        if state == .fallback || state == .checkingPrimary {
            guard let current = targetDevice else { return }
            let devices = getInputDevices()
            if !devices.contains(where: { $0.id == current.id }) {
                print("✖ Current device disconnected")
                state = .normal
                stopPrimaryCheckTimer()
                primaryQuery = nil
                primaryDevice = nil
                refreshTargetDevice()
                if targetDevice != nil {
                    enforceTarget()
                    startSilenceMonitoring()
                }
            }
            return
        }

        // Normal state - handle device changes normally
        let previousTarget = targetDevice
        let previousQuery = currentQuery
        refreshTargetDevice()

        if targetQuery == nil {
            // Priority mode - check if we should switch to a higher priority device
            if let current = targetDevice {
                if previousTarget == nil {
                    print("✚ \(currentQuery ?? current.name) connected")
                    enforceTarget()
                    // Restart monitoring on new device
                    stopSilenceMonitoring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startSilenceMonitoring()
                    }
                } else if previousQuery != currentQuery {
                    print("⬆ Switching to higher priority: \(currentQuery ?? current.name)")
                    enforceTarget()
                    // Restart monitoring on new device
                    stopSilenceMonitoring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startSilenceMonitoring()
                    }
                }
            } else if previousTarget != nil {
                print("✖ \(previousQuery ?? previousTarget!.name) disconnected")
            }
        } else {
            // Single device mode
            if previousTarget == nil && targetDevice != nil {
                print("✚ \(targetDevice!.name) connected")
                enforceTarget()
            } else if previousTarget != nil && targetDevice == nil {
                print("✖ \(previousTarget!.name) disconnected")
            }
        }
    }

    func onDefaultInputChanged() {
        guard let currentID = getDefaultInputDeviceID() else { return }

        // In checking state, don't interfere
        if state == .checkingPrimary {
            return
        }

        // In fallback state, keep the fallback device
        if state == .fallback {
            guard let target = targetDevice else { return }
            if currentID != target.id {
                enforceTarget()
            }
            return
        }

        // Normal state
        if targetQuery == nil {
            refreshTargetDevice()
        }

        guard let target = targetDevice else { return }

        if currentID != target.id {
            let currentName = getInputDevices().first { $0.id == currentID }?.name ?? "unknown"
            print("↩ Reverting: \(currentName) → \(target.name)")
            enforceTarget()
        }
    }

    func enforceTarget() {
        // Refresh to handle device ID changes
        if let query = targetQuery {
            guard let target = findDevice(matching: query) else { return }
            targetDevice = target
        } else if targetDevice == nil {
            refreshTargetDevice()
        }

        guard let target = targetDevice else { return }
        guard let currentID = getDefaultInputDeviceID() else { return }

        if currentID != target.id {
            if setDefaultInputDevice(target.id) {
                print("✓ Default input set to: \(target.name)")
            } else {
                print("✗ Failed to set default input device")
            }
        }
    }
}

// MARK: - CLI

let zshCompletion = #"""
_miclock() {
    local -a commands devices aliases

    # Get devices dynamically
    devices=(${(f)"$(miclock list 2>/dev/null | grep -v '^→\|^Available\|^$' | sed 's/^[→ ]*//' | sed 's/^  //')"})

    # Get aliases dynamically
    aliases=(${(f)"$(miclock aliases 2>/dev/null | grep '→' | sed 's/ →.*//' | sed 's/^  //')"})

    commands=(
        'list:List available input devices'
        'status:Show lock status'
        'stop:Stop the background lock'
        'aliases:List all configured aliases'
        'alias:Create or delete an alias'
        'completion:Output shell completion script'
        'help:Show help'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'commands' commands
        _describe -t devices 'input devices' devices
        _describe -t aliases 'aliases' aliases
    elif (( CURRENT == 3 )) && [[ ${words[2]} == "alias" ]]; then
        _describe -t aliases 'aliases' aliases
    elif (( CURRENT == 4 )) && [[ ${words[2]} == "alias" ]]; then
        local -a opts
        opts=('--delete:Remove this alias')
        _describe -t options 'options' opts
        _describe -t devices 'input devices' devices
    elif (( CURRENT == 3 )) && [[ ${words[2]} == "completion" ]]; then
        local -a shells
        shells=('zsh:Zsh completion script')
        _describe -t shells 'shells' shells
    fi
}

compdef _miclock miclock
"""#

func printUsage() {
    print("""
    miclock - Lock macOS to a specific microphone

    Usage:
      miclock <d1> [d2] [d3]...           Set priority & start
      miclock set                         Interactive priority picker
      miclock stop                        Stop
      miclock list                        Pick single device
      miclock alias <name> <device>       Create alias
      miclock aliases                     List aliases

    Examples:
      miclock hollyland                   # hollyland first, then fallback
      miclock hollyland airpods macbook   # explicit chain
      miclock set                         # interactive priority setup

    Config: ~/.config/mic-lock/
    """)
}

func showPriority() {
    let priority = loadPriority()
    if priority.isEmpty {
        print("No priority configured. Use: miclock <device> or miclock set")
        return
    }

    let devices = getInputDevices()
    let currentID = getDefaultInputDeviceID()

    print("Priority:\n")
    for (i, query) in priority.enumerated() {
        let resolved = resolveAlias(query)
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        let available = matches.count == 1
        let isCurrent = available && matches[0].id == currentID

        let marker = isCurrent ? "→" : " "
        let status = available ? "✓" : "✗"
        let display = query == resolved ? query : "\(query) (\(resolved))"

        print("\(marker) \(i + 1). \(display) [\(status)]")
    }
}

func interactivePriorityPicker() {
    let devices = getInputDevices()
    let aliases = loadAliases()
    let currentID = getDefaultInputDeviceID()

    // Build reverse alias lookup
    var deviceToAlias: [String: String] = [:]
    for (alias, deviceName) in aliases {
        for device in devices {
            if device.name.lowercased().contains(deviceName.lowercased()) {
                deviceToAlias[device.name] = alias
            }
        }
    }

    if devices.isEmpty {
        print("No input devices found.")
        return
    }

    var selected = 0
    var priorityOrder: [Int] = []  // indices of selected devices in order

    // Pre-select current default
    for (i, d) in devices.enumerated() {
        if d.id == currentID {
            selected = i
            break
        }
    }

    let originalTerm = enableRawMode()
    defer { disableRawMode(originalTerm) }

    print("\u{001B}[?25l", terminator: "")  // Hide cursor

    func render() {
        print("\u{001B}[H\u{001B}[J", terminator: "")  // Clear
        print("Set priority order (↑/↓ Space=add Enter=done q=cancel)\n")

        // Show current priority chain
        if priorityOrder.isEmpty {
            print("Priority: (none selected)\n")
        } else {
            let chain = priorityOrder.map { i -> String in
                let device = devices[i]
                return deviceToAlias[device.name] ?? device.name
            }.joined(separator: " → ")
            print("Priority: \(chain)\n")
        }

        for (i, device) in devices.enumerated() {
            let current = device.id == currentID ? "→" : " "
            let cursor = i == selected ? "▸" : " "
            let highlight = i == selected ? "\u{001B}[7m" : ""
            let reset = i == selected ? "\u{001B}[0m" : ""

            // Show position in priority if selected
            let position: String
            if let pos = priorityOrder.firstIndex(of: i) {
                position = "[\(pos + 1)]"
            } else {
                position = "   "
            }

            let displayName = deviceToAlias[device.name] ?? device.name
            print("\(current) \(cursor) \(position) \(highlight) \(displayName) \(reset)")
        }
        print("\nSpace=toggle Enter=save q=cancel")
        fflush(stdout)
    }

    render()

    while true {
        let key = readKey()

        switch key {
        case "UP", "k":
            selected = (selected - 1 + devices.count) % devices.count
            render()
        case "DOWN", "j":
            selected = (selected + 1) % devices.count
            render()
        case " ":
            // Toggle selection
            if let pos = priorityOrder.firstIndex(of: selected) {
                priorityOrder.remove(at: pos)
            } else {
                priorityOrder.append(selected)
            }
            render()
        case "\r", "\n":
            print("\u{001B}[?25h\u{001B}[H\u{001B}[J", terminator: "")
            disableRawMode(originalTerm)

            if priorityOrder.isEmpty {
                print("No devices selected.")
                return
            }

            // Build priority list using aliases where available
            let priorityList = priorityOrder.map { i -> String in
                let device = devices[i]
                return deviceToAlias[device.name] ?? device.name
            }

            savePriority(priorityList)

            // Stop existing daemon
            if isDaemonRunning() {
                _ = stopDaemon()
            }

            // Start daemon
            let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["--daemon-priority"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
                usleep(100_000)
                print("🎤 " + priorityList.joined(separator: " → ") + " ✓")
            } catch {
                print("✗ Failed: \(error)")
            }
            return

        case "q", "\u{1B}":
            print("\u{001B}[?25h\u{001B}[H\u{001B}[J", terminator: "")
            print("Cancelled")
            return

        default:
            break
        }
    }
}

func showStatus() {
    let devices = getInputDevices()
    let aliases = loadAliases()

    // Current default
    print("Current: ", terminator: "")
    if let currentID = getDefaultInputDeviceID(),
       let current = devices.first(where: { $0.id == currentID }) {
        var deviceAlias: String? = nil
        for (alias, deviceName) in aliases {
            if current.name.lowercased().contains(deviceName.lowercased()) {
                deviceAlias = alias
                break
            }
        }
        if let alias = deviceAlias {
            print("\(alias) (\(current.name))")
        } else {
            print(current.name)
        }
    } else {
        print("None")
    }

    // Lock status
    if isDaemonRunning() {
        let priority = loadPriority()
        if !priority.isEmpty {
            print("Priority: " + priority.joined(separator: " → "))
        }
    } else {
        print("Locked:  No")
        clearPid()
        clearLock()
    }
}

func listAliases() {
    let aliases = loadAliases()
    if aliases.isEmpty {
        print("No aliases configured.")
        print("Use: miclock alias <name> <device>")
        return
    }
    print("Configured aliases:\n")
    for (alias, device) in aliases.sorted(by: { $0.key < $1.key }) {
        print("  \(alias) → \(device)")
    }
}

func setAlias(name: String, device: String) {
    var aliases = loadAliases()
    aliases[name.lowercased()] = device
    saveAliases(aliases)
    print("✓ Alias set: \(name) → \(device)")
}

func deleteAlias(name: String) {
    var aliases = loadAliases()
    if aliases.removeValue(forKey: name.lowercased()) != nil {
        saveAliases(aliases)
        print("✓ Alias '\(name)' removed")
    } else {
        print("✗ Alias '\(name)' not found")
    }
}

// MARK: - Interactive Picker

func enableRawMode() -> termios {
    var raw = termios()
    tcgetattr(STDIN_FILENO, &raw)
    let original = raw
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    return original
}

func disableRawMode(_ original: termios) {
    var term = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
}

func readKey() -> String {
    var buf = [UInt8](repeating: 0, count: 3)
    let n = read(STDIN_FILENO, &buf, 3)
    if n == 1 {
        return String(UnicodeScalar(buf[0]))
    } else if n == 3 && buf[0] == 27 && buf[1] == 91 {
        switch buf[2] {
        case 65: return "UP"
        case 66: return "DOWN"
        default: return ""
        }
    }
    return ""
}

func listDevices(interactive: Bool = false) {
    let devices = getInputDevices()
    let currentID = getDefaultInputDeviceID()
    let aliases = loadAliases()

    // Reverse lookup: device name -> alias
    var deviceToAlias: [String: String] = [:]
    for (alias, deviceName) in aliases {
        for device in devices {
            if device.name.lowercased().contains(deviceName.lowercased()) {
                deviceToAlias[device.name] = alias
            }
        }
    }

    if devices.isEmpty {
        print("No input devices found.")
        return
    }

    if !interactive {
        print("Available input devices:\n")
        for (index, device) in devices.enumerated() {
            let marker = device.id == currentID ? "→" : " "
            let num = "\(index + 1))".padding(toLength: 3, withPad: " ", startingAt: 0)
            if let alias = deviceToAlias[device.name] {
                print("\(marker) \(num) \(alias) (\(device.name))")
            } else {
                print("\(marker) \(num) \(device.name)")
            }
        }
        print("\n→ = current default")
        return
    }

    // Interactive mode with arrow keys
    var selected = 0
    // Find currently active device
    for (i, d) in devices.enumerated() {
        if d.id == currentID {
            selected = i
            break
        }
    }

    let originalTerm = enableRawMode()
    defer { disableRawMode(originalTerm) }

    // Hide cursor
    print("\u{001B}[?25l", terminator: "")

    func render() {
        // Move cursor to start and clear
        print("\u{001B}[H\u{001B}[J", terminator: "")
        print("Select input device (↑/↓ Enter q)\n")

        for (i, device) in devices.enumerated() {
            let current = device.id == currentID ? "→" : " "
            let cursor = i == selected ? "▸" : " "
            let highlight = i == selected ? "\u{001B}[7m" : ""  // Reverse video
            let reset = i == selected ? "\u{001B}[0m" : ""

            if let alias = deviceToAlias[device.name] {
                print("\(current) \(cursor) \(highlight) \(alias) (\(device.name)) \(reset)")
            } else {
                print("\(current) \(cursor) \(highlight) \(device.name) \(reset)")
            }
        }
        print("\n→ = current default")
        fflush(stdout)
    }

    render()

    while true {
        let key = readKey()

        switch key {
        case "UP", "k":
            selected = (selected - 1 + devices.count) % devices.count
            render()
        case "DOWN", "j":
            selected = (selected + 1) % devices.count
            render()
        case "\r", "\n", " ":
            // Show cursor and clear screen
            print("\u{001B}[?25h\u{001B}[H\u{001B}[J", terminator: "")
            disableRawMode(originalTerm)

            let device = devices[selected]
            let query = deviceToAlias[device.name] ?? device.name

            // Stop existing daemon
            if isDaemonRunning() {
                _ = stopDaemon()
            }

            // Start new lock
            let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["--daemon", query]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
                usleep(100_000)
                if let alias = deviceToAlias[device.name] {
                    print("🎤 \(alias) → \(device.name) ✓")
                } else {
                    print("🎤 \(device.name) ✓")
                }
            } catch {
                print("✗ Failed: \(error)")
            }
            return

        case "q", "\u{1B}":  // q or Escape
            print("\u{001B}[?25h\u{001B}[H\u{001B}[J", terminator: "")
            return

        default:
            break
        }
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    showStatus()
    print("")
    printUsage()
    exit(0)
}

switch args[0].lowercased() {
case "list", "ls", "-l":
    // Interactive if terminal, non-interactive if piped
    let isInteractive = isatty(STDOUT_FILENO) != 0
    listDevices(interactive: isInteractive)

case "status":
    showStatus()

case "set":
    interactivePriorityPicker()

case "stop":
    if isDaemonRunning() {
        if stopDaemon() {
            print("✓ Stopped")
        } else {
            print("✗ Failed to stop")
            exit(1)
        }
    } else {
        print("Not running")
    }

case "aliases":
    listAliases()

case "config":
    let settings = loadSettings()
    if args.count < 2 {
        // Show current config
        print("Settings (~/.config/mic-lock/settings.json):\n")
        print("  silenceTimeout:        \(settings.silenceTimeout)s")
        print("  silenceThreshold:      \(settings.silenceThreshold)")
        print("  enableSilenceDetection: \(settings.enableSilenceDetection)")
        print("")
        print("Usage:")
        print("  miclock config timeout <seconds>    Set silence timeout")
        print("  miclock config threshold <value>    Set silence threshold")
        print("  miclock config detection <on|off>   Enable/disable silence detection")
    } else {
        var newSettings = settings
        switch args[1].lowercased() {
        case "timeout":
            if args.count < 3 {
                print("Current: \(settings.silenceTimeout)s")
                print("Usage: miclock config timeout <seconds>")
            } else if let value = Double(args[2]) {
                newSettings.silenceTimeout = value
                saveSettings(newSettings)
                print("✓ Silence timeout set to \(value)s")
            } else {
                print("✗ Invalid value. Use a number (e.g., 10)")
            }
        case "threshold":
            if args.count < 3 {
                print("Current: \(settings.silenceThreshold)")
                print("Usage: miclock config threshold <value>")
            } else if let value = Float(args[2]) {
                newSettings.silenceThreshold = value
                saveSettings(newSettings)
                print("✓ Silence threshold set to \(value)")
            } else {
                print("✗ Invalid value. Use a number (e.g., 0.0001)")
            }
        case "detection":
            if args.count < 3 {
                print("Current: \(settings.enableSilenceDetection ? "on" : "off")")
                print("Usage: miclock config detection <on|off>")
            } else {
                let value = args[2].lowercased()
                if value == "on" || value == "true" || value == "1" {
                    newSettings.enableSilenceDetection = true
                    saveSettings(newSettings)
                    print("✓ Silence detection enabled")
                } else if value == "off" || value == "false" || value == "0" {
                    newSettings.enableSilenceDetection = false
                    saveSettings(newSettings)
                    print("✓ Silence detection disabled")
                } else {
                    print("✗ Invalid value. Use 'on' or 'off'")
                }
            }
        default:
            print("Unknown config option: \(args[1])")
            print("Options: timeout, threshold, detection")
        }
    }

case "alias":
    if args.count < 2 {
        print("Usage: miclock alias <name> <device>")
        print("       miclock alias <name> --delete")
        exit(1)
    }
    let aliasName = args[1]
    if args.count == 2 {
        // Show single alias
        let aliases = loadAliases()
        if let device = aliases[aliasName.lowercased()] {
            print("\(aliasName) → \(device)")
        } else {
            print("Alias '\(aliasName)' not found")
        }
    } else if args[2] == "--delete" || args[2] == "-d" {
        deleteAlias(name: aliasName)
    } else {
        let deviceName = args.dropFirst(2).joined(separator: " ")
        setAlias(name: aliasName, device: deviceName)
    }

case "completion":
    let shell = args.count > 1 ? args[1] : "zsh"
    if shell == "zsh" {
        print(zshCompletion)
    } else {
        print("Only zsh completion is supported")
        exit(1)
    }

case "--daemon":
    // Internal: run as daemon for single device
    if args.count < 2 {
        exit(1)
    }
    let query = args.dropFirst().joined(separator: " ")
    let lock = MicLock(targetQuery: query)
    lock.start(silent: true)

case "--daemon-priority":
    // Internal: run as daemon using priority list
    let lock = MicLock(targetQuery: nil)  // nil = priority mode
    lock.start(silent: true)

case "watch":
    // Run in foreground with visible output (for debugging silence detection)
    if isDaemonRunning() {
        _ = stopDaemon()
    }

    print("👀 Watch mode (foreground) - Ctrl+C to stop")
    print("   Silence detection: \(loadSettings().enableSilenceDetection ? "ON" : "OFF")")
    print("   Timeout: \(loadSettings().silenceTimeout)s")
    print("")

    let lock = MicLock(targetQuery: nil)
    lock.start(silent: false)

case "inspect":
    // Inspect all properties of a device
    if args.count < 2 {
        print("Usage: miclock inspect <device>")
        exit(1)
    }
    let rawQuery = args.dropFirst().joined(separator: " ")
    let query = resolveAlias(rawQuery)
    let devices = getInputDevices()
    let matches = devices.filter { $0.name.lowercased().contains(query.lowercased()) }

    if matches.isEmpty {
        print("No device found matching '\(query)'")
        exit(1)
    }

    let device = matches[0]
    print("🔍 Inspecting: \(device.name)")
    print("   ID: \(device.id)")
    print("   UID: \(device.uid)")
    print("")

    // Check various properties
    print("   Properties:")

    // IsAlive
    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isAlive) == noErr {
        print("   - IsAlive: \(isAlive == 1 ? "Yes" : "No")")
    }

    // IsRunning (global)
    var isRunning: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyDeviceIsRunning
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isRunning) == noErr {
        print("   - IsRunning (global): \(isRunning == 1 ? "Yes" : "No")")
    }

    // IsRunning (input scope)
    addr.mScope = kAudioObjectPropertyScopeInput
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isRunning) == noErr {
        print("   - IsRunning (input): \(isRunning == 1 ? "Yes" : "No")")
    }

    // IsRunningSomewhere
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    addr.mScope = kAudioObjectPropertyScopeGlobal
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isRunning) == noErr {
        print("   - IsRunningSomewhere: \(isRunning == 1 ? "Yes" : "No")")
    }

    // TransportType
    var transportType: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyTransportType
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &transportType) == noErr {
        let type: String
        switch transportType {
        case kAudioDeviceTransportTypeUSB: type = "USB"
        case kAudioDeviceTransportTypeBluetooth: type = "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: type = "Built-in"
        case kAudioDeviceTransportTypeVirtual: type = "Virtual"
        default: type = "Unknown (\(transportType))"
        }
        print("   - TransportType: \(type)")
    }

    // Jack connected (for devices that support it)
    var jackConnected: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyJackIsConnected
    addr.mScope = kAudioObjectPropertyScopeInput
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &jackConnected) == noErr {
        print("   - JackConnected (input): \(jackConnected == 1 ? "Yes" : "No")")
    }

    // DataSource
    var dataSource: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyDataSource
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &dataSource) == noErr {
        print("   - DataSource: \(dataSource)")
    }

    // Input volume/level
    var volume: Float32 = 0
    var volSize = UInt32(MemoryLayout<Float32>.size)
    addr.mSelector = kAudioDevicePropertyVolumeScalar
    addr.mScope = kAudioObjectPropertyScopeInput
    addr.mElement = kAudioObjectPropertyElementMain
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &volSize, &volume) == noErr {
        print("   - InputVolume: \(volume)")
    }

    // Clock domain
    var clockDomain: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyClockDomain
    addr.mScope = kAudioObjectPropertyScopeGlobal
    addr.mElement = kAudioObjectPropertyElementMain
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &clockDomain) == noErr {
        print("   - ClockDomain: \(clockDomain)")
    }

    // Clock source
    var clockSource: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyClockSource
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &clockSource) == noErr {
        print("   - ClockSource: \(clockSource)")
    }

    // Nominal sample rate
    var sampleRate: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    addr.mSelector = kAudioDevicePropertyNominalSampleRate
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &srSize, &sampleRate) == noErr {
        print("   - NominalSampleRate: \(sampleRate)")
    }

    // Actual sample rate
    addr.mSelector = kAudioDevicePropertyActualSampleRate
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &srSize, &sampleRate) == noErr {
        print("   - ActualSampleRate: \(sampleRate)")
    }

    // Check streams
    addr.mSelector = kAudioDevicePropertyStreams
    addr.mScope = kAudioObjectPropertyScopeInput
    addr.mElement = kAudioObjectPropertyElementMain
    var streamSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(device.id, &addr, 0, nil, &streamSize) == noErr {
        let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
        print("   - InputStreams: \(streamCount)")

        if streamCount > 0 {
            var streams = [AudioStreamID](repeating: 0, count: streamCount)
            if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &streamSize, &streams) == noErr {
                for (i, streamID) in streams.enumerated() {
                    var streamActive: UInt32 = 0
                    var streamAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioStreamPropertyIsActive,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var activeSize = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(streamID, &streamAddr, 0, nil, &activeSize, &streamActive) == noErr {
                        print("     Stream \(i): active=\(streamActive == 1)")
                    }

                    // Stream physical format
                    var format = AudioStreamBasicDescription()
                    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    streamAddr.mSelector = kAudioStreamPropertyPhysicalFormat
                    if AudioObjectGetPropertyData(streamID, &streamAddr, 0, nil, &formatSize, &format) == noErr {
                        print("     Stream \(i): sampleRate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame)")
                    }
                }
            }
        }
    }

    print("")
    print("   Run 'miclock inspect <device>' again with mic on/off to compare")

case "rms":
    // Measure RMS audio level from a device to detect digital silence
    if args.count < 2 {
        print("Usage: miclock rms <device>")
        print("Samples audio input and displays RMS level to detect transmitter state")
        exit(1)
    }
    let rawQuery = args.dropFirst().joined(separator: " ")
    let query = resolveAlias(rawQuery)
    let devices = getInputDevices()
    let matches = devices.filter { $0.name.lowercased().contains(query.lowercased()) }

    if matches.isEmpty {
        print("No device found matching '\(query)'")
        exit(1)
    }

    let targetDevice = matches[0]
    print("🎤 Sampling: \(targetDevice.name)")
    print("   Press Ctrl+C to stop\n")

    // Set this device as default input temporarily
    let originalDefault = getDefaultInputDeviceID()
    _ = setDefaultInputDevice(targetDevice.id)

    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)

    print("   Format: \(format.sampleRate)Hz, \(format.channelCount) channels\n")

    var sampleCount = 0
    var silentSamples = 0
    let silenceThreshold: Float = 0.0001  // Below this = digital silence

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelDataPtr = channelData[0]

        // Calculate RMS using Accelerate
        var rms: Float = 0
        vDSP_rmsqv(channelDataPtr, 1, &rms, vDSP_Length(frameLength))

        // Also get peak
        var peak: Float = 0
        vDSP_maxmgv(channelDataPtr, 1, &peak, vDSP_Length(frameLength))

        sampleCount += 1

        let isSilent = rms < silenceThreshold
        if isSilent { silentSamples += 1 }

        let status = isSilent ? "🔇 SILENT" : "🔊 SIGNAL"
        let bar = String(repeating: "█", count: min(50, Int(rms * 5000)))

        print("\r   [\(sampleCount)] RMS: \(String(format: "%.6f", rms)) | Peak: \(String(format: "%.6f", peak)) | \(status) \(bar)     ", terminator: "")
        fflush(stdout)
    }

    do {
        try audioEngine.start()
        print("   Listening for 5 seconds...\n")

        // Run for 5 seconds then stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)

            print("\n\n   Summary:")
            print("   - Total samples: \(sampleCount)")
            print("   - Silent samples: \(silentSamples)")
            if sampleCount > 0 {
                let silentPercent = Double(silentSamples) / Double(sampleCount) * 100
                print("   - Silent ratio: \(String(format: "%.1f", silentPercent))%")
                if silentPercent > 95 {
                    print("   → Transmitter likely OFF (digital silence)")
                } else {
                    print("   → Transmitter likely ON (noise floor detected)")
                }
            }

            if let orig = originalDefault {
                _ = setDefaultInputDevice(orig)
            }
            exit(0)
        }

        RunLoop.main.run()
    } catch {
        print("   ✗ Failed to start audio engine: \(error)")
        if let orig = originalDefault {
            _ = setDefaultInputDevice(orig)
        }
        exit(1)
    }

case "debug":
    // Run in foreground with full output for debugging
    if args.count < 2 {
        print("Usage: miclock debug <device>")
        exit(1)
    }
    let rawQuery = args.dropFirst().joined(separator: " ")
    let query = resolveAlias(rawQuery)

    print("🔍 Debug mode")
    print("   Query: '\(rawQuery)' → '\(query)'")

    let devices = getInputDevices()
    print("   Available devices:")
    for d in devices {
        print("      - \(d.name) (ID: \(d.id))")
    }

    let matches = devices.filter { $0.name.lowercased().contains(query.lowercased()) }
    print("   Matches for '\(query)': \(matches.count)")
    for m in matches {
        print("      - \(m.name) (ID: \(m.id))")
    }

    if matches.count != 1 {
        print("   ⚠️  Need exactly 1 match, got \(matches.count)")
        exit(1)
    }

    let target = matches[0]
    print("   Target: \(target.name) (ID: \(target.id))")

    if let currentID = getDefaultInputDeviceID() {
        print("   Current default ID: \(currentID)")
        if currentID == target.id {
            print("   ✓ Already set to target")
        } else {
            print("   Attempting to set default...")
            if setDefaultInputDevice(target.id) {
                print("   ✓ setDefaultInputDevice returned success")
                // Verify
                if let newID = getDefaultInputDeviceID() {
                    print("   New default ID: \(newID)")
                    if newID == target.id {
                        print("   ✓ Verified: default is now target")
                    } else {
                        print("   ✗ FAILED: default is still \(newID), not \(target.id)")
                    }
                }
            } else {
                print("   ✗ setDefaultInputDevice returned failure")
            }
        }
    }

    print("\n   Running listener (Ctrl+C to stop)...")
    let lock = MicLock(targetQuery: query)
    lock.start(silent: false)

case "-h", "--help", "help":
    printUsage()

default:
    // All arguments are devices for priority chain
    let priorityList = args

    // Validate each device exists or is an alias
    let devices = getInputDevices()
    for query in priorityList {
        let resolved = resolveAlias(query)
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        if matches.count > 1 {
            print("'\(query)' matches multiple devices:")
            for m in matches { print("  - \(m.name)") }
            print("Be more specific.")
            exit(1)
        }
    }

    // Save priority list
    savePriority(priorityList)

    // Stop existing daemon
    if isDaemonRunning() {
        _ = stopDaemon()
    }

    // Spawn priority daemon
    let execPath: String
    if let resolvedPath = Bundle.main.executablePath {
        execPath = resolvedPath
    } else {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            execPath = arg0
        } else {
            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            var found = arg0
            for dir in pathDirs {
                let candidate = "\(dir)/\(arg0)"
                if FileManager.default.fileExists(atPath: candidate) {
                    found = candidate
                    break
                }
            }
            execPath = found
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = ["--daemon-priority"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
        usleep(100_000)

        if let (device, query) = findBestAvailableDevice() {
            let resolved = resolveAlias(query)
            if query != resolved {
                print("🎤 \(query) (\(device.name)) ✓")
            } else {
                print("🎤 \(device.name) ✓")
            }
        } else {
            print("🎤 Waiting for devices...")
        }
    } catch {
        print("✗ Failed: \(error)")
        exit(1)
    }
}
