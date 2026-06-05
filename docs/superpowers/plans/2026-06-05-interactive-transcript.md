# Interactive Synced Transcript Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the transcript an audio-synced, interactive surface: words highlight as they're spoken (karaoke), tap a word to seek, and edit words/sentences inline with timestamp-keyed restore — across both the plain and diarized views.

**Architecture:** One word-aware SwiftUI renderer (`InteractiveTranscriptView` → `WordFlowView` → `FlowLayout`) drives display/highlight/seek/edit off `segments[words]`, with all the nuanced logic (active word, edit reconciliation, restore) in a pure, unit-tested `TimedTranscript`. The existing `AutoScrollingTextView` stays for streaming; the interactive renderer takes over on completion.

**Tech Stack:** Swift 6.2, SwiftUI (`Layout`, `ScrollViewReader`), AVAudioPlayer (existing), XCTest. macOS 26.

**Spec:** `docs/superpowers/specs/2026-06-05-interactive-transcript-design.md`

**Branch:** `feature/interactive-transcript` (based on `feature/diarization`).

**Build/test (Mac only — this environment is Linux and cannot run these):**
```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

---

## File Structure

**New:**
- `Transcribe/Services/TimedTranscript.swift` — pure logic: active-word lookup, edit reconciliation, text rebuild, timestamp-based restore. No SwiftUI. Fully unit-tested.
- `Transcribe/FlowLayout.swift` — SwiftUI `Layout` that wraps word subviews like text.
- `Transcribe/WordFlowView.swift` — renders one segment's words: color-by-time, tap-to-seek, inline edit, confidence hint, context menu.
- `Transcribe/InteractiveTranscriptView.swift` — `LazyVStack` of timed segments; follow-playback auto-scroll. Used by plain + diarized.
- `TranscribeTests/TimedTranscriptTests.swift` — unit tests for `TimedTranscript`.

**Modified:**
- `Transcribe/TranscriptionView.swift` — `TranscriptionSegmentData`/`WordTimestamp` become `var` + `timingApproximate`; integrate renderer; Edit / Follow-playback toggles; edit + restore + persistence wiring.
- `Transcribe/Models/DiarizationModels.swift` — `DiarizedUtterance` gains `words`.
- `Transcribe/Services/DiarizationMerger.swift` — populate utterance `words`.
- `Transcribe/WhisperKitService.swift` + `Transcribe/TranscriptionService.swift` — word timestamps always-on.
- `Transcribe/Models/SavedRecording.swift` — `originalTranscriptionSegments`.
- `Transcribe/Models/VoiceMemoRecording.swift` — `VoiceMemoTranscription.originalSegments` + carry diarization words already present.
- `Transcribe/Services/RecordingLibraryManager.swift` — persist original snapshot.
- `Transcribe/Resources/en.lproj/Localizable.strings`, `sv.lproj/Localizable.strings` — new UI strings.

---

## Task 1: Make segment/word types editable

**Files:**
- Modify: `Transcribe/TranscriptionView.swift` (the `TranscriptionSegmentData` / `WordTimestamp` definitions near the bottom of the file)

- [ ] **Step 1: Make fields `var` and add the approximate-timing flag**

Replace the two struct definitions with:

```swift
struct TranscriptionSegmentData: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var words: [WordTimestamp]?
    /// True when word timings inside this segment were interpolated after a
    /// sentence rewrite (highlight is sentence-accurate, word-level is approximate).
    /// Optional so older persisted metadata decodes (missing key → nil → false).
    var timingApproximate: Bool?
}

struct WordTimestamp: Codable, Equatable {
    var word: String
    var start: Double
    var end: Double
    var confidence: Float
}
```

- [ ] **Step 2: Build**

Run the build command above.
Expected: BUILD SUCCEEDED. (All existing initializers use positional/labeled args that still compile; `timingApproximate` defaults via Swift's memberwise init when constructing — see note.)

NOTE: existing call sites construct `TranscriptionSegmentData(start:end:text:words:)` without `timingApproximate`. Swift's memberwise init requires all members. To avoid touching every call site, add an explicit init right below the struct:

```swift
extension TranscriptionSegmentData {
    init(start: Double, end: Double, text: String, words: [WordTimestamp]?, timingApproximate: Bool? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.timingApproximate = timingApproximate
    }
}
```

Re-run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "refactor: make transcript segment/word types editable (var + timingApproximate)"
```

---

## Task 2: TimedTranscript pure core (TDD)

**Files:**
- Create: `Transcribe/Services/TimedTranscript.swift`
- Test: `TranscribeTests/TimedTranscriptTests.swift`

`TimedTranscript` is a namespace of pure functions operating on `[TranscriptionSegmentData]`. No SwiftUI, no audio — the unit-tested heart.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Transcribe

final class TimedTranscriptTests: XCTestCase {

    private func w(_ t: String, _ s: Double, _ e: Double, _ c: Float = 0.9) -> WordTimestamp {
        WordTimestamp(word: t, start: s, end: e, confidence: c)
    }
    private func seg(_ s: Double, _ e: Double, _ words: [WordTimestamp]) -> TranscriptionSegmentData {
        TranscriptionSegmentData(start: s, end: e, text: words.map(\.word).joined(separator: " "), words: words)
    }

    // activeWordIndex
    func testActiveWordWithinSecond() {
        let segs = [seg(0, 2, [w("a", 0, 0.5), w("b", 0.5, 1.0), w("c", 1.0, 2.0)])]
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 0.7)?.wordIndex, 1)
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 0.7)?.segmentIndex, 0)
    }
    func testActiveWordBeforeFirstIsNil() {
        let segs = [seg(1, 2, [w("a", 1, 2)])]
        XCTAssertNil(TimedTranscript.activeWord(in: segs, at: 0.5))
    }
    func testActiveWordAfterLastIsLast() {
        let segs = [seg(0, 2, [w("a", 0, 1), w("b", 1, 2)])]
        let r = TimedTranscript.activeWord(in: segs, at: 5.0)
        XCTAssertEqual(r?.wordIndex, 1)
    }
    func testActiveWordInGapPicksPrevious() {
        let segs = [seg(0, 3, [w("a", 0, 1), w("b", 2, 3)])]   // gap 1..2
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 1.5)?.wordIndex, 0)
    }

    // rebuildText
    func testRebuildTextJoinsSegments() {
        let segs = [seg(0, 1, [w("Hej", 0, 1)]), seg(1, 2, [w("då", 1, 2)])]
        XCTAssertEqual(TimedTranscript.rebuildText(from: segs), "Hej då")
    }

    // sentence reconciliation
    func testReconcileSameWordCountKeepsTiming() {
        let original = seg(0, 2, [w("the", 0, 0.5), w("cat", 0.5, 2.0)])
        let result = TimedTranscript.reconcileSentence(original, newText: "the dog")
        XCTAssertEqual(result.words?.map(\.word), ["the", "dog"])
        XCTAssertEqual(result.words?[0].start, 0)      // timing preserved 1:1
        XCTAssertEqual(result.words?[1].start, 0.5)
        XCTAssertNotEqual(result.timingApproximate, true)
    }
    func testReconcileDifferentCountDistributesEvenly() {
        let original = seg(0, 3, [w("the", 0, 1.5), w("cat", 1.5, 3.0)])
        let result = TimedTranscript.reconcileSentence(original, newText: "the big black cat")
        XCTAssertEqual(result.words?.count, 4)
        XCTAssertEqual(result.words?.first?.start, 0)
        XCTAssertEqual(result.words?.last?.end, 3.0)
        XCTAssertEqual(result.timingApproximate, true)
        // evenly spaced: each ~0.75s
        XCTAssertEqual(result.words?[1].start ?? 0, 0.75, accuracy: 0.001)
    }

    // restore
    func testOriginalWordByTime() {
        let original = [seg(0, 2, [w("the", 0, 1), w("cat", 1, 2)])]
        XCTAssertEqual(TimedTranscript.originalWord(in: original, atMidpointOf: w("CAT", 1, 2))?.word, "cat")
    }
    func testOriginalSegmentByOverlap() {
        let original = [seg(0, 2, [w("a", 0, 2)]), seg(2, 4, [w("b", 2, 4)])]
        XCTAssertEqual(TimedTranscript.originalSegment(in: original, overlapping: seg(2, 4, [w("X", 2, 4)]))?.text, "b")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO CODE_SIGNING_ALLOWED=NO -only-testing:TranscribeTests/TimedTranscriptTests`
Expected: FAIL to compile — `TimedTranscript` undefined.

- [ ] **Step 3: Implement `TimedTranscript`**

```swift
import Foundation

/// Pure, framework-free operations over timed transcript segments: active-word
/// lookup for highlighting, edit/timing reconciliation, text rebuild, and
/// timestamp-keyed restore from an original snapshot.
enum TimedTranscript {

    struct WordLocation: Equatable {
        let segmentIndex: Int
        let wordIndex: Int
    }

    /// The word that should be highlighted at `time`: the last word whose start
    /// is <= time. Returns nil before the first word. In a gap between words it
    /// stays on the previous word.
    static func activeWord(in segments: [TranscriptionSegmentData], at time: TimeInterval) -> WordLocation? {
        var result: WordLocation?
        for (s, segment) in segments.enumerated() {
            guard let words = segment.words else { continue }
            for (i, word) in words.enumerated() {
                if word.start <= time {
                    result = WordLocation(segmentIndex: s, wordIndex: i)
                } else {
                    return result
                }
            }
        }
        return result
    }

    /// Full transcript text rebuilt from segments (after edits).
    static func rebuildText(from segments: [TranscriptionSegmentData]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Re-tokenizes a sentence edit into words against the segment's [start, end].
    /// Same word count → keep original timings 1:1. Different count → distribute
    /// the segment span evenly and flag timingApproximate.
    static func reconcileSentence(_ segment: TranscriptionSegmentData, newText: String) -> TranscriptionSegmentData {
        let tokens = newText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var updated = segment
        updated.text = tokens.joined(separator: " ")

        let oldWords = segment.words ?? []
        if tokens.count == oldWords.count && !tokens.isEmpty {
            updated.words = zip(tokens, oldWords).map { token, old in
                WordTimestamp(word: token, start: old.start, end: old.end, confidence: old.confidence)
            }
            updated.timingApproximate = segment.timingApproximate
            return updated
        }

        guard !tokens.isEmpty else { updated.words = []; return updated }
        let span = max(0, segment.end - segment.start)
        let step = span / Double(tokens.count)
        updated.words = tokens.enumerated().map { i, token in
            let start = segment.start + step * Double(i)
            let end = (i == tokens.count - 1) ? segment.end : start + step
            return WordTimestamp(word: token, start: start, end: end, confidence: 1.0)
        }
        updated.timingApproximate = true
        return updated
    }

    /// The original word whose time range contains the midpoint of `edited`.
    static func originalWord(in original: [TranscriptionSegmentData], atMidpointOf edited: WordTimestamp) -> WordTimestamp? {
        let mid = (edited.start + edited.end) / 2
        for segment in original {
            for word in segment.words ?? [] where word.start <= mid && mid <= word.end {
                return word
            }
        }
        // Fallback: greatest overlap.
        return original.flatMap { $0.words ?? [] }.max { a, b in
            overlap(a.start, a.end, edited.start, edited.end) < overlap(b.start, b.end, edited.start, edited.end)
        }
    }

    /// The original segment with the greatest time overlap with `edited`.
    static func originalSegment(in original: [TranscriptionSegmentData], overlapping edited: TranscriptionSegmentData) -> TranscriptionSegmentData? {
        original.max { a, b in
            overlap(a.start, a.end, edited.start, edited.end) < overlap(b.start, b.end, edited.start, edited.end)
        }.flatMap { best in
            overlap(best.start, best.end, edited.start, edited.end) > 0 ? best : nil
        }
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test ... -only-testing:TranscribeTests/TimedTranscriptTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Transcribe/Services/TimedTranscript.swift TranscribeTests/TimedTranscriptTests.swift
git commit -m "feat: add TimedTranscript pure core with unit tests"
```

---

## Task 3: Word timestamps always-on

**Files:**
- Modify: `Transcribe/WhisperKitService.swift` (the `wordTimestamps` line in `DecodingOptions`)
- Modify: `Transcribe/TranscriptionView.swift` (the `needWords` call site)

- [ ] **Step 1: Always request word timestamps on the WhisperKit path**

In `WhisperKitService.swift`, change:
```swift
let wordTimestamps = UserDefaults.standard.bool(forKey: "wordTimestamps") || forceWordTimestamps
```
to:
```swift
// Always generate word timestamps locally — powers the synced/interactive transcript
// and improves diarization. (forceWordTimestamps retained for callers/back-compat.)
let wordTimestamps = true
```

- [ ] **Step 2: Simplify the caller**

In `TranscriptionView.swift`, the streaming call currently passes `forceWordTimestamps: needWords`. Change the `needWords` line to always true (keeps the explicit signal even though the service now forces it):
```swift
let needWords = true
for try await update in transcriptionService!.transcribe(fileURL: fileURL, forceWordTimestamps: needWords) {
```

- [ ] **Step 3: Build**

Run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Transcribe/WhisperKitService.swift Transcribe/TranscriptionView.swift
git commit -m "feat: always generate word timestamps on local transcription"
```

---

## Task 4: DiarizedUtterance carries its words

**Files:**
- Modify: `Transcribe/Models/DiarizationModels.swift`
- Modify: `Transcribe/Services/DiarizationMerger.swift`

- [ ] **Step 1: Add `words` to `DiarizedUtterance`**

In `DiarizationModels.swift`, add the stored property and init param. The struct becomes:

```swift
struct DiarizedUtterance: Identifiable, Equatable, Codable {
    let id: UUID
    let speakerID: String
    var displayName: String
    var text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Per-word timings for this utterance, enabling word-level highlight/seek/edit
    /// in the diarized view. Optional so older persisted utterances decode.
    var words: [WordTimestamp]?

    init(
        id: UUID = UUID(),
        speakerID: String,
        displayName: String? = nil,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        words: [WordTimestamp]? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName ?? speakerID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }
}
```

- [ ] **Step 2: Populate words in the merger**

`DiarizationMerger.Word` (`{ text, start, end }`) lacks confidence; map it to `WordTimestamp` with confidence 1.0. In `DiarizationMerger.merge`, accumulate the words per utterance. Replace the merge body so each utterance collects its `Word`s and converts them on append/extend:

```swift
func merge(words: [Word], speakers: [SpeakerSegment]) -> [DiarizedUtterance] {
    guard !words.isEmpty else { return [] }

    var utterances: [DiarizedUtterance] = []
    var currentWords: [[WordTimestamp]] = []   // parallel to utterances
    var lastSpeaker: String? = nil

    func wt(_ word: Word) -> WordTimestamp {
        WordTimestamp(word: word.text, start: word.start, end: word.end, confidence: 1.0)
    }

    for word in words {
        let speaker = speakerLabel(for: word, in: speakers, fallback: lastSpeaker)
        lastSpeaker = speaker

        if let current = utterances.last, current.speakerID == speaker {
            currentWords[currentWords.count - 1].append(wt(word))
            let merged = currentWords[currentWords.count - 1]
            utterances[utterances.count - 1] = DiarizedUtterance(
                id: current.id,
                speakerID: current.speakerID,
                displayName: current.displayName,
                text: current.text + " " + word.text,
                startTime: current.startTime,
                endTime: word.end,
                words: merged
            )
        } else {
            currentWords.append([wt(word)])
            utterances.append(DiarizedUtterance(
                speakerID: speaker,
                text: word.text,
                startTime: word.start,
                endTime: word.end,
                words: [wt(word)]
            ))
        }
    }
    return utterances
}
```

- [ ] **Step 3: Build and run existing merger tests**

Run: `xcodebuild test ... -only-testing:TranscribeTests/DiarizationMergerTests`
Expected: PASS (existing tests still green — they assert text/speaker, which are unchanged).

- [ ] **Step 4: Commit**

```bash
git add Transcribe/Models/DiarizationModels.swift Transcribe/Services/DiarizationMerger.swift
git commit -m "feat: diarized utterances retain per-word timings"
```

---

## Task 5: FlowLayout

**Files:**
- Create: `Transcribe/FlowLayout.swift`

- [ ] **Step 1: Implement the wrapping layout**

```swift
import SwiftUI

/// A SwiftUI Layout that arranges subviews left-to-right, wrapping to the next line
/// when the row width is exceeded — like text flow. Used to lay out word views.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
```

- [ ] **Step 2: Build**

Run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/FlowLayout.swift
git commit -m "feat: add FlowLayout for wrapping word views"
```

---

## Task 6: WordFlowView

**Files:**
- Create: `Transcribe/WordFlowView.swift`

Renders one segment's words: color by time, tap to seek, inline edit, confidence hint, and restore context menu. The owning view supplies callbacks and the active state.

- [ ] **Step 1: Implement WordFlowView**

```swift
import SwiftUI

/// Renders the words of a single segment as a wrapping, interactive flow.
struct WordFlowView: View {
    let words: [WordTimestamp]
    let segmentIndex: Int
    /// Playback position; a word is "spoken" once currentTime passes its end.
    let currentTime: TimeInterval
    let fontSize: CGFloat
    let isEditing: Bool
    let showConfidenceHints: Bool
    /// confidence below this gets a subtle cue (only when hints shown)
    let lowConfidenceThreshold: Float

    let onSeek: (TimeInterval) -> Void
    let onEditWord: (_ wordIndex: Int, _ newText: String) -> Void
    let onRestoreWord: (_ wordIndex: Int) -> Void
    let onRestoreSentence: () -> Void

    @State private var editingWordIndex: Int? = nil
    @State private var editText: String = ""

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                wordView(index: index, word: word)
                    .id("w-\(segmentIndex)-\(index)")
            }
        }
    }

    @ViewBuilder
    private func wordView(index: Int, word: WordTimestamp) -> some View {
        if isEditing && editingWordIndex == index {
            TextField("", text: $editText, onCommit: {
                onEditWord(index, editText)
                editingWordIndex = nil
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: fontSize))
            .frame(minWidth: 40)
        } else {
            Text(word.word)
                .font(.system(size: fontSize))
                .foregroundColor(color(for: word))
                .underline(showConfidenceHints && word.confidence < lowConfidenceThreshold, pattern: .dot)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditing {
                        editingWordIndex = index
                        editText = word.word
                    } else {
                        onSeek(word.start)
                    }
                }
                .contextMenu {
                    Button(localized("restore_word")) { onRestoreWord(index) }
                    Button(localized("restore_sentence")) { onRestoreSentence() }
                }
        }
    }

    private func color(for word: WordTimestamp) -> Color {
        if word.start <= currentTime && currentTime <= word.end {
            return .primaryAccent          // current word
        }
        return word.end <= currentTime ? .textPrimary : .textTertiary  // spoken vs upcoming
    }
}
```

- [ ] **Step 2: Build**

Run the build. Expected: BUILD SUCCEEDED. (Strings `restore_word`/`restore_sentence` resolve to keys until Task 12; `localized`, `.primaryAccent`, `.textPrimary/Tertiary` already exist.)

- [ ] **Step 3: Commit**

```bash
git add Transcribe/WordFlowView.swift
git commit -m "feat: add WordFlowView (color-by-time, tap-seek, inline edit, restore menu)"
```

---

## Task 7: InteractiveTranscriptView

**Files:**
- Create: `Transcribe/InteractiveTranscriptView.swift`

Hosts the segments in a `LazyVStack`, follows playback by scrolling to the active word, and forwards callbacks. It is data-source agnostic: it takes `[TranscriptionSegmentData]` (plain) — the diarized view composes `WordFlowView` directly per utterance in Task 8.

- [ ] **Step 1: Implement InteractiveTranscriptView**

```swift
import SwiftUI

struct InteractiveTranscriptView: View {
    let segments: [TranscriptionSegmentData]
    let currentTime: TimeInterval
    let fontSize: CGFloat
    let isEditing: Bool
    let followPlayback: Bool
    let showConfidenceHints: Bool

    let onSeek: (TimeInterval) -> Void
    let onEditWord: (_ segmentIndex: Int, _ wordIndex: Int, _ newText: String) -> Void
    let onRestoreWord: (_ segmentIndex: Int, _ wordIndex: Int) -> Void
    let onRestoreSentence: (_ segmentIndex: Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { sIndex, segment in
                        WordFlowView(
                            words: segment.words ?? [],
                            segmentIndex: sIndex,
                            currentTime: currentTime,
                            fontSize: fontSize,
                            isEditing: isEditing,
                            showConfidenceHints: isEditingTranscript || showConfidenceHints,
                            lowConfidenceThreshold: 0.5,
                            onSeek: onSeek,
                            onEditWord: { wIndex, text in onEditWord(sIndex, wIndex, text) },
                            onRestoreWord: { wIndex in onRestoreWord(sIndex, wIndex) },
                            onRestoreSentence: { onRestoreSentence(sIndex) }
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: currentTime) { _, t in
                guard followPlayback, !isEditing,
                      let active = TimedTranscript.activeWord(in: segments, at: t) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("w-\(active.segmentIndex)-\(active.wordIndex)", anchor: .center)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Transcribe/InteractiveTranscriptView.swift
git commit -m "feat: add InteractiveTranscriptView (lazy segments + follow-playback scroll)"
```

---

## Task 8: Integrate into TranscriptionView (display + seek + highlight)

**Files:**
- Modify: `Transcribe/TranscriptionView.swift`

Wire the renderer into the plain transcript (completed, has word timings) and the diarized blocks. Editing/restore callbacks land in Task 9–10; here they're stubbed to mutate view state.

- [ ] **Step 1: Add view state for the new toggles**

Near the other diarization `@State` vars in `TranscriptionView`:
```swift
@State private var isEditingTranscript = false
@State private var followPlayback = true
@AppStorage("showConfidenceHints") private var showConfidenceHints = false
```

- [ ] **Step 2: Add a helper to detect word-level availability**

Add to `TranscriptionView`:
```swift
private var hasWordTimings: Bool {
    viewModel.segments.contains { ($0.words?.isEmpty == false) }
}
```

- [ ] **Step 3: Render the interactive view for completed plain transcripts**

In `transcriptionContent`, replace the `else { AutoScrollingTextView(... plainDisplayText ...) }` branch so that when the transcript is complete and has word timings (and not in segments mode), it uses the interactive renderer; otherwise it falls back to `AutoScrollingTextView`:

```swift
} else if !viewModel.isTranscribing && hasWordTimings && displayMode != .segments {
    InteractiveTranscriptView(
        segments: viewModel.segments,
        currentTime: viewModel.currentTime,
        fontSize: fontSize,
        isEditing: isEditingTranscript,
        followPlayback: followPlayback,
        showConfidenceHints: isEditingTranscript || showConfidenceHints,
        onSeek: { viewModel.seek(to: $0) },
        onEditWord: { s, w, text in applyWordEdit(segmentIndex: s, wordIndex: w, newText: text) },
        onRestoreWord: { s, w in restoreWord(segmentIndex: s, wordIndex: w) },
        onRestoreSentence: { s in restoreSentence(segmentIndex: s) }
    )
} else {
    AutoScrollingTextView(
        text: plainDisplayText,
        fontSize: fontSize,
        isStreaming: viewModel.isTranscribing
    )
}
```

- [ ] **Step 4: Add Edit + Follow-playback toggles to the header**

In `transcriptionHeader`, before `transcriptionStats`, add (only when there's a completed transcript with word timings):
```swift
if !viewModel.isTranscribing && hasWordTimings {
    Toggle(isOn: $followPlayback) { Image(systemName: "arrow.down.to.line") }
        .toggleStyle(.button).help(localized("follow_playback"))
    Toggle(isOn: $isEditingTranscript) { Image(systemName: "pencil") }
        .toggleStyle(.button).help(localized("edit_transcript"))
}
```

- [ ] **Step 5: Add stub edit/restore methods (filled in Tasks 9–10)**

Add to `TranscriptionView` so Step 3 compiles; real bodies come next:
```swift
private func applyWordEdit(segmentIndex: Int, wordIndex: Int, newText: String) { }
private func restoreWord(segmentIndex: Int, wordIndex: Int) { }
private func restoreSentence(segmentIndex: Int) { }
```

- [ ] **Step 6: Use WordFlowView inside the diarized blocks**

In `diarizedTranscriptView`, replace the `Text(utterance.text)` body with a `WordFlowView` when the utterance has words (fallback to `Text` otherwise):
```swift
if let uWords = utterance.words, !uWords.isEmpty {
    WordFlowView(
        words: uWords,
        segmentIndex: 10_000 + (viewModel.diarizedUtterances.firstIndex(of: utterance) ?? 0),
        currentTime: viewModel.currentTime,
        fontSize: fontSize,
        isEditing: isEditingTranscript,
        showConfidenceHints: isEditingTranscript || showConfidenceHints,
        lowConfidenceThreshold: 0.5,
        onSeek: { viewModel.seek(to: $0) },
        onEditWord: { _, _ in },          // diarized word edit wired in Task 9
        onRestoreWord: { _ in },
        onRestoreSentence: { }
    )
} else {
    Text(utterance.text)
        .font(.system(size: fontSize))
        .foregroundColor(.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
}
```
(The `segmentIndex` offset keeps diarized word `.id`s from colliding with plain ones.)

- [ ] **Step 7: Build and smoke-test**

Run the build. Expected: BUILD SUCCEEDED. Then `Cmd+R`: transcribe a file → completed transcript shows interactive words; play audio → words highlight grey→white, current word accented, view follows; tap a word → audio jumps there; diarized view highlights per word.

- [ ] **Step 8: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: render interactive synced transcript with highlight + tap-to-seek"
```

---

## Task 9: Inline editing with reconciliation

**Files:**
- Modify: `Transcribe/TranscriptionView.swift`

Make the view model own the editable segments and persist edits.

- [ ] **Step 1: Add an edit method to the view model**

In `TranscriptionViewModel`, add:
```swift
/// Replaces a single word's text, keeping its timing; rebuilds transcribedText.
func editWord(segmentIndex: Int, wordIndex: Int, newText: String) {
    guard segments.indices.contains(segmentIndex),
          var words = segments[segmentIndex].words,
          words.indices.contains(wordIndex) else { return }
    let trimmed = newText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    captureOriginalIfNeeded()
    words[wordIndex].word = trimmed
    segments[segmentIndex].words = words
    segments[segmentIndex].text = words.map(\.word).joined(separator: " ")
    transcribedText = TimedTranscript.rebuildText(from: segments)
}

/// Re-tokenizes a whole sentence (segment) edit via TimedTranscript reconciliation.
func editSentence(segmentIndex: Int, newText: String) {
    guard segments.indices.contains(segmentIndex) else { return }
    captureOriginalIfNeeded()
    segments[segmentIndex] = TimedTranscript.reconcileSentence(segments[segmentIndex], newText: newText)
    transcribedText = TimedTranscript.rebuildText(from: segments)
}
```

- [ ] **Step 2: Add the original snapshot field + capture to the view model**

In `TranscriptionViewModel`, add:
```swift
@Published var originalSegments: [TranscriptionSegmentData]? = nil

/// Snapshots the unedited segments the first time an edit occurs.
func captureOriginalIfNeeded() {
    if originalSegments == nil { originalSegments = segments }
}
```
Also clear it in `retranscribe()` (add `originalSegments = nil` alongside the other resets).

- [ ] **Step 3: Fill the view's edit stub + persist**

Replace `applyWordEdit` stub:
```swift
private func applyWordEdit(segmentIndex: Int, wordIndex: Int, newText: String) {
    viewModel.editWord(segmentIndex: segmentIndex, wordIndex: wordIndex, newText: newText)
    persistAfterEdit()
}

private func persistAfterEdit() {
    let model = UserDefaults.standard.string(forKey: "selectedTranscriptionModel") ?? ""
    if let recordingID = appState.currentRecordingID {
        recordingLibrary.updateTranscription(
            recordingID: recordingID, text: viewModel.transcribedText,
            segments: viewModel.segments, model: model)
        recordingLibrary.updateOriginalSegments(recordingID: recordingID, segments: viewModel.originalSegments)
    } else if let memoID = appState.currentVoiceMemoID {
        recordingLibrary.cacheVoiceMemoTranscription(
            id: memoID, text: viewModel.transcribedText, segments: viewModel.segments, model: model,
            diarizedUtterances: viewModel.diarizedUtterances, speakerNames: speakerNames)
    }
}
```
(`updateOriginalSegments` is added in Task 10.)

- [ ] **Step 4: Build**

Run the build. Expected: BUILD SUCCEEDED (note: `updateOriginalSegments` is referenced; if building this task in isolation, temporarily comment that line — Task 10 adds it. Otherwise implement Tasks 9 and 10 together before building.)

- [ ] **Step 5: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: inline word/sentence editing with reconciliation + persistence"
```

---

## Task 10: Original snapshot persistence + restore

**Files:**
- Modify: `Transcribe/Models/SavedRecording.swift`
- Modify: `Transcribe/Models/VoiceMemoRecording.swift`
- Modify: `Transcribe/Services/RecordingLibraryManager.swift`
- Modify: `Transcribe/TranscriptionView.swift`

- [ ] **Step 1: Add original-snapshot fields to persistence models**

In `SavedRecording.swift`, add the stored property after `transcriptionSegments`:
```swift
    /// Immutable snapshot of the unedited transcription segments, for per-element restore.
    var originalTranscriptionSegments: [TranscriptionSegmentData]?
```
Add the matching init param (default `nil`) and assignment, alongside `transcriptionSegments`.

In `VoiceMemoRecording.swift`, add to `VoiceMemoTranscription`:
```swift
    var originalSegments: [TranscriptionSegmentData]?
```

- [ ] **Step 2: Add `updateOriginalSegments` to the manager**

In `RecordingLibraryManager.swift`, mirroring `updateDiarization`:
```swift
func updateOriginalSegments(recordingID: UUID, segments: [TranscriptionSegmentData]?) {
    guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
    var updated = savedRecordings[index]
    updated.originalTranscriptionSegments = segments
    updated.updatedAt = Date()
    guard writeMetadata(updated) else { return }
    savedRecordings[index] = updated
}
```

- [ ] **Step 3: Implement restore in the view model**

In `TranscriptionViewModel`:
```swift
func restoreWord(segmentIndex: Int, wordIndex: Int) {
    guard let original = originalSegments,
          segments.indices.contains(segmentIndex),
          var words = segments[segmentIndex].words,
          words.indices.contains(wordIndex),
          let originalWord = TimedTranscript.originalWord(in: original, atMidpointOf: words[wordIndex])
    else { return }
    words[wordIndex] = originalWord
    segments[segmentIndex].words = words
    segments[segmentIndex].text = words.map(\.word).joined(separator: " ")
    transcribedText = TimedTranscript.rebuildText(from: segments)
}

func restoreSentence(segmentIndex: Int) {
    guard let original = originalSegments,
          segments.indices.contains(segmentIndex),
          let originalSeg = TimedTranscript.originalSegment(in: original, overlapping: segments[segmentIndex])
    else { return }
    segments[segmentIndex] = originalSeg
    transcribedText = TimedTranscript.rebuildText(from: segments)
}

func restoreAll() {
    guard let original = originalSegments else { return }
    segments = original
    transcribedText = TimedTranscript.rebuildText(from: segments)
}
```

- [ ] **Step 4: Fill the view's restore stubs + load original on open**

Replace the stubs:
```swift
private func restoreWord(segmentIndex: Int, wordIndex: Int) {
    viewModel.restoreWord(segmentIndex: segmentIndex, wordIndex: wordIndex)
    persistAfterEdit()
}
private func restoreSentence(segmentIndex: Int) {
    viewModel.restoreSentence(segmentIndex: segmentIndex)
    persistAfterEdit()
}
```
Add a **Restore all** button to `transcriptionHeader` (shown only when `viewModel.originalSegments != nil`, i.e. edits exist):
```swift
if viewModel.originalSegments != nil {
    Button(localized("restore_all")) {
        viewModel.restoreAll()
        persistAfterEdit()
    }
    .buttonStyle(.plain)
    .foregroundColor(.primaryAccent)
}
```

In `loadOrTranscribe()` (saved-recording branch), after `loadPersisted(...)`, restore the snapshot:
```swift
viewModel.originalSegments = saved.originalTranscriptionSegments
```
and in the voice-memo branch:
```swift
viewModel.originalSegments = cached.originalSegments
```
Update `cacheVoiceMemoTranscription` call in `persistAfterEdit`/`persistTranscription` to also pass the original — extend `cacheVoiceMemoTranscription` with an `originalSegments:` param (default nil) and write it into the payload (mirror Task 8 of the diarization plan's pattern).

- [ ] **Step 5: Build**

Run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add -f Transcribe/Models/SavedRecording.swift Transcribe/Models/VoiceMemoRecording.swift
git add Transcribe/Services/RecordingLibraryManager.swift Transcribe/TranscriptionView.swift
git commit -m "feat: original snapshot persistence + timestamp-based restore"
```

---

## Task 11: Localization

**Files:**
- Modify: `Transcribe/Resources/en.lproj/Localizable.strings`, `sv.lproj/Localizable.strings`

- [ ] **Step 1: Add English strings**
```
"edit_transcript" = "Edit transcript";
"follow_playback" = "Follow playback";
"restore_word" = "Restore word";
"restore_sentence" = "Restore sentence";
"restore_all" = "Restore all";
```

- [ ] **Step 2: Add Swedish strings**
```
"edit_transcript" = "Redigera transkription";
"follow_playback" = "Följ uppspelning";
"restore_word" = "Återställ ord";
"restore_sentence" = "Återställ mening";
"restore_all" = "Återställ allt";
```

- [ ] **Step 3: Build & commit**
```bash
git add Transcribe/Resources/en.lproj/Localizable.strings Transcribe/Resources/sv.lproj/Localizable.strings
git commit -m "feat: add interactive transcript localization strings (en + sv)"
```

---

## Task 12: Verification

- [ ] **Step 1: Full build** — `xcodebuild build ...` → BUILD SUCCEEDED.
- [ ] **Step 2: Full tests** — `xcodebuild test ...` → all pass incl. `TimedTranscriptTests`, `DiarizationMergerTests`.
- [ ] **Step 3: Manual end-to-end** (`Cmd+R`):
  - Transcribe a file → words highlight during playback; current word accented; view follows; toggle Follow off → no auto-scroll.
  - Tap a word → audio seeks there.
  - Edit mode → tap a word, change it, commit → text updates, persists; reopen → edit retained.
  - Right-click an edited word → Restore word → original returns; Restore sentence works.
  - Diarized recording → per-word highlight + seek inside speaker blocks.
  - Confidence hints toggle → low-confidence words get the dotted cue in edit mode.
  - Old recording without word timings / Berget → falls back to `AutoScrollingTextView` cleanly.
- [ ] **Step 4: Push**
```bash
git push -u origin feature/interactive-transcript
```

---

## Notes for the implementer

- **Cannot build/test on Linux** — every build/test step runs on the Mac. Write the code; run the gates there.
- **Tasks 9 + 10 are interdependent** (`updateOriginalSegments`, `persistAfterEdit`) — implement them back-to-back before building.
- **Word identity** is index-based (`w-<segmentIndex>-<wordIndex>`); diarized words offset their segment index by 10,000 to avoid `.id` collisions in a shared scroll space.
- **Fallback is load-bearing**: any segment without `words` (old cached transcripts, Berget) must render via `AutoScrollingTextView`. `hasWordTimings` gates this.
- **Confidence threshold** 0.5 is a starting value; tune after seeing real WhisperKit probabilities.
- **Diarized-view editing & restore are staged.** This plan delivers, in the diarized view, **highlight + tap-to-seek** (read-only — easy, fully wired). It delivers the **full set** (highlight + seek + edit + restore) in the **plain transcript** view. Diarized-view *editing and restore* are intentionally stubbed (the empty `onEditWord`/`onRestoreWord`/`onRestoreSentence` handlers in Task 8 Step 6) because they need parallel view-model methods that mutate `diarizedUtterances[i].words`, re-derive utterance text, and persist via `updateDiarization` — a mechanical fast-follow reusing the same `TimedTranscript` core. **Confirm with the user** whether to fold diarized edit/restore into this pass or ship it as the immediate next increment.
