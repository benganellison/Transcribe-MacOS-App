import Foundation
import FluidAudio

/// Wraps FluidAudio's offline diarizer. Loads CoreML models lazily (auto-download
/// on first use), resamples any audio file to 16kHz mono internally, runs
/// diarization, and returns framework-agnostic `SpeakerSegment` values.
///
/// This is the ONLY file that imports or references FluidAudio types — everything
/// downstream sees only `SpeakerSegment`.
@MainActor
final class DiarizationService {
    private var manager: OfflineDiarizerManager?

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

    /// Loads (and downloads on first use) the CoreML diarization models.
    func prepare() async throws {
        if manager != nil { return }
        do {
            let config = OfflineDiarizerConfig()
            let m = OfflineDiarizerManager(config: config)
            try await m.prepareModels()
            manager = m
        } catch {
            throw DiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Runs diarization on any audio file and returns ordered speaker segments.
    /// FluidAudio's `AudioConverter` resamples to the 16kHz mono Float32 the
    /// pipeline expects, so the original recording URL can be passed directly.
    func diarize(fileURL: URL) async throws -> [SpeakerSegment] {
        try await prepare()
        guard let manager else { throw DiarizationError.modelLoadFailed("manager nil") }
        do {
            let samples = try AudioConverter().resampleAudioFile(fileURL)
            let result = try await manager.process(audio: samples)

            // Map raw diarizer speaker IDs to "Speaker 1/2/3…" in first-appearance
            // order. The FluidAudio segment type is inferred (never named here), and
            // `speakerId` is stringified via String(describing:) so this works whether
            // FluidAudio types it as Int or String. These property names
            // (`speakerId`, `startTimeSeconds`, `endTimeSeconds`) are the only
            // FluidAudio surface in the app — adjust here if the resolved API differs.
            var mapping: [String: String] = [:]
            var next = 1
            let sorted = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            return sorted.map { seg in
                let raw = String(describing: seg.speakerId)
                let label: String
                if let existing = mapping[raw] {
                    label = existing
                } else {
                    label = "Speaker \(next)"
                    mapping[raw] = label
                    next += 1
                }
                return SpeakerSegment(
                    speakerLabel: label,
                    start: TimeInterval(seg.startTimeSeconds),
                    end: TimeInterval(seg.endTimeSeconds)
                )
            }
        } catch let error as DiarizationError {
            throw error
        } catch {
            throw DiarizationError.processingFailed(error.localizedDescription)
        }
    }
}
