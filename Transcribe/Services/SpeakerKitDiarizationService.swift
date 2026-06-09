#if canImport(SpeakerKit)
import Foundation
import SpeakerKit
import WhisperKit   // AudioProcessor.loadAudioAsFloatArray (already a dependency)

/// SpeakerKit / Pyannote v4 diarizer, behind the same `Diarizing` seam as the FluidAudio
/// backend. The ONLY file that imports SpeakerKit types — everything downstream still sees
/// framework-agnostic `[SpeakerSegment]` via `SpeakerSegmentMapper`.
///
/// An `actor`: SpeakerKit loading + inference is heavy and should stay off the main thread,
/// matching `DiarizationService`.
///
/// NOTE — name collision: SpeakerKit also defines a `SpeakerSegment` type, so its segments
/// are referenced as `SpeakerKit.SpeakerSegment`; the app's own `SpeakerSegment` is the
/// (unqualified) return type. If the compiler reports ambiguity on the return type once the
/// package is added, qualify it with the app module name (e.g. `Transcribe.SpeakerSegment`).
actor SpeakerKitDiarizationService: Diarizing {
    private var speakerKit: SpeakerKit?

    func release() {
        speakerKit = nil
    }

    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerSegment] {
        let kit = try await loadedKit()

        // SpeakerKit needs 16 kHz mono Float32 PCM. WhisperKit's AudioProcessor resamples
        // and down-mixes arbitrary inputs (mp3/m4a/stereo/44.1k) to exactly that, so no
        // separate decode path is needed.
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)

        // expectedSpeakers 0/nil → let Pyannote decide; >0 → hint the speaker count.
        // VERIFY against the installed SDK: the option initializer label was
        // `numberOfSpeakers:` in the source; some docs showed `numSpeakers:`.
        let options: (any DiarizationOptions)?
        if let n = expectedSpeakers, n > 0 {
            options = PyannoteDiarizationOptions(numberOfSpeakers: n)
        } else {
            options = nil
        }

        let result = try await kit.diarize(audioArray: samples, options: options)

        // Map SpeakerKit segments → mapper rows → first-appearance "Speaker N" labels,
        // reusing the exact same pure mapper the FluidAudio path uses (consistent labels).
        let rows: [SpeakerSegmentMapper.Row] = result.segments.compactMap { (seg: SpeakerKit.SpeakerSegment) in
            // SpeakerInfo is an enum (.speakerId / .multiple / .noMatch). Take the single
            // speaker id; for `.multiple` use its first; skip `.noMatch`.
            guard let index = seg.speaker.speakerId ?? seg.speaker.speakerIds.first else {
                return nil
            }
            return SpeakerSegmentMapper.Row(
                speakerIndex: index,
                start: TimeInterval(seg.startTime),
                end: TimeInterval(seg.endTime)
            )
        }
        return SpeakerSegmentMapper.map(rows)
    }

    // MARK: - Model loading (cached)

    private func loadedKit() async throws -> SpeakerKit {
        if let kit = speakerKit { return kit }
        // Default config is Pyannote v4; CoreML models auto-download from HuggingFace on
        // first use (mirrors FluidAudio's loadFromHuggingFace behavior).
        let kit = try await SpeakerKit(PyannoteConfig())
        speakerKit = kit
        return kit
    }
}
#endif
