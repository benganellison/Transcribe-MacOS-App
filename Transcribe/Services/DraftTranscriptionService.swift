import Foundation
import FluidAudio

/// Fast first-pass transcription via FluidAudio's Parakeet v3 (multilingual,
/// auto language detection, ~120x real-time). Produces draft segments with word
/// timings for the progressive splice + diarized draft. The ONLY file importing
/// FluidAudio ASR types.
@MainActor
final class DraftTranscriptionService {
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
    func transcribe(fileURL: URL) async throws -> [TranscriptionSegmentData] {
        try await prepare()
        guard let manager else { throw DraftError.modelLoadFailed("manager nil") }
        do {
            // FluidAudio's TDT transcribe needs a decoder state (inout); language nil = auto-detect.
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: nil)
            let tokens = (result.tokenTimings ?? []).map { timing in
                ParakeetDraftParser.Token(text: timing.token, start: timing.startTime, end: timing.endTime, confidence: timing.confidence)
            }
            let words = ParakeetDraftParser.tokensToWords(tokens)
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
