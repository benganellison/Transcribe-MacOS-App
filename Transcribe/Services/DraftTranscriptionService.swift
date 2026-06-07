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
            let result = try await manager.transcribe(fileURL, source: .system)
            let tokens = (result.tokenTimings ?? []).map {
                ParakeetDraftParser.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
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
