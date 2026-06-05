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
    /// Signature of the options the cached `manager` was built with, so we rebuild
    /// it only when tuning actually changes.
    private var loadedSignature: String?

    /// Tunable diarization parameters surfaced to the UI.
    struct Options: Equatable {
        /// Expected number of distinct speakers. When set, clustering is forced to
        /// this exact count — the strongest lever for meetings where several people
        /// speak only briefly and would otherwise be merged into dominant speakers.
        var expectedSpeakers: Int?

        /// Clustering distance threshold (Euclidean, unit-normalized embeddings).
        /// Lower = more willing to split into separate speakers; higher = more merging.
        /// FluidAudio's community default is 0.6.
        var clusteringThreshold: Double

        /// Minimum speech length (seconds) that still gets a voice embedding.
        /// FluidAudio's default of 1.0 silently drops sub-second turns, which makes
        /// short self-introductions disappear; we default lower to catch them.
        var minSegmentDuration: Double

        static let `default` = Options(
            expectedSpeakers: nil,
            clusteringThreshold: 0.6,
            minSegmentDuration: 0.45
        )
    }

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

    /// Builds a FluidAudio config from `.community` defaults, overriding only the
    /// tunable fields. The speaker-count and min-segment knobs live on the nested
    /// structs (the convenience initializer doesn't expose them).
    private func makeConfig(_ options: Options) -> OfflineDiarizerConfig {
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = options.clusteringThreshold
        if let count = options.expectedSpeakers, count > 0 {
            clustering.numSpeakers = count
        }

        var embedding = OfflineDiarizerConfig.Embedding.community
        embedding.minSegmentDurationSeconds = options.minSegmentDuration

        return OfflineDiarizerConfig(embedding: embedding, clustering: clustering)
    }

    private func signature(_ options: Options) -> String {
        let speakers = options.expectedSpeakers.map(String.init) ?? "-"
        return "\(speakers)|\(options.clusteringThreshold)|\(options.minSegmentDuration)"
    }

    /// Loads (and downloads on first use) the CoreML diarization models, rebuilding
    /// the manager when tuning options change so the new config takes effect.
    func prepare(_ options: Options) async throws {
        let sig = signature(options)
        if manager != nil && loadedSignature == sig { return }
        do {
            let m = OfflineDiarizerManager(config: makeConfig(options))
            try await m.prepareModels()
            manager = m
            loadedSignature = sig
        } catch {
            throw DiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Runs diarization on any audio file and returns ordered speaker segments.
    /// FluidAudio's `AudioConverter` resamples to the 16kHz mono Float32 the
    /// pipeline expects, so the original recording URL can be passed directly.
    func diarize(fileURL: URL, options: Options = .default) async throws -> [SpeakerSegment] {
        try await prepare(options)
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
