# Speaker Diarization — Design

**Date:** 2026-06-05
**Status:** Approved (design); pending implementation plan
**Branch context:** `feature/recording-library` (diarization will get its own branch)

## Goal

Add speaker diarization ("who spoke when") to transcriptions. For single-channel
audio (podcasts, single-mic room recordings, mixed meeting recordings, YouTube),
channel-splitting is impossible, so we combine the existing WhisperKit transcript
with a local CoreML speaker-embedding pipeline (FluidAudio) and merge the two
tracks at the word level.

The result is a speaker-labeled transcript the user can read as grouped blocks
("Speaker 1: …", "Speaker 2: …"), rename speakers, and optionally auto-name via
the existing LLM integration.

All processing is on-device (CoreML / Apple Neural Engine). No Python, no new
cloud dependency.

## Requirements (from brainstorming)

- **Scope:** applies to all transcription inputs — imported files, meeting
  recordings (system + mic), mic recordings, and YouTube. Therefore diarization
  lives at the transcription-pipeline level, not in any single input path.
- **Trigger:** opt-in. A settings toggle ("Identify speakers") controls the
  default first-pass behavior. Additionally, an on-demand "Identify speakers"
  button is available on any finished/saved transcript so the user can run it
  after the fact ("change my mind later"). Both paths share one service.
- **Speaker count:** auto-detected by clustering. No required user input.
- **Display:** transcript renders as speaker-grouped blocks. Tapping a label
  renames that speaker everywhere it appears. Renames persist with the saved
  recording.
- **Merge granularity:** word-level. Each word is assigned to the speaker active
  at that moment; consecutive same-speaker words are grouped into utterances.
- **LLM auto-naming:** optional step that reads the labeled transcript and
  proposes real names from self-introductions / direct address, feeding the same
  rename mechanism. User can always override.

## Data flow

```
                          ┌─────────────────────────────────────┐
[Audio file] ─► AudioPreprocessor ─► 16kHz mono WAV ─┐
                                                      │
                          ┌───────────────────────────┴──────────────┐
                          ▼                                            ▼
              WhisperKit (KB-Whisper)                    FluidAudio OfflineDiarizerManager
              → segments + WORD timestamps               → [speakerId, start, end] blocks
                          │                                            │
                          └──────────────► DiarizationMerger ◄─────────┘
                                          (word→speaker by time)
                                                   │
                                                   ▼
                                        [DiarizedUtterance] (grouped by speaker)
                                                   │
                              (optional) LLMService.suggestSpeakerNames()
                                                   │
                                                   ▼
                                    TranscriptionView renders speaker blocks
                                          (tap label → rename)
```

Both tracks consume the **same** 16kHz mono WAV produced by the existing
`AudioPreprocessor` (FluidAudio requires 16kHz mono; WhisperKit already uses it).
No duplicate conversion.

Diarization is a whole-file operation: clustering needs all embeddings before it
can assign labels. It therefore runs as a second pass after WhisperKit
transcription completes, reported as its own progress phase
("Identifying speakers…").

## New components

### `Services/DiarizationService.swift` (`@MainActor` class)

Wraps FluidAudio's `OfflineDiarizerManager` (Pyannote powerset segmentation →
WeSpeaker embeddings → VBx clustering — the full pipeline, run internally).

- Lazy model load via `prepareModels()`; models auto-download on first use.
- Surfaces download progress/state through `ModelManager`, mirroring the
  existing WhisperKit model-download UX.
- `func diarize(fileURL: URL) async throws -> [SpeakerSegment]`.
- Init / load / unload lifecycle mirroring `WhisperKitService`.

### `DiarizationMerger` (actor)

Pure merge logic, no service dependencies → unit-testable in isolation.

- Input: WhisperKit word timestamps + `[SpeakerSegment]`.
- Assigns each word to the speaker active at the word's midpoint.
- Groups consecutive same-speaker words into `DiarizedUtterance`s.
- Output: `[DiarizedUtterance]`.

### `LLMService.suggestSpeakerNames(utterances:) async -> [String: String]`

New method on the existing service (Berget/Ollama path reused).

- Sends the labeled transcript, returns a `Speaker N → name` map.
- Confidence gate: only confident matches are applied; everything else stays as
  the generic label.
- Failure is non-fatal — generic labels are kept.

## Data model changes

- **`DiarizedUtterance`** (new; `Identifiable`, `Codable`, `Equatable`):
  `speakerID`, `displayName`, `text`, `startTime`, `endTime`.
- **`SpeakerSegment`** (new): thin wrapper over FluidAudio output
  (`speakerLabel`, `start`, `end`) — keeps FluidAudio types out of the merge
  logic and tests.
- Reuse the existing `speaker: String?` field on `TranscriptionSegment`.
- Add optional `speakerNames: [String: String]` to `TranscriptionResult` so
  renames persist with saved recordings (via `RecordingLibraryManager`).
- Enable word timestamps in `DecodingOptions` when diarization is requested, and
  populate the existing `words:` placeholder in `TranscriptionSegmentData`.

## UI / control flow

- **Settings toggle** "Identify speakers" (`@AppStorage`) gating the default
  first pass.
- **On-demand button** "Identify speakers" on the finished/saved transcript.
  Both paths call `DiarizationService` + `DiarizationMerger`.
- **TranscriptionView:** when diarized, render speaker-grouped blocks. Tapping a
  label opens rename; rename applies to all utterances of that speaker and
  persists. An "Auto-name with AI" action triggers `suggestSpeakerNames`.
- **Progress:** diarization reported as its own phase after transcription.
- **Localization:** all new UI strings added to `en.lproj` and `sv.lproj` per
  project convention.

## Error handling & edge cases

- FluidAudio model download failure → surfaced like WhisperKit download errors;
  the transcript still shows (un-diarized). Diarization is additive — its failure
  never breaks the plain transcript.
- Single speaker detected → render normally, without forcing labels.
- LLM naming failure → silently keep generic labels (enhancement, never blocks).
- Word exactly on a speaker-block boundary → assigned deterministically (midpoint
  rule, with a defined tie-break).

## Testing

- `DiarizationMerger` unit tests with synthetic word + speaker arrays:
  - turn boundary mid-segment
  - overlapping speech
  - gaps between speakers
  - single speaker
  - word exactly on a boundary (tie-break)
- Verify build: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`.

## Dependency

Add `FluidAudio` (from `0.12.4`) to `Package.swift` and the `Transcribe` target:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
// product: .product(name: "FluidAudio", package: "FluidAudio")
```

Min macOS 14+ (project targets macOS 26 — well within range). Swift 6.2.

## Addendum (2026-06-05): accuracy tuning

Field testing on a 10-speaker meeting (most speakers only self-introduced, then
listened) surfaced the expected weakness of clustering-based diarization: brief,
imbalanced speakers get merged or dropped. Two real FluidAudio knobs address this,
so the design now exposes light tuning instead of auto-only:

- **`Embedding.minSegmentDurationSeconds`** — FluidAudio default 1.0s drops
  sub-second turns (short intros). We default to **0.45s**.
- **`Clustering.numSpeakers`** — an optional **expected speaker count** set by the
  user forces the clustering target, the strongest lever for brief speakers.
- **`Clustering.threshold`** — a sensitivity slider (0.4–0.9; lower = more
  speakers) exposed for fine-tuning.

These live in `DiarizationService.Options`. The transcript header gains an
always-visible **Identify speakers / Re-run** control (popover with the count
field + sensitivity slider) so post-processing is discoverable and can be re-run
without re-transcribing. This supersedes the original "auto-detect only, no UI
input" and "known count out of scope" decisions.

## Out of scope (YAGNI)

- Streaming / real-time diarization (offline pass is simpler and more accurate).
- Speaker voice-print persistence across different recordings (each recording
  clusters independently).
