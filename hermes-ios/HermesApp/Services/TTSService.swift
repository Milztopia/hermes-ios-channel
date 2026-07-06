import AVFoundation

// MARK: - TTSService
// Handles both server TTS (Hermes via /api/tts) and
// programmatically generated chimes for VAD state transitions.

@Observable
@MainActor
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    var isSpeaking = false
    // 0..1 live amplitude of current playback (drives the audio-reactive orb).
    var meterLevel: Float = 0
    // 0..1 fraction of the utterance spoken so far (drives karaoke highlight):
    // exact char-based for AVSpeech; for WAV playback, word-synced — each chunk's
    // real audio duration is spread across its words by syllable weight.
    var progressFraction: Double = 0
    var progressCharacterIndex: Int = 0

    // Speech and UI cues must not share a player reference. Replacing the speech
    // player with a chime (or vice versa) can deallocate the first player and cut
    // its audio off mid-cue.
    private var player: AVAudioPlayer?
    private var cuePlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    // Producer task for the current server-TTS stream (fetching not-yet-played
    // chunks). Held so stop() can kill in-flight/future chunk fetches immediately.
    private var streamProducer: Task<Void, Never>?
    // Monotonic cancellation boundary. AsyncStream may already contain a rendered
    // chunk when its producer is cancelled; generation checks prevent that buffered
    // audio (or a late network/alignment completion) from starting after stop().
    private var playbackGeneration: UInt64 = 0
    // Looping "thinking" bed played from submit until the spoken response starts.
    private var thinkingPlayer: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Thinking bed (looping background sound while the reply is generated)

    /// Start the looping "thinking" bed. Plays from the moment a voice utterance is
    /// submitted until the spoken response begins, then it's crossfaded out (see
    /// `fadeOutThinkingLoop`). No-op if already playing. Session is .playback at
    /// this point (restoreOutputVolume was called; mic engine is torn down).
    func startThinkingLoop() {
        guard thinkingPlayer == nil else { return }
        guard let url = Bundle.main.url(forResource: "ThinkingLoop", withExtension: "m4a") else {
            NSLog("HERMES thinking bed: resource not found in bundle")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1          // loop until we fade/stop it
            p.volume = 0
            p.prepareToPlay()
            p.play()
            p.setVolume(1.0, fadeDuration: 0.22)    // max — the bed is also ducked in voice mode
            thinkingPlayer = p
        } catch {
            NSLog("HERMES thinking bed error: \(error)")
        }
    }

    /// Crossfade the thinking bed out as speech starts — a smooth ramp to silence,
    /// not an abrupt cut. No-op if it isn't playing (so it's safe to call on every
    /// speech chunk; only the first call, while the bed is live, does anything).
    func fadeOutThinkingLoop(duration: TimeInterval = 0.22) {
        guard let p = thinkingPlayer else { return }
        thinkingPlayer = nil
        p.setVolume(0, fadeDuration: duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { p.stop() }
    }

    /// Hard-stop the thinking bed immediately — for cancel / abandon / interrupt.
    func stopThinkingLoop() {
        thinkingPlayer?.stop()
        thinkingPlayer = nil
    }

    // MARK: - Chimes

    enum Chime {
        case ready   // 800 Hz, 150 ms — VAD ready, start listening
        case done    // 600 Hz, 150 ms — speech/run finished
    }

    func playChime(_ chime: Chime) {
        _ = startChime(chime)
    }

    /// Play one transition cue and wait for its actual playback to finish. Callers
    /// use this before changing the audio session or starting another audible cue,
    /// while unrelated work (transcription/model generation) may continue.
    func playChimeAndWait(_ chime: Chime, outputDrain: Bool = true) async {
        guard let activePlayer = startChime(chime) else { return }
        while cuePlayer === activePlayer, activePlayer.isPlaying {
            if Task.isCancelled {
                activePlayer.stop()
                if cuePlayer === activePlayer { cuePlayer = nil }
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if cuePlayer === activePlayer { cuePlayer = nil }
        // AVAudioPlayer reaches `isPlaying == false` when it has submitted its
        // final buffer, slightly before those samples clear speaker/Bluetooth
        // hardware. Leave a short output tail so the next audible state (thinking
        // bed or live microphone) cannot step on the cue's decay. The "ready"
        // chime is the exception: it tells the user to speak, so the mic must arm
        // as soon as the audible cue finishes.
        if outputDrain, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    @discardableResult
    private func startChime(_ chime: Chime) -> AVAudioPlayer? {
        guard let data = generateChimeWAV(chime) else { return nil }
        // Ensure the session is live. .playback routes to CarPlay/Bluetooth/headphones
        // and falls back to speaker. Only configure if neither .playback nor
        // .playAndRecord (mic active) is already set up.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord && session.category != .playback {
            try? session.setCategory(.playback, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
            try? session.setActive(true)
        }
        // Normalize so chimes are loud through the voice-processing duck. No extra
        // gain — they're pure tones and would buzz if clipped.
        do {
            let wav = Self.applyEdgeFades(Self.normalizedWAV(data))
            cuePlayer?.stop()
            let p = try AVAudioPlayer(data: wav)
            p.prepareToPlay()
            cuePlayer = p
            let started = p.play()
            NSLog("HERMES cue play started=\(started) dur=\(p.duration)")
            return started ? p : nil
        } catch {
            NSLog("HERMES cue play ERROR: \(error)")
            cuePlayer = nil
            return nil
        }
    }

    // Two-tone transition cues. Keep `ready` short because the app waits for it
    // before arming the mic; a long decay feels silent but still delays listening.
    private func generateChimeWAV(_ chime: Chime) -> Data? {
        let sr = 44100
        let f1: Double, f2: Double, switchT: Double, totalT: Double, peak: Double
        let attackT = 0.02
        var holdEnd = 0.0
        switch chime {
        case .ready: f1 = 523; f2 = 784; switchT = 0.10; totalT = 0.24; peak = 0.20; holdEnd = 0.16
        case .done:  f1 = 659; f2 = 494; switchT = 0.11; totalT = 0.32; peak = 0.16
        }
        let n = Int(Double(sr) * totalT)
        var samples: [Int16] = []
        samples.reserveCapacity(n)
        var phase = 0.0
        let floorG = 0.001
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            phase += 2 * Double.pi * (t < switchT ? f1 : f2) / Double(sr)
            let g: Double
            if t < attackT {
                g = peak * (t / attackT)                          // linear attack
            } else if chime == .ready && t < holdEnd {
                g = peak                                          // hold
            } else {
                let decayStart = (chime == .ready) ? holdEnd : attackT
                let frac = (t - decayStart) / (totalT - decayStart)
                g = peak * pow(floorG / peak, frac)               // exponential decay
            }
            samples.append(Int16(max(-1, min(1, sin(phase) * g)) * 32767))
        }
        return Self.makeWAV(samples: samples, sampleRate: sr, channels: 1)
    }

    // MARK: - Server TTS

    func speak(text: String, voice: String, client: HermesClient) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = playbackGeneration
        isSpeaking = true
        progressFraction = 0
        defer { isSpeaking = false; meterLevel = 0; progressFraction = 1 }
        do {
            let data = try await client.synthesize(text: text, voice: voice)
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            try? await Task.sleep(nanoseconds: Self.outputWarmupNanos)
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            await MainActor.run { playWAV(data, normalize: true, extraGain: Self.voiceLoudness) }
            await meterAndWait()
        } catch {
            // Non-fatal — silence is fine if TTS fails
        }
    }

    /// One unit of streamed audio: a WAV ready to play, the exact text it covers,
    /// and where that text starts in the full reply (so karaoke maps precisely
    /// onto the displayed string). Sendable so it can cross the stream boundary.
    struct TTSChunk: Sendable {
        let data: Data
        let text: String
        let baseChars: Int
        let preciseTimeline: [KaraokeWordTiming]?

        init(data: Data, text: String, baseChars: Int,
             preciseTimeline: [KaraokeWordTiming]? = nil) {
            self.data = data
            self.text = text
            self.baseChars = baseChars
            self.preciseTimeline = preciseTimeline
        }
    }

    /// Render and precisely align one server-TTS sentence without playing it.
    /// VoiceCoordinator uses this to keep one sentence prepared ahead of the
    /// sentence currently reaching the listener.
    func prepareServerChunk(
        text: String,
        voice: String,
        client: HermesClient,
        karaokeAligner: WhisperService? = nil
    ) async -> TTSChunk? {
        let generation = playbackGeneration
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let tReq = Date()
            let data = try await client.synthesize(text: text, voice: voice)
            NSLog("HERMES⏱ server-tts    %.3fs  bytes=%d  chars=%d",
                  Date().timeIntervalSince(tReq), data.count, text.count)
            guard !Task.isCancelled, generation == playbackGeneration else { return nil }
            let preciseTimeline: [KaraokeWordTiming]?
            if let karaokeAligner {
                preciseTimeline = try? await karaokeAligner.alignForKaraoke(
                    wav: data,
                    expectedText: text
                )
            } else {
                preciseTimeline = nil
            }
            guard !Task.isCancelled, generation == playbackGeneration else { return nil }
            return TTSChunk(
                data: data,
                text: text,
                baseChars: 0,
                preciseTimeline: preciseTimeline
            )
        } catch {
            NSLog("HERMES server-tts prepare error: \(error)")
            return nil
        }
    }

    /// Play one already-rendered sentence. Preparation of the next sentence can
    /// continue concurrently while this awaits audible completion.
    func playPreparedServerChunk(_ chunk: TTSChunk) async {
        let pair = AsyncStream<TTSChunk>.makeStream()
        pair.continuation.yield(chunk)
        pair.continuation.finish()
        await playChunks(pair.stream, totalChars: max(1, chunk.text.count))
    }

    /// Establish the next sentence's timing baseline before its UI monitor starts.
    /// The previous sentence intentionally leaves progress at 1; without this
    /// explicit boundary a concurrently-created monitor can briefly inherit that
    /// value and mark the new sentence complete before playback resets it.
    func beginPreparedSentence() {
        progressFraction = 0
        progressCharacterIndex = 0
        meterLevel = 0
    }

    /// Streaming server TTS: splits the reply into sentence-sized chunks, fetches
    /// each from /api/tts, and starts playing the first one as soon as it lands
    /// while later chunks fetch in the background. Same latency win as on-device
    /// Kokoro streaming. Hermes can return whole audio per request; we request
    /// one sentence at a time to preserve quick first playback.
    func speakStream(
        text: String,
        voice: String,
        client: HermesClient,
        karaokeAligner: WhisperService? = nil
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = playbackGeneration
        // Range-based chunking so each chunk's character offset maps exactly onto
        // the displayed text (no trimming/drift) — required for synced karaoke.
        // The caller (voice streaming) already feeds us one sentence at a time, so
        // keep each sentence as a SINGLE request/WAV — splitting it would put a gap
        // mid-sentence. Only a pathological run-on (> this cap) would ever split,
        // and the upstream run-on flush keeps segments well under it.
        let ranges = KokoroService.sentenceChunkRanges(text, maxChars: 600, fastFirst: true)
        let stream = AsyncStream<TTSChunk> { continuation in
            let task = Task {
                for r in ranges {
                    if Task.isCancelled || generation != playbackGeneration { break }
                    let piece = String(text[r])
                    let base = text.distance(from: text.startIndex, to: r.lowerBound)
                    do {
                        let tReq = Date()
                        let data = try await client.synthesize(text: piece, voice: voice)
                        NSLog("HERMES⏱ server-tts    %.3fs  bytes=%d  chars=%d",
                              Date().timeIntervalSince(tReq), data.count, piece.count)
                        if Task.isCancelled || generation != playbackGeneration { break }
                        let preciseTimeline: [KaraokeWordTiming]?
                        if let karaokeAligner {
                            preciseTimeline = try? await karaokeAligner.alignForKaraoke(
                                wav: data, expectedText: piece)
                        } else {
                            preciseTimeline = nil
                        }
                        if Task.isCancelled || generation != playbackGeneration { break }
                        continuation.yield(TTSChunk(
                            data: data,
                            text: piece,
                            baseChars: base,
                            preciseTimeline: preciseTimeline
                        ))
                    } catch {
                        NSLog("HERMES tts stream chunk error: \(error)")
                    }
                }
                continuation.finish()
            }
            streamProducer = task
            continuation.onTermination = { _ in task.cancel() }
        }
        await playChunks(stream, totalChars: text.count, generation: generation)
        if generation == playbackGeneration { streamProducer = nil }
    }

    // MARK: - On-device TTS (AVSpeechSynthesizer — fully local, no server)

    func speakOnDevice(text: String, voiceId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSpeaking = true
        progressFraction = 0
        defer { isSpeaking = false; meterLevel = 0; progressFraction = 1 }

        do {
            let session = AVAudioSession.sharedInstance()
            // Don't reset the session if it's already .playback or .playAndRecord.
            // Reconfiguring to .playAndRecord here was overriding the .playback session
            // (set by restoreOutputVolume) and routing AVSpeechSynthesizer audio to
            // the phone speaker instead of CarPlay.
            if session.category != .playAndRecord && session.category != .playback {
                try session.setCategory(.playback, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
                try session.setActive(true)
            }
        } catch { NSLog("HERMES tts(onDevice) session ERROR: \(error)") }

        let utt = AVSpeechUtterance(string: trimmed)
        if let voiceId, let v = AVSpeechSynthesisVoice(identifier: voiceId) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        synthesizer.speak(utt)   // progressFraction updated exactly by the delegate
        fadeOutThinkingLoop()    // crossfade the thinking bed out as speech begins

        // Wait for start, then until playback finishes. AVSpeech gives no audio
        // buffer to meter, so drive a gentle synthetic pulse for the orb.
        try? await Task.sleep(nanoseconds: 200_000_000)
        var t = 0.0
        while synthesizer.isSpeaking || synthesizer.isPaused {
            if Task.isCancelled { synthesizer.stopSpeaking(at: .immediate); break }
            t += 0.1
            meterLevel = 0.35 + 0.25 * Float(abs(sin(t * 5.0)))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // Play raw Float PCM (e.g. Kokoro's 24kHz output) through the speaker.
    func play(samples: [Float], sampleRate: Int) async {
        guard !samples.isEmpty else { return }
        let pcm16 = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let data = Self.makeWAV(samples: pcm16, sampleRate: sampleRate, channels: 1)
        isSpeaking = true
        progressFraction = 0
        defer { isSpeaking = false; meterLevel = 0; progressFraction = 1 }
        await MainActor.run { playWAV(data) }
        await meterAndWait()
    }

    /// Play a stream of pre-rendered WAV chunks back-to-back, starting the moment
    /// the first arrives. Karaoke timing is derived cheaply from each finished WAV:
    /// voiced onset/ending and real silence gaps constrain a syllable-weighted word
    /// schedule. No second model pass is required.
    func playChunks(
        _ stream: AsyncStream<TTSChunk>,
        totalChars: Int,
        generation: UInt64? = nil
    ) async {
        let activeGeneration = generation ?? playbackGeneration
        isSpeaking = true
        progressFraction = 0
        let t0Chunks = Date()
        var firstChunkLogged = false
        var outputSettled = false
        defer { isSpeaking = false; meterLevel = 0; progressFraction = 1 }
        for await item in stream {
            if Task.isCancelled || activeGeneration != playbackGeneration {
                player?.stop()
                break
            }
            if !firstChunkLogged {
                firstChunkLogged = true
                let e = Date().timeIntervalSince(t0Chunks)
                NSLog("HERMES⏱ first-audio   +%.3fs  bytes=%d", e, item.data.count)
                TimingReporter.mark("first-audio", detail: "bytes=\(item.data.count) synth=\(String(format:"%.3f",e))s")
                fadeOutThinkingLoop()   // crossfade the thinking bed out as speech begins
            }
            // AVAudioPlayer.currentTime can run slightly ahead of what has reached
            // the listener through the hardware/Bluetooth route. Preserve a small
            // audible-output allowance so even precise timestamps do not look early.
            let preciseTimeline = Self.validPreciseTimeline(
                item.preciseTimeline,
                wav: item.data,
                text: item.text
            )
            let wordTimeline = preciseTimeline?.map {
                KaraokeWordTiming(
                    start: $0.start + 0.12,
                    end: $0.end + 0.12,
                    charStart: $0.charStart,
                    charEnd: $0.charEnd
                )
            } ?? Self.wordTimeline(wav: item.data, text: item.text)
            guard !Task.isCancelled, activeGeneration == playbackGeneration else { break }
            if !outputSettled {
                outputSettled = true
                try? await Task.sleep(nanoseconds: Self.outputWarmupNanos)
                guard !Task.isCancelled, activeGeneration == playbackGeneration else { break }
            }
            playWAV(item.data, normalize: true, extraGain: Self.voiceLoudness)
            await meterAndWaitSynced(wordTimeline: wordTimeline,
                                     baseChars: item.baseChars,
                                     chunkChars: item.text.count,
                                     totalChars: max(1, totalChars),
                                     generation: activeGeneration)
        }
    }

    /// Switch the audio session to playback-only so TTS routes to CarPlay / Bluetooth /
    /// headphones naturally and falls back to the built-in speaker when nothing is
    /// connected. Called right before TTS playback begins (after the mic engine is
    /// torn down via releaseMicForPlayback). Using .playAndRecord + .defaultToSpeaker
    /// here was pinning audio to the built-in speaker even with a car stereo connected
    /// via USB-C CarPlay, because .defaultToSpeaker only defers to headphones, not to
    /// USB/CarPlay outputs.
    func restoreOutputVolume() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    func stop() {
        playbackGeneration &+= 1
        streamProducer?.cancel()
        streamProducer = nil
        // User-requested stop must be synchronous. Muting first prevents a tail/pop;
        // stop immediately flushes AVAudioPlayer instead of allowing several quiet
        // words through a fade or a queued chunk transition.
        player?.volume = 0
        player?.stop()
        player = nil
        cuePlayer?.volume = 0
        cuePlayer?.stop()
        cuePlayer = nil
        stopThinkingLoop()   // hard cut — cancel/abandon/interrupt
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    // MARK: - Internals

    private func playWAV(_ data: Data, normalize: Bool = false, extraGain: Float = 1.0) {
        do {
            // Normalize first, then fade the tail so AVAudioPlayer stopping at a
            // non-zero sample doesn't pop. Applies to TTS chunks and chimes alike.
            let wav = Self.applyEdgeFades(normalize ? Self.normalizedWAV(data, extraGain: extraGain) : data)
            // playAndRecord + force-speaker so this works while voice mode holds
            // the mic (a .playback switch conflicts with the live record engine).
            let session = AVAudioSession.sharedInstance()
            // Leave the session alone if it's already .playback (TTS routing to CarPlay /
            // Bluetooth / headphones, set by restoreOutputVolume) or .playAndRecord (mic
            // is active). Reconfiguring on every chunk causes an audible gap. Only set
            // up a fresh session for standalone playback (e.g. a chime with no prior session).
            if session.category != .playAndRecord && session.category != .playback {
                try session.setCategory(.playback, options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
                try session.setActive(true)
            }
            player = try AVAudioPlayer(data: wav)
            player?.prepareToPlay()
            player?.isMeteringEnabled = true
            let ok = player?.play() ?? false
            NSLog("HERMES tts playWAV bytes=\(data.count) started=\(ok) dur=\(player?.duration ?? -1)")
        } catch {
            NSLog("HERMES tts playWAV ERROR: \(error)")
        }
    }

    // Poll the player ~25Hz: update meterLevel (amplitude) + progressFraction
    // (playback position) so the orb reacts and the transcript scrolls/highlights.
    private func meterAndWait() async {
        guard let p = player else { return }
        let dur = p.duration
        while let p = player, p.isPlaying {
            p.updateMeters()
            let db = p.averagePower(forChannel: 0)            // ~ -160...0 dB
            meterLevel = max(0, min(1, (db + 45) / 45))       // -45..0 dB → 0..1
            progressFraction = dur > 0 ? min(1, p.currentTime / dur) : 0
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        if !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.outputDrainNanos)
        }
    }

    // Snap whole words to white at their estimated audible start. `wordTimeline`
    // incorporates actual voiced onset, ending, and detected pauses from the WAV,
    // which avoids the large global drift caused by mapping the entire file duration
    // linearly across text.
    private func meterAndWaitSynced(
        wordTimeline: [KaraokeWordTiming],
        baseChars: Int,
        chunkChars: Int,
        totalChars: Int,
        generation: UInt64
    ) async {
        guard let p = player else { return }
        var highlightedChars = 0
        var lastHighlightUpdate = Date()
        let maxCharsPerSecond = max(18, Double(chunkChars) / max(0.5, p.duration) * 1.35)
        while let p = player,
              p.isPlaying,
              generation == playbackGeneration,
              !Task.isCancelled {
            p.updateMeters()
            let db = p.averagePower(forChannel: 0)
            meterLevel = max(0, min(1, (db + 45) / 45))
            if let current = wordTimeline.last(where: { p.currentTime >= $0.start }) {
                let duration = max(0.04, current.end - current.start)
                let wordProgress = max(0, min(1, (p.currentTime - current.start) / duration))
                let targetChars = current.charStart
                    + Int(Double(current.charEnd - current.charStart) * wordProgress)
                let now = Date()
                let elapsed = max(0.025, now.timeIntervalSince(lastHighlightUpdate))
                let maxAdvance = max(1, Int((maxCharsPerSecond * elapsed).rounded(.up)))
                highlightedChars = min(targetChars, highlightedChars + maxAdvance)
                lastHighlightUpdate = now
            }
            progressFraction = min(
                1,
                Double(baseChars + highlightedChars) / Double(totalChars)
            )
            progressCharacterIndex = baseChars + highlightedChars
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if generation == playbackGeneration, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.outputDrainNanos)
        }
        guard generation == playbackGeneration, !Task.isCancelled else { return }
        // Ensure the whole chunk is marked spoken once its audio ends.
        progressFraction = min(1, Double(baseChars + chunkChars) / Double(totalChars))
        progressCharacterIndex = baseChars + chunkChars
    }

    private static func validPreciseTimeline(
        _ timeline: [KaraokeWordTiming]?,
        wav: Data,
        text: String
    ) -> [KaraokeWordTiming]? {
        guard let timeline, !timeline.isEmpty else { return nil }
        let textCount = text.count
        guard let first = timeline.first,
              let last = timeline.last,
              first.start >= 0,
              last.end > first.start,
              last.charEnd <= textCount else { return nil }

        var previousEnd = 0.0
        var previousCharEnd = 0
        for item in timeline {
            guard item.start >= 0,
                  item.end >= item.start,
                  item.start >= previousEnd - 0.05,
                  item.charStart >= 0,
                  item.charEnd >= item.charStart,
                  item.charStart >= previousCharEnd,
                  item.charEnd <= textCount else {
                return nil
            }
            previousEnd = item.end
            previousCharEnd = item.charEnd
        }

        guard let activity = analyzeActivity(wav) else { return timeline }
        let minimumUsefulEnd = max(0.35, activity.speechEnd * 0.72)
        if last.end < minimumUsefulEnd {
            NSLog("HERMES karaoke precise timeline rejected: lastEnd=%.3f speechEnd=%.3f chars=%d",
                  last.end, activity.speechEnd, textCount)
            return nil
        }
        return timeline
    }

    private struct WordTiming {
        let end: Int
        let weight: Double
        let hasPauseAfter: Bool
    }

    private struct AudioActivity {
        let duration: TimeInterval
        let speechStart: TimeInterval
        let speechEnd: TimeInterval
        let pauses: [(start: TimeInterval, end: TimeInterval)]
    }

    /// Build a whole-word timeline from text plus lightweight PCM energy analysis.
    /// Detected silence gaps are greedily associated with punctuation boundaries
    /// near the same relative position in the sentence.
    private static func wordTimeline(wav: Data, text: String) -> [KaraokeWordTiming] {
        let arr = Array(text)
        let n = arr.count
        var words: [WordTiming] = []
        var i = 0
        while i < n {
            while i < n, arr[i] == " " || arr[i] == "\n" { i += 1 }   // skip spaces
            guard i < n else { break }
            while i < n, arr[i] != " ", arr[i] != "\n" { i += 1 }
            let end = i
            let start = arr[..<end].lastIndex(where: { $0 == " " || $0 == "\n" })
                .map { arr.distance(from: arr.startIndex, to: $0) + 1 } ?? 0
            let core = String(arr[start..<end])
            var w = Double(syllables(core))
            // Numbers and initialisms generally take longer to speak than their
            // visible character count or naïve vowel-group estimate suggests.
            if core.contains(where: \.isNumber) { w += 1.0 }
            let letters = core.filter(\.isLetter)
            if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
                w = max(w, Double(letters.count))
            }
            let last = core.last(where: { !$0.isWhitespace })
            words.append(WordTiming(
                end: end,
                weight: max(1, w),
                hasPauseAfter: last.map { ".,;:!?—".contains($0) } ?? false
            ))
        }
        guard !words.isEmpty else { return [] }

        let activity = analyzeActivity(wav)
        let duration = activity?.duration ?? max(0.1, Double(words.count) * 0.32)
        let speechStart = activity?.speechStart ?? 0
        let speechEnd = activity?.speechEnd ?? duration
        let pauses = activity?.pauses ?? []
        let pauseDuration = pauses.reduce(0) { $0 + ($1.end - $1.start) }
        let activeDuration = max(0.1, speechEnd - speechStart - pauseDuration)
        let totalWeight = words.reduce(0) { $0 + $1.weight }

        let punctuationIndices = words.indices.filter { words[$0].hasPauseAfter }
        var assignedPauses: [Int: TimeInterval] = [:]
        var minimumBoundary = 0
        for pause in pauses {
            let relativePause = (pause.start - speechStart) / max(0.1, speechEnd - speechStart)
            var best: (index: Int, distance: Double)?
            var cumulativeWeight = 0.0
            for wordIndex in words.indices {
                cumulativeWeight += words[wordIndex].weight
                guard wordIndex >= minimumBoundary,
                      punctuationIndices.contains(wordIndex) else { continue }
                let expected = cumulativeWeight / totalWeight
                let distance = abs(expected - relativePause)
                if best == nil || distance < best!.distance {
                    best = (wordIndex, distance)
                }
            }
            if let best {
                assignedPauses[best.index, default: 0] += pause.end - pause.start
                minimumBoundary = best.index + 1
            }
        }

        // AVAudioPlayer.currentTime describes the decoded stream, which can lead
        // what reaches the listener through the hardware/Bluetooth output path.
        // Keep a conservative audible-output allowance.
        let outputDelay: TimeInterval = 0.14
        var time = speechStart + outputDelay
        var result: [KaraokeWordTiming] = []
        for index in words.indices {
            let wordDuration = activeDuration * words[index].weight / totalWeight
            let previousEnd = index == 0 ? 0 : words[index - 1].end
            result.append(KaraokeWordTiming(
                start: min(time, duration),
                end: min(time + wordDuration, duration),
                charStart: previousEnd,
                charEnd: words[index].end
            ))
            time += wordDuration
            time += assignedPauses[index] ?? 0
        }
        return result
    }

    /// Analyze standard PCM16 WAV energy in 20 ms windows. This takes well under
    /// a millisecond for normal sentence chunks and does not delay synthesis.
    private static func analyzeActivity(_ wav: Data) -> AudioActivity? {
        let bytes = [UInt8](wav)
        guard bytes.count > 44,
              let dataStart = findDataChunk(bytes) else { return nil }
        let channels = max(1, Int(bytes[22]) | (Int(bytes[23]) << 8))
        let sampleRate = Int(bytes[24]) | (Int(bytes[25]) << 8)
            | (Int(bytes[26]) << 16) | (Int(bytes[27]) << 24)
        let bits = Int(bytes[34]) | (Int(bytes[35]) << 8)
        guard sampleRate > 0, bits == 16 else { return nil }

        let frameBytes = channels * 2
        let frameCount = (bytes.count - dataStart) / frameBytes
        guard frameCount > 0 else { return nil }
        let windowFrames = max(1, sampleRate / 50) // 20 ms
        var rms: [Double] = []
        rms.reserveCapacity((frameCount + windowFrames - 1) / windowFrames)
        var frame = 0
        while frame < frameCount {
            let end = min(frameCount, frame + windowFrames)
            var sum = 0.0
            var count = 0
            for sampleFrame in frame..<end {
                for channel in 0..<channels {
                    let offset = dataStart + sampleFrame * frameBytes + channel * 2
                    guard offset + 1 < bytes.count else { continue }
                    let value = Int16(bitPattern:
                        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
                    let normalized = Double(value) / 32768.0
                    sum += normalized * normalized
                    count += 1
                }
            }
            rms.append(count > 0 ? sqrt(sum / Double(count)) : 0)
            frame = end
        }
        guard let peak = rms.max(), peak > 0.001 else { return nil }
        let threshold = max(0.006, peak * 0.07)
        var voiced = rms.map { $0 >= threshold }

        // Bridge very short unvoiced gaps (< 100 ms) inside speech; retain longer
        // gaps as real pauses.
        var cursor = 0
        while cursor < voiced.count {
            guard !voiced[cursor] else { cursor += 1; continue }
            let start = cursor
            while cursor < voiced.count, !voiced[cursor] { cursor += 1 }
            if start > 0, cursor < voiced.count, cursor - start < 5 {
                for index in start..<cursor { voiced[index] = true }
            }
        }
        guard let first = voiced.firstIndex(of: true),
              let last = voiced.lastIndex(of: true) else { return nil }
        let windowSeconds = Double(windowFrames) / Double(sampleRate)
        var pauses: [(TimeInterval, TimeInterval)] = []
        cursor = first
        while cursor <= last {
            guard !voiced[cursor] else { cursor += 1; continue }
            let start = cursor
            while cursor <= last, !voiced[cursor] { cursor += 1 }
            let length = cursor - start
            if length >= 6 { // at least ~120 ms
                pauses.append((
                    Double(start) * windowSeconds,
                    Double(cursor) * windowSeconds
                ))
            }
        }
        return AudioActivity(
            duration: Double(frameCount) / Double(sampleRate),
            speechStart: Double(first) * windowSeconds,
            speechEnd: min(
                Double(frameCount) / Double(sampleRate),
                Double(last + 1) * windowSeconds
            ),
            pauses: pauses
        )
    }

    // Rough syllable count = number of vowel groups (min 1). Correlates with
    // spoken length far better than character count.
    private static func syllables(_ word: String) -> Int {
        let vowels = Set("aeiouy")
        var count = 0, prevVowel = false
        for ch in word.lowercased() {
            let isV = vowels.contains(ch)
            if isV, !prevVowel { count += 1 }
            prevVowel = isV
        }
        return max(1, count)
    }

    // MARK: - AVSpeechSynthesizerDelegate (exact word timing for Apple voices)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let total = (utterance.speechString as NSString).length
        let spoken = characterRange.location + characterRange.length
        let frac = total > 0 ? Double(spoken) / Double(total) : 0
        Task { @MainActor in self.progressFraction = min(1, frac) }
    }

    // MARK: - Sine WAV generation

    private func generateSineWAV(frequency: Double, durationMs: Int, amplitude: Double) -> Data? {
        let sampleRate: Int = 44100
        let totalSamples = sampleRate * durationMs / 1000
        var samples: [Int16] = []
        samples.reserveCapacity(totalSamples)

        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            // Fade envelope: 10ms fade-in + 10ms fade-out
            let fadeFrames = sampleRate / 100
            let env: Double
            if i < fadeFrames {
                env = Double(i) / Double(fadeFrames)
            } else if i > totalSamples - fadeFrames {
                env = Double(totalSamples - i) / Double(fadeFrames)
            } else {
                env = 1.0
            }
            let value = sin(2 * Double.pi * frequency * t) * amplitude * env
            samples.append(Int16(value * 32767))
        }

        return Self.makeWAV(samples: samples, sampleRate: sampleRate, channels: 1)
    }

    /// Peak-normalize a 16-bit PCM WAV to `target` of full scale, then apply
    /// `extraGain` on top (hard-limited) to push the signal louder through the
    /// voice-processing output duck that `.playAndRecord` applies in voice mode.
    /// `extraGain > 1` clips the loudest peaks but raises the body of the speech
    /// (a loudness maximizer). Returns the input unchanged if not 16-bit PCM.
    static func normalizedWAV(_ data: Data, target: Float = 0.97, extraGain: Float = 1.0) -> Data {
        var bytes = [UInt8](data)
        guard let start = findDataChunk(bytes), start + 1 < bytes.count else { return data }
        func sample(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)) }
        var peak: Int32 = 0
        var i = start
        while i + 1 < bytes.count { let a = abs(Int32(sample(i))); if a > peak { peak = a }; i += 2 }
        guard peak > 0 else { return data }
        let gain = (Float(32767) * target / Float(peak)) * extraGain
        guard gain > 1.01 else { return data }   // already loud enough
        // Soft-clip limiter: below `knee` of full scale the signal is linear (the
        // body of the speech just gets louder); above it, peaks are rounded off
        // smoothly toward full scale with tanh instead of hard-clipped. Same
        // loudness, far less of the buzzy distortion a brick-wall clip produces.
        let knee: Float = 0.62
        i = start
        while i + 1 < bytes.count {
            var v = (Float(sample(i)) / 32768.0) * gain
            let a = abs(v)
            if a > knee {
                let over = (a - knee) / (1 - knee)
                v = (v < 0 ? -1 : 1) * min(knee + (1 - knee) * tanhf(over), 0.999)
            }
            let out = Int16(max(-32767, min(32767, v * 32767)))
            let u = UInt16(bitPattern: out)
            bytes[i] = UInt8(u & 0xFF); bytes[i + 1] = UInt8(u >> 8)
            i += 2
        }
        return Data(bytes)
    }

    /// Extra loudness on top of peak-normalization. Voice processing is now torn
    /// down during playback (no output duck), so the normalized signal already
    /// plays at full level — only a gentle lift is needed, which keeps it clean
    /// (the soft limiter barely engages). Raise toward ~1.5 if more is wanted.
    private static let voiceLoudness: Float = 1.2
    private static let outputWarmupNanos: UInt64 = 120_000_000
    private static let outputDrainNanos: UInt64 = 120_000_000

    /// Apply a short linear fade-in and fade-out to a 16-bit PCM WAV so AVAudioPlayer
    /// neither pops when it starts (DAC jump from silence to a non-zero first sample)
    /// nor clicks when it stops (DAC snap from a non-zero last sample to silence).
    /// Reads sample rate from the standard RIFF/WAVE fmt chunk (bytes 24-27).
    static func applyEdgeFades(_ data: Data, fadeInMs: Int = 8, fadeOutMs: Int = 25) -> Data {
        var bytes = [UInt8](data)
        guard bytes.count > 27, let dataStart = findDataChunk(bytes) else { return data }
        let sr = Int(bytes[24]) | (Int(bytes[25]) << 8) | (Int(bytes[26]) << 16) | (Int(bytes[27]) << 24)
        guard sr > 0 else { return data }
        let inSamples  = max(1, sr * fadeInMs  / 1000)
        let outSamples = max(1, sr * fadeOutMs / 1000)
        let totalSamples = (bytes.count - dataStart) / 2
        guard totalSamples > (inSamples + outSamples) * 2 else { return data }

        func applyGain(_ sampleIdx: Int, _ gain: Float) {
            let byteIdx = dataStart + sampleIdx * 2
            guard byteIdx + 1 < bytes.count else { return }
            let raw = Int16(bitPattern: UInt16(bytes[byteIdx]) | (UInt16(bytes[byteIdx + 1]) << 8))
            let faded = Int16(clamping: Int32(Float(raw) * gain))
            let u = UInt16(bitPattern: faded)
            bytes[byteIdx] = UInt8(u & 0xFF); bytes[byteIdx + 1] = UInt8(u >> 8)
        }

        // Fade in: 0.0 → 1.0 over the first inSamples
        for i in 0..<inSamples {
            applyGain(i, Float(i) / Float(inSamples))
        }
        // Fade out: 1.0 → 0.0 over the last outSamples
        let outStart = totalSamples - outSamples
        for i in 0..<outSamples {
            applyGain(outStart + i, Float(outSamples - 1 - i) / Float(outSamples))
        }
        return Data(bytes)
    }

    /// Byte offset of the first PCM sample (after the "data" subchunk header).
    /// Walks the RIFF subchunks so it isn't fooled by a "data" byte sequence in fmt.
    private static func findDataChunk(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > 12 else { return nil }
        var i = 12   // past "RIFF"<size>"WAVE"
        while i + 8 <= bytes.count {
            let isData = bytes[i] == 0x64 && bytes[i+1] == 0x61 && bytes[i+2] == 0x74 && bytes[i+3] == 0x61
            let size = Int(bytes[i+4]) | (Int(bytes[i+5]) << 8) | (Int(bytes[i+6]) << 16) | (Int(bytes[i+7]) << 24)
            if isData { return i + 8 }
            i += 8 + size + (size & 1)   // subchunks are word-aligned
        }
        return nil
    }

    fileprivate static func makeWAV(samples: [Int16], sampleRate: Int, channels: Int) -> Data {
        let dataSize = samples.count * 2
        var wav = Data()
        wav.appendLE("RIFF")
        wav.appendLE(Int32(36 + dataSize))
        wav.appendLE("WAVE")
        wav.appendLE("fmt ")
        wav.appendLE(Int32(16))
        wav.appendLE(Int16(1))              // PCM
        wav.appendLE(Int16(channels))
        wav.appendLE(Int32(sampleRate))
        wav.appendLE(Int32(sampleRate * channels * 2))  // byte rate
        wav.appendLE(Int16(channels * 2))   // block align
        wav.appendLE(Int16(16))             // bits per sample
        wav.appendLE("data")
        wav.appendLE(Int32(dataSize))
        for s in samples { wav.appendLE(s) }
        return wav
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLE(_ v: Int16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: Int32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ s: String) { append(contentsOf: s.utf8.prefix(4)) }
}

// MARK: - KokoroService (on-device neural TTS via mlx-audio-swift)

import MLXAudioTTS
import MLX

@Observable
@MainActor
final class KokoroService {
    static let shared = KokoroService()

    // English Kokoro voices (af_=US female, am_=US male, bf_=UK female, bm_=UK male).
    static let allVoices = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    var isLoading = false
    var isReady = false
    private(set) var isSynthesizing = false
    var loadError: String?

    // KokoroModel is non-Sendable; ferry it across the actor boundary safely.
    private final class Box<T>: @unchecked Sendable { let v: T; init(_ v: T) { self.v = v } }
    private var modelBox: Box<KokoroModel>?
    private var loadTask: Task<Void, Never>?
    // Producer task for the current streaming synthesis, so it can be killed
    // mid-flight (e.g. user exits voice mode) instead of synthesizing the rest.
    private var streamTask: Task<Void, Never>?

    var sampleRate: Int { modelBox?.v.sampleRate ?? 24000 }

    /// Kill any in-progress streaming synthesis (chunks not yet produced).
    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Release the model weights and GPU cache. Called when the app backgrounds
    /// so the 400MB+ of mapped MLX memory is freed, preventing page-fault storms
    /// during background scene-update watchdog checks (0x8BADF00D kills).
    /// loadIfNeeded() reloads transparently on next use.
    func unload() {
        guard !isLoading, !isSynthesizing else {
            cancelStreaming()
            return
        }
        cancelStreaming()
        loadTask?.cancel()
        loadTask = nil
        modelBox = nil
        isReady = false
        isLoading = false
        MLX.Memory.clearCache()
    }

    /// Background memory cleanup that never tears MLX state out from underneath
    /// an in-flight generation.
    func unloadIfIdle() {
        guard !isLoading, !isSynthesizing else { return }
        unload()
    }

    func loadIfNeeded() async {
        if isReady { return }
        if let loadTask { await loadTask.value; return }
        isLoading = true
        loadError = nil
        let task = Task { [weak self] in
            do {
                // Downloads the Kokoro model from HuggingFace on first use (cached
                // afterwards). Runs on GPU via mlx-audio-swift (correct + fast).
                // The text processor is REQUIRED — without it the model skips
                // phonemization and speaks gibberish. KokoroMultilingualProcessor
                // routes English through Misaki G2P.
                let model = try await KokoroModel.fromPretrained(
                    "mlx-community/Kokoro-82M-bf16",
                    textProcessor: KokoroMultilingualProcessor())
                // Bound MLX's GPU buffer cache so repeated synths don't grow into
                // a jetsam (signal 9) kill.
                MLX.Memory.cacheLimit = 256 * 1024 * 1024
                await MainActor.run { self?.modelBox = Box(model); self?.isReady = true }
            } catch {
                await MainActor.run { self?.loadError = "\(error)" }
                NSLog("HERMES kokoro load error: \(error)")
            }
        }
        loadTask = task
        await task.value
        isLoading = false
        if !isReady { loadTask = nil }   // allow retry
        NSLog("HERMES kokoro load done isReady=\(isReady) error=\(loadError ?? "none")")
    }

    /// Synthesize mono Float samples (at `sampleRate`) for the given voice.
    /// Long text is split into sentence-sized chunks (Kokoro caps at 510 tokens
    /// per call) and concatenated, then peak-normalized for consistent loudness.
    func synthesize(text: String, voice: String) async -> [Float]? {
        await loadIfNeeded()
        guard let modelBox else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lang = voice.hasPrefix("b") ? "en-gb" : "en-us"
        let model = modelBox.v
        let t0 = Date()
        var samples: [Float] = []
        isSynthesizing = true
        defer {
            isSynthesizing = false
            MLX.Memory.clearCache()
        }
        for piece in Self.chunkText(trimmed, maxChars: 380) {
            do {
                for try await chunk in model.generateSamplesStream(
                    text: piece, voice: voice, refAudio: nil, refText: nil, language: lang
                ) {
                    samples.append(contentsOf: chunk)
                }
            } catch {
                NSLog("HERMES kokoro synth chunk error: \(error)")
            }
        }
        NSLog("HERMES kokoro synth ok samples=\(samples.count) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        guard !samples.isEmpty else { return nil }
        return Self.normalize(samples)
    }

    /// Streaming synthesis: yields one ready-to-play WAV chunk per sentence-group
    /// as soon as it's synthesized, so the caller can start PLAYING the first
    /// sentence while the rest is still being generated. Each `TTSChunk` carries
    /// its exact text + character offset so the player can drive word-synced
    /// karaoke. The first chunk is a single sentence (fastest possible start);
    /// later chunks pack up to 380 chars for synthesis efficiency.
    func synthesizeStream(text: String, voice: String) -> AsyncStream<TTSService.TTSChunk> {
        // Range-based, full-coverage chunking over the DISPLAYED text so each
        // chunk's character offset maps exactly onto what the transcript shows.
        let ranges = Self.sentenceChunkRanges(text, maxChars: 380, fastFirst: true)
        let sr = sampleRate
        let lang = voice.hasPrefix("b") ? "en-gb" : "en-us"
        return AsyncStream { continuation in
            // Runs on the MainActor (KokoroService is @MainActor), cooperatively
            // interleaving with the player's awaits — this keeps every MLX call
            // on one thread (MLX requires serial access) while still overlapping
            // synthesis with playback.
            let task = Task { @MainActor in
                await loadIfNeeded()
                guard let modelBox else { continuation.finish(); return }
                isSynthesizing = true
                defer {
                    isSynthesizing = false
                    streamTask = nil
                    MLX.Memory.clearCache()
                }
                let model = modelBox.v
                for r in ranges {
                    if Task.isCancelled { break }
                    let piece = String(text[r])
                    let base = text.distance(from: text.startIndex, to: r.lowerBound)
                    let t0 = Date()
                    var samples: [Float] = []
                    do {
                        for try await chunk in model.generateSamplesStream(
                            text: piece, voice: voice, refAudio: nil, refText: nil, language: lang) {
                            samples.append(contentsOf: chunk)
                        }
                    } catch {
                        NSLog("HERMES kokoro stream chunk error: \(error)")
                    }
                    NSLog("HERMES kokoro stream chunk samples=\(samples.count) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
                    if Task.isCancelled { break }
                    if !samples.isEmpty {
                        let pcm16 = Self.normalize(samples).map { Int16(max(-1, min(1, $0)) * 32767) }
                        let data = TTSService.makeWAV(samples: pcm16, sampleRate: sr, channels: 1)
                        continuation.yield(TTSService.TTSChunk(data: data, text: piece, baseChars: base))
                    }
                }
                continuation.finish()
            }
            streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Range-based sentence chunking that FULLY covers `text` (no gaps, no
    /// trimming) so every displayed character belongs to exactly one chunk and
    /// karaoke offsets line up with the transcript. Packs sentences up to
    /// `maxChars`; when `fastFirst`, the first chunk is a single sentence for the
    /// quickest possible start. An over-long single sentence is split on spaces.
    fileprivate static func sentenceChunkRanges(_ text: String,
                                                maxChars: Int,
                                                fastFirst: Bool) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }

        // 1. Sentence ranges covering the whole string (terminator + following
        //    whitespace stay with the sentence that ends).
        var sentences: [Range<String.Index>] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            i = text.index(after: i)
            if ".!?\n".contains(c) {
                while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
                sentences.append(start..<i)
                start = i
            }
        }
        if start < text.endIndex { sentences.append(start..<text.endIndex) }
        if sentences.isEmpty { return [text.startIndex..<text.endIndex] }

        // 2. Expand any over-long sentence into space-delimited sub-ranges.
        func splitLong(_ r: Range<String.Index>) -> [Range<String.Index>] {
            if text.distance(from: r.lowerBound, to: r.upperBound) <= maxChars { return [r] }
            var out: [Range<String.Index>] = []
            var segStart = r.lowerBound
            var j = r.lowerBound
            var lastSpace: String.Index? = nil
            while j < r.upperBound {
                if text[j] == " " { lastSpace = j }
                if text.distance(from: segStart, to: j) >= maxChars, let sp = lastSpace, sp > segStart {
                    let cut = text.index(after: sp)
                    out.append(segStart..<cut); segStart = cut; lastSpace = nil
                }
                j = text.index(after: j)
            }
            if segStart < r.upperBound { out.append(segStart..<r.upperBound) }
            return out
        }
        var units: [Range<String.Index>] = []
        for s in sentences { units.append(contentsOf: splitLong(s)) }

        // 3. Pack units up to maxChars (first chunk kept to one unit if fastFirst).
        var ranges: [Range<String.Index>] = []
        var idx = 0
        if fastFirst, units.count > 1 { ranges.append(units[0]); idx = 1 }
        var curLo: String.Index? = nil
        var curHi = text.startIndex
        func flush() { if let lo = curLo { ranges.append(lo..<curHi) }; curLo = nil }
        while idx < units.count {
            let u = units[idx]
            let uLen = text.distance(from: u.lowerBound, to: u.upperBound)
            if curLo == nil {
                curLo = u.lowerBound; curHi = u.upperBound
            } else if text.distance(from: curLo!, to: curHi) + uLen > maxChars {
                flush(); curLo = u.lowerBound; curHi = u.upperBound
            } else {
                curHi = u.upperBound
            }
            idx += 1
        }
        flush()
        return ranges
    }

    /// Split text into chunks of at most `maxChars`, preferring sentence breaks.
    fileprivate static func chunkText(_ text: String, maxChars: Int) -> [String] {
        if text.count <= maxChars { return [text] }
        // Split into sentences (keep the terminator), then greedily pack.
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?\n".contains(ch) {
                sentences.append(current); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }

        var chunks: [String] = []
        var buf = ""
        func flush() { let t = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { chunks.append(t) }; buf = "" }
        for s in sentences {
            // A single over-long sentence: hard-split by words.
            if s.count > maxChars {
                flush()
                var wordBuf = ""
                for word in s.split(separator: " ", omittingEmptySubsequences: false) {
                    if wordBuf.count + word.count + 1 > maxChars {
                        let t = wordBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { chunks.append(t) }
                        wordBuf = ""
                    }
                    wordBuf += word + " "
                }
                let t = wordBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { chunks.append(t) }
            } else if buf.count + s.count > maxChars {
                flush(); buf = s
            } else {
                buf += s
            }
        }
        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    /// Peak-normalize to ~0.95 so Kokoro is as loud as the server voices.
    private static func normalize(_ s: [Float]) -> [Float] {
        var peak: Float = 0
        for v in s { let a = abs(v); if a > peak { peak = a } }
        guard peak > 0.0001 else { return s }
        let gain = min(0.95 / peak, 8.0)
        if gain <= 1.01 { return s }   // already loud enough
        return s.map { $0 * gain }
    }
}

// MARK: - BackgroundAudioKeepAlive
// Keeps the app alive past the ~30s background-task limit while a run is in
// flight (e.g. a long reply streaming with the screen locked). Plays a silent,
// looping buffer so the `audio` background mode keeps us scheduled. No-ops when
// voice mode already holds a record session (that keeps us alive on its own).
// NOTE: keeping a silent session active draws extra battery for the run's
// duration and isn't App-Store-compliant — fine for this personal build.

@MainActor
final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()

    private var player: AVAudioPlayer?
    private var activatedSession = false
    private var refCount = 0

    func begin() {
        refCount += 1
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord (mic active) and .playback (TTS routing to CarPlay / Bluetooth)
        // already keep the session alive — reconfiguring either would clobber the route
        // and cause a mid-playback audio glitch.
        guard session.category != .playAndRecord, session.category != .playback else { return }
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            activatedSession = true
            let p = try AVAudioPlayer(data: Self.silentWAV())
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
        } catch {
            NSLog("HERMES keepalive begin error: \(error)")
        }
    }

    func end() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        player?.stop()
        player = nil
        if activatedSession {
            activatedSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func silentWAV() -> Data {
        let sampleRate = 8000, seconds = 1
        let dataSize = sampleRate * seconds * 2
        var d = Data()
        func le32(_ v: Int32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: Int16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        str("RIFF"); le32(Int32(36 + dataSize)); str("WAVE")
        str("fmt "); le32(16); le16(1); le16(1); le32(Int32(sampleRate)); le32(Int32(sampleRate * 2)); le16(2); le16(16)
        str("data"); le32(Int32(dataSize))
        d.append(Data(count: dataSize))   // zeros = silence
        return d
    }
}
