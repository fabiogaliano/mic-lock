import CoreAudio
import Foundation
import Rainbow

// MARK: - State

enum MicLockState {
    case normal           // On primary device, monitoring for silence
    case fallback         // On fallback device, periodically checking primary
    case checkingPrimary  // Temporarily sampling primary to see if it's back
}

// MARK: - MicLock

class MicLock {
    // Configuration
    let targetQuery: String?  // nil = use priority list
    var settings: Settings

    // Current state
    private(set) var state: MicLockState = .normal
    var targetDevice: AudioInputDevice?
    var currentQuery: String?

    // Primary device (when in fallback)
    private var primaryQuery: String?
    private var primaryDevice: AudioInputDevice?

    // Audio monitoring
    private var monitor: AudioMonitor?
    private var silenceStartTime: Date?
    private var lastDebugPrint = Date()

    // Intermittent sampling
    private var sampleTimer: Timer?
    private var windowEndTimer: Timer?
    private var accumulatedSilence: TimeInterval = 0
    private var windowHadSignal = false

    // Timers
    private var primaryCheckTimer: Timer?
    private var skippedDevices: Set<String> = []

    // Output control
    var silent: Bool = false

    init(targetQuery: String? = nil) {
        self.targetQuery = targetQuery
        self.settings = loadSettings()
    }

    // MARK: - Lifecycle

    func start(silent: Bool = false) {
        self.silent = silent
        savePid(getpid())

        signal(SIGTERM) { _ in
            clearPid()
            clearLock()
            exit(0)
        }

        if let query = targetQuery {
            saveLock(query)
        } else {
            saveLock("priority")
        }

        refreshTargetDevice()

        if !silent {
            if let target = targetDevice {
                if targetQuery != nil {
                    printInfo("Locked: " + target.name.accent)
                } else {
                    printInfo("Using: " + (currentQuery ?? target.name).accent + " (priority #\(getPriorityIndex() + 1))".dim)
                }
            } else if targetQuery != nil {
                printWarning("'\(targetQuery!)' not connected")
            } else {
                printWarning("No priority devices available")
            }
        }

        enforceTarget()
        registerListeners()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDeviceAlive()
        }

        if targetQuery == nil && settings.enableSilenceDetection {
            startSilenceMonitoring()
        }

        RunLoop.main.run()
    }

    // MARK: - Listeners

    private func registerListeners() {
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
                DispatchQueue.main.async { lock.onDevicesChanged() }
                return noErr
            },
            selfPtr
        )

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
                DispatchQueue.main.async { lock.onDefaultInputChanged() }
                return noErr
            },
            selfPtr
        )
    }

    // MARK: - Intermittent Silence Monitoring

    func startSilenceMonitoring() {
        guard targetDevice != nil else { return }

        accumulatedSilence = 0
        windowHadSignal = false

        // Schedule sample windows
        scheduleSampleWindow()
    }

    func stopSilenceMonitoring() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        windowEndTimer?.invalidate()
        windowEndTimer = nil
        monitor?.stop()
        monitor = nil
        silenceStartTime = nil
        accumulatedSilence = 0
    }

    /// Schedules sample windows at regular intervals
    private func scheduleSampleWindow() {
        let interval = settings.sampleInterval

        // Run first sample immediately
        runSampleWindow()

        // Schedule repeating timer for subsequent samples
        sampleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.runSampleWindow()
        }
    }

    /// Runs a single sample window
    private func runSampleWindow() {
        guard state != .checkingPrimary else { return }

        let duration = settings.sampleDuration
        windowHadSignal = false

        // Start monitoring for this window
        monitor = AudioMonitor()
        monitor?.onSample = { [weak self] rms in
            self?.processRMS(rms)
        }
        monitor?.start()

        if !silent {
            print("\r   " + "▶ Sampling".cyan + "...    ", terminator: "")
            fflush(stdout)
        }

        // Schedule end of sample window
        windowEndTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.endSampleWindow()
        }
    }

    /// Called when sample window ends
    private func endSampleWindow() {
        monitor?.stop()
        monitor = nil

        guard state != .checkingPrimary else { return }

        let duration = settings.sampleDuration

        if windowHadSignal {
            // Signal detected - reset silence accumulator
            if accumulatedSilence > 0 {
                accumulatedSilence = 0
                if !silent {
                    print("\r   " + Sym.check.green + " Signal restored".dim + "         ")
                }
            }
        } else {
            // All samples were silent - accumulate silence time
            accumulatedSilence += duration

            if !silent {
                let stateStr = state == .fallback ? " [fallback]".dim : ""
                print("\r   " + Sym.silent + " Silence: ".dim + "\(Int(accumulatedSilence))s".yellow + "/\(Int(settings.silenceTimeout))s".dim + stateStr + "    ", terminator: "")
                fflush(stdout)
            }

            // Check if we should trigger fallback
            if accumulatedSilence >= settings.silenceTimeout && state == .normal {
                DispatchQueue.main.async { [weak self] in
                    self?.transitionToFallback()
                }
            }
        }
    }

    private func processRMS(_ rms: Float) {
        guard state != .checkingPrimary else { return }

        let isSilent = rms < settings.silenceThreshold

        // Track if any signal was detected in this window
        if !isSilent {
            windowHadSignal = true
        }

        // Debug output (throttled)
        if !silent && Date().timeIntervalSince(lastDebugPrint) >= 0.2 {
            lastDebugPrint = Date()
            let rmsDisplay = formatRMS(rms, threshold: settings.silenceThreshold)
            let stateStr = state == .fallback ? " [fallback]".dim : ""
            print("\r   \(rmsDisplay)\(stateStr)    ", terminator: "")
            fflush(stdout)
        }
    }

    // MARK: - State Transitions

    private func transitionToFallback() {
        guard state == .normal else { return }
        guard targetQuery == nil else { return }
        guard let current = targetDevice else { return }

        if !silent {
            print("\n" + Sym.silent + " " + (currentQuery ?? current.name).accent + " silent for \(Int(settings.silenceTimeout))s".dim)
        }

        primaryQuery = currentQuery
        primaryDevice = current
        stopSilenceMonitoring()
        tryNextFallbackDevice(startingAfter: current.id)
    }

    private func tryNextFallbackDevice(startingAfter deviceId: AudioDeviceID) {
        let priority = loadPriority()
        let devices = getInputDevices()

        var startIdx = 0
        if let pQuery = primaryQuery {
            if let idx = priority.firstIndex(of: pQuery) {
                startIdx = idx + 1
            }
        }

        for (idx, query) in priority.enumerated() {
            if idx < startIdx { continue }

            let resolved = resolveAlias(query)
            let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }

            if matches.count == 1 {
                let device = matches[0]

                if skippedDevices.contains(query) { continue }
                if device.id == deviceId { continue }

                if !silent { print(Sym.arrowDown + " Fallback: ".dim + query.accent) }

                validateAndUseFallback(device: device, query: query, fallbackIndex: idx)
                return
            }
        }

        if !silent { printWarning("No valid fallback devices") }
        state = .normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startSilenceMonitoring()
        }
    }

    private func validateAndUseFallback(device: AudioInputDevice, query: String, fallbackIndex: Int) {
        state = .checkingPrimary

        _ = setDefaultInputDevice(device.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sampleFallbackCandidate(device: device, query: query, fallbackIndex: fallbackIndex)
        }
    }

    private func sampleFallbackCandidate(device: AudioInputDevice, query: String, fallbackIndex: Int) {
        sampleAudio(duration: 1.5, threshold: settings.silenceThreshold) { [weak self] hasSignal in
            guard let self = self else { return }

            if hasSignal {
                if !self.silent { printSuccess("\(query) has signal") }
                self.commitToFallback(device: device, query: query)
            } else {
                if !self.silent { printError("\(query) silent, trying next...") }
                self.skippedDevices.insert(query)
                self.tryNextFallbackDevice(startingAfter: device.id)
            }
        }
    }

    private func commitToFallback(device: AudioInputDevice, query: String) {
        state = .fallback
        targetDevice = device
        currentQuery = query
        enforceTarget()

        startPrimaryCheckTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startSilenceMonitoring()
        }
    }

    private func startPrimaryCheckTimer() {
        primaryCheckTimer?.invalidate()
        primaryCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkPrimaryDevice()
        }
    }

    private func stopPrimaryCheckTimer() {
        primaryCheckTimer?.invalidate()
        primaryCheckTimer = nil
    }

    private func checkPrimaryDevice() {
        guard state == .fallback else { return }
        guard let pQuery = primaryQuery else { return }

        let resolved = resolveAlias(pQuery)
        let devices = getInputDevices()
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        guard matches.count == 1 else { return }
        let pDevice = matches[0]

        if !silent { print("\n" + Sym.question + " Checking ".dim + pQuery.accent + "...".dim) }

        state = .checkingPrimary
        stopSilenceMonitoring()

        _ = setDefaultInputDevice(pDevice.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.samplePrimaryDevice(pDevice, query: pQuery)
        }
    }

    private func samplePrimaryDevice(_ device: AudioInputDevice, query: String) {
        sampleAudio(duration: 2.0, threshold: settings.silenceThreshold) { [weak self] hasSignal in
            guard let self = self else { return }

            if hasSignal {
                if !self.silent { printSuccess("\(query) has signal!") }

                self.state = .normal
                self.stopPrimaryCheckTimer()
                self.targetDevice = device
                self.currentQuery = query
                self.primaryQuery = nil
                self.primaryDevice = nil
                self.silenceStartTime = nil

                self.enforceTarget()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startSilenceMonitoring()
                }
            } else {
                if !self.silent { printError("\(query) still silent") }
                self.returnToFallback()
            }
        }
    }

    private func returnToFallback() {
        state = .fallback

        guard let fallback = targetDevice else {
            if !silent { printWarning("No fallback set, searching...") }
            tryNextFallbackDevice(startingAfter: primaryDevice?.id ?? 0)
            return
        }

        let devices = getInputDevices()
        if devices.contains(where: { $0.id == fallback.id }) {
            if !silent { print(Sym.arrowLeft + " Returning to: ".dim + (currentQuery ?? fallback.name).accent) }
            enforceTarget()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startSilenceMonitoring()
            }
        } else {
            if !silent { printWarning("Fallback disconnected, searching...") }
            tryNextFallbackDevice(startingAfter: primaryDevice?.id ?? 0)
        }
    }

    // MARK: - Device Events

    private func checkDeviceAlive() {
        guard targetQuery == nil else { return }
        guard let current = targetDevice else { return }

        if !isDeviceAlive(current.id) {
            if !silent { printWarning("\(currentQuery ?? current.name) inactive") }
            refreshTargetDevice()
            if let newTarget = targetDevice, newTarget.id != current.id {
                if !silent { print(Sym.arrowDown + " Fallback: ".dim + (currentQuery ?? newTarget.name).accent) }
                enforceTarget()
            }
        }
    }

    private func onDevicesChanged() {
        if state == .fallback || state == .checkingPrimary {
            guard let current = targetDevice else { return }
            let devices = getInputDevices()
            if !devices.contains(where: { $0.id == current.id }) {
                if !silent { print(Sym.minus + " Device disconnected".dim) }
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

        let previousTarget = targetDevice
        let previousQuery = currentQuery
        refreshTargetDevice()

        if targetQuery == nil {
            if let current = targetDevice {
                if previousTarget == nil {
                    if !silent { print(Sym.plus + " " + (currentQuery ?? current.name).accent + " connected".dim) }
                    enforceTarget()
                    stopSilenceMonitoring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startSilenceMonitoring()
                    }
                } else if previousQuery != currentQuery {
                    if !silent { print(Sym.arrowUp + " Priority: ".dim + (currentQuery ?? current.name).accent) }
                    enforceTarget()
                    stopSilenceMonitoring()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startSilenceMonitoring()
                    }
                }
            } else if previousTarget != nil {
                if !silent { print(Sym.minus + " " + (previousQuery ?? previousTarget!.name) + " disconnected".dim) }
            }
        } else {
            if previousTarget == nil && targetDevice != nil {
                if !silent { print(Sym.plus + " " + targetDevice!.name.accent + " connected".dim) }
                enforceTarget()
            } else if previousTarget != nil && targetDevice == nil {
                if !silent { print(Sym.minus + " " + previousTarget!.name + " disconnected".dim) }
            }
        }
    }

    private func onDefaultInputChanged() {
        guard let currentID = getDefaultInputDeviceID() else { return }

        if state == .checkingPrimary { return }

        if state == .fallback {
            guard let target = targetDevice else { return }
            if currentID != target.id {
                enforceTarget()
            }
            return
        }

        if targetQuery == nil {
            refreshTargetDevice()
        }

        guard let target = targetDevice else { return }

        if currentID != target.id {
            let currentName = getInputDevices().first { $0.id == currentID }?.name ?? "unknown"
            if !silent { print(Sym.arrowLeft + " Reverting: ".dim + currentName + " → ".dim + target.name.accent) }
            enforceTarget()
        }
    }

    // MARK: - Helpers

    func getPriorityIndex() -> Int {
        guard let current = currentQuery else { return -1 }
        let priority = loadPriority()
        return priority.firstIndex(of: current) ?? -1
    }

    func refreshTargetDevice() {
        if let query = targetQuery {
            targetDevice = findDevice(matching: query)
        } else {
            if let (device, query) = findBestAvailableDevice() {
                targetDevice = device
                currentQuery = query
            } else {
                targetDevice = nil
                currentQuery = nil
            }
        }
    }

    func enforceTarget() {
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
                if !silent { printSuccess("Set: " + target.name) }
            } else {
                if !silent { printError("Failed to set: " + target.name) }
            }
        }
    }
}
