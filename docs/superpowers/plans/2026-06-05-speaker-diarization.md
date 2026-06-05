# Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in, on-device speaker diarization that labels a WhisperKit transcript with "who spoke when", rendered as renameable speaker blocks with optional LLM auto-naming.

**Architecture:** A second analysis pass runs FluidAudio's `OfflineDiarizerManager` (CoreML: Pyannote segmentation → WeSpeaker embeddings → VBx clustering) over the same 16kHz mono WAV that WhisperKit uses. A pure `DiarizationMerger` actor assigns each WhisperKit *word* to the speaker active at its midpoint and groups consecutive same-speaker words into `DiarizedUtterance`s. Results render in `TranscriptionView` and persist with `SavedRecording`.

**Tech Stack:** Swift 6.2, SwiftUI, WhisperKit (existing), FluidAudio 0.12.4 (new), CoreML/ANE, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-05-speaker-diarization-design.md`

**Branch:** `feature/diarization` (based on `feature/recording-library`; merge once at the end).

**Build/test commands** (per CLAUDE.md — Xcode UI build is broken by a coverage bug):
```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO
```

---

## File Structure

**New files:**
- `Transcribe/Models/DiarizationModels.swift` — `SpeakerSegment`, `DiarizedUtterance` value types (no framework dependencies).
- `Transcribe/Services/DiarizationMerger.swift` — pure merge actor; the only word→speaker logic. Fully unit-tested.
- `Transcribe/Services/DiarizationService.swift` — `@MainActor` wrapper over FluidAudio. The ONLY file that imports `FluidAudio`.
- `TranscribeTests/DiarizationMergerTests.swift` — unit tests for the merge logic.

**Modified files:**
- `Package.swift` — add FluidAudio dependency + product.
- `Transcribe/WhisperKitService.swift` — populate word timestamps; force `wordTimestamps` on when diarization requested.
- `Transcribe/Services/LLMService.swift` — add `suggestSpeakerNames`.
- `Transcribe/Models/SavedRecording.swift` — schema v2: optional `diarizedUtterances`, `speakerNames`.
- `Transcribe/Services/RecordingLibraryManager.swift` — `updateDiarization(...)`.
- `Transcribe/SimplifiedManagers.swift` — `identifySpeakers` setting (via `@AppStorage` key).
- `Transcribe/TranscriptionView.swift` — speaker-block rendering, rename UI, on-demand + auto-name buttons.
- `Transcribe/Resources/en.lproj/Localizable.strings` and `sv.lproj/Localizable.strings` — new UI strings.

---

## Task 1: Add FluidAudio dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, add to the `dependencies` array (after the YouTubeKit line):

```swift
        // FluidAudio for on-device speaker diarization (CoreML)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
```

- [ ] **Step 2: Add the product to the Transcribe target**

In the `Transcribe` target's `dependencies` array (currently `["WhisperKit", "YouTubeKit"]`), add:

```swift
                .product(name: "FluidAudio", package: "FluidAudio"),
```

- [ ] **Step 3: Resolve and build**

Run: `xcodebuild -resolvePackageDependencies -scheme Transcribe`
Then: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED, FluidAudio fetched into SourcePackages.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add FluidAudio dependency for diarization"
```

---

## Task 2: Core diarization data types

**Files:**
- Create: `Transcribe/Models/DiarizationModels.swift`

These types have NO framework dependency so they can be unit-tested and persisted freely.

- [ ] **Step 1: Create the models file**

```swift
import Foundation

/// A contiguous block of audio attributed to one speaker by the diarizer.
/// Framework-agnostic wrapper so FluidAudio types never leak past DiarizationService.
struct SpeakerSegment: Equatable {
    let speakerLabel: String   // e.g. "Speaker 1"
    let start: TimeInterval
    let end: TimeInterval
}

/// One speaker turn of transcribed text, ready for the UI and for persistence.
struct DiarizedUtterance: Identifiable, Equatable, Codable {
    let id: UUID
    let speakerID: String      // stable label from the diarizer, e.g. "Speaker 1"
    var displayName: String    // shown in UI; defaults to speakerID, overridden by rename/LLM
    var text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(id: UUID = UUID(), speakerID: String, displayName: String? = nil, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName ?? speakerID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/Models/DiarizationModels.swift
git commit -m "feat: add SpeakerSegment and DiarizedUtterance models"
```

---

## Task 3: DiarizationMerger (the heart — TDD)

**Files:**
- Create: `Transcribe/Services/DiarizationMerger.swift`
- Test: `TranscribeTests/DiarizationMergerTests.swift`

The merger takes flat word timings (word + start/end) plus `[SpeakerSegment]`, assigns each word to the speaker whose block contains the word's **midpoint**, and groups consecutive same-speaker words into utterances. Tie-break: if no block contains the midpoint, pick the block with the greatest temporal overlap; if still none, attach to the previous word's speaker (or "Speaker 1" if first).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Transcribe

final class DiarizationMergerTests: XCTestCase {

    // Minimal word input shape the merger consumes.
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizationMerger.Word {
        DiarizationMerger.Word(text: text, start: start, end: end)
    }

    func testGroupsConsecutiveSameSpeakerWords() async {
        let words = [w("Hej", 0.0, 0.5), w("alla", 0.5, 1.0), w("välkomna", 1.0, 1.8)]
        let speakers = [SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 2.0)]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "Hej alla välkomna")
        XCTAssertEqual(result[0].startTime, 0.0)
        XCTAssertEqual(result[0].endTime, 1.8)
    }

    func testSplitsAtSpeakerChangeMidStream() async {
        // Speaker 1 then Speaker 2 at t=1.0 — boundary falls between words.
        let words = [w("Hej", 0.0, 0.4), w("Bob", 0.4, 0.9), w("Hej", 1.1, 1.5), w("Anna", 1.5, 2.0)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 1.0, end: 2.5),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.map(\.speakerID), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result[0].text, "Hej Bob")
        XCTAssertEqual(result[1].text, "Hej Anna")
    }

    func testWordMidpointDecidesAssignment() async {
        // Word spans 0.8–1.2, midpoint 1.0 lands exactly on the boundary -> earlier block wins.
        let words = [w("gräns", 0.8, 1.2)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 1.0, end: 2.0),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
    }

    func testSingleSpeakerWhenNoSpeakerBlocks() async {
        let words = [w("ensam", 0.0, 0.5)]
        let result = await DiarizationMerger().merge(words: words, speakers: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
    }

    func testEmptyWordsReturnsEmpty() async {
        let result = await DiarizationMerger().merge(words: [], speakers: [SpeakerSegment(speakerLabel: "Speaker 1", start: 0, end: 1)])
        XCTAssertTrue(result.isEmpty)
    }

    func testWordInGapAttachesToPreviousSpeaker() async {
        // Second word's midpoint (2.0) is in a gap between blocks -> overlap=0 -> previous speaker.
        let words = [w("ett", 0.2, 0.6), w("två", 1.9, 2.1)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 3.0, end: 4.0),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "ett två")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO -only-testing:TranscribeTests/DiarizationMergerTests`
Expected: FAIL to compile — `DiarizationMerger` and `DiarizationMerger.Word` not defined.

- [ ] **Step 3: Implement the merger**

```swift
import Foundation

/// Pure, framework-free merge of transcript words with speaker blocks.
/// Assigns each word to the speaker active at its midpoint and groups
/// consecutive same-speaker words into utterances.
actor DiarizationMerger {

    /// Minimal word timing the merger needs (decoupled from WhisperKit types).
    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    func merge(words: [Word], speakers: [SpeakerSegment]) -> [DiarizedUtterance] {
        guard !words.isEmpty else { return [] }

        var utterances: [DiarizedUtterance] = []
        var lastSpeaker: String? = nil

        for word in words {
            let speaker = speakerLabel(for: word, in: speakers, fallback: lastSpeaker)
            lastSpeaker = speaker

            if var current = utterances.last, current.speakerID == speaker {
                current.text += " " + word.text
                // endTime extends with each appended word.
                utterances[utterances.count - 1] = DiarizedUtterance(
                    id: current.id,
                    speakerID: current.speakerID,
                    displayName: current.displayName,
                    text: current.text,
                    startTime: current.startTime,
                    endTime: word.end
                )
            } else {
                utterances.append(DiarizedUtterance(
                    speakerID: speaker,
                    text: word.text,
                    startTime: word.start,
                    endTime: word.end
                ))
            }
        }
        return utterances
    }

    /// Picks the speaker whose block contains the word midpoint; on a tie/boundary
    /// the earlier block wins (blocks assumed sorted by start). Falls back to the
    /// greatest-overlap block, then to the previous word's speaker, then "Speaker 1".
    private func speakerLabel(for word: Word, in speakers: [SpeakerSegment], fallback: String?) -> String {
        guard !speakers.isEmpty else { return fallback ?? "Speaker 1" }
        let midpoint = (word.start + word.end) / 2.0

        // Containment (half-open (start, end] so a midpoint on a boundary goes to the EARLIER block,
        // whose interval ends there — not the later block whose interval starts there).
        if let containing = speakers.first(where: { midpoint > $0.start && midpoint <= $0.end }) {
            return containing.speakerLabel
        }
        // Greatest temporal overlap with the word's span.
        let best = speakers.max { a, b in overlap(word, a) < overlap(word, b) }
        if let best, overlap(word, best) > 0 {
            return best.speakerLabel
        }
        return fallback ?? speakers[0].speakerLabel
    }

    private func overlap(_ word: Word, _ block: SpeakerSegment) -> TimeInterval {
        max(0, min(word.end, block.end) - max(word.start, block.start))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO -only-testing:TranscribeTests/DiarizationMergerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Transcribe/Services/DiarizationMerger.swift TranscribeTests/DiarizationMergerTests.swift
git commit -m "feat: add word-level DiarizationMerger with unit tests"
```

---

## Task 4: Populate WhisperKit word timestamps

**Files:**
- Modify: `Transcribe/WhisperKitService.swift` (DecodingOptions ~line 261; final segment mapping ~line 295-300)

WhisperKit's `TranscriptionSegment.words` is `[WordTiming]?` where `WordTiming` has `word: String`, `start: Float`, `end: Float`, `probability: Float`. Map these into the app's existing `WordTimestamp`. Word timestamps must be ON whenever diarization is requested.

- [ ] **Step 1: Thread a `forceWordTimestamps` flag through `transcribe`**

Change the signature:

```swift
    func transcribe(fileURL: URL, modelId: String, language: String?, forceWordTimestamps: Bool = false) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
```

In the `DecodingOptions` construction, OR the flag into the existing setting:

```swift
                    let wordTimestamps = UserDefaults.standard.bool(forKey: "wordTimestamps") || forceWordTimestamps
```

- [ ] **Step 2: Map WhisperKit words into the final segments**

Replace the final-segment mapping block (currently `words: nil`) with:

```swift
                        let finalSegments = firstResult.segments.map { segment in
                            TranscriptionSegmentData(
                                start: Double(segment.start),
                                end: Double(segment.end),
                                text: segment.text,
                                words: segment.words?.map { wt in
                                    WordTimestamp(
                                        word: wt.word,
                                        start: Double(wt.start),
                                        end: Double(wt.end),
                                        confidence: wt.probability
                                    )
                                }
                            )
                        }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED. (If `WordTiming` property names differ in the resolved WhisperKit version, the compiler error pinpoints them — adjust the four mapped fields accordingly.)

- [ ] **Step 4: Commit**

```bash
git add Transcribe/WhisperKitService.swift
git commit -m "feat: populate WhisperKit word timestamps for diarization"
```

---

## Task 5: DiarizationService (FluidAudio wrapper)

**Files:**
- Create: `Transcribe/Services/DiarizationService.swift`

This is the ONLY file importing FluidAudio. It converts FluidAudio output into `[SpeakerSegment]` and relabels raw speaker IDs to friendly "Speaker N" labels in first-appearance order.

- [ ] **Step 1: Create the service**

```swift
import Foundation
import FluidAudio

/// Wraps FluidAudio's offline diarizer. Loads CoreML models lazily (auto-download
/// on first use), runs diarization on a prepared 16kHz mono WAV, and returns
/// framework-agnostic SpeakerSegment values.
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

    /// Runs diarization on a 16kHz mono WAV and returns ordered speaker segments.
    func diarize(fileURL: URL) async throws -> [SpeakerSegment] {
        try await prepare()
        guard let manager else { throw DiarizationError.modelLoadFailed("manager nil") }
        do {
            let result = try await manager.process(fileURL)
            return relabel(result.segments)
        } catch {
            throw DiarizationError.processingFailed(error.localizedDescription)
        }
    }

    /// Maps raw diarizer speaker IDs to "Speaker 1/2/3…" in first-appearance order.
    /// NOTE: FluidAudio segment property names (speakerId/startTimeSeconds/endTimeSeconds)
    /// are confined to this method — adjust here if the resolved version differs.
    private func relabel(_ segments: [DiarizedSegment]) -> [SpeakerSegment] {
        var mapping: [String: String] = [:]
        var next = 1
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
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
            return SpeakerSegment(speakerLabel: label,
                                  start: TimeInterval(seg.startTimeSeconds),
                                  end: TimeInterval(seg.endTimeSeconds))
        }
    }
}
```

- [ ] **Step 2: Build and reconcile FluidAudio type names**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED. If it fails on `DiarizedSegment`, `speakerId`, `startTimeSeconds`, or `endTimeSeconds`, open the resolved package to find the real names:
```bash
find ~/Library/Developer/Xcode/DerivedData -path '*checkouts/FluidAudio/Sources*' -name '*.swift' | xargs grep -l "func process" 
```
Adjust ONLY `relabel(_:)` and the `process` call — `SpeakerSegment` keeps the rest of the app insulated.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/Services/DiarizationService.swift
git commit -m "feat: add DiarizationService wrapping FluidAudio offline diarizer"
```

---

## Task 6: Orchestrate transcription + diarization into utterances

**Files:**
- Modify: `Transcribe/TranscriptionView.swift` (the view model / `transcribe` flow that consumes `TranscriptionService`)

Goal: after a transcription completes with word timestamps, optionally run diarization and produce `[DiarizedUtterance]` held in view state. This task wires the pieces; UI rendering is Task 10.

- [ ] **Step 1: Add diarization state to the transcription view model**

Find the `@StateObject`/`ObservableObject` backing `TranscriptionView` (the type holding transcription text/segments). Add:

```swift
    @Published var diarizedUtterances: [DiarizedUtterance] = []
    @Published var isDiarizing: Bool = false
    @Published var diarizationError: String? = nil
    private let diarizationService = DiarizationService()
    private let diarizationMerger = DiarizationMerger()
```

- [ ] **Step 2: Add a method that diarizes a completed transcription**

`segments` here are the `[TranscriptionSegmentData]` produced by the completed transcription (must carry `words`). `audioURL` is the 16kHz mono WAV used for transcription (reuse `AudioPreprocessor` output; if the original was native, preprocess once for diarization).

```swift
    /// Runs diarization for an already-transcribed file and builds utterances.
    @MainActor
    func diarize(audioURL: URL, segments: [TranscriptionSegmentData]) async {
        isDiarizing = true
        diarizationError = nil
        defer { isDiarizing = false }

        // Flatten words (fall back to segment-level pseudo-words if word timings absent).
        let words: [DiarizationMerger.Word] = segments.flatMap { seg -> [DiarizationMerger.Word] in
            if let ws = seg.words, !ws.isEmpty {
                return ws.map { DiarizationMerger.Word(text: $0.word.trimmingCharacters(in: .whitespaces),
                                                       start: $0.start, end: $0.end) }
            }
            return [DiarizationMerger.Word(text: seg.text.trimmingCharacters(in: .whitespaces),
                                           start: seg.start, end: seg.end)]
        }.filter { !$0.text.isEmpty }

        do {
            let speakers = try await diarizationService.diarize(fileURL: audioURL)
            let utterances = await diarizationMerger.merge(words: words, speakers: speakers)
            self.diarizedUtterances = utterances
        } catch {
            self.diarizationError = error.localizedDescription
        }
    }
```

- [ ] **Step 3: Pass `forceWordTimestamps` when the toggle is on**

Where the view model calls `TranscriptionService.transcribe(...)`, ensure the WhisperKit path receives `forceWordTimestamps: UserDefaults.standard.bool(forKey: "identifySpeakers")`. Add a matching parameter to `TranscriptionService.transcribe` and `transcribeWithWhisperKit` that forwards into `WhisperKitService.transcribe(..., forceWordTimestamps:)`. Default `false` to keep existing callers working.

In `TranscriptionService.swift`:
```swift
    func transcribe(fileURL: URL, forceWordTimestamps: Bool = false) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
```
forward it down to `service.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage, forceWordTimestamps: forceWordTimestamps)`.

- [ ] **Step 4: Auto-run diarization after transcription when toggle is on**

In the completion branch (where `update.isComplete` is handled and final `segments` are available), add:

```swift
        if UserDefaults.standard.bool(forKey: "identifySpeakers") {
            await diarize(audioURL: completedAudioURL, segments: finalSegments)
        }
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Transcribe/TranscriptionView.swift Transcribe/TranscriptionService.swift
git commit -m "feat: orchestrate diarization pass after transcription"
```

---

## Task 7: LLM speaker auto-naming

**Files:**
- Modify: `Transcribe/Services/LLMService.swift`

Add a one-shot (non-streaming use of the streaming API) method that asks the configured LLM to map speaker labels to real names found in the dialogue. Returns a `[label: name]` map; only confident names are included by the model per the prompt instructions.

- [ ] **Step 1: Add `suggestSpeakerNames`**

```swift
    /// Asks the LLM to infer real speaker names from a labeled transcript.
    /// Returns a map from speaker label (e.g. "Speaker 1") to a name (e.g. "Anna").
    /// Only includes labels the model is confident about; returns [:] on any failure.
    func suggestSpeakerNames(
        utterances: [DiarizedUtterance],
        provider: Provider,
        model: String,
        apiKey: String = "",
        ollamaHost: String = "http://127.0.0.1:11434"
    ) async -> [String: String] {
        // Build a compact labeled transcript.
        let transcript = utterances
            .map { "\($0.speakerID): \($0.text)" }
            .joined(separator: "\n")

        let system = """
        You identify speaker names in a transcript. The transcript uses generic labels \
        like "Speaker 1". Using only evidence in the text (self-introductions such as \
        "I'm Anna", or direct address such as "Bob, what do you think?"), map labels to \
        real first names. Respond with ONLY a JSON object mapping label to name, e.g. \
        {"Speaker 1":"Anna"}. Omit any speaker you are not confident about. No prose.
        """

        var collected = ""
        do {
            for try await chunk in streamCompletion(
                systemPrompt: system, userMessage: transcript,
                provider: provider, model: model, apiKey: apiKey, ollamaHost: ollamaHost
            ) {
                collected += chunk
            }
        } catch {
            return [:]
        }

        // Extract the first {...} JSON object from the response.
        guard let start = collected.firstIndex(of: "{"),
              let end = collected.lastIndex(of: "}"),
              start < end else { return [:] }
        let json = String(collected[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var result: [String: String] = [:]
        for (k, v) in raw {
            if let name = v as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                result[k] = name
            }
        }
        return result
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/Services/LLMService.swift
git commit -m "feat: add LLM speaker auto-naming to LLMService"
```

---

## Task 8: Persist diarization with saved recordings

**Files:**
- Modify: `Transcribe/Models/SavedRecording.swift`
- Modify: `Transcribe/Services/RecordingLibraryManager.swift`

- [ ] **Step 1: Bump schema and add optional fields to `SavedRecording`**

Set `static let currentSchemaVersion = 2`. Add stored properties (after `transcribedAt`):

```swift
    var diarizedUtterances: [DiarizedUtterance]?
    var speakerNames: [String: String]?   // speakerID -> display name override
```

Add them to the initializer with defaults `nil` (place params alongside the existing transcription params):

```swift
        diarizedUtterances: [DiarizedUtterance]? = nil,
        speakerNames: [String: String]? = nil,
```
and assign `self.diarizedUtterances = diarizedUtterances` / `self.speakerNames = speakerNames`.

Because all new fields are optional, existing v1 JSON decodes cleanly (missing keys → nil). No custom decoder needed.

- [ ] **Step 2: Add an update method to `RecordingLibraryManager`**

Mirror the existing `updateTranscription(recordingID:text:model:)` (around line 166):

```swift
    func updateDiarization(recordingID: UUID, utterances: [DiarizedUtterance], speakerNames: [String: String]) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
        var updated = savedRecordings[index]
        updated.diarizedUtterances = utterances
        updated.speakerNames = speakerNames
        updated.updatedAt = Date()
        savedRecordings[index] = updated
        persist(updated)   // use whatever the existing private save helper is named (see updateTranscription)
    }
```

(Match the persistence call used by `updateTranscription` — e.g. writing `metadataURL` via the existing encoder around line 366.)

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Transcribe/Models/SavedRecording.swift Transcribe/Services/RecordingLibraryManager.swift
git commit -m "feat: persist diarization and speaker names with recordings"
```

---

## Task 9: Settings toggle

**Files:**
- Modify: `Transcribe/SimplifiedManagers.swift` (SettingsManager) and `Transcribe/SettingsView.swift`

- [ ] **Step 1: Expose the setting**

The app uses `@AppStorage` keys directly. Standardize on key `"identifySpeakers"` (already referenced in Task 6). In `SettingsView.swift`, add a `Toggle` bound to `@AppStorage("identifySpeakers") private var identifySpeakers = false` in the transcription/preferences section:

```swift
            Toggle(localized("identify_speakers_toggle"), isOn: $identifySpeakers)
            Text(localized("identify_speakers_help"))
                .font(.caption)
                .foregroundColor(.textSecondary)
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED (strings show as keys until Task 11).

- [ ] **Step 3: Commit**

```bash
git add Transcribe/SettingsView.swift
git commit -m "feat: add Identify Speakers settings toggle"
```

---

## Task 10: TranscriptionView UI — speaker blocks, rename, buttons

**Files:**
- Modify: `Transcribe/TranscriptionView.swift`

- [ ] **Step 1: Add a speaker-block list view**

When `viewModel.diarizedUtterances` is non-empty, render blocks instead of the flowing transcript. Apply name overrides from a local `@State var speakerNames: [String:String]`.

```swift
    @ViewBuilder
    private func diarizedTranscript(_ utterances: [DiarizedUtterance]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(utterances) { u in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        renamingSpeakerID = u.speakerID
                        renameFieldText = speakerNames[u.speakerID] ?? u.displayName
                    } label: {
                        Text(speakerNames[u.speakerID] ?? u.displayName)
                            .font(.headline)
                            .foregroundColor(.primaryAccent)
                    }
                    .buttonStyle(.plain)
                    Text(u.text).foregroundColor(.textPrimary)
                }
            }
        }
    }
```

Add `@State private var renamingSpeakerID: String?` and `@State private var renameFieldText = ""` and `@State private var speakerNames: [String:String] = [:]`.

- [ ] **Step 2: Add the rename sheet/alert**

```swift
        .alert(localized("rename_speaker_title"), isPresented: Binding(
            get: { renamingSpeakerID != nil },
            set: { if !$0 { renamingSpeakerID = nil } })
        ) {
            TextField(localized("speaker_name_placeholder"), text: $renameFieldText)
            Button(localized("save")) {
                if let id = renamingSpeakerID {
                    speakerNames[id] = renameFieldText.trimmingCharacters(in: .whitespaces)
                }
                renamingSpeakerID = nil
            }
            Button(localized("cancel"), role: .cancel) { renamingSpeakerID = nil }
        }
```

- [ ] **Step 3: Add on-demand "Identify speakers" and "Auto-name with AI" buttons**

In the transcript toolbar/actions area, show when `!viewModel.diarizedUtterances.isEmpty == false` (i.e. not yet diarized):

```swift
            if viewModel.diarizedUtterances.isEmpty {
                Button(localized("identify_speakers_button")) {
                    Task { await viewModel.diarize(audioURL: currentAudioURL, segments: viewModel.finalSegments) }
                }
                .disabled(viewModel.isDiarizing)
            } else {
                Button(localized("auto_name_speakers_button")) {
                    Task {
                        let names = await viewModel.suggestSpeakerNames()   // wraps LLMService with stored provider/model/key
                        for (k, v) in names { speakerNames[k] = v }
                    }
                }
            }
```

Add `viewModel.suggestSpeakerNames()` that reads provider/model/apiKey from settings (mirror how `TranscriptionView` already calls `LLMService` for text processing) and calls `LLMService().suggestSpeakerNames(...)`.

- [ ] **Step 4: Persist renames back to the saved recording**

When `speakerNames` changes for a saved recording (has a recording ID), call `recordingLibraryManager.updateDiarization(recordingID:utterances:speakerNames:)`. Hook this on the rename save and after auto-naming.

- [ ] **Step 5: Build and smoke-test**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED. Then `Cmd+R` in Xcode: transcribe a 2-speaker file with the toggle on, confirm speaker blocks render, rename works and persists, auto-name maps labels.

- [ ] **Step 6: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: render diarized speaker blocks with rename and auto-name"
```

---

## Task 11: Localization strings

**Files:**
- Modify: `Transcribe/Resources/en.lproj/Localizable.strings`
- Modify: `Transcribe/Resources/sv.lproj/Localizable.strings`

- [ ] **Step 1: Add English strings**

```
"identify_speakers_toggle" = "Identify speakers";
"identify_speakers_help" = "Detects who spoke when and labels the transcript. Adds an extra processing pass.";
"identify_speakers_button" = "Identify speakers";
"auto_name_speakers_button" = "Auto-name with AI";
"rename_speaker_title" = "Rename speaker";
"speaker_name_placeholder" = "Name";
"identifying_speakers" = "Identifying speakers…";
```

- [ ] **Step 2: Add Swedish strings**

```
"identify_speakers_toggle" = "Identifiera talare";
"identify_speakers_help" = "Upptäcker vem som talade när och märker transkriptionen. Lägger till ett extra bearbetningssteg.";
"identify_speakers_button" = "Identifiera talare";
"auto_name_speakers_button" = "Namnge automatiskt med AI";
"rename_speaker_title" = "Byt namn på talare";
"speaker_name_placeholder" = "Namn";
"identifying_speakers" = "Identifierar talare…";
```

(Ensure `save`/`cancel` keys already exist; if not, add them in both files.)

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED; UI shows localized text.

- [ ] **Step 4: Commit**

```bash
git add Transcribe/Resources/en.lproj/Localizable.strings Transcribe/Resources/sv.lproj/Localizable.strings
git commit -m "feat: add diarization localization strings (en + sv)"
```

---

## Task 12: Full verification

- [ ] **Step 1: Full build**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Full test suite**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO`
Expected: all tests pass, including `DiarizationMergerTests`.

- [ ] **Step 3: Manual end-to-end (Xcode `Cmd+R`)**

- Toggle "Identify speakers" ON → transcribe a 2-speaker file → speaker blocks render.
- Rename a speaker → applies everywhere → reopen recording → name persisted.
- "Auto-name with AI" → confident labels replaced with names.
- Toggle OFF → transcribe → plain transcript → on-demand "Identify speakers" button works.
- Single-speaker file → renders normally without forced labels.

- [ ] **Step 4: Final commit (if any cleanup)**

```bash
git add -A
git commit -m "chore: diarization polish and verification"
```

---

## Notes for the implementer

- **Reuse the preprocessed WAV.** `AudioPreprocessor` already yields 16kHz mono for WhisperKit — feed the same file to `DiarizationService` rather than converting twice. If transcription used a native file directly (no conversion), preprocess once before diarizing.
- **FluidAudio type names** (`DiarizedSegment`, `speakerId`, `startTimeSeconds`, `endTimeSeconds`, `process`) are isolated to `DiarizationService.relabel(_:)` and `diarize(_:)`. If the resolved 0.12.x API differs, fix only there.
- **Diarization is additive** — never let its failure break the plain transcript. All entry points catch and surface errors into `diarizationError` only.
- **Merge tie-break is deterministic:** midpoint containment with half-open intervals (earlier block wins on a boundary), then greatest overlap, then previous speaker.
