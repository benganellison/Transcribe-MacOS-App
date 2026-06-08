# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native macOS SwiftUI app. Open and build with Xcode:

```bash
open Transcribe.xcodeproj
# Build: Cmd+B | Run: Cmd+R
```

The project requires macOS 26+ (Tahoe) and runs on Apple Silicon (M1+).

### Known Xcode 26 Build Issue

Building from Xcode's UI fails with `___llvm_profile_runtime` undefined symbol (yyjson, a pure C SPM transitive dependency of WhisperKit). This is an Xcode 26 bug where `CLANG_COVERAGE_MAPPING` defaults to YES and pure C SPM package targets get coverage instrumentation but miss `-fprofile-instr-generate` in their linker invocation. Build from the command line instead:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

**Important**: Always rebuild after making code changes to verify they compile and so the user can test them. Never skip the build step.

When code signing isn't available (e.g. no "Mac Development" certificate), build with:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""
```

### Versioning & Build Stamp
- `MARKETING_VERSION = 2.3` (user-facing version). `CURRENT_PROJECT_VERSION` is overwritten at build time.
- A **"Stamp Git Commit"** `PBXShellScriptBuildPhase` writes `GitCommit` (`git rev-parse --short HEAD` + date) and `CFBundleVersion` (`git rev-list --count HEAD`) into the built Info.plist. `AboutView` reads `Bundle.main.infoDictionary["GitCommit"]` to show the commit + build number.
- The phase needs `ENABLE_USER_SCRIPT_SANDBOXING = NO` (otherwise it can't read git / write the plist) and lists Info.plist in `inputPaths` for correct ordering.
- About/Preferences `NSWindow`s set `isReleasedWhenClosed = false` so they can reopen after closing.

## Architecture

### Entry Point
- `Transcribe/TranscribeApp.swift` - Main app with SwiftUI lifecycle
- `Transcribe/AppDelegate.swift` - NSApplicationDelegate for status bar menu, file cleanup, window management

### Core Services

**Transcription Pipeline:**
- `WhisperKitService.swift` - Primary transcription engine using WhisperKit (CoreML). Handles model loading, transcription with progress streaming, and segment generation.
- `UnifiedTranscriptionService.swift` - Routes between local (WhisperKit) and cloud (Berget) services. Manages model state and active service selection.
- `BergetTranscriptionService.swift` - Cloud transcription via Berget AI API (requires API key stored in Keychain)
- `TranscriptionService.swift` - Lightweight streaming wrapper around WhisperKitService

**Audio Processing:**
- `Services/AudioPreprocessor.swift` - Audio format conversion and preprocessing. Automatically extracts audio from video containers (`.mp4`, `.mov`, etc.) and converts non-native formats to 16kHz mono WAV using `AVAssetReader`/`AVAssetWriter`. Used by both local (WhisperKit) and cloud (Berget) transcription paths.

**System Audio Capture:**
- `Services/SystemAudioCaptureService.swift` - Captures system audio output using ScreenCaptureKit with optional microphone mixing. Two-phase architecture: monitoring (level meter, permission prompt) and recording (48kHz stereo float32 WAV). Supports mixing mic input via `AVAudioEngine` + `AudioRingBuffer` for meeting recording (both sides of a conversation). Includes CoreAudio device enumeration and selection for mic input.
- `Services/AudioRingBuffer.swift` - Thread-safe SPSC ring buffer using `os_unfair_lock`. Decouples mic capture (AVAudioEngine thread) from system audio capture (SCStream callback thread) during mixed recording.

**LLM Integration:**
- `Services/LLMService.swift` - Text processing via Berget AI or Ollama LLM APIs (summarization, action points, etc.). Also provides speaker auto-naming: `defaultSpeakerNamingPrompt` + `suggestSpeakerNames(...,systemPrompt:)` infers real names from a diarized transcript using a user-editable prompt.

**Speaker Diarization (who-spoke-when):**
- `Services/DiarizationService.swift` - `@MainActor` wrapper around FluidAudio's `OfflineDiarizerManager` (Pyannote powerset segmentation → WeSpeaker embeddings → VBx clustering). Resamples any file to 16kHz mono internally, returns framework-agnostic `[SpeakerSegment]` ("Speaker 1/2/3…" in first-appearance order). Tunable via `Options` (min/max speakers, `clusteringThreshold` default 0.6, `minSegmentDuration` default 0.45). **The only file that imports FluidAudio diarizer types.** Rebuilds its manager only when the options signature changes.
- `Services/DiarizationMerger.swift` - `actor`, pure. Merges WhisperKit words with speaker blocks: assigns each word to the speaker active at its midpoint (half-open `(start, end]` so a boundary goes to the earlier block), groups consecutive same-speaker words into `DiarizedUtterance`s, and retains per-word timings on each utterance.
- `Services/SpeakerReconciliation.swift` - pure, no UI/audio. Manual diarization correction: `merge(from:into:)` (whole speaker), `reassign(utteranceID:to:)` (one turn, no regroup), `splitUtterance(utteranceID:beforeWordIndex:)`, `joinWithPrevious(utteranceID:)`, `regroupAdjacent`, `nextSpeakerLabel`, `distinctSpeakers`. Unit-tested.

**Interactive Transcript Core:**
- `Services/TimedTranscript.swift` - pure helpers for the synced/editable transcript: `activeWord(in:at:)` (karaoke highlight lookup), `reconcileSentence` (re-tokenize an edit against a segment's `[start,end]`, even-distribute timings + `timingApproximate` flag when word count changes), `rebuildText`, and timestamp-keyed restore (`originalWord(in:atMidpointOf:)`, `originalSegment(in:overlapping:)`). Unit-tested.

**Instant Draft (fast first pass for long recordings):**
- `Services/DraftTranscriptionService.swift` - `@MainActor` wrapper around FluidAudio's Parakeet TDT v3 ASR (~120× realtime, multilingual incl. Swedish, auto language detect). Produces word-timed draft segments shown immediately while KB-Whisper streams the accurate transcription behind it. **The only file that imports FluidAudio ASR types.**
- `Services/ParakeetDraftParser.swift` - pure. Converts Parakeet SentencePiece token timings (▁ word-start marker) into `WordTimestamp`s and groups them into segments (break on sentence-final punctuation or a pause > `maxGapSeconds`). Unit-tested.
- `Services/DraftSplice.swift` - pure. `tailDraft(_:after:)` keeps draft segments Whisper hasn't reached; `combinedText(whisperText:draft:coveredUntil:)` builds the progressive display (accurate text up to `coveredUntil`, draft beyond). Unit-tested.

**Recording Library & Persistence:**
- `Services/RecordingLibraryManager.swift` - manages saved recordings (metadata JSON sidecars) and the voice-memo transcription cache. Persists transcription + diarization so reopening never re-transcribes: `updateTranscription(…segments…)`, `updateDiarization`, `updateOriginalSegments`, `updateOriginalDiarization`, `recording(id:)`, and `cacheVoiceMemoTranscription(…)` (voice-memo sidecar in Application Support).
- `Services/VoiceMemosMetadataReader.swift` - reads Apple Voice Memos metadata (names, dates) for the library's Voice Memos section.

**Model Support:**
- KB Whisper models (Swedish-optimized): `kb_whisper-base/small/medium/large-coreml`
- OpenAI Whisper models: `openai_whisper-base/small/medium/large-v2/large-v3`
- Cloud: Berget KB Whisper Large (requires API key)

KB Whisper models load from `mickekringai/kb-whisper-coreml` HuggingFace repo. Default model (`kb_whisper-small-coreml`) auto-downloads on first launch.

### Key Managers
- `ModelManager.swift` - Model downloads, availability checking, and storage management
- `LanguageManager.swift` - Language selection (100+ languages)
- `SimplifiedManagers.swift` - Contains `SettingsManager` (app preferences, API keys, text processing prompts) and `KeychainHelper` (Keychain wrapper for API key storage)
- `LocalizationManager.swift` - UI localization (English/Swedish) via `localized(_:)` helper
- `Services/RecordingLibraryManager.swift` - Owns the saved-recordings library and voice-memo transcription cache (see Core Services above)

### Views
- `ContentView.swift` - Main window with toolbar (file picker, recording, YouTube, settings)
- `TranscriptionView.swift` - Transcription display with audio player, export, and text processing
- `RecordingView.swift` - Built-in audio recording with live level meter, device selector, and playback
- `SystemAudioRecordingView.swift` - System audio capture with live level meter, record/stop, playback, and transcription
- `YouTubeTranscriptionView.swift` - YouTube URL transcription workflow
- `SettingsView.swift` - Preferences with model management, text processing prompts, LLM settings
- `RecordingLibraryView.swift` - "My Recordings" + Apple Voice Memos browser; opens a recording into `TranscriptionView` (cached transcription/diarization restored, no re-transcribe)
- `QuickTranscribeView.swift` - Lightweight drop-in transcription entry point
- `TranscriptionView.swift` (transcript surface) renders via three reusable views below:
  - `InteractiveTranscriptView.swift` - `LazyVStack` of segments inside a `ScrollViewReader`; karaoke highlight, tap-to-seek, inline edit, and **Follow playback** auto-scroll for the plain transcript
  - `WordFlowView.swift` - renders one segment/utterance's words; colors each by playback time, handles tap-seek, inline word/sentence edit, low-confidence cue, and the per-word "Split turn here" action
  - `FlowLayout.swift` - a pure SwiftUI `Layout` that wraps word subviews like text (no state)

### Data Models
- `TranscriptionModels.swift` - `TranscriptionResult`, `TranscriptionSegment`, `TextProcessingPrompt`, `AudioInputDevice`
- `Models/DiarizationModels.swift` - `SpeakerSegment` (framework-agnostic speaker block) and `DiarizedUtterance` (`Identifiable`/`Equatable`/`Codable`; one speaker turn with `displayName`, `text`, `startTime`/`endTime`, and optional per-word `words`)
- `Models/SavedRecording.swift` - library recording metadata (**schema v2**). Carries cached `transcriptionSegments`, `originalTranscriptionSegments` (restore snapshot), `diarizedUtterances`, `speakerNames`, and `originalDiarizedUtterances` — all optional so older metadata decodes
- `Models/VoiceMemoRecording.swift` - `VoiceMemoRecording` + `VoiceMemoTranscription` (sidecar cache: text, segments, diarization, speaker names, and original snapshots)
- `TranscriptionView.swift` also defines `TranscriptionSegmentData` (`start`/`end`/`text`/`words?`/`timingApproximate?`) and `WordTimestamp` (`word`/`start`/`end`/`confidence`) — the editable, persisted transcript shape. Fields are `var`; optionals default to `nil` to avoid memberwise-init ambiguity
- `AppState.swift` - Navigation state (`currentTranscriptionURL`, `showTranscriptionView`, `showRecordingView`, `showSystemAudioView`, `currentVoiceMemoID`, `openVoiceMemoForTranscription`)

### File Storage & Security
All temporary files auto-cleanup on app quit and on startup (handles force-quit scenarios):
- Recordings: `~/Library/Caches/Transcribe/Recordings/`
- YouTube downloads: `~/Library/Caches/Transcribe/YouTube/`
- Cleanup handled in `AppDelegate.cleanupTemporaryFiles()`

API keys are stored in macOS Keychain via `KeychainHelper` (not UserDefaults). Legacy UserDefaults keys are migrated to Keychain on launch. No `print()` statements in production code — all debug logging has been removed.

## Key Patterns

### State Management
Uses `@EnvironmentObject` for global state:
- `AppState` - Navigation state (current file, view visibility)
- `SettingsManager` - User preferences (persisted via `@AppStorage` and Keychain)
- `TranscriptionManager` - Transcription queue

**Settings defaults gotcha:** `@AppStorage` does **not** write its inline default into `UserDefaults` — only an explicit change persists a value. Code that isn't a SwiftUI `View` (e.g. `TranscriptionViewModel`) reads settings raw via `UserDefaults.standard.bool/double/string(forKey:)`, which returns Foundation's unset-key fallback (`false`/`0`/`""`), **not** the `@AppStorage` default. `SettingsManager.registerDefaultSettings()` (called from `TranscribeApp.init`) registers the canonical defaults so raw reads and `@AppStorage` agree. When adding an `@AppStorage` setting that any non-View code reads, add it to that dictionary. (This is why fast draft / identify-speakers silently never ran until the defaults were registered.)

### Streaming Transcription
WhisperKit provides `AsyncThrowingStream<TranscriptionUpdate, Error>`:
```swift
for try await update in whisperKitService.transcribe(fileURL:modelId:language:) {
    // update.text, update.progress, update.segments, update.isComplete
}
```

### Audio Preprocessing
`TranscriptionService` automatically preprocesses files before passing them to WhisperKit:
- **Native formats** (`.wav`, `.mp3`, `.m4a`, `.flac`, `.aac`, `.aif`, `.aiff`, `.caf`) are passed directly
- **Video containers** (`.mp4`, `.mov`, `.mkv`, etc.) and other formats have their audio extracted to 16kHz mono WAV via `AVAssetReader`/`AVAssetWriter`
- Temporary files are cleaned up after transcription completes

### Recording
`RecordingView` contains `AudioRecorderManager` which handles:
- Microphone permission via `AVAudioApplication.shared.recordPermission` (modern API)
- Live audio level metering via `AVAudioEngine` input tap (pre-recording) and `AVAudioRecorder` metering (during recording)
- Audio input device selection via CoreAudio (`AudioObjectGetPropertyData`)
- Proper lifecycle management — engine taps removed before deallocation, no async self capture in `deinit`

### System Audio Recording
`SystemAudioRecordingView` uses `SystemAudioCaptureService` which wraps ScreenCaptureKit:
- **Permission**: `SCShareableContent.excludingDesktopWindows()` triggers the macOS "Screen & System Audio Recording" prompt on first use. Requires app restart after granting permission.
- **Monitoring**: `SCStream` with `capturesAudio = true` and minimal video (2x2px, 1fps) provides live audio level metering before recording starts.
- **Recording**: Audio buffers from `SCStreamOutput` callbacks written to WAV via `AVAudioFile`. Format: 48kHz stereo float32 non-interleaved (native ScreenCaptureKit output).
- **Mic mixing**: Optional "Include Microphone" toggle mixes mic input with system audio for meeting recording. `AVAudioEngine` captures mic, `AVAudioConverter` resamples to 48kHz stereo, `AudioRingBuffer` decouples the two threads. SCStream callback reads from ring buffer and mixes (sample addition + clamping). Dual level meters show system and mic levels separately.
- **Device selection**: When mic is enabled, CoreAudio device enumeration lets users pick their mic input. Same pattern as `RecordingView`'s `AudioRecorderManager`.
- **Transcription**: Recorded WAV passed to the same pipeline as microphone recordings — `AudioPreprocessor` converts to 16kHz mono for WhisperKit.
- **Entitlements**: Uses `com.apple.security.device.audio-input` (shared with microphone). `NSAudioCaptureUsageDescription` in Info.plist.
- **Temp files**: `~/tmp/Transcribe/SystemAudio/` — cleaned up by existing `AppDelegate.cleanupTemporaryFiles()`.

### Color System
Adaptive dark/light colors defined in `ColorExtensions.swift` using `NSColor(name:dynamicProvider:)`:
- `.primaryAccent` (`#3ECF8E` green), `.secondaryAccent`, `.tertiaryAccent` - Brand accent
- `.surfaceBackground`, `.cardBackground`, `.elevatedSurface` - Surface hierarchy
- `.textPrimary/Secondary/Tertiary` - Text hierarchy
- `LinearGradient.accentGradient`, `LinearGradient.primaryGradient`
- `.glassCard()` modifier - `ultraThinMaterial` + subtle border

### Theme
- Dark mode default, toggle via toolbar button
- `@AppStorage("appColorScheme")` stores `"dark"` or `"light"`
- Colors auto-adapt via `NSColor` dynamic provider — no `@Environment(\.colorScheme)` needed in views

### Text Processing Prompts
- `TextProcessingPrompt` model in `TranscriptionModels.swift` — `Identifiable`, `Codable`, `Equatable`
- CRUD in `SettingsManager` (`SimplifiedManagers.swift`) — JSON-encoded in UserDefaults
- 3 default Swedish prompts seeded on first launch (Sammanfattning, Åtgärdspunkter, Nyckelpunkter)
- Settings UI: `TextProcessingPromptsView` in `SettingsView.swift` under "Bearbeta text" sidebar section

### LLM Services
- **Berget AI**: 5-model registry (`BergetLLMModel` in `SettingsView.swift`), selected via `@AppStorage("selectedBergetLLMModel")`
- **Ollama**: Local models, links to `ollama.com` when not running
- Service layer: `LLMService.swift` handles API calls for both providers

### Speaker Diarization
End-to-end "who spoke when", layered so the framework stays isolated and the logic stays testable:
- **Pipeline**: `DiarizationService.diarize(fileURL:options:)` → `[SpeakerSegment]`, then `DiarizationMerger.merge(words:speakers:)` combines them with WhisperKit's word timings into `[DiarizedUtterance]`.
- **Word timestamps are always-on** on the local WhisperKit path (`let wordTimestamps = true` in `WhisperKitService`) — they power diarization *and* the interactive transcript. Recordings transcribed before this change need a re-transcribe to gain word sync.
- **Trigger**: auto when "Identify speakers" is enabled, or on demand from the transcript header (`diarizationMenuButton`). Re-run with adjusted tuning from the same header popover (min/max speakers, sensitivity = `clusteringThreshold`, min segment).
- **Auto-naming**: `LLMService.suggestSpeakerNames` proposes real names from the transcript; the prompt is user-editable (`speakerNamingPrompt`).
- **Display**: diarized blocks render as `WordFlowView` per utterance with a `Menu` on the speaker label (Rename / Merge with previous turn / Merge entire speaker into ▸ / Assign this turn to ▸).
- **Boundary**: only `DiarizationService` touches FluidAudio diarizer types; everything else sees `SpeakerSegment` / `DiarizedUtterance`.

### Interactive Synced Transcript
The completed plain transcript becomes an audio-synced, editable surface (`InteractiveTranscriptView` + `WordFlowView` + `FlowLayout`, driven by `viewModel.currentTime`):
- **Highlight + seek**: words color grey→white as playback passes them (`TimedTranscript.activeWord`); tap any word to seek. **Follow playback** auto-scrolls to the active word (plain view).
- **Edit** (header toggle): tap a word → inline edit (timing preserved); edit a sentence → `TimedTranscript.reconcileSentence` re-tokenizes against the segment span (1:1 timings if word count matches, else even-distribute + `timingApproximate`).
- **Non-destructive restore**: first edit captures an immutable `originalTranscriptionSegments` snapshot; right-click → Restore word / Restore sentence / Restore all, keyed by timeline position (`originalWord`, `originalSegment`). Re-transcribe clears the snapshot.
- **Fallback**: no word timings (pre-always-on cache, Berget cloud) → segment-level highlight/seek; streaming still uses `AutoScrollingTextView`.

### Speaker Reconciliation
Manual correction of diarizer mistakes, all reducing to "relabel an utterance + regroup" (`SpeakerReconciliation`, pure + unit-tested), surfaced via the speaker-label `Menu` and a header "Restore original speakers":
- **Merge** whole speaker B→A; **Reassign** one turn (no regroup, so manual splits survive); **Split** a turn at a word boundary; **Join** with the previous turn; **Restore** the diarizer's original assignment from the `originalDiarizedUtterances` snapshot.
- VM methods on `TranscriptionViewModel`: `mergeSpeaker(_:into:)`, `reassignUtterance(id:to:)`, `splitDiarizedUtterance(id:beforeWordIndex:)`, `joinUtteranceWithPrevious(id:)`, `restoreOriginalSpeakers()`. Each snapshots originals on first change and persists via `updateDiarization` + `updateOriginalDiarization` (or the voice-memo sidecar).

### Instant Draft + Progressive Refinement (long recordings)
For recordings over `fastDraftThresholdMinutes` (when `fastDraftEnabled`), the ML work is **sequenced** so each stage runs on idle engines — running diarization concurrently with Parakeet/Whisper makes it collapse to one speaker:
1. **Draft (Parakeet)** — `DraftTranscriptionService` transcribes the whole file fast → `draftSegments`, shown immediately via `isShowingDraft` (words are **blue** = unrefined).
2. **Diarization alone** — after the draft, `DiarizationService` runs on its own → `cachedSpeakerSegments`; `applyDiarizationIfPossible` groups the draft words into correct speaker turns (marked unrefined/blue via `markWords`).
3. **Whisper refinement** — WhisperKit streams accurate words; on each update (throttled by covered-time) `TranscriptRefiner.refine(turns:whisperWords:coveredUntil:)` splices them into the existing turns **in place** (blue → **white**), preserving turn identity (no scroll reflow), speaker edits, and **locked** user-edited words. The final `isComplete` update refines with full coverage.
- **Word state**: `WordTimestamp.refined` (false = draft/blue) and `locked` (true = user-edited, never overwritten). `WordFlowView` colors by source (`colorBySource`) while `isTranscribing`. Both optional → old transcripts decode as final/white.
- **Plain-text splice** (non-diarized streaming) still uses `DraftSplice.combinedText(whisperText:draft:coveredUntil:)`; `coveredUntil` is surfaced on `TranscriptionUpdate`.
- **Editing during streaming**: the diarized view is interactive while Whisper refines — fix speakers (label menu) and edit words (edits lock against refinement). No diarization re-run at completion on the draft path (would wipe edits); the non-draft/short-file path diarizes once after Whisper finishes.

### Transcription Persistence
Transcription (text + segments + word timings) and diarization are cached so reopening a recording never re-transcribes:
- **Library recordings**: stored on `SavedRecording` (schema v2) via `RecordingLibraryManager.updateTranscription/updateDiarization/updateOriginalSegments/updateOriginalDiarization`; metadata JSON sidecars in the library `.metadata` dir.
- **Voice memos**: `cacheVoiceMemoTranscription(…)` writes a `VoiceMemoTranscription` sidecar (Application Support) keyed by the memo's stable file id.
- `TranscriptionView.loadOrTranscribe()` restores from cache when present; all new persisted fields are optional so older data decodes cleanly.

## Dependencies (Package.swift)

- `WhisperKit` - On-device speech recognition (CoreML)
- `FluidAudio` - On-device speaker diarization (`OfflineDiarizerManager`) and Parakeet v3 fast ASR (`AsrManager`)
- `YouTubeKit` - YouTube video downloading

**Note:** `Transcribe.xcodeproj` maintains its own `XCRemoteSwiftPackageReference` package list and does *not* read `Package.swift`. Adding/upgrading a dependency requires wiring it into the `.xcodeproj` as well (this is how FluidAudio was added).

Keychain access uses the native Security framework (`SimplifiedManagers.swift` → `KeychainHelper`).

## Localization

Uses `localized(_:)` helper function (defined in `LocalizationManager.swift`). String files:
- `Transcribe/Resources/en.lproj/Localizable.strings` - English
- `Transcribe/Resources/sv.lproj/Localizable.strings` - Swedish

English is the default locale with full Swedish localization.

## Testing

```bash
# Run from Xcode: Cmd+U
# Or via xcodebuild:
xcodebuild test -scheme Transcribe -destination 'platform=macOS'
```

The pure logic of the new subsystems is framework-free and unit-tested (these tests can be reasoned about without a Mac, though the build itself is Mac-only):

- `TranscribeTests/DiarizationMergerTests.swift` - word→speaker assignment + grouping
- `TranscribeTests/TimedTranscriptTests.swift` - active-word lookup, edit reconciliation, restore
- `TranscribeTests/SpeakerReconciliationTests.swift` - merge/reassign/split/join/regroup
- `TranscribeTests/ParakeetDraftParserTests.swift` - token→word→segment parsing
- `TranscribeTests/DraftSpliceTests.swift` - progressive draft→Whisper splice
- `TranscribeTests/RecordingLibraryManagerTests.swift`, `VoiceMemosMetadataReaderTests.swift` - library/cache + Voice Memos metadata

Other test files:
- `TranscribeTests/TranscribeTests.swift`
- `TranscribeUITests/TranscribeUITests.swift`

## Known Issues / Future Work

- `localOnlyMode` setting exists in UI but is not enforced — network calls can still occur when enabled
- `nonisolated(unsafe) static let shared` on `LocalizationManager` suppresses concurrency warnings without fixing thread safety
- YouTubeTranscriptionView UI strings are hardcoded in Swedish (not using `localized()`)
- AppDelegate status bar menu strings are hardcoded in English (not using `localized()`)
- **Diarized view has no follow-playback auto-scroll** — the "Follow playback" toggle only drives the plain `InteractiveTranscriptView`; the diarized utterance list doesn't scroll to the active turn
- **Berget cloud path is segment-level only** — no word timings, so the interactive transcript degrades to segment highlight/seek and diarization-by-word merge isn't available on cloud transcripts
- **Design docs** for these features live in `docs/superpowers/specs/` and `docs/superpowers/plans/` (gitignored by default; force-added). Each feature has a dated design + implementation plan.

### Deliberately out of scope (YAGNI, per the design specs)
- Multi-select batch reassignment, automatic re-clustering split, and drag-and-drop speaker reassignment
- Word insertion/deletion as a timing-aware edit (only replace + sentence re-tokenize) and re-running forced alignment after heavy edits
- Editing the instant draft while it's still being replaced
- True per-word VTT/SRT export (word timings now make this possible — a candidate follow-on)
