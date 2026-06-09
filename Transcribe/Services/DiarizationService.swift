import Foundation
import FluidAudio

/// Wraps FluidAudio's streaming diarizers (Sortformer / LS-EEND), choosing the model
/// from an estimated speaker count and returning framework-agnostic `SpeakerSegment`s.
///
/// - 1–4 expected speakers → **Sortformer** (4 fixed slots, very stable identities).
/// - 5–10 / unknown → **LS-EEND** dihard3 (variable slots up to 10, CPU).
///
/// This is the ONLY file that imports or references FluidAudio diarizer types —
/// everything downstream sees only `SpeakerSegment`.
///
/// An `actor` (not `@MainActor`): the underlying `processComplete` is a synchronous,
/// CPU-heavy call that would otherwise block the main thread for the whole file.
actor DiarizationService: Diarizing {
    enum Backend: Equatable { case sortformer, lseend }

    /// Loaded models cached per backend so re-runs don't re-download/compile.
    private var sortformerModels: SortformerModels?
    private var lseendModel: LSEENDModel?

    enum DiarizationError: LocalizedError {
        case modelLoadFailed(String)
        case processingFailed(String)
        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let m): return "Could not load diarization models: \(m)"
            case .processingFailed(let m): return "Diarization failed: \(m)"
            }
        }
    }

    /// Releases the loaded diarizer models to free memory once diarization is done
    /// (the completion re-merge only needs the cached segments + the word merger, no
    /// model). A manual re-run reloads on demand.
    func release() {
        sortformerModels = nil
        lseendModel = nil
    }

    /// Sortformer handles up to 4 speakers with the most stable identities; anything
    /// larger or unknown uses LS-EEND (up to 10).
    static func backend(forExpectedSpeakers expected: Int?) -> Backend {
        if let n = expected, n >= 1, n <= 4 { return .sortformer }
        return .lseend
    }

    /// Runs diarization on any audio file and returns ordered speaker segments.
    /// FluidAudio resamples the file internally, so the original URL is passed directly.
    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerSegment] {
        let timeline: DiarizerTimeline
        do {
            switch Self.backend(forExpectedSpeakers: expectedSpeakers) {
            case .sortformer:
                let models = try await loadedSortformerModels()
                let diarizer = SortformerDiarizer(config: .default, timelineConfig: .sortformerDefault)
                diarizer.initialize(models: models)
                timeline = try diarizer.processComplete(audioFileURL: fileURL, keepingEnrolledSpeakers: false)
            case .lseend:
                let model = try await loadedLSEENDModel()
                let diarizer = try LSEENDDiarizer(model: model)
                timeline = try diarizer.processComplete(audioFileURL: fileURL, keepingEnrolledSpeakers: false)
            }
        } catch let e as DiarizationError {
            throw e
        } catch {
            throw DiarizationError.processingFailed(error.localizedDescription)
        }
        return Self.extractSegments(from: timeline)
    }

    // MARK: - Model loading (cached)

    private func loadedSortformerModels() async throws -> SortformerModels {
        if let m = sortformerModels { return m }
        do {
            let m = try await SortformerModels.loadFromHuggingFace(config: .default)
            sortformerModels = m
            return m
        } catch {
            throw DiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func loadedLSEENDModel() async throws -> LSEENDModel {
        if let m = lseendModel { return m }
        do {
            let m = try await LSEENDModel.loadFromHuggingFace(variant: .dihard3)
            lseendModel = m
            return m
        } catch {
            throw DiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    // MARK: - Timeline → SpeakerSegment

    /// Flattens every speaker's finalized segments into framework-agnostic rows and
    /// hands them to the pure mapper for first-appearance "Speaker N" labeling.
    private static func extractSegments(from timeline: DiarizerTimeline) -> [SpeakerSegment] {
        var rows: [SpeakerSegmentMapper.Row] = []
        for (_, speaker) in timeline.speakers {
            for seg in speaker.finalizedSegments {
                rows.append(SpeakerSegmentMapper.Row(
                    speakerIndex: speaker.index,
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime)
                ))
            }
        }
        return SpeakerSegmentMapper.map(rows)
    }
}
