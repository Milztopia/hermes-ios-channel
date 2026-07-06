import Foundation
import UIKit

// MARK: - VoiceCoordinator
// @Observable state machine that orchestrates the full voice loop:
//   idle → calibrating → waitingForSpeech → recording
//       → transcribing → running → speaking → waitingForSpeech → …
// Owns AudioRecorder, WhisperService, TTSService.

@Observable
@MainActor
final class VoiceCoordinator {

    enum State: Equatable {
        case idle
        case calibrating
        case waitingForSpeech
        case recording
        case transcribing
        case running       // waiting for AI stream to finish
        case speaking
        case error(String)

        var label: String {
            switch self {
            case .idle:            return "Tap to start"
            case .calibrating:     return "Calibrating…"
            case .waitingForSpeech:return "Listening…"
            case .recording:       return "Recording…"
            case .transcribing:    return "Transcribing…"
            case .running:         return "Thinking…"
            case .speaking:        return "Speaking…"
            case .error(let msg):  return msg
            }
        }

        var isActive: Bool { self != .idle }
    }

    var state: State = .idle
    var audioLevel: Float = 0    // normalised 0..1 for waveform animation (mic)
    var noiseFloorLevel: Float = 0
    var audioHistory: [Float] = Array(repeating: 0, count: 42)
    var gateLevel: Double = 0.38
    var gateClosure: Float = 0
    var meterLevel: Float = 0
    var meterPeak: Float = 0
    private var meterPeakHoldTicks = 0

    // Spoken-response state for the live transcript + audio-reactive orb.
    var spokenText: String = ""        // full text being spoken
    var spokenCharIndex: Int = 0       // chars spoken so far (karaoke highlight)
    var speakingLevel: Float = 0       // 0..1 TTS amplitude while speaking
    private(set) var isBargeInEnabled = false
    private var pendingBargeEnable = false

    private(set) var whisperService = WhisperService()
    private let ttsService = TTSService()
    private let recorder = AudioRecorder()

    private var voiceTask: Task<Void, Never>?        // recording loop
    private var processingTask: Task<Void, Never>?   // transcribe → run → speak
    private var runTask: Task<Void, Never>?          // the LLM run itself
    private weak var settings: SettingsStore?
    private weak var chatStore: ChatStore?
    private var currentChatId: String?

    // MARK: - Public API

    /// Warm up the on-device model at app launch so the first utterance doesn't
    /// have to wait for (or fail on) a cold load. No-op for server STT.
    func preloadSTT(settings: SettingsStore) {
        // Whisper also supplies precise word timestamps for server-TTS karaoke.
        // Preload it so alignment adds only the warm per-sentence pass, never a
        // multi-second cold load before the first spoken response.
        guard settings.sttEngine == .onDevice || settings.ttsEngine == .server else { return }
        Task { await whisperService.loadModelIfNeeded() }
    }

    func toggle(settings: SettingsStore, chatStore: ChatStore, chatId: String) {
        if state.isActive {
            stop()
        } else {
            start(settings: settings, chatStore: chatStore, chatId: chatId)
        }
    }

    /// Manually submit the current utterance, bypassing silence detection. Used
    /// when background noise stops the VAD from auto-finalizing. Only meaningful
    /// while actively listening or recording.
    func forceSend() {
        guard state == .recording || state == .waitingForSpeech else { return }
        Haptics.impact(.medium)
        recorder.forceSend()
    }

    func setGateLevel(_ value: Double) {
        let clamped = max(0, min(1, value))
        gateLevel = clamped
        recorder.gateLevel = clamped
        settings?.voiceGateLevel = clamped
    }

    /// Whether the force-send control should be shown/enabled right now.
    var canForceSend: Bool {
        state == .recording || state == .waitingForSpeech
    }

    /// Barge-in is intentionally session-scoped and defaults off every time voice
    /// mode opens. Enabling it while a response is active starts conservative,
    /// echo-cancelled speech monitoring.
    func setBargeInEnabled(_ enabled: Bool) {
        guard isBargeInEnabled != enabled else { return }
        isBargeInEnabled = enabled
        if let chatStore, let currentChatId {
            chatStore.setBargeInEnabled(enabled, for: currentChatId)
        }
        Haptics.impact(.light)
        // Authorization changes immediately even if the voice-processing route
        // must remain alive until a sentence boundary for stable playback volume.
        recorder.setBargeTriggerEnabled(enabled)
        if canInterrupt {
            // Never change AVAudioSession category while speech is playing. The
            // playback ↔ voiceChat transition changes system gain/route and causes
            // the audible volume jump. Disabling still takes effect immediately
            // because handleAutomaticBargeIn checks this flag; the existing monitor
            // is left running until the turn ends. Enabling is armed in the quiet
            // boundary after the current sentence and before the next WAV begins.
            pendingBargeEnable = enabled && !recorder.isBargeMonitoringActive
            NSLog("HERMES barge toggle pending-boundary enabled=\(enabled)")
        } else if !enabled {
            pendingBargeEnable = false
            recorder.stopBargeMonitoring()
        }
    }

    /// Barge-in: stop the current turn (transcribe / run / speak) WITHOUT leaving
    /// voice mode, and go straight back to listening. Cancels the LLM run
    /// (incl. server-side) and any in-flight/queued TTS so it stops talking at once.
    func interrupt() {
        guard canInterrupt else { return }
        Haptics.impact(.medium)
        recorder.stopBargeMonitoring()
        // Tear down just the current turn's work — keep the recording session alive.
        processingTask?.cancel(); processingTask = nil
        runTask?.cancel();        runTask = nil
        if let chatId = currentChatId { Task { await chatStore?.stopRun(chatId: chatId) } }
        ttsService.stop()
        KokoroService.shared.cancelStreaming()
        pendingBargeEnable = false
        spokenText = ""
        spokenCharIndex = 0
        speakingLevel = 0
        // "Your turn" chime, then re-arm the mic. The chime must finish BEFORE
        // resumeListening() rebuilds the engine (re-enabling voice processing cuts
        // off audio playing through the session). Mirrors the end-of-turn path.
        processingTask = Task {
            await ttsService.playChimeAndWait(.ready, outputDrain: false)
            if state != .idle, !Task.isCancelled { resumeListening() }
        }
    }

    /// Whether the interrupt control should be shown right now (a turn is in flight).
    var canInterrupt: Bool {
        state == .transcribing || state == .running || state == .speaking
    }

    func stop() {
        // Tear down EVERYTHING: the recording loop, the transcribe→run→speak
        // pipeline, the LLM run (incl. server-side), the current audio, and any
        // not-yet-produced TTS chunks. Exiting voice mode must kill the whole
        // stream, not let it keep talking in the background.
        voiceTask?.cancel();      voiceTask = nil
        processingTask?.cancel(); processingTask = nil
        runTask?.cancel();        runTask = nil
        if let chatId = currentChatId { Task { await chatStore?.stopRun(chatId: chatId) } }
        recorder.stop()
        ttsService.stop()
        KokoroService.shared.cancelStreaming()
        pendingBargeEnable = false
        state = .idle
        audioLevel = 0
        gateClosure = 0
        meterLevel = 0
        meterPeak = 0
        spokenText = ""
        spokenCharIndex = 0
        speakingLevel = 0
        isBargeInEnabled = false
    }

    // MARK: - Start

    private func start(settings: SettingsStore, chatStore: ChatStore, chatId: String) {
        self.settings = settings
        self.chatStore = chatStore
        self.currentChatId = chatId
        isBargeInEnabled = chatStore.bargeInEnabled(
            for: chatId,
            default: settings.defaultBargeInEnabled
        )
        pendingBargeEnable = false
        gateLevel = settings.voiceGateLevel
        recorder.gateLevel = gateLevel
        gateClosure = 0
        meterLevel = 0
        meterPeak = 0

        // Pre-load Whisper if on-device STT is selected
        if settings.sttEngine == .onDevice {
            Task { await whisperService.loadModelIfNeeded() }
        }

        // Pre-warm Kokoro so the first utterance doesn't stall on model load
        if settings.ttsEngine == .kokoro {
            Task { await KokoroService.shared.loadIfNeeded() }
        }

        // Wire up recorder callbacks
        recorder.onLevelUpdate = { [weak self] level in
            guard let self else { return }
            self.audioLevel = level
            self.audioHistory.append(level)
            if self.audioHistory.count > 42 {
                self.audioHistory.removeFirst(self.audioHistory.count - 42)
            }
            let rms = max(0.000001, level * 0.15)
            let db = 20 * log10(rms)
            let target = max(0, min(1, (db + 54) / 36))
            self.meterLevel = target > self.meterLevel
                ? self.meterLevel * 0.28 + target * 0.72
                : self.meterLevel * 0.82 + target * 0.18
            if self.meterLevel >= self.meterPeak {
                self.meterPeak = self.meterLevel
                self.meterPeakHoldTicks = 9
            } else if self.meterPeakHoldTicks > 0 {
                self.meterPeakHoldTicks -= 1
            } else {
                self.meterPeak = max(self.meterLevel, self.meterPeak - 0.035)
            }
            if target >= self.gateDisplayLevel {
                // Hardware-style meter behavior: opening the gate is immediate.
                self.gateClosure = 0
            } else {
                // Closing follows roughly the configured VAD release time.
                let releaseTicks = max(3, self.settings.map { $0.vadSilenceMs / 90 } ?? 13)
                self.gateClosure = min(1, self.gateClosure + 1 / Float(releaseTicks))
            }
        }
        recorder.onNoiseFloorUpdate = { [weak self] floor in
            self?.noiseFloorLevel = floor
        }
        recorder.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .idle:              self.state = .idle
            case .calibrating:       self.state = .calibrating
            case .waitingForSpeech:  self.state = .waitingForSpeech
            case .inSpeech, .countingSilence:
                if self.state != .recording { Haptics.impact(.medium) }  // pulse on speech onset
                self.state = .recording
            }
        }
        recorder.onCaptureEnded = { [weak self] in
            self?.settleInputMeter()
        }
        recorder.onAudioReady = { [weak self] floatPCM, wavData in
            guard let self else { return }
            self.handleAudioReady(floatPCM: floatPCM, wavData: wavData)
        }
        recorder.onBargeIn = { [weak self] in
            self?.handleAutomaticBargeIn()
        }

        voiceTask = Task {
            do {
                let granted = await AudioRecorder.requestPermission()
                guard granted else {
                    state = .error("Microphone permission denied")
                    return
                }
                // Sound the "ready" chime BEFORE bringing the mic up. recorder.start()
                // enables voice-processing IO, which ducks output to near-silence —
                // that's why the entry chime was inaudible while the loop-back chime
                // (mic torn down at that point) was fine. Mirror the loop-back order:
                // chime on a plain active session, let it finish, then start the mic.
                ttsService.restoreOutputVolume()
                await ttsService.playChimeAndWait(.ready, outputDrain: false)
                // Only bail if voice mode was exited during the chime (stop()
                // cancels voiceTask). Don't check state here — it's still .idle
                // until recorder.start() drives the first phase change.
                if Task.isCancelled { return }
                recorder.silenceMs = settings.vadSilenceMs
                try recorder.start(silenceMs: settings.vadSilenceMs)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private var gateDisplayLevel: Float {
        Float(max(0, min(1, gateLevel)))
    }

    /// Clear all microphone-meter state at once. Called immediately when VAD
    /// closes capture and again when packaged audio arrives as a safety net.
    private func settleInputMeter() {
        audioLevel = 0
        meterLevel = 0
        meterPeak = 0
        meterPeakHoldTicks = 0
        gateClosure = 1
        audioHistory = Array(repeating: 0, count: 42)
    }

    // MARK: - Audio ready → transcribe → run

    private func handleAudioReady(floatPCM: [Float], wavData: Data) {
        guard let settings, let chatStore, let chatId = currentChatId else { return }
        guard state != .idle else { return }

        // The microphone has handed off its final buffer and will be torn down for
        // transcription. No more low-level callbacks will arrive, so settle the
        // visual meter explicitly instead of freezing halfway through release.
        settleInputMeter()

        // Stored so stop() (X / exit voice mode) can cancel the whole pipeline,
        // not just the recording loop.
        processingTask = Task {
            // Full, un-ducked volume for the whole response. Voice processing's
            // output AGC ducks playback (and only releases at stop — that's the
            // "louder right before it stops" spike). So we (1) tear the mic engine
            // + voice processing DOWN for playback so there's no duck/AGC at all,
            // and (2) force the speaker route to reach normal level. The captured
            // audio is already packaged, so transcription is unaffected; the engine
            // is rebuilt when we resume listening.
            recorder.releaseMicForPlayback()
            ttsService.restoreOutputVolume()
            // 1. Transcribe (recording just finished — chime to acknowledge capture)
            state = .transcribing
            // Begin transcription immediately, but serialize the audible transition:
            // acknowledgement cue first, then the thinking bed. This preserves
            // latency without letting the two sounds talk over/cut off each other.
            async let pendingTranscript = transcribe(
                floatPCM: floatPCM,
                wavData: wavData,
                settings: settings
            )
            await ttsService.playChimeAndWait(.done)
            if Task.isCancelled { return }
            ttsService.startThinkingLoop()
            let transcript: String
            do {
                transcript = try await pendingTranscript
            } catch {
                // Transcription failed — re-arm the mic and go back to listening
                resumeListening()
                return
            }

            if Task.isCancelled { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                resumeListening()
                return
            }

            // 2. Start the AI run CONCURRENTLY (don't await it fully) so we can
            //    speak sentences as they generate instead of after the whole reply.
            state = .running
            let priorAssistantId = chatStore.messages[chatId]?.last(where: { $0.type == .assistant })?.id
            runTask = Task { await chatStore.startRun(chatId: chatId, text: trimmed, images: [], voiceMode: true) }
            startBargeMonitoringIfNeeded()

            // 3+4. Stream the response into speech sentence-by-sentence.
            if settings.client != nil {
                await streamSpeakResponse(
                    chatId: chatId,
                    priorAssistantId: priorAssistantId,
                    chatStore: chatStore,
                    settings: settings
                )
            } else {
                // No server client: wait for the run to finish.
                while chatStore.isStreaming[chatId] == true, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            await runTask?.value

            // 5. Speaking done — brief pause, then "your turn" chime, then listen.
            //    The pause gives the last word room to breathe before the chime (and
            //    lets any acoustic echo from car speakers decay so VAD doesn't fire
            //    immediately). Let the chime finish BEFORE resumeListening() so the
            //    mic engine rebuild doesn't cut it off.
            if state != .idle, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)   // 300ms after last word
                await ttsService.playChimeAndWait(.ready, outputDrain: false)
                if state != .idle, !Task.isCancelled { resumeListening() }
            }
        }
    }

    // MARK: - Streaming speech (speak sentences as the model generates them)

    /// Watches the streaming assistant message and speaks it sentence-by-sentence
    /// as it arrives, so the user hears (and sees) the reply start within ~one
    /// sentence of generation instead of waiting for the whole thing. The live
    /// transcript (`spokenText`) grows as sentences are enqueued; the karaoke
    /// highlight (`spokenCharIndex`) tracks what's actually been spoken.
    private func streamSpeakResponse(
        chatId: String,
        priorAssistantId: String?,
        chatStore: ChatStore,
        settings: SettingsStore
    ) async {
        guard let client = settings.client else { return }
        spokenText = ""
        spokenCharIndex = 0
        speakingLevel = 0

        // Pin to THIS turn's assistant message. Until startRun creates a new one,
        // the previous turn's completed reply is still the last assistant message —
        // so capture the old id before startRun and then track the new id only.
        var targetId: String?
        let startWait = Date()
        while !Task.isCancelled, state != .idle {
            if let last = chatStore.messages[chatId]?.last(where: { $0.type == .assistant }),
               last.id != priorAssistantId {
                targetId = last.id
                break
            }
            // The run is accepted (and its message created) within the startRun
            // round-trip; if nothing appears in 20s the run failed to start.
            if Date().timeIntervalSince(startWait) > 20 { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let targetId else { return }

        if settings.ttsEngine == .server {
            await streamPreparedServerResponse(
                chatId: chatId,
                targetId: targetId,
                chatStore: chatStore,
                settings: settings,
                client: client
            )
            return
        }

        var rawUpto = 0          // chars of raw assistant content already enqueued
        var spokenBase = 0       // chars of `spokenText` fully spoken so far
        let t0Voice = Date()
        var firstSegmentLogged = false

        func currentRaw() -> String {
            chatStore.responseContent(chatId: chatId, msgId: targetId)
        }

        while !Task.isCancelled, state != .idle {
            let raw = currentRaw()
            let streaming = chatStore.isStreaming[chatId] == true

            guard let (segment, newUpto) = Self.nextSpeakableSegment(raw: raw, from: rawUpto, streaming: streaming) else {
                // Nothing ready yet. Done if the run finished and we've consumed all.
                if !streaming, rawUpto >= raw.count { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            rawUpto = newUpto

            if !firstSegmentLogged {
                firstSegmentLogged = true
                let e = Date().timeIntervalSince(t0Voice)
                NSLog("HERMES⏱ first-segment +%.3fs  chars=%d  %@",
                      e, segment.count,
                      String(segment.prefix(60)).replacingOccurrences(of: "\n", with: "↵"))
                TimingReporter.mark("first-segment",
                    detail: "chars=\(segment.count) \(String(segment.prefix(40)))")
            }

            let displayText = stripMarkdown(segment)
            guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let speakable = Self.speechForm(for: displayText).spoken

            // If barge was enabled while thinking or during the previous sentence,
            // arm it before this sentence starts. Checking here as well as after
            // playback closes the race where the toggle changes between segments.
            armPendingBargeAtBoundaryIfNeeded()
            state = .speaking   // first real audio is about to start

            // Display + index bookkeeping: append exactly what we'll speak so the
            // highlight offsets line up with the displayed transcript.
            let display = displayText.hasSuffix(" ") ? displayText : displayText + " "
            spokenText += display
            let base = spokenBase
            let segLen = display.count

            // Mirror TTS amplitude + per-segment progress into absolute karaoke.
            let monitor = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let nextLevel = self.ttsService.meterLevel
                    let nextIndex = min(self.spokenText.count,
                        base + Int(self.ttsService.progressFraction * Double(segLen)))
                    // Word highlighting changes only at word boundaries, so a
                    // 30 Hz foreground poll improves perceived synchronization
                    // without causing continuous text layout. Background updates
                    // remain heavily throttled.
                    if UIApplication.shared.applicationState == .active {
                        if abs(self.speakingLevel - nextLevel) >= 0.03 {
                            self.speakingLevel = nextLevel
                        }
                        if self.spokenCharIndex != nextIndex {
                            self.spokenCharIndex = nextIndex
                        }
                    }
                    let delay: UInt64 = UIApplication.shared.applicationState == .active
                        ? 33_000_000
                        : 250_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            let ttsEngine = settings.ttsEngine
            let tTTSStart = Date()
            let eTTSStart = Date().timeIntervalSince(t0Voice)
            NSLog("HERMES⏱ tts-start    +%.3fs  engine=%@  chars=%d",
                  eTTSStart, "\(ttsEngine)", speakable.count)
            TimingReporter.mark("tts-start", detail: "engine=\(ttsEngine) chars=\(speakable.count)")
            switch ttsEngine {
            case .server:
                await ttsService.speakStream(
                    text: speakable,
                    voice: settings.effectiveTtsVoice,
                    client: client,
                    karaokeAligner: whisperService
                )
            case .apple:
                await ttsService.speakOnDevice(
                    text: speakable,
                    voiceId: settings.onDeviceVoiceId.isEmpty ? nil : settings.onDeviceVoiceId)
            case .kokoro:
                let stream = KokoroService.shared.synthesizeStream(text: speakable, voice: settings.kokoroVoice)
                await ttsService.playChunks(stream, totalChars: speakable.count)
            }
            let eDone = Date().timeIntervalSince(t0Voice)
            let segTook = Date().timeIntervalSince(tTTSStart)
            NSLog("HERMES⏱ tts-done     +%.3fs  segment-took=%.3fs", eDone, segTook)
            TimingReporter.mark("tts-done", detail: "segment=\(String(format:"%.3f",segTook))s")

            monitor.cancel()
            spokenBase += segLen
            spokenCharIndex = spokenBase
            speakingLevel = 0

            // A user may enable barge while this sentence is playing. Arm the
            // echo-cancelled mic now, in the silence between sentence WAVs, so the
            // current sentence keeps its original volume and the next one is
            // interruptible. This is a clean boundary, so use the shorter AEC
            // settling profile reserved for deliberate activation.
            if !Task.isCancelled { armPendingBargeAtBoundaryIfNeeded() }
        }
    }

    private struct PreparedVoiceSegment: Sendable {
        let displayText: String
        let speechText: String
        let speechBoundaryToDisplay: [Int]
        let audio: TTSService.TTSChunk
    }

    /// Server-TTS lookahead pipeline. The producer follows Hermes' live text stream,
    /// renders and precisely aligns sentences, and keeps at most two prepared WAVs.
    /// The consumer starts sentence one immediately and plays later sentences from
    /// that queue, eliminating synthesis/alignment work from most sentence gaps.
    private func streamPreparedServerResponse(
        chatId: String,
        targetId: String,
        chatStore: ChatStore,
        settings: SettingsStore,
        client: HermesClient
    ) async {
        let pair = AsyncStream<PreparedVoiceSegment>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let producer = Task { [weak self] in
            guard let self else {
                pair.continuation.finish()
                return
            }
            defer { pair.continuation.finish() }
            var rawUpto = 0
            var firstSegmentLogged = false
            let t0Voice = Date()

            while !Task.isCancelled, self.state != .idle {
                let raw = chatStore.responseContent(chatId: chatId, msgId: targetId)
                let streaming = chatStore.isStreaming[chatId] == true
                guard let (segment, newUpto) = Self.nextSpeakableSegment(
                    raw: raw,
                    from: rawUpto,
                    streaming: streaming
                ) else {
                    if !streaming, rawUpto >= raw.count { break }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continue
                }
                rawUpto = newUpto
                let displayText = self.stripMarkdown(segment)
                guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let speechForm = Self.speechForm(for: displayText)
                let speechText = speechForm.spoken

                if !firstSegmentLogged {
                    firstSegmentLogged = true
                    let elapsed = Date().timeIntervalSince(t0Voice)
                    NSLog("HERMES⏱ first-segment +%.3fs  chars=%d  %@",
                          elapsed, segment.count,
                          String(segment.prefix(60)).replacingOccurrences(of: "\n", with: "↵"))
                    TimingReporter.mark(
                        "first-segment",
                        detail: "chars=\(segment.count) \(String(segment.prefix(40)))"
                    )
                }

                guard let audio = await self.ttsService.prepareServerChunk(
                    text: speechText,
                    voice: settings.effectiveTtsVoice,
                    client: client,
                    karaokeAligner: self.whisperService
                ) else {
                    if Task.isCancelled { break }
                    continue
                }
                let prepared = PreparedVoiceSegment(
                    displayText: displayText,
                    speechText: speechText,
                    speechBoundaryToDisplay: speechForm.spokenBoundaryToDisplay,
                    audio: audio
                )

                // AsyncStream reports a dropped newest item when the two-sentence
                // buffer is full. Retry that same item once playback frees a slot;
                // never discard or reorder spoken text.
                enqueue: while !Task.isCancelled {
                    switch pair.continuation.yield(prepared) {
                    case .enqueued:
                        break enqueue
                    case .dropped:
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
            }
        }
        defer {
            producer.cancel()
            pair.continuation.finish()
        }

        var spokenBase = 0
        let t0Voice = Date()
        for await prepared in pair.stream {
            if Task.isCancelled || state == .idle { break }

            armPendingBargeAtBoundaryIfNeeded()
            state = .speaking
            let display = prepared.displayText.hasSuffix(" ")
                ? prepared.displayText
                : prepared.displayText + " "
            spokenText += display
            let base = spokenBase
            let segmentLength = display.count
            ttsService.beginPreparedSentence()

            let monitor = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let nextLevel = self.ttsService.meterLevel
                    let speechPosition = max(
                        0,
                        min(
                            prepared.speechBoundaryToDisplay.count - 1,
                            self.ttsService.progressCharacterIndex
                        )
                    )
                    let displayPosition = prepared.speechBoundaryToDisplay[speechPosition]
                    let nextIndex = min(
                        self.spokenText.count,
                        base + displayPosition
                    )
                    if UIApplication.shared.applicationState == .active {
                        if abs(self.speakingLevel - nextLevel) >= 0.03 {
                            self.speakingLevel = nextLevel
                        }
                        if self.spokenCharIndex != nextIndex {
                            self.spokenCharIndex = nextIndex
                        }
                    }
                    let delay: UInt64 = UIApplication.shared.applicationState == .active
                        ? 33_000_000
                        : 250_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            let started = Date()
            NSLog("HERMES⏱ tts-start    +%.3fs  engine=server-buffered chars=%d",
                  Date().timeIntervalSince(t0Voice), prepared.speechText.count)
            await ttsService.playPreparedServerChunk(prepared.audio)
            NSLog("HERMES⏱ tts-done     +%.3fs  segment-took=%.3fs",
                  Date().timeIntervalSince(t0Voice), Date().timeIntervalSince(started))

            monitor.cancel()
            spokenBase += segmentLength
            spokenCharIndex = spokenBase
            speakingLevel = 0
            if !Task.isCancelled { armPendingBargeAtBoundaryIfNeeded() }
        }
    }

    /// Extract the next chunk of raw assistant text that's ready to speak,
    /// starting at `from`. Prefers complete sentences; when the run has finished
    /// (`streaming == false`) it returns whatever remains; while still streaming
    /// it flushes a long run-on at the last space so speech never stalls waiting
    /// for a terminator. Returns the segment text and the new consumed offset.
    private static func nextSpeakableSegment(raw: String, from: Int, streaming: Bool) -> (String, Int)? {
        let chars = Array(raw)
        guard from < chars.count else { return nil }

        // Furthest sentence boundary (terminator followed by whitespace, or the
        // very end once generation is done).
        var boundary = -1
        var i = from
        while i < chars.count {
            if ".!?\n".contains(chars[i]) {
                if i + 1 < chars.count {
                    if chars[i + 1] == " " || chars[i + 1] == "\n" { boundary = i + 1 }
                } else if !streaming {
                    boundary = i + 1
                }
            }
            i += 1
        }
        if boundary > from { return (String(chars[from..<boundary]), boundary) }

        // No sentence boundary yet.
        if !streaming { return (String(chars[from..<chars.count]), chars.count) }   // flush remainder

        // Still streaming and no terminator yet. Speaking each segment as a WHOLE
        // sentence keeps playback gap-free; chopping mid-sentence creates an audible
        // stop while the next piece is synthesized. So only flush a partial for a
        // genuinely long run-on (rare — generation now outpaces TTS), and cut at a
        // clause boundary (comma/semicolon/colon/dash) when one exists, else the
        // last space.
        if chars.count - from > 280 {
            var cut = -1
            var j = chars.count - 1
            while j > from {
                if chars[j] == " ", ",;:—".contains(chars[j - 1]) { cut = j + 1; break }
                j -= 1
            }
            if cut <= from {                       // no clause boundary — last space
                var sp = chars.count - 1
                while sp > from, chars[sp] != " " { sp -= 1 }
                if sp > from { cut = sp + 1 }
            }
            if cut > from { return (String(chars[from..<cut]), cut) }
        }
        return nil
    }

    /// Re-arm the recorder and return the UI to the listening state. Used on
    /// every path that finishes processing an utterance (success, empty, error).
    private func resumeListening() {
        guard state != .idle else { return }
        // If the bed is still playing (e.g. empty transcript / error / no spoken
        // reply), cut it — speech already crossfaded it out on the normal path,
        // so this is a no-op there.
        ttsService.stopThinkingLoop()
        do {
            try recorder.resumeListening()
        } catch {
            NSLog("HERMES recorder resume error: \(error)")
            recorder.stop()
            audioLevel = 0
            state = .error("Could not restart microphone")
        }
    }

    private func startBargeMonitoringIfNeeded() {
        guard isBargeInEnabled,
              state == .running || state == .speaking else { return }
        do {
            try recorder.startBargeMonitoring()
        } catch {
            NSLog("HERMES barge monitor start error: \(error)")
            isBargeInEnabled = false
        }
    }

    private func armPendingBargeAtBoundaryIfNeeded() {
        guard pendingBargeEnable, isBargeInEnabled else { return }
        if recorder.isBargeMonitoringActive {
            recorder.setBargeTriggerEnabled(true)
            pendingBargeEnable = false
            return
        }
        do {
            try recorder.startBargeMonitoring(expedited: true)
            pendingBargeEnable = false
            NSLog("HERMES barge armed at sentence boundary")
        } catch {
            NSLog("HERMES barge boundary arm error: \(error)")
            isBargeInEnabled = false
            pendingBargeEnable = false
        }
    }

    /// The recorder has already promoted its pre-roll into a normal utterance.
    /// Stop the current answer immediately and leave the mic running so the user
    /// can finish the sentence that caused the interruption.
    private func handleAutomaticBargeIn() {
        guard isBargeInEnabled, canInterrupt else { return }
        Haptics.impact(.medium)
        processingTask?.cancel(); processingTask = nil
        runTask?.cancel(); runTask = nil
        if let chatId = currentChatId {
            Task { await chatStore?.stopRun(chatId: chatId) }
        }
        ttsService.stop()
        KokoroService.shared.cancelStreaming()
        pendingBargeEnable = false
        spokenText = ""
        spokenCharIndex = 0
        speakingLevel = 0
        state = .recording
    }

    // MARK: - STT dispatch

    private func transcribe(floatPCM: [Float], wavData: Data, settings: SettingsStore) async throws -> String {
        switch settings.sttEngine {
        case .onDevice:
            return try await whisperService.transcribe(floatPCM)
        case .server:
            guard let client = settings.client else { throw HermesError.notConfigured }
            return try await client.transcribe(audioData: wavData)
        }
    }

    // MARK: - Markdown strip

    private func stripMarkdown(_ text: String) -> String {
        var s = text
        // Drop fenced code blocks — too long to read aloud
        if let re = try? NSRegularExpression(pattern: "```[\\s\\S]*?```") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        // Transform inline code spans to natural speech: `.voiceChat` → "voice chat",
        // `VoiceCoordinator.swift` → "Voice Coordinator dot swift", `setActive()` → "set active"
        if let re = try? NSRegularExpression(pattern: "`([^`]+)`") {
            var out = ""
            var tail = s.startIndex
            re.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { m, _, _ in
                guard let m, let inner = Range(m.range(at: 1), in: s),
                      let full = Range(m.range, in: s) else { return }
                out += s[tail..<full.lowerBound]
                out += Self.naturalCodePhrase(String(s[inner]))
                tail = full.upperBound
            }
            out += s[tail...]
            s = out
        }
        // Remove bold/italic markers
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
        // Remove heading markers
        if let re = try? NSRegularExpression(pattern: "^#{1,6} ", options: .anchorsMatchLines) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Produce a TTS-only form while preserving the original response for display.
    /// This is intentionally deterministic rather than relying on the model to
    /// obey a voice-mode formatting instruction every time.
    private struct SpeechForm: Sendable {
        let spoken: String
        // Entry i is the displayed-character boundary corresponding to spoken
        // character boundary i. Count is always spoken.count + 1.
        let spokenBoundaryToDisplay: [Int]
    }

    private static func speechForm(for input: String) -> SpeechForm {
        var text = input
        var boundaries = Array(0...input.count)

        func spelled(_ raw: String) -> String? {
            let cleaned = raw.replacingOccurrences(of: ",", with: "")
            guard let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
                return nil
            }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            return formatter.string(from: NSDecimalNumber(decimal: decimal))
        }

        func replacing(
            pattern: String,
            transform: (_ match: NSTextCheckingResult, _ source: String) -> String?
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let source = text
            let matches = regex.matches(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            )
            for match in matches.reversed() {
                guard let sourceWhole = Range(match.range, in: source),
                      let replacement = transform(match, source) else { continue }
                let startOffset = source.distance(from: source.startIndex, to: sourceWhole.lowerBound)
                let endOffset = source.distance(from: source.startIndex, to: sourceWhole.upperBound)
                guard startOffset >= 0, endOffset <= boundaries.count - 1 else { continue }
                let displayStart = boundaries[startOffset]
                let displayEnd = boundaries[endOffset]
                let replacementCount = replacement.count
                let replacementBoundaries: [Int]
                if replacementCount == 0 {
                    replacementBoundaries = [displayStart]
                } else {
                    replacementBoundaries = (0...replacementCount).map { position in
                        displayStart + Int(
                            (Double(displayEnd - displayStart) * Double(position)
                                / Double(replacementCount)).rounded()
                        )
                    }
                }
                let wholeStart = text.index(text.startIndex, offsetBy: startOffset)
                let wholeEnd = text.index(text.startIndex, offsetBy: endOffset)
                let whole = wholeStart..<wholeEnd
                text.replaceSubrange(whole, with: replacement)
                boundaries.replaceSubrange(startOffset...endOffset, with: replacementBoundaries)
            }
        }

        // Times: 7:05 → "seven oh five"; 14:30 → "fourteen thirty".
        replacing(pattern: #"(?<![\w.])([0-2]?\d):([0-5]\d)(?![\w.])"#) { match, source in
            guard let hourRange = Range(match.range(at: 1), in: source),
                  let minuteRange = Range(match.range(at: 2), in: source),
                  let hour = spelled(String(source[hourRange])) else { return nil }
            let minuteRaw = String(source[minuteRange])
            if minuteRaw == "00" { return "\(hour) o'clock" }
            if minuteRaw.first == "0", let digit = spelled(String(minuteRaw.dropFirst())) {
                return "\(hour) oh \(digit)"
            }
            guard let minute = spelled(minuteRaw) else { return nil }
            return "\(hour) \(minute)"
        }

        func magnitudeWord(_ raw: String) -> String {
            switch raw.lowercased() {
            case "k": return "thousand"
            case "m": return "million"
            case "b": return "billion"
            case "t": return "trillion"
            default: return raw.lowercased()
            }
        }

        // Magnitude currency is a decimal quantity, not dollars-and-cents:
        // $1.5 million → "one point five million dollars".
        replacing(
            pattern: #"([$£€])\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*(thousand|million|billion|trillion|[kKmMbBtT])\b"#
        ) { match, source in
            guard let symbolRange = Range(match.range(at: 1), in: source),
                  let amountRange = Range(match.range(at: 2), in: source),
                  let magnitudeRange = Range(match.range(at: 3), in: source),
                  let amount = spelled(String(source[amountRange])) else { return nil }
            let unit: String
            switch String(source[symbolRange]) {
            case "£": unit = "pounds"
            case "€": unit = "euros"
            default: unit = "dollars"
            }
            return "\(amount) \(magnitudeWord(String(source[magnitudeRange]))) \(unit)"
        }

        // Numeric ranges must be captured before individual percentages/numbers:
        // 20–30% → "twenty to thirty percent".
        replacing(
            pattern: #"(?<![\w.])([0-9][0-9,]*(?:\.[0-9]+)?)\s*[-–—]\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*%"#
        ) { match, source in
            guard let lowerRange = Range(match.range(at: 1), in: source),
                  let upperRange = Range(match.range(at: 2), in: source),
                  let lower = spelled(String(source[lowerRange])),
                  let upper = spelled(String(source[upperRange])) else { return nil }
            return "\(lower) to \(upper) percent"
        }

        // Non-currency magnitudes retain the decimal reading.
        replacing(
            pattern: #"(?<![\w.])([0-9][0-9,]*(?:\.[0-9]+)?)\s*(thousand|million|billion|trillion|[kKmMbBtT])\b"#
        ) { match, source in
            guard let amountRange = Range(match.range(at: 1), in: source),
                  let magnitudeRange = Range(match.range(at: 2), in: source),
                  let amount = spelled(String(source[amountRange])) else { return nil }
            return "\(amount) \(magnitudeWord(String(source[magnitudeRange])))"
        }

        // Currency before generic numbers so the symbol and fractional unit are
        // spoken naturally rather than independently.
        replacing(pattern: #"([$£€])\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#) { match, source in
            guard let symbolRange = Range(match.range(at: 1), in: source),
                  let amountRange = Range(match.range(at: 2), in: source) else { return nil }
            let symbol = String(source[symbolRange])
            let raw = String(source[amountRange]).replacingOccurrences(of: ",", with: "")
            let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard let wholeValue = Int(pieces[0]),
                  let whole = spelled(String(wholeValue)) else { return nil }
            let unit: String
            let subunit: String
            switch symbol {
            case "£": unit = wholeValue == 1 ? "pound" : "pounds"; subunit = "pence"
            case "€": unit = wholeValue == 1 ? "euro" : "euros"; subunit = "cents"
            default:  unit = wholeValue == 1 ? "dollar" : "dollars"; subunit = "cents"
            }
            guard pieces.count == 2,
                  let cents = Int(pieces[1].padding(toLength: 2, withPad: "0", startingAt: 0)),
                  cents > 0,
                  let centsWords = spelled(String(cents)) else {
                return "\(whole) \(unit)"
            }
            return "\(whole) \(unit) and \(centsWords) \(subunit)"
        }

        replacing(pattern: #"(?<![\w.])([0-9][0-9,]*(?:\.[0-9]+)?)\s*%"#) { match, source in
            guard let numberRange = Range(match.range(at: 1), in: source),
                  let words = spelled(String(source[numberRange])) else { return nil }
            return "\(words) percent"
        }

        let ordinalEndings: [String: String] = [
            "one": "first", "two": "second", "three": "third", "five": "fifth",
            "eight": "eighth", "nine": "ninth", "twelve": "twelfth"
        ]
        replacing(pattern: #"(?<![\w.])([0-9][0-9,]*)(st|nd|rd|th)(?!\w)"#) { match, source in
            guard let numberRange = Range(match.range(at: 1), in: source),
                  let cardinal = spelled(String(source[numberRange])) else { return nil }
            var words = cardinal.split(separator: " ").map(String.init)
            guard let last = words.last else { return cardinal }
            words[words.count - 1] = ordinalEndings[last] ?? {
                if last.hasSuffix("y") { return String(last.dropLast()) + "ieth" }
                return last + "th"
            }()
            return words.joined(separator: " ")
        }

        // Remaining integers and decimals.
        replacing(pattern: #"(?<![\w.])[-+]?[0-9][0-9,]*(?:\.[0-9]+)?(?![\w.])"#) { match, source in
            guard let range = Range(match.range, in: source) else { return nil }
            return spelled(String(source[range]))
        }

        return SpeechForm(spoken: text, spokenBoundaryToDisplay: boundaries)
    }

    /// Turn a raw code token into words a TTS voice can read naturally.
    /// Examples: `.voiceChat` → "voice chat",  `releaseMicForPlayback()` → "release mic for playback",
    ///           `AVAudioSession` → "AV audio session",  `Chat.swift` → "Chat dot swift"
    private static func naturalCodePhrase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return raw }

        // Recognise file extensions before we destroy the dot
        for ext in ["swift", "py", "js", "ts", "json", "html", "css", "md", "txt", "cpp", "h"] {
            if s.hasSuffix(".\(ext)") {
                s = String(s.dropLast(ext.count + 1)) + " dot \(ext)"
                break
            }
        }

        // Strip trailing () — function-call indicator
        if s.hasSuffix("()") { s = String(s.dropLast(2)) }

        // Dots → spaces (member access, leading enum dot, chained paths)
        // Underscores → spaces (snake_case)
        s = s.replacingOccurrences(of: ".", with: " ")
             .replacingOccurrences(of: "_", with: " ")

        // Split camelCase / PascalCase into words
        s = splitCamelCase(s)

        // Strip leftover syntax punctuation (parens, brackets, commas, colons…)
        s = s.replacingOccurrences(of: #"[^a-zA-Z0-9 ]"#, with: " ", options: .regularExpression)

        // Collapse whitespace
        s = s.split(separator: " ").joined(separator: " ")

        return s.isEmpty ? raw : s
    }

    /// Insert a space before each capital that marks a new word in a camelCase or
    /// PascalCase identifier. Handles ALL_CAPS runs like "AV" or "URL" correctly:
    /// the split fires at the boundary between the run and the following word
    /// (e.g. "AVAudio" → "AV Audio", "URLSession" → "URL Session").
    private static func splitCamelCase(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let c = chars[i]
            if c.isUppercase, i > 0 {
                let prevLower = chars[i - 1].isLowercase
                let prevUpper = chars[i - 1].isUppercase
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prevLower || (prevUpper && nextLower) { out += " " }
            }
            out.append(c)
        }
        return out
    }
}
