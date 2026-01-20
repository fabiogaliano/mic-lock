import CoreAudio
import Foundation

// MARK: - Types

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct DeviceProperties {
    var isAlive: Bool = false
    var isRunning: Bool = false
    var isRunningSomewhere: Bool = false
    var transportType: String = "Unknown"
    var sampleRate: Double = 0
    var streamCount: Int = 0
    var jackConnected: Bool? = nil
}

// MARK: - Device Enumeration

func getInputDevices() -> [AudioInputDevice] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil, &dataSize
    ) == noErr else { return [] }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil, &dataSize, &deviceIDs
    ) == noErr else { return [] }

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

// MARK: - Default Device

func getDefaultInputDeviceID() -> AudioDeviceID? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil, &size, &deviceID
    ) == noErr else { return nil }

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
        0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &mutableDeviceID
    )

    return status == noErr
}

// MARK: - Device Status

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

// MARK: - Device Lookup

func findDevice(matching query: String) -> AudioInputDevice? {
    let devices = getInputDevices()
    let resolved = resolveAlias(query)
    let lowercaseQuery = resolved.lowercased()
    let matches = devices.filter { $0.name.lowercased().contains(lowercaseQuery) }
    return matches.count == 1 ? matches[0] : nil
}

func findBestAvailableDevice(checkAlive: Bool = true) -> (device: AudioInputDevice, query: String)? {
    let priority = loadPriority()
    if priority.isEmpty { return nil }

    let devices = getInputDevices()

    for query in priority {
        let resolved = resolveAlias(query)
        let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
        if matches.count == 1 {
            let device = matches[0]
            if checkAlive && !isDeviceAlive(device.id) {
                continue
            }
            return (device, query)
        }
    }
    return nil
}

// MARK: - Device Inspection

func inspectDevice(_ device: AudioInputDevice) -> DeviceProperties {
    var props = DeviceProperties()
    var size = UInt32(MemoryLayout<UInt32>.size)

    // IsAlive
    var isAlive: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isAlive) == noErr {
        props.isAlive = isAlive == 1
    }

    // IsRunning
    var isRunning: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyDeviceIsRunning
    addr.mScope = kAudioObjectPropertyScopeInput
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isRunning) == noErr {
        props.isRunning = isRunning == 1
    }

    // IsRunningSomewhere
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    addr.mScope = kAudioObjectPropertyScopeGlobal
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &isRunning) == noErr {
        props.isRunningSomewhere = isRunning == 1
    }

    // TransportType
    var transportType: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyTransportType
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &transportType) == noErr {
        switch transportType {
        case kAudioDeviceTransportTypeUSB: props.transportType = "USB"
        case kAudioDeviceTransportTypeBluetooth: props.transportType = "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: props.transportType = "Built-in"
        case kAudioDeviceTransportTypeVirtual: props.transportType = "Virtual"
        default: props.transportType = "Other"
        }
    }

    // Sample rate
    var sampleRate: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    addr.mSelector = kAudioDevicePropertyNominalSampleRate
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &srSize, &sampleRate) == noErr {
        props.sampleRate = sampleRate
    }

    // Stream count
    addr.mSelector = kAudioDevicePropertyStreams
    addr.mScope = kAudioObjectPropertyScopeInput
    var streamSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(device.id, &addr, 0, nil, &streamSize) == noErr {
        props.streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
    }

    // Jack connected (optional - not all devices support this)
    var jackConnected: UInt32 = 0
    addr.mSelector = kAudioDevicePropertyJackIsConnected
    if AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &jackConnected) == noErr {
        props.jackConnected = jackConnected == 1
    }

    return props
}
