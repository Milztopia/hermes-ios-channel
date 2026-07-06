import AVFoundation
import Accelerate

// MARK: - AudioRecorder
// Manages mic input + 3-phase adaptive VAD matching the web app's JS VAD.
// All VAD logic runs on the audio tap thread; state changes dispatch to main.

final class AudioRecorder {

    enum Phase: Equatable {
        case idle, calibrating, waitingForSpeech, inSpeech, countingSilence
    }

    var onPhaseChange: ((Phase) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?   // normalised 0..1 for waveform
    var onNoiseFloorUpdate: ((Float) -> Void)?
    // Fired at the exact VAD/force-send boundary, before resampling and WAV
    // packaging, so the UI can settle without waiting on background processing.
    var onCaptureEnded: (() -> Void)?
    var onAudioReady: (([Float], Data) -> Void)?  // floatPCM@16kHz + WAV
    var onBargeIn: (() -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    // VAD state — only touched on the audio tap thread
    private var phase: Phase = .idle
    // When true, the tap keeps running but ignores audio: no VAD, no phase
    // changes, no capture. Used while the coordinator transcribes/runs/speaks
    // so the live mic can't re-trigger recording (or capture TTS playback).
    private var suspended = false
    private var noiseFloor: Float = 0.001
    private var calibrationRMS: [Float] = []
    private var captureBuffer: [Float] = []   // grows from waitingForSpeech onward
    // Set from the main thread (force-send button), consumed on the audio thread:
    // finalize the current capture on the next tick, bypassing silence detection.
    private var forceFinalizeRequested = false
    private var silenceTickCount = 0
    private var silenceThresholdTicks = 15    // = 1500 ms / 100 ms per tick
    private var tickAccum: [Float] = []       // accumulate samples per tick
    private let tickSampleTarget = 4096       // ~93 ms @ 44100, ~85 ms @ 48000
    private var monitoringBargeIn = false
    // Separate from the live voice-processing route. We may intentionally keep
    // that route running until a sentence ends to avoid a volume jump, while
    // disabling interruption detection immediately.
    private var bargeTriggerEnabled = false
    private var bargeNoiseFloor: Float = 0.004
    private var bargeSpeechTicks = 0
    private var bargeWarmupTicks = 0
    private var bargeWarmupTarget = 12
    private var bargeRequiredSpeechTicks = 8
    private var bargePreRoll: [Float] = []
    // UI-facing logarithmic control position. Converted to RMS on the audio
    // thread; 0 is whisper-sensitive (~0.003 RMS), 1 rejects very loud rooms.
    var gateLevel: Double = 0.38
    var isBargeMonitoringActive: Bool { monitoringBargeIn && engine.isRunning }

    func setBargeTriggerEnabled(_ enabled: Bool) {
        bargeTriggerEnabled = enabled
        if !enabled {
            bargeSpeechTicks = 0
            bargePreRoll = []
        }
    }

    var silenceMs: Int = 1500 {
        didSet { silenceThresholdTicks = max(1, silenceMs / 100) }
    }

    // MARK: - Permissions

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Start / Stop

    func start(silenceMs: Int = 1500) throws {
        self.silenceMs = silenceMs

        let session = AVAudioSession.sharedInstance()
        // playAndRecord (not .record) so TTS auto-speak can play OUT through the
        // speaker while voice mode holds the mic. .record / .measurement silence
        // output. .default mode keeps playback audible; VAD uses raw RMS anyway.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        // No forced speaker override: .defaultToSpeaker routes to the built-in
        // speaker only when nothing else is connected, so CarPlay/Bluetooth take
        // over automatically when present.
        try configureMic()
    }

    /// Bring up the mic engine with voice processing and start capturing. Called on
    /// initial start AND when resuming listening after a response — we tear the
    /// engine down during playback (see `releaseMicForPlayback`) so voice
    /// processing doesn't duck the output, then rebuild it here for the next turn.
    private func configureMic(forBargeIn: Bool = false, expeditedBargeArm: Bool = false) throws {
        let inputNode = engine.inputNode
        // Apple's built-in voice processing: AEC (so TTS playback isn't picked
        // up) + noise suppression + AGC. Cleans the signal so we can drop the
        // adaptive noise floor and use a low fixed VAD threshold. NOTE: it also
        // ducks OUTPUT, which is why we only keep it on while actually recording.
        try? inputNode.setVoiceProcessingEnabled(true)
        if #available(iOS 17.0, *) {
            // TTS is played by AVAudioPlayer, outside this engine's voice-processing
            // signal path. The VPIO therefore treats it as "other audio" and ducks
            // it by default. Keep AEC/noise suppression for barge-in, but request
            // the minimum available output ducking so enabling the mic does not
            // materially change sentence volume.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Build a 16 kHz mono format for WhisperKit / server
        guard let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: false),
              let conv = AVAudioConverter(from: hwFormat, to: mono16k) else {
            throw AudioError.formatConversionFailed
        }
        self.converter = conv
        self.targetFormat = mono16k

        // Reset state
        phase = .idle
        noiseFloor = 0.001
        calibrationRMS = []
        captureBuffer = []
        forceFinalizeRequested = false
        silenceTickCount = 0
        tickAccum = []
        suspended = false
        monitoringBargeIn = forBargeIn
        bargeTriggerEnabled = forBargeIn
        bargeNoiseFloor = 0.004
        bargeSpeechTicks = 0
        bargeWarmupTicks = 0
        // A deliberate mid-response enable happens at a clean sentence boundary,
        // so route transients are much smaller than at response startup. Keep the
        // same conservative level threshold but shorten settling/confirmation so
        // the user can interrupt the next sentence in roughly half a second.
        bargeWarmupTarget = expeditedBargeArm ? 3 : 12
        bargeRequiredSpeechTicks = expeditedBargeArm ? 5 : 8
        bargePreRoll = []

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(tickSampleTarget), format: hwFormat) { [weak self] buf, _ in
            self?.processTap(buf)
        }
        try engine.start()

        if forBargeIn {
            // Give AEC/noise suppression a short settling period before accepting
            // speech so route changes and the beginning of TTS cannot self-trigger.
            phase = .idle
        } else {
            // No calibration needed — voice processing + fixed threshold. Start listening.
            phase = .waitingForSpeech
            DispatchQueue.main.async { [weak self] in self?.onPhaseChange?(.waitingForSpeech) }
        }
    }

    /// Listen through Apple's echo-cancelled voice-processing path while TTS is
    /// playing. A sustained, foreground voice promotes this same tap into normal
    /// utterance capture, preserving a short pre-roll so the interruption itself
    /// becomes the next prompt.
    func startBargeMonitoring(expedited: Bool = false) throws {
        if engine.isRunning {
            if monitoringBargeIn { setBargeTriggerEnabled(true) }
            return
        }
        let session = AVAudioSession.sharedInstance()
        // Voice processing/AEC is enabled explicitly on the input node. Keeping
        // the session in `.default` avoids a second, telephony-oriented gain/mode
        // transition when barge is armed between TTS sentences.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try configureMic(forBargeIn: true, expeditedBargeArm: expedited)
    }

    /// Stop only the special playback-time monitor. Normal listening/capture is
    /// left untouched if speech has already promoted the recorder.
    func stopBargeMonitoring() {
        guard monitoringBargeIn else { return }
        releaseMicForPlayback()
    }

    /// Tear down the mic engine + voice processing while a response plays, so the
    /// chimes / thinking bed / TTS aren't ducked by VPIO. The audio session stays
    /// active so AVAudioPlayer can still play out at full volume. Main thread only
    /// (never from the audio tap — stopping the engine there would deadlock).
    func releaseMicForPlayback() {
        suspended = true
        monitoringBargeIn = false
        bargeTriggerEnabled = false
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        // Deactivate so the subsequent switch to .playback (restoreOutputVolume, called
        // immediately after) forces a fresh route negotiation. Without this the route
        // stays on the VPIO output path and audio doesn't reach CarPlay / Bluetooth.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Fully release the mic: tear down the voice-processing IO unit and
        // deactivate the audio session so the system mic indicator clears.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
        suspended = false
        forceFinalizeRequested = false
        tickAccum = []
        captureBuffer = []
        monitoringBargeIn = false
        bargeTriggerEnabled = false
        bargePreRoll = []
    }

    /// Force the current utterance to be submitted now, bypassing silence
    /// detection. Safe to call from the main thread — it only sets a flag that the
    /// audio thread acts on at its next tick (≤ ~100 ms), so `captureBuffer` is
    /// never touched off-thread. No-op if not actively listening.
    func forceSend() {
        forceFinalizeRequested = true
    }

    // MARK: - Audio tap (runs on real-time audio thread)

    private func processTap(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        tickAccum.append(contentsOf: UnsafeBufferPointer(start: data, count: count))

        while tickAccum.count >= tickSampleTarget {
            let chunk = Array(tickAccum.prefix(tickSampleTarget))
            tickAccum.removeFirst(tickSampleTarget)
            processTick(chunk, buffer: buffer)
        }
    }

    private func processTick(_ chunk: [Float], buffer: AVAudioPCMBuffer) {
        // While suspended, drain audio without acting on it and report a flat
        // level so the waveform settles instead of reacting to TTS / room noise.
        if suspended {
            DispatchQueue.main.async { [weak self] in self?.onLevelUpdate?(0) }
            return
        }

        // Manual force-send: finalize the current capture now, ignoring the VAD.
        // Lets the user submit when background noise keeps silence detection from
        // ever firing. Includes this last chunk so nothing said is dropped.
        if forceFinalizeRequested {
            forceFinalizeRequested = false
            if phase != .idle, phase != .calibrating, !captureBuffer.isEmpty {
                captureBuffer.append(contentsOf: chunk)
                finalizeSpeech()
                return
            }
        }

        let rms = computeRMS(chunk)
        let normLevel = min(rms / 0.15, 1.0)
        let observedFloor = monitoringBargeIn ? bargeNoiseFloor : noiseFloor
        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(normLevel)
            self?.onNoiseFloorUpdate?(min(observedFloor / 0.15, 1.0))
        }

        if monitoringBargeIn {
            processBargeTick(chunk, rms: rms)
            return
        }

        // Track ambient sound only while speech is not active. The user's gate is
        // authoritative; the floor is reported visually so they can place the
        // threshold just above it.
        if phase == .waitingForSpeech {
            noiseFloor = noiseFloor * 0.88 + min(rms, 0.15) * 0.12
        }
        let speechOnThreshold = gateRMS
        let speechOffThreshold = speechOnThreshold * 0.62
        switch phase {
        case .idle, .calibrating: break

        case .waitingForSpeech:
            captureBuffer.append(contentsOf: chunk)
            if rms > speechOnThreshold {
                silenceTickCount = 0
                transition(to: .inSpeech)
            }

        case .inSpeech:
            captureBuffer.append(contentsOf: chunk)
            if rms < speechOffThreshold {
                silenceTickCount = 1
                transition(to: .countingSilence)
            }

        case .countingSilence:
            captureBuffer.append(contentsOf: chunk)
            if rms > speechOnThreshold {
                silenceTickCount = 0
                transition(to: .inSpeech)   // resumed speaking — don't cut off
            } else {
                silenceTickCount += 1
                if silenceTickCount >= silenceThresholdTicks {
                    finalizeSpeech()
                }
            }
        }
    }

    private var gateRMS: Float {
        // Exact same -54...-18 dBFS scale used by the meter and threshold handle.
        // Therefore a displayed signal below the handle cannot open this gate.
        let position = max(0, min(1, gateLevel))
        let db = -54.0 + 36.0 * position
        return Float(pow(10, db / 20))
    }

    private func processBargeTick(_ chunk: [Float], rms: Float) {
        guard bargeTriggerEnabled else {
            bargeSpeechTicks = 0
            bargePreRoll = []
            bargeNoiseFloor = bargeNoiseFloor * 0.94 + min(rms, 0.025) * 0.06
            return
        }
        // Keep roughly half a second before the confirmed trigger. This avoids
        // chopping off the first word after requiring several sustained ticks.
        bargePreRoll.append(contentsOf: chunk)
        let maxPreRoll = tickSampleTarget * 10
        if bargePreRoll.count > maxPreRoll {
            bargePreRoll.removeFirst(bargePreRoll.count - maxPreRoll)
        }

        // Let the voice-processing/AEC path settle for about one second after it
        // starts. Route changes, the thinking bed, and initial TTS transients are
        // especially prone to leaking through before echo cancellation converges.
        if bargeWarmupTicks < bargeWarmupTarget {
            bargeWarmupTicks += 1
            bargeNoiseFloor = bargeNoiseFloor * 0.75 + min(rms, 0.03) * 0.25
            return
        }

        // Require both a clearly voice-like absolute level and a large rise over
        // ambient/AEC residue. Eight consecutive ticks is roughly 700 ms: enough
        // to reject clinks, coughs, nearby chatter, and brief playback leakage,
        // while the longer pre-roll still preserves the user's opening words.
        // Honor the manual gate while retaining a small margin above measured AEC
        // residue. Raising the slider always wins; lowering it enables whispers
        // when the measured room floor is genuinely quiet.
        let trigger = max(gateRMS, bargeNoiseFloor * 1.15)
        if rms >= trigger {
            bargeSpeechTicks += 1
        } else {
            bargeSpeechTicks = 0
            bargeNoiseFloor = bargeNoiseFloor * 0.94 + min(rms, 0.025) * 0.06
        }

        guard bargeSpeechTicks >= bargeRequiredSpeechTicks else { return }
        monitoringBargeIn = false
        bargeTriggerEnabled = false
        captureBuffer = bargePreRoll
        bargePreRoll = []
        silenceTickCount = 0
        phase = .inSpeech
        DispatchQueue.main.async { [weak self] in
            self?.onBargeIn?()
            self?.onPhaseChange?(.inSpeech)
        }
    }

    private func adaptFloor(rms: Float) {
        if rms < noiseFloor {
            noiseFloor = max(noiseFloor * 0.93, 0.0001)  // falls fast
        } else {
            noiseFloor = noiseFloor * 1.00005             // rises very slowly
        }
    }

    private func transition(to next: Phase) {
        phase = next
        DispatchQueue.main.async { [weak self] in self?.onPhaseChange?(next) }
    }

    private func finalizeSpeech() {
        let captured = captureBuffer
        captureBuffer = []
        silenceTickCount = 0
        // Suspend immediately: the coordinator now owns the UI state through the
        // transcribe → run → speak phases. Without this the still-live mic keeps
        // firing phase changes and re-captures, snapping the UI back to recording.
        suspended = true
        phase = .idle
        DispatchQueue.main.async { [weak self] in self?.onCaptureEnded?() }

        // Resample + package on background thread to avoid blocking the tap
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let resampled = self.resampleToMono16k(captured),
                  let wavData = self.makePCM16WAV(resampled) else { return }
            DispatchQueue.main.async { self.onAudioReady?(resampled, wavData) }
        }
    }

    /// Re-arm the mic for the next utterance after the coordinator finishes
    /// processing/speaking. If the engine was torn down during playback (to drop
    /// the voice-processing output duck), rebuild it; otherwise just re-arm.
    func resumeListening() throws {
        if engine.isRunning {
            monitoringBargeIn = false
            bargeTriggerEnabled = false
            bargePreRoll = []
            captureBuffer = []
            forceFinalizeRequested = false
            tickAccum = []
            silenceTickCount = 0
            phase = .waitingForSpeech
            suspended = false
            DispatchQueue.main.async { [weak self] in self?.onPhaseChange?(.waitingForSpeech) }
        } else {
            // Mic engine + voice processing were released for playback — bring them
            // back up. The session was switched to .playback by restoreOutputVolume()
            // so we must restore .playAndRecord before configureMic() installs the
            // input tap (installing a tap on a .playback session throws an NSException).
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try configureMic()
        }
    }

    // MARK: - DSP helpers

    private func computeRMS(_ samples: [Float]) -> Float {
        var sumSq: Float = 0
        vDSP_measqv(samples, 1, &sumSq, vDSP_Length(samples.count))
        return sqrt(sumSq)
    }

    // MARK: - Resampling (hardware rate → 16 kHz mono Float32)

    private func resampleToMono16k(_ src: [Float]) -> [Float]? {
        guard let conv = converter, let targetFmt = targetFormat else { return nil }
        guard !src.isEmpty else { return nil }

        let hwSR = conv.inputFormat.sampleRate
        let ratio = 16000.0 / hwSR
        let outFrames = AVAudioFrameCount(Double(src.count) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outFrames) else { return nil }

        // Create source buffer matching the hardware format
        let inFmt = conv.inputFormat
        let inFrames = AVAudioFrameCount(src.count)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inFrames) else { return nil }
        inBuf.frameLength = inFrames

        // Fill input buffer — if stereo, duplicate mono to both channels
        for ch in 0..<Int(inFmt.channelCount) {
            guard let dst = inBuf.floatChannelData?[ch] else { return nil }
            src.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                dst.initialize(from: base, count: src.count)
            }
        }

        var error: NSError?
        var consumed = false
        conv.convert(to: outBuf, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        guard error == nil, outBuf.frameLength > 0 else { return nil }

        let outCount = Int(outBuf.frameLength)
        guard let output = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: output, count: outCount))
    }

    // MARK: - WAV packaging (16-bit PCM, mono, 16 kHz)

    private func makePCM16WAV(_ float32: [Float]) -> Data? {
        let sampleRate: Int32 = 16000
        let channelCount: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = sampleRate * Int32(channelCount) * Int32(bitsPerSample / 8)
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = Int32(float32.count * 2)
        let riffSize = 36 + dataSize

        var wav = Data()
        wav.appendLE("RIFF")
        wav.appendLE(riffSize)
        wav.appendLE("WAVE")
        wav.appendLE("fmt ")
        wav.appendLE(Int32(16))
        wav.appendLE(Int16(1))       // PCM
        wav.appendLE(channelCount)
        wav.appendLE(sampleRate)
        wav.appendLE(byteRate)
        wav.appendLE(blockAlign)
        wav.appendLE(bitsPerSample)
        wav.appendLE("data")
        wav.appendLE(dataSize)

        for sample in float32 {
            let clamped = max(-1.0, min(1.0, sample))
            let s16 = Int16(clamped * 32767)
            wav.appendLE(s16)
        }
        return wav
    }
}

// MARK: - Errors

enum AudioError: LocalizedError {
    case formatConversionFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .formatConversionFailed: return "Could not set up audio format conversion"
        case .permissionDenied:       return "Microphone permission denied"
        }
    }
}

// MARK: - Data helpers for little-endian WAV writing

private extension Data {
    mutating func appendLE(_ value: Int16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Int32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: String) {
        append(contentsOf: value.utf8.prefix(4))
    }
}
