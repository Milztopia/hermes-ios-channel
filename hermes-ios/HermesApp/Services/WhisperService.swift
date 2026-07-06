import Foundation
import WhisperKit

struct KaraokeWordTiming: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let charStart: Int
    let charEnd: Int
}

// MARK: - WhisperService
// Wraps WhisperKit for on-device transcription (whisper-base, ~147 MB).
// The model + tokenizer are bundled in the app (Resources/whisper-base), so the
// first use works fully offline with no download.

@Observable
@MainActor
final class WhisperService {
    var isLoading = false
    var isLoaded = false
    var loadError: String?
    var loadProgress: Double = 0

    private var kit: WhisperKit?
    // Single shared load. Concurrent callers (launch preload + first transcribe)
    // await the SAME task instead of racing — so transcribe never fails just
    // because a load was already in flight.
    private var loadTask: Task<WhisperKit?, Never>?

    // MARK: - Load

    func loadModelIfNeeded() async {
        _ = await ensureKit()
    }

    private func ensureKit() async -> WhisperKit? {
        if let kit { return kit }
        if let loadTask { return await loadTask.value }

        isLoading = true
        loadError = nil
        let task = Task<WhisperKit?, Never> {
            do {
                let config: WhisperKitConfig
                if let bundled = Bundle.main.url(forResource: "whisper-base", withExtension: nil) {
                    // Bundled model + tokenizer — fully offline, no download.
                    config = WhisperKitConfig(
                        modelFolder: bundled.path,
                        tokenizerFolder: bundled,
                        verbose: false,
                        logLevel: .none,
                        load: true,
                        download: false
                    )
                } else {
                    config = WhisperKitConfig(model: "openai/whisper-base", verbose: false, logLevel: .none)
                }
                return try await WhisperKit(config)
            } catch {
                self.loadError = error.localizedDescription
                NSLog("HERMES whisper LOAD ERROR: \(error)")
                return nil
            }
        }
        loadTask = task
        let result = await task.value
        kit = result
        isLoaded = (result != nil)
        isLoading = false
        if result == nil { loadTask = nil }   // allow a retry after failure
        NSLog("HERMES whisper load done isLoaded=\(isLoaded)")
        return result
    }

    // MARK: - Transcribe

    // float32 PCM samples at 16 kHz, mono
    func transcribe(_ samples: [Float]) async throws -> String {
        // Waits for an in-progress load (or starts one) instead of failing fast.
        guard let kit = await ensureKit() else { throw WhisperError.notLoaded }

        let results = try await kit.transcribe(audioArray: samples)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        NSLog("HERMES whisper transcribed len=\(text.count)")
        return text
    }

    /// Align a known TTS sentence to its generated audio. Whisper's attention
    /// timestamps provide real spoken word boundaries; the recognized words are
    /// mapped back onto the exact source text so the UI can progressively reveal
    /// each source word without changing its layout.
    func alignForKaraoke(wav: Data, expectedText: String) async throws -> [KaraokeWordTiming] {
        guard let kit = await ensureKit() else { throw WhisperError.notLoaded }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-karaoke-\(UUID().uuidString).wav")
        try wav.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0,
            temperatureFallbackCount: 0,
            wordTimestamps: true
        )
        let started = Date()
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        let recognized = results.flatMap(\.allWords)
        let source = Self.sourceWords(expectedText)
        let aligned = Self.mapTimings(source: source, recognized: recognized)
        NSLog("HERMES⏱ karaoke-align %.3fs source=%d recognized=%d aligned=%d",
              Date().timeIntervalSince(started), source.count, recognized.count, aligned.count)
        return aligned
    }

    private struct SourceWord {
        let normalized: String
        let start: Int
        let end: Int
    }

    private static func sourceWords(_ text: String) -> [SourceWord] {
        let chars = Array(text)
        var result: [SourceWord] = []
        var index = 0
        while index < chars.count {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            guard index < chars.count else { break }
            let start = index
            while index < chars.count, !chars[index].isWhitespace { index += 1 }
            let raw = String(chars[start..<index])
            let normalized = normalize(raw)
            if !normalized.isEmpty {
                result.append(SourceWord(normalized: normalized, start: start, end: index))
            }
        }
        return result
    }

    private static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func mapTimings(
        source: [SourceWord],
        recognized: [WordTiming]
    ) -> [KaraokeWordTiming] {
        guard !source.isEmpty, !recognized.isEmpty else { return [] }
        let heard = recognized.map { normalize($0.word) }
        var mapped: [Int: WordTiming] = [:]
        var heardIndex = 0

        for sourceIndex in source.indices {
            let wanted = source[sourceIndex].normalized
            let searchEnd = min(heard.count, heardIndex + 4)
            if let exact = (heardIndex..<searchEnd).first(where: { heard[$0] == wanted }) {
                mapped[sourceIndex] = recognized[exact]
                heardIndex = exact + 1
            } else if heardIndex < heard.count,
                      similarity(wanted, heard[heardIndex]) >= 0.6 {
                mapped[sourceIndex] = recognized[heardIndex]
                heardIndex += 1
            }
        }

        // A synthetic sentence should normally map every word. If Whisper misses
        // one, interpolate it between the surrounding known words instead of
        // abandoning the precise timeline for the whole sentence.
        var result: [KaraokeWordTiming] = []
        var index = 0
        while index < source.count {
            if let timing = mapped[index] {
                result.append(KaraokeWordTiming(
                    start: TimeInterval(timing.start),
                    end: TimeInterval(max(timing.end, timing.start + 0.04)),
                    charStart: source[index].start,
                    charEnd: source[index].end
                ))
                index += 1
                continue
            }

            let gapStart = index
            while index < source.count, mapped[index] == nil { index += 1 }
            let previousEnd = result.last?.end ?? 0
            let nextStart = index < source.count
                ? TimeInterval(mapped[index]?.start ?? Float(previousEnd + Double(index - gapStart) * 0.25))
                : previousEnd + Double(index - gapStart) * 0.25
            let count = index - gapStart
            let span = max(0.04 * Double(count), nextStart - previousEnd)
            for offset in 0..<count {
                let start = previousEnd + span * Double(offset) / Double(count)
                let end = previousEnd + span * Double(offset + 1) / Double(count)
                let word = source[gapStart + offset]
                result.append(KaraokeWordTiming(
                    start: start, end: end, charStart: word.start, charEnd: word.end))
            }
        }
        return result
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (ca == cb ? 0 : 1)
                ))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

enum WhisperError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "Whisper model not loaded" }
}
