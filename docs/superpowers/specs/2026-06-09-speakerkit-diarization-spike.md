# SpeakerKit Diarization Swap — Spike

**Date:** 2026-06-09
**Goal:** Make the on-device diarizer A/B-swappable between FluidAudio (current) and
SpeakerKit / Pyannote v4 (argmax-oss-swift), behind the existing `[SpeakerSegment]`
boundary, with the build staying green until the package is wired.

## Decision recap
- **Option 1**: keep FluidAudio **only** as the headless Parakeet instant-draft ASR engine;
  use **SpeakerKit** for diarization. Pipeline stays **sequential** (draft → diarize →
  Whisper refine), matching today's behavior.
- Evaluating **OSS** SpeakerKit (MIT), not `speakerkit-pro`.
- Memory of SpeakerKit's array API is a non-issue on the target 32 GB machine.

## Key packaging fact (the consolidation)
WhisperKit and SpeakerKit ship in the **same** Swift package: **`argmax-oss-swift`**
(v1.0.0, May 2026, MIT). You cannot keep the standalone `WhisperKit` package *and* add
`argmax-oss-swift` — both vend a `WhisperKit` product, which collides. So adopting
SpeakerKit is a **consolidation**, not an addition:

> Replace the `WhisperKit` package reference with `argmax-oss-swift`, and source **both**
> the `WhisperKit` and `SpeakerKit` products from it.

This also fixes security finding **M1** (WhisperKit currently pinned to a moving `main`
branch): pin `argmax-oss-swift` to an exact released version while you're in there.

⚠️ Migration risk: the codebase was adapted to WhisperKit's `main` (e.g. the
`usePrefillCache` removal). Moving to `argmax-oss-swift`'s released WhisperKit may surface
API differences in `WhisperKitService.swift`. Do this in Xcode with a build to verify.

## What the spike already added (inert until package is wired)
- `Transcribe/Services/Diarizing.swift` — `protocol Diarizing` (the seam:
  `diarize(fileURL:expectedSpeakers:) -> [SpeakerSegment]` + `release()`),
  `enum DiarizationBackend { fluidAudio, speakerKit }`, and
  `DiarizationServiceFactory.make()`.
- `Transcribe/Services/SpeakerKitDiarizationService.swift` — the SpeakerKit backend,
  wrapped in `#if canImport(SpeakerKit)`. Loads audio via WhisperKit's
  `AudioProcessor.loadAudioAsFloatArray` (16 kHz mono Float32 — exactly SpeakerKit's
  required input), calls `SpeakerKit(PyannoteConfig())` → `diarize(audioArray:options:)`,
  maps `DiarizationResult.segments` → `SpeakerSegmentMapper.Row` → `[SpeakerSegment]`.
- `DiarizationService` now declares `: Diarizing` (FluidAudio backend).
- `TranscriptionView` builds the diarizer via `DiarizationServiceFactory.make()`.
- `diarizationBackend` default registered (`fluidAudio`).

Until `argmax-oss-swift` is added, `canImport(SpeakerKit)` is false → the SpeakerKit file
compiles to nothing and the factory always returns FluidAudio. No behavior change.

## Wiring steps (in Xcode, on the Mac)
1. **Remove** the `WhisperKit` package dependency from the app target.
2. **Add** package `https://github.com/argmaxinc/argmax-oss-swift.git`, pinned to an exact
   version (e.g. `1.0.0`, "Up to Next Major").
3. Add **both** products to the `Transcribe` target: `WhisperKit` and `SpeakerKit`.
4. Mirror the change in `Package.swift` (dependency + target products) so `swift test`
   resolves. Replace the `WhisperKit` dependency with `argmax-oss-swift`; add `SpeakerKit`
   to the target's products.
5. Build (`xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`). Fix any
   WhisperKit API drift in `WhisperKitService.swift` and any flagged signature in
   `SpeakerKitDiarizationService.swift` (see "Verify" below).

## Verify against the installed SDK (API guessed from docs/source)
- `PyannoteDiarizationOptions(numberOfSpeakers:)` — source showed `numberOfSpeakers:`;
  one doc page showed `numSpeakers:`. Confirm the label.
- `SpeakerInfo.speakerId: Int?` and `.speakerIds: [Int]` accessors.
- `SpeakerSegment` name collision (app type vs `SpeakerKit.SpeakerSegment`) — qualify the
  return type with the app module if the compiler reports ambiguity.
- Confirm OSS `SpeakerKit(PyannoteConfig())` auto-downloads CoreML models (no Pro/API key).

## A/B testing
Flip the backend without a UI (until a Settings picker is added):
```
defaults write <app-bundle-id> diarizationBackend speakerKit   # or fluidAudio
```
Then diarize the same recordings on both and compare speaker accuracy / wall-clock.
Optional follow-up: add a Picker in `SettingsView` bound to `@AppStorage("diarizationBackend")`.

## Out of scope for the spike
- Removing FluidAudio (it stays for the Parakeet draft).
- Parallelizing draft/diarize/refine (kept sequential by decision).
- UI for backend selection (use `defaults write` for the A/B).
