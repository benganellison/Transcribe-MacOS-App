import Foundation

/// Backend-agnostic diarization seam.
///
/// Both the FluidAudio diarizer (`DiarizationService`) and the SpeakerKit / Pyannote v4
/// diarizer (`SpeakerKitDiarizationService`) conform, so the call site can A/B them with
/// **zero downstream change** — both return framework-agnostic `[SpeakerSegment]`, which
/// `DiarizationMerger` and the UI already consume.
///
/// `release()` lets a backend free its loaded models between runs (FluidAudio does; the
/// SpeakerKit backend may too) so the diarizer isn't resident while Whisper refines.
protocol Diarizing: Sendable {
    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerSegment]
    func release() async
}

/// Which on-device diarizer to use. Persisted under `UserDefaults` key `diarizationBackend`.
enum DiarizationBackend: String {
    case fluidAudio
    case speakerKit
}

/// Picks the diarization backend from the `diarizationBackend` setting.
///
/// SpeakerKit is only selectable once the `argmax-oss-swift` package is added to the app
/// target (so `canImport(SpeakerKit)` becomes true); until then this always returns the
/// FluidAudio backend, regardless of the setting — the build stays green with the package
/// absent. FluidAudio remains the engine for the Parakeet instant-draft either way; this
/// only switches the *diarizer*.
enum DiarizationServiceFactory {
    static func make() -> any Diarizing {
        let raw = UserDefaults.standard.string(forKey: "diarizationBackend")
            ?? DiarizationBackend.fluidAudio.rawValue
        #if canImport(SpeakerKit)
        if raw == DiarizationBackend.speakerKit.rawValue {
            return SpeakerKitDiarizationService()
        }
        #endif
        return DiarizationService()
    }
}
