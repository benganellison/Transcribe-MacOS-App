import Foundation
import FluidAudio

/// Fast first-pass transcription via FluidAudio's Parakeet v3 (multilingual,
/// auto language detection, ~120x real-time). Produces draft segments with word
/// timings for the progressive splice + diarized draft. The ONLY file importing
/// FluidAudio ASR types.
/// An `actor` (not `@MainActor`) so the Parakeet pass runs off the main thread.
actor DraftTranscriptionService {
    private var manager: AsrManager?

    enum DraftError: LocalizedError {
        case modelLoadFailed(String)
        case transcriptionFailed(String)
        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let m): return "Could not load draft model: \(m)"
            case .transcriptionFailed(let m): return "Draft transcription failed: \(m)"
            }
        }
    }

    /// Releases the Parakeet model to free memory once the draft is done (it isn't
    /// needed again until a re-transcribe), so it doesn't compete with Whisper.
    func release() {
        manager = nil
    }

    func prepare() async throws {
        if manager != nil { return }
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let m = AsrManager()
            try await m.loadModels(models)
            manager = m
        } catch {
            throw DraftError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Transcribes the whole file to draft segments (word-timed). FluidAudio's
    /// AudioConverter handles format internally.
    /// - Parameter languageCode: ISO code (e.g. "sv"); "auto"/nil/unsupported → auto-detect.
    ///   Passed to Parakeet v3 as a script-aware hint so Swedish audio isn't mis-decoded
    ///   as English.
    func transcribe(fileURL: URL, languageCode: String?) async throws -> [TranscriptionSegmentData] {
        try await prepare()
        guard let manager else { throw DraftError.modelLoadFailed("manager nil") }
        do {
            // FluidAudio's TDT transcribe needs a decoder state (inout).
            var decoderState = try TdtDecoderState()
            let language: Language? = languageCode.flatMap { $0 == "auto" ? nil : Language(rawValue: $0) }
            let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: language)
            let timings = result.tokenTimings ?? []
            let tokens = timings.map { timing in
                ParakeetDraftParser.Token(text: timing.token, start: timing.startTime, end: timing.endTime, confidence: timing.confidence)
            }
            var words = ParakeetDraftParser.tokensToWords(tokens)
            // If token grouping collapsed (the tokens lack the ▁ boundary marker for this
            // audio), rebuild words from the accurate text so the draft isn't one giant
            // word — which otherwise breaks the diarization merge.
            let textWordCount = result.text.split(separator: " ").count
            if words.count <= 1 && textWordCount > 1 {
                let spanStart = timings.first?.startTime ?? 0
                let spanEnd = timings.last?.endTime ?? result.duration
                words = ParakeetDraftParser.wordsFromText(result.text, start: spanStart, end: spanEnd)
            }
            if words.isEmpty {
                return [TranscriptionSegmentData(start: 0, end: result.duration, text: result.text, words: nil)]
            }
            return ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        } catch let e as DraftError {
            throw e
        } catch {
            throw DraftError.transcriptionFailed(error.localizedDescription)
        }
    }
}
