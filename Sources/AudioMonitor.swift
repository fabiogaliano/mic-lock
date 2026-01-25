import AVFoundation
import Accelerate

// MARK: - Audio Monitor

/// Monitors audio input and calculates RMS levels
class AudioMonitor {
    private var engine: AVAudioEngine?
    private var isRunning = false

    var onSample: ((Float) -> Void)?

    func start() {
        guard !isRunning else { return }

        engine = AVAudioEngine()
        guard let engine = engine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Validate format before installing tap (device may have changed)
        // This prevents "Input HW format is invalid" crash
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.engine = nil
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)

            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

            self?.onSample?(rms)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}

// MARK: - One-Shot Sampling

/// Sample audio for a duration and determine if there's signal
/// - Parameters:
///   - duration: How long to sample (seconds)
///   - threshold: RMS below this is considered silent
///   - completion: Called with true if signal detected, false if silent
func sampleAudio(
    duration: TimeInterval,
    threshold: Float,
    completion: @escaping (Bool) -> Void
) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)

    // Validate format (device may have changed)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        completion(false)
        return
    }

    var hasSignal = false

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

        if rms >= threshold {
            hasSignal = true
        }
    }

    do {
        try engine.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            completion(hasSignal)
        }
    } catch {
        engine.stop()
        inputNode.removeTap(onBus: 0)
        completion(false)
    }
}

// MARK: - Continuous Sampling (for diagnostics)

/// Sample audio continuously with callbacks for each measurement
/// - Parameters:
///   - duration: How long to sample (seconds)
///   - onSample: Called for each RMS measurement
///   - completion: Called when finished with (sampleCount, signalCount)
func sampleAudioContinuous(
    duration: TimeInterval,
    threshold: Float,
    onSample: @escaping (Float, Bool) -> Void,
    completion: @escaping (Int, Int) -> Void
) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)

    // Validate format (device may have changed)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        completion(0, 0)
        return
    }

    var sampleCount = 0
    var signalCount = 0

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

        sampleCount += 1
        let hasSignal = rms >= threshold
        if hasSignal { signalCount += 1 }

        onSample(rms, hasSignal)
    }

    do {
        try engine.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            completion(sampleCount, signalCount)
        }
    } catch {
        engine.stop()
        inputNode.removeTap(onBus: 0)
        completion(0, 0)
    }
}
