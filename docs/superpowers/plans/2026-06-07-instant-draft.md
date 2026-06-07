# Instant Draft for Long Recordings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For long recordings, show a fast Parakeet draft transcript immediately, progressively replace it front-to-back with streaming KB-Whisper, and run diarization as a concurrent audio-only track (computed once, merged with draft then final).

**Architecture:** Three concurrent tracks orchestrated in the view model — Parakeet draft (fast, FluidAudio ASR), Whisper refine (streaming, existing), diarization (audio-only, existing service). Display = `splice(WhisperText[0…t], draftTail(t…end))`; speaker labels assigned by time. The genuinely hard bits (token→word→segment parsing, the splice) are pure, unit-tested functions.

**Tech Stack:** Swift 6.2, SwiftUI, FluidAudio (already a dependency — `AsrManager`/`AsrModels`), WhisperKit, AVFoundation, XCTest. macOS 26.

**Spec:** `docs/superpowers/specs/2026-06-07-instant-draft-design.md`

**Branch:** `feature/instant-draft` (based on `main`).

**Build/test (Mac only — this environment is Linux):**
```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

> **No package changes:** FluidAudio is already wired (diarization). The draft uses `import FluidAudio` → `AsrManager`/`AsrModels`. No `Package.swift`/`.pbxproj` edits.

---

## File Structure

**New:**
- `Transcribe/Services/ParakeetDraftParser.swift` — pure: `[TokenTiming-like]` → `[WordTimestamp]` → `[TranscriptionSegmentData]`. Unit-tested. (Takes a local minimal token type so it stays framework-free.)
- `Transcribe/Services/DraftTranscriptionService.swift` — `@MainActor` wrapper over FluidAudio `AsrManager` (Parakeet v3); the only file importing FluidAudio ASR types. Calls the parser.
- `Transcribe/Services/DraftSplice.swift` — pure: combine Whisper-covered text + draft tail at boundary `t`. Unit-tested.
- `TranscribeTests/ParakeetDraftParserTests.swift`, `TranscribeTests/DraftSpliceTests.swift`.

**Modified:**
- `Transcribe/WhisperKitService.swift` / `Transcribe/TranscriptionService.swift` — add a `coveredUntil` time to streaming updates.
- `Transcribe/TranscriptionView.swift` — `TranscriptionViewModel` orchestrates the three tracks + splice display + diarize-once-merge-twice; a "Draft — refining…" banner.
- `Transcribe/SimplifiedManagers.swift` + `Transcribe/SettingsView.swift` — "Fast draft for long recordings" toggle + threshold.
- `Transcribe/Resources/en.lproj/Localizable.strings`, `sv.lproj/Localizable.strings`.

---

## Task 0: Spike — confirm Parakeet token word-boundary marker (Mac)

**Why:** the parser groups subword tokens into words using the SentencePiece word-start marker (assumed `▁`, U+2581). Confirm before building the parser.

- [ ] **Step 1: Temporary print** — in a scratch spot (or the CLI), run Parakeet on a short Swedish clip and print `result.tokenTimings?.prefix(20).map(\.token)`. Confirm word-initial tokens carry a leading `▁` (e.g. `["▁Jag", "▁vet", "▁inte", …]`). Note the exact marker if different.
- [ ] **Step 2: Record the finding** in the parser file's doc comment. If the marker differs from `▁`, adjust the `wordStartMarker` constant in Task 1. No commit (throwaway).

---

## Task 1: ParakeetDraftParser pure core (TDD)

**Files:**
- Create: `Transcribe/Services/ParakeetDraftParser.swift`
- Test: `TranscribeTests/ParakeetDraftParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Transcribe

final class ParakeetDraftParserTests: XCTestCase {

    private func tok(_ t: String, _ s: Double, _ e: Double) -> ParakeetDraftParser.Token {
        ParakeetDraftParser.Token(text: t, start: s, end: e, confidence: 0.9)
    }

    func testTokensToWordsGroupsSubwords() {
        // "▁Jag" "▁ve" "t" "▁inte"  ->  ["Jag", "vet", "inte"]
        let tokens = [tok("▁Jag", 0, 0.3), tok("▁ve", 0.3, 0.5), tok("t", 0.5, 0.6), tok("▁inte", 0.6, 1.0)]
        let words = ParakeetDraftParser.tokensToWords(tokens)
        XCTAssertEqual(words.map(\.word), ["Jag", "vet", "inte"])
        XCTAssertEqual(words[1].start, 0.3)   // first subword's start
        XCTAssertEqual(words[1].end, 0.6)     // last subword's end
    }

    func testWordsToSegmentsSplitsOnSentenceEnd() {
        let words = [
            WordTimestamp(word: "Hej.", start: 0, end: 1, confidence: 1),
            WordTimestamp(word: "Då", start: 1.1, end: 1.5, confidence: 1),
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 2)                 // sentence-final "." ends segment 1
        XCTAssertEqual(segs[0].text, "Hej.")
        XCTAssertEqual(segs[1].text, "Då")
    }

    func testWordsToSegmentsSplitsOnGap() {
        let words = [
            WordTimestamp(word: "a", start: 0, end: 1, confidence: 1),
            WordTimestamp(word: "b", start: 3.0, end: 3.5, confidence: 1),   // 2s gap > 0.8
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 2)
    }

    func testWordsToSegmentsKeepsRunTogether() {
        let words = [
            WordTimestamp(word: "a", start: 0, end: 0.5, confidence: 1),
            WordTimestamp(word: "b", start: 0.6, end: 1.0, confidence: 1),
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "a b")
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[0].end, 1.0)
        XCTAssertEqual(segs[0].words?.count, 2)
    }

    func testEmptyTokens() {
        XCTAssertTrue(ParakeetDraftParser.tokensToWords([]).isEmpty)
        XCTAssertTrue(ParakeetDraftParser.wordsToSegments([], maxGapSeconds: 0.8).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests → fail** (`ParakeetDraftParser` undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure conversion of Parakeet token-level timings into the app's word/segment
/// model. Framework-free (takes a minimal local `Token`), so it's unit-tested.
enum ParakeetDraftParser {

    /// Minimal mirror of FluidAudio's TokenTiming (keeps this file framework-free).
    struct Token: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
    }

    /// SentencePiece word-start marker (confirm in Task 0).
    static let wordStartMarker = "\u{2581}"  // ▁

    /// Groups subword tokens into words. A token beginning with the word-start
    /// marker starts a new word; others append to the current word.
    static func tokensToWords(_ tokens: [Token]) -> [WordTimestamp] {
        var words: [WordTimestamp] = []
        for t in tokens {
            let isWordStart = t.text.hasPrefix(wordStartMarker)
            let clean = t.text.replacingOccurrences(of: wordStartMarker, with: "")
            if clean.isEmpty { continue }
            if isWordStart || words.isEmpty {
                words.append(WordTimestamp(word: clean, start: t.start, end: t.end, confidence: t.confidence))
            } else {
                let last = words[words.count - 1]
                words[words.count - 1] = WordTimestamp(
                    word: last.word + clean,
                    start: last.start,
                    end: t.end,
                    confidence: min(last.confidence, t.confidence)
                )
            }
        }
        return words
    }

    /// Groups words into segments, breaking on a sentence-final word (ends with
    /// . ! ?) or a pause longer than `maxGapSeconds`.
    static func wordsToSegments(_ words: [WordTimestamp], maxGapSeconds: TimeInterval) -> [TranscriptionSegmentData] {
        guard !words.isEmpty else { return [] }
        var segments: [TranscriptionSegmentData] = []
        var current: [WordTimestamp] = []

        func flush() {
            guard !current.isEmpty else { return }
            segments.append(TranscriptionSegmentData(
                start: current.first!.start,
                end: current.last!.end,
                text: current.map(\.word).joined(separator: " "),
                words: current
            ))
            current = []
        }

        for (i, w) in words.enumerated() {
            if let prev = current.last, w.start - prev.end > maxGapSeconds {
                flush()
            }
            current.append(w)
            let endsSentence = w.word.hasSuffix(".") || w.word.hasSuffix("!") || w.word.hasSuffix("?")
            let isLast = i == words.count - 1
            if endsSentence || isLast { flush() }
        }
        return segments
    }
}
```

- [ ] **Step 4: Run tests → pass** (5 tests).
- [ ] **Step 5: Commit**
```bash
git add Transcribe/Services/ParakeetDraftParser.swift TranscribeTests/ParakeetDraftParserTests.swift
git commit -m "feat: add ParakeetDraftParser (tokens→words→segments) with tests"
```

---

## Task 2: DraftTranscriptionService (FluidAudio Parakeet)

**Files:**
- Create: `Transcribe/Services/DraftTranscriptionService.swift`

- [ ] **Step 1: Implement**

```swift
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
                // No usable timings — return a single untimed segment with the text.
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
```

- [ ] **Step 2: Build.** Expected: BUILD SUCCEEDED. If `AsrManager`/`AsrModels`/`transcribe(_:source:)`/`.tokenTimings` names differ in the resolved FluidAudio version, adjust ONLY this file (it isolates FluidAudio ASR types) — confirm against `SourcePackages/checkouts/FluidAudio`.
- [ ] **Step 3: Commit**
```bash
git add Transcribe/Services/DraftTranscriptionService.swift
git commit -m "feat: add DraftTranscriptionService (Parakeet v3 fast draft)"
```

---

## Task 3: DraftSplice pure core (TDD)

**Files:**
- Create: `Transcribe/Services/DraftSplice.swift`
- Test: `TranscribeTests/DraftSpliceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Transcribe

final class DraftSpliceTests: XCTestCase {

    private func seg(_ s: Double, _ e: Double, _ text: String) -> TranscriptionSegmentData {
        TranscriptionSegmentData(start: s, end: e, text: text, words: nil)
    }

    func testTailDropsSegmentsCoveredByWhisper() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b"), seg(4, 6, "c")]
        let tail = DraftSplice.tailDraft(draft, after: 3.0)   // keep segments starting at/after 3
        XCTAssertEqual(tail.map(\.text), ["b", "c"])          // b starts at 2 but spans past 3 -> kept; c kept
    }

    func testTailEmptyWhenAllCovered() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b")]
        XCTAssertTrue(DraftSplice.tailDraft(draft, after: 10).isEmpty)
    }

    func testTailAllWhenNothingCovered() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b")]
        XCTAssertEqual(DraftSplice.tailDraft(draft, after: 0).count, 2)
    }

    func testCombinedTextPrefixPlusTail() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b"), seg(4, 6, "c")]
        let text = DraftSplice.combinedText(whisperText: "ACCURATE", draft: draft, coveredUntil: 3.0)
        XCTAssertEqual(text, "ACCURATE b c")
    }
}
```

- [ ] **Step 2: Run tests → fail.**

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure helpers for the progressive draft→Whisper splice: keep the part of the
/// draft that Whisper hasn't reached yet, and build the combined display text.
enum DraftSplice {

    /// Draft segments not yet covered by Whisper: those whose END is past `t`
    /// (a segment straddling the boundary is kept so no words are dropped).
    static func tailDraft(_ draft: [TranscriptionSegmentData], after t: TimeInterval) -> [TranscriptionSegmentData] {
        draft.filter { $0.end > t }
    }

    /// Combined plain text: Whisper's covered text + the remaining draft tail.
    static func combinedText(whisperText: String, draft: [TranscriptionSegmentData], coveredUntil t: TimeInterval) -> String {
        let tail = tailDraft(draft, after: t).map { $0.text.trimmingCharacters(in: .whitespaces) }
        return ([whisperText.trimmingCharacters(in: .whitespaces)] + tail)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run tests → pass** (4 tests).
- [ ] **Step 5: Commit**
```bash
git add Transcribe/Services/DraftSplice.swift TranscribeTests/DraftSpliceTests.swift
git commit -m "feat: add DraftSplice (progressive draft→whisper splice) with tests"
```

---

## Task 4: Whisper streaming reports covered-until time

**Files:**
- Modify: `Transcribe/TranscriptionService.swift` (`TranscriptionUpdate`)
- Modify: `Transcribe/WhisperKitService.swift` (streaming callback)

- [ ] **Step 1: Add `coveredUntil` to `TranscriptionUpdate`**

In `TranscriptionService.swift`, add a field (default 0 so existing constructions compile):
```swift
struct TranscriptionUpdate {
    let text: String
    let progress: Double
    let segments: [TranscriptionSegmentData]
    let isComplete: Bool
    var coveredUntil: TimeInterval = 0
}
```

- [ ] **Step 2: Populate it from completed windows in `WhisperKitService`**

In the streaming `StreamingCallbackState.handleProgress` (where it yields non-complete updates), estimate covered time from completed windows. WhisperKit windows are ~30s; use `Double(completedSegments.count) * 30.0`. Add to the yielded `TranscriptionUpdate(... coveredUntil: Double(completedSegments.count) * 30.0)`. On the final/complete yield, set `coveredUntil` to the last segment end (`finalSegments.last?.end ?? 0`).

- [ ] **Step 3: Build & commit**
```bash
git add Transcribe/TranscriptionService.swift Transcribe/WhisperKitService.swift
git commit -m "feat: surface covered-until time in transcription streaming updates"
```

---

## Task 5: Settings — fast-draft toggle + threshold

**Files:**
- Modify: `Transcribe/SimplifiedManagers.swift`, `Transcribe/SettingsView.swift`, strings

- [ ] **Step 1: SettingsManager**

In `SimplifiedManagers.swift` (with the other `@AppStorage`):
```swift
@AppStorage("fastDraftEnabled") var fastDraftEnabled: Bool = true
@AppStorage("fastDraftThresholdMinutes") var fastDraftThresholdMinutes: Double = 5
```

- [ ] **Step 2: SettingsView (GeneralSettingsView)**

Add a `SettingsCard` with a `Toggle(localized("fast_draft_toggle"), isOn:)` bound to `@AppStorage("fastDraftEnabled")`, a help `Text(localized("fast_draft_help"))`, and a `Stepper` for the threshold (1…30 min) bound to `@AppStorage("fastDraftThresholdMinutes")`, shown when the toggle is on. Mirror the existing "Identify speakers" card structure.

- [ ] **Step 3: Build & commit**
```bash
git add Transcribe/SimplifiedManagers.swift Transcribe/SettingsView.swift Transcribe/Resources/en.lproj/Localizable.strings Transcribe/Resources/sv.lproj/Localizable.strings
git commit -m "feat: add fast-draft settings (toggle + duration threshold)"
```

---

## Task 6: Orchestrate the three tracks in the view model

**Files:**
- Modify: `Transcribe/TranscriptionView.swift` (`TranscriptionViewModel` + view)

- [ ] **Step 1: Add draft state to the view model**

```swift
@Published var draftSegments: [TranscriptionSegmentData] = []
@Published var isShowingDraft = false
private var cachedSpeakerSegments: [SpeakerSegment]? = nil
private let draftService = DraftTranscriptionService()
```

- [ ] **Step 2: Gate + launch the draft and diarization tracks at start**

In `startTranscription()` (before/alongside `startWhisperKitTranscription()`), when eligible run the draft + concurrent diarization:
```swift
let thresholdSec = UserDefaults.standard.double(forKey: "fastDraftThresholdMinutes") * 60
let draftEnabled = UserDefaults.standard.bool(forKey: "fastDraftEnabled")
if draftEnabled && duration >= thresholdSec {
    isShowingDraft = true
    statusMessage = localized("draft_refining")
    Task { @MainActor in
        if let segs = try? await draftService.transcribe(fileURL: fileURL) {
            // Only show the draft if Whisper hasn't already produced text.
            if transcribedText.isEmpty || isShowingDraft {
                draftSegments = segs
                refreshDraftDisplay(coveredUntil: 0)
            }
        }
    }
    // Concurrent diarization (only if identify-speakers is on): compute speaker segments once.
    if UserDefaults.standard.bool(forKey: "identifySpeakers") {
        Task { @MainActor in
            cachedSpeakerSegments = try? await diarizationService.diarize(fileURL: fileURL)
            await applyDiarizationIfPossible()
        }
    }
}
```
(`duration` is the view model's `duration`; `diarizationService` already exists.)

- [ ] **Step 3: Splice on each Whisper streaming update**

In `startWhisperKitTranscription()`'s streaming loop, when a non-complete update arrives, if a draft is showing, render the splice instead of raw Whisper text:
```swift
if isShowingDraft && !draftSegments.isEmpty {
    self.transcribedText = DraftSplice.combinedText(
        whisperText: update.text, draft: draftSegments, coveredUntil: update.coveredUntil)
} else {
    self.transcribedText = update.text
}
```
On `update.isComplete`: `isShowingDraft = false; draftSegments = []` (Whisper fully replaces the draft); keep the existing final-segments handling.

- [ ] **Step 4: Diarize-once-merge-twice helper**

Add to the view model — re-merge the cached speaker segments with whatever word-timed transcript is current:
```swift
private func applyDiarizationIfPossible() async {
    guard let speakers = cachedSpeakerSegments else { return }
    // Prefer final segments once Whisper is done; otherwise the draft.
    let source = (!isShowingDraft && !segments.isEmpty) ? segments : draftSegments
    let words: [DiarizationMerger.Word] = source.flatMap { seg in
        (seg.words ?? []).map { DiarizationMerger.Word(text: $0.word, start: $0.start, end: $0.end) }
    }
    guard !words.isEmpty else { return }
    diarizedUtterances = await diarizationMerger.merge(words: words, speakers: speakers)
}
```
Call `applyDiarizationIfPossible()` when the draft arrives, when diarization finishes, and after Whisper completes (replacing the existing post-Whisper `diarize()` path: if `cachedSpeakerSegments != nil`, just re-merge; else run the existing `diarize()`).

- [ ] **Step 5: A `refreshDraftDisplay` helper** that sets `transcribedText` from the current draft (covered 0) so the draft shows immediately:
```swift
private func refreshDraftDisplay(coveredUntil t: TimeInterval) {
    transcribedText = DraftSplice.combinedText(whisperText: "", draft: draftSegments, coveredUntil: t)
    wordCount = transcribedText.split(separator: " ").count
}
```

- [ ] **Step 6: Banner** — in the transcript header (or near the streaming indicator), show `Text(localized("draft_refining"))` when `viewModel.isShowingDraft`.

- [ ] **Step 7: Reset** — in `retranscribe()`, add `draftSegments = []; isShowingDraft = false; cachedSpeakerSegments = nil`.

- [ ] **Step 8: Build & smoke-test** on a long Swedish file: draft appears in seconds; speakers appear when clustering finishes; Whisper text rolls in front-to-back; on completion, full interactive transcript. Short files behave exactly as before.

- [ ] **Step 9: Commit**
```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: orchestrate Parakeet draft + progressive Whisper splice + concurrent diarization"
```

---

## Task 7: Localization

**Files:** `en.lproj`, `sv.lproj`

- [ ] **Step 1: English**
```
"fast_draft_toggle" = "Fast draft for long recordings";
"fast_draft_help" = "Show an instant draft (Parakeet) for long files while the accurate transcription is prepared.";
"fast_draft_threshold" = "Minimum length (minutes)";
"draft_refining" = "Draft — refining with Whisper…";
```
- [ ] **Step 2: Swedish**
```
"fast_draft_toggle" = "Snabbutkast för långa inspelningar";
"fast_draft_help" = "Visa ett direkt utkast (Parakeet) för långa filer medan den noggranna transkriptionen förbereds.";
"fast_draft_threshold" = "Minsta längd (minuter)";
"draft_refining" = "Utkast — förbättras med Whisper…";
```
- [ ] **Step 3: Commit**

---

## Task 8: Verification + push

- [ ] **Step 1: Full build** → BUILD SUCCEEDED.
- [ ] **Step 2: Tests** → all pass incl. `ParakeetDraftParserTests`, `DraftSpliceTests`.
- [ ] **Step 3: Manual**: long Swedish file → fast draft → speakers appear → progressive Whisper replacement → final interactive transcript persists; short file unchanged; draft setting off → unchanged; Parakeet model download failure → falls straight to Whisper.
- [ ] **Step 4: Push** → `git push -u origin feature/instant-draft`.

---

## Notes for the implementer

- **Cannot build/test on Linux** — gates run on the Mac.
- **Do Task 0 first** — confirm the `▁` token marker; it's the parser's one assumption.
- **FluidAudio already a dependency** — no package edits; `DraftTranscriptionService` is the only file touching FluidAudio ASR types (adjust there if the resolved API differs).
- **Diarize once, merge twice** — reuse `DiarizationService.diarize` (segments) + `DiarizationMerger.merge`; do NOT re-cluster. `cachedSpeakerSegments` holds the single computation.
- **Draft is transient** — never persisted; only the final Whisper transcript persists via the existing path. No persistence/model changes.
- **Fallback is load-bearing** — any draft/Parakeet failure must fall straight through to today's Whisper streaming.
