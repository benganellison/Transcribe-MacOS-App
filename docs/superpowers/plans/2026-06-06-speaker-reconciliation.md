# Speaker Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user fix diarization mistakes by merging two speaker labels, reassigning individual turns to another/new speaker, and restoring the diarizer's original assignment.

**Architecture:** Both operations reduce to one primitive — relabel an utterance's `speakerID` — followed by re-grouping adjacent same-speaker utterances. All that logic lives in a pure, unit-tested `SpeakerReconciliation` enum; the view model applies it to `@Published diarizedUtterances` with a snapshot for restore; the UI is a menu on the existing speaker label plus a header restore button.

**Tech Stack:** Swift 6.2, SwiftUI (`Menu`), XCTest. macOS 26.

**Spec:** `docs/superpowers/specs/2026-06-06-speaker-reconciliation-design.md`

**Branch:** `feature/speaker-reconciliation` (based on `feature/interactive-transcript`).

**Build/test (Mac only — this environment is Linux, cannot run these):**
```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

---

## File Structure

**New:**
- `Transcribe/Services/SpeakerReconciliation.swift` — pure relabel/regroup/label logic.
- `TranscribeTests/SpeakerReconciliationTests.swift` — unit tests.

**Modified:**
- `Transcribe/TranscriptionView.swift` — VM methods + `originalDiarizedUtterances` snapshot; speaker-label `Menu`; header "Restore original speakers" button; persistence wiring; load snapshot on open.
- `Transcribe/Models/SavedRecording.swift` — `originalDiarizedUtterances`.
- `Transcribe/Models/VoiceMemoRecording.swift` — `VoiceMemoTranscription.originalDiarizedUtterances`.
- `Transcribe/Services/RecordingLibraryManager.swift` — `updateOriginalDiarization`; extend voice-memo cache write.
- `Transcribe/Resources/en.lproj/Localizable.strings`, `sv.lproj/Localizable.strings` — new strings.

---

## Task 1: SpeakerReconciliation pure core (TDD)

**Files:**
- Create: `Transcribe/Services/SpeakerReconciliation.swift`
- Test: `TranscribeTests/SpeakerReconciliationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Transcribe

final class SpeakerReconciliationTests: XCTestCase {

    private func u(_ speaker: String, _ text: String, _ start: Double, _ end: Double) -> DiarizedUtterance {
        let words = text.split(separator: " ").enumerated().map { i, w in
            WordTimestamp(word: String(w), start: start + Double(i) * 0.1, end: start + Double(i) * 0.1 + 0.1, confidence: 1.0)
        }
        return DiarizedUtterance(speakerID: speaker, text: text, startTime: start, endTime: end, words: words)
    }

    func testMergeRelabelsAndRegroups() {
        let utts = [u("Speaker 1", "hello", 0, 1), u("Speaker 3", "there", 1, 2)]
        let result = SpeakerReconciliation.merge(utts, from: "Speaker 3", into: "Speaker 1")
        XCTAssertEqual(result.count, 1)                       // adjacent same-speaker coalesced
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "hello there")
        XCTAssertEqual(result[0].startTime, 0)
        XCTAssertEqual(result[0].endTime, 2)
        XCTAssertEqual(result[0].words?.count, 2)
    }

    func testMergeIntoSelfIsNoop() {
        let utts = [u("Speaker 1", "a", 0, 1), u("Speaker 2", "b", 1, 2)]
        XCTAssertEqual(SpeakerReconciliation.merge(utts, from: "Speaker 1", into: "Speaker 1"), utts)
    }

    func testReassignOneSplitsRun() {
        let a = u("Speaker 1", "a", 0, 1)
        let b = u("Speaker 1", "b", 1, 2)
        let c = u("Speaker 1", "c", 2, 3)
        let result = SpeakerReconciliation.reassign([a, b, c], utteranceID: b.id, to: "Speaker 2")
        XCTAssertEqual(result.map(\.speakerID), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(result.count, 3)                       // neighbors not same-speaker-adjacent
    }

    func testNextSpeakerLabelSkipsToMaxPlusOne() {
        let utts = [u("Speaker 1", "a", 0, 1), u("Speaker 3", "b", 1, 2)]
        XCTAssertEqual(SpeakerReconciliation.nextSpeakerLabel(in: utts), "Speaker 4")
    }

    func testRegroupConcatenatesInTimeOrder() {
        let utts = [u("Speaker 1", "one", 0, 1), u("Speaker 1", "two", 1, 2)]
        let result = SpeakerReconciliation.regroupAdjacent(utts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "one two")
        XCTAssertEqual(result[0].words?.map(\.word), ["one", "two"])
        XCTAssertEqual(result[0].endTime, 2)
    }

    func testDistinctSpeakersFirstAppearanceOrder() {
        let utts = [u("Speaker 2", "a", 0, 1), u("Speaker 1", "b", 1, 2), u("Speaker 2", "c", 2, 3)]
        XCTAssertEqual(SpeakerReconciliation.distinctSpeakers(in: utts), ["Speaker 2", "Speaker 1"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO CODE_SIGNING_ALLOWED=NO -only-testing:TranscribeTests/SpeakerReconciliationTests`
Expected: FAIL to compile — `SpeakerReconciliation` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure, framework-free speaker-label reconciliation over diarized utterances:
/// merge two speakers, reassign a single turn, and re-group adjacent same-speaker
/// utterances. No UI, no audio — unit-tested.
enum SpeakerReconciliation {

    /// Distinct speaker IDs in first-appearance order (for menus).
    static func distinctSpeakers(in utterances: [DiarizedUtterance]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for u in utterances where !seen.contains(u.speakerID) {
            seen.insert(u.speakerID)
            result.append(u.speakerID)
        }
        return result
    }

    /// The next free "Speaker N" label (one past the highest existing number).
    static func nextSpeakerLabel(in utterances: [DiarizedUtterance]) -> String {
        let prefix = "Speaker "
        var maxN = 0
        for u in utterances where u.speakerID.hasPrefix(prefix) {
            if let n = Int(u.speakerID.dropFirst(prefix.count)) { maxN = max(maxN, n) }
        }
        return "\(prefix)\(maxN + 1)"
    }

    /// Merges consecutive same-speaker utterances into one, concatenating words/text
    /// and spanning first start → last end (input assumed in time order).
    static func regroupAdjacent(_ utterances: [DiarizedUtterance]) -> [DiarizedUtterance] {
        var result: [DiarizedUtterance] = []
        for u in utterances {
            if let last = result.last, last.speakerID == u.speakerID {
                let mergedWords = (last.words ?? []) + (u.words ?? [])
                let mergedText = [last.text, u.text]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                result[result.count - 1] = DiarizedUtterance(
                    id: last.id,
                    speakerID: last.speakerID,
                    displayName: last.displayName,
                    text: mergedText,
                    startTime: last.startTime,
                    endTime: u.endTime,
                    words: mergedWords.isEmpty ? nil : mergedWords
                )
            } else {
                result.append(u)
            }
        }
        return result
    }

    /// Relabels every `source` utterance to `target`, then re-groups. No-op if source == target.
    static func merge(_ utterances: [DiarizedUtterance], from source: String, into target: String) -> [DiarizedUtterance] {
        guard source != target else { return utterances }
        let relabeled = utterances.map { u -> DiarizedUtterance in
            guard u.speakerID == source else { return u }
            return relabel(u, to: target)
        }
        return regroupAdjacent(relabeled)
    }

    /// Relabels a single utterance (by id) to `target`, then re-groups.
    static func reassign(_ utterances: [DiarizedUtterance], utteranceID: UUID, to target: String) -> [DiarizedUtterance] {
        let relabeled = utterances.map { u -> DiarizedUtterance in
            guard u.id == utteranceID else { return u }
            return relabel(u, to: target)
        }
        return regroupAdjacent(relabeled)
    }

    private static func relabel(_ u: DiarizedUtterance, to target: String) -> DiarizedUtterance {
        DiarizedUtterance(
            id: u.id,
            speakerID: target,
            displayName: target,   // shown name still resolves via speakerNames[target] in the view
            text: u.text,
            startTime: u.startTime,
            endTime: u.endTime,
            words: u.words
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:TranscribeTests/SpeakerReconciliationTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Transcribe/Services/SpeakerReconciliation.swift TranscribeTests/SpeakerReconciliationTests.swift
git commit -m "feat: add SpeakerReconciliation pure core with unit tests"
```

---

## Task 2: View-model operations + snapshot

**Files:**
- Modify: `Transcribe/TranscriptionView.swift` (`TranscriptionViewModel`)

- [ ] **Step 1: Add snapshot state + capture helper**

In `TranscriptionViewModel`, near `originalSegments`:
```swift
@Published var originalDiarizedUtterances: [DiarizedUtterance]? = nil

/// Snapshots the diarizer's speaker assignment the first time the user changes it.
func captureOriginalSpeakersIfNeeded() {
    if originalDiarizedUtterances == nil { originalDiarizedUtterances = diarizedUtterances }
}
```

- [ ] **Step 2: Add the operations**

```swift
func mergeSpeaker(_ source: String, into target: String) {
    guard source != target, !diarizedUtterances.isEmpty else { return }
    captureOriginalSpeakersIfNeeded()
    diarizedUtterances = SpeakerReconciliation.merge(diarizedUtterances, from: source, into: target)
}

func reassignUtterance(id: UUID, to target: String) {
    guard !diarizedUtterances.isEmpty else { return }
    captureOriginalSpeakersIfNeeded()
    diarizedUtterances = SpeakerReconciliation.reassign(diarizedUtterances, utteranceID: id, to: target)
}

/// Label for a brand-new speaker (used by "Assign this turn to → New speaker").
func newSpeakerLabel() -> String {
    SpeakerReconciliation.nextSpeakerLabel(in: diarizedUtterances)
}

func restoreOriginalSpeakers() {
    guard let original = originalDiarizedUtterances else { return }
    diarizedUtterances = original
}
```

- [ ] **Step 3: Clear snapshot on re-transcribe**

In `retranscribe()`, alongside `originalSegments = nil`, add:
```swift
        originalDiarizedUtterances = nil
```

- [ ] **Step 4: Build**

Run the build. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: speaker merge/reassign/restore on the view model"
```

---

## Task 3: Persist the original-speakers snapshot

**Files:**
- Modify: `Transcribe/Models/SavedRecording.swift`
- Modify: `Transcribe/Models/VoiceMemoRecording.swift`
- Modify: `Transcribe/Services/RecordingLibraryManager.swift`

- [ ] **Step 1: SavedRecording field**

After `originalTranscriptionSegments`, add the stored property:
```swift
    /// Snapshot of the diarizer's original speaker assignment, for "Restore original speakers".
    var originalDiarizedUtterances: [DiarizedUtterance]?
```
Add the matching init parameter (`originalDiarizedUtterances: [DiarizedUtterance]? = nil`) and assignment, beside `originalTranscriptionSegments`.

- [ ] **Step 2: VoiceMemoTranscription field**

In `VoiceMemoRecording.swift`, add to `VoiceMemoTranscription` after `originalSegments`:
```swift
    var originalDiarizedUtterances: [DiarizedUtterance]?
```

- [ ] **Step 3: Manager `updateOriginalDiarization`**

In `RecordingLibraryManager.swift`, mirroring `updateOriginalSegments`:
```swift
func updateOriginalDiarization(recordingID: UUID, utterances: [DiarizedUtterance]?) {
    guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
    var updated = savedRecordings[index]
    updated.originalDiarizedUtterances = utterances
    updated.updatedAt = Date()
    guard writeMetadata(updated) else { return }
    savedRecordings[index] = updated
}
```
Extend `cacheVoiceMemoTranscription` with `originalDiarizedUtterances: [DiarizedUtterance]? = nil` (default), and include it in the `VoiceMemoTranscription(...)` payload it writes. READ the current signature/body and add the parameter alongside `originalSegments`.

- [ ] **Step 4: Build & commit**

Run the build. Expected: BUILD SUCCEEDED.
```bash
git add -f Transcribe/Models/SavedRecording.swift Transcribe/Models/VoiceMemoRecording.swift
git add Transcribe/Services/RecordingLibraryManager.swift
git commit -m "feat: persist original-speakers snapshot (recordings + voice memos)"
```

---

## Task 4: UI — speaker-label menu + restore button + persistence wiring

**Files:**
- Modify: `Transcribe/TranscriptionView.swift`

- [ ] **Step 1: Add a persist helper for speaker changes**

In `TranscriptionView` (near `persistDiarizedAfterEdit`):
```swift
private func persistSpeakerChange() {
    if let recordingID = appState.currentRecordingID {
        recordingLibrary.updateDiarization(
            recordingID: recordingID, utterances: viewModel.diarizedUtterances, speakerNames: speakerNames)
        recordingLibrary.updateOriginalDiarization(
            recordingID: recordingID, utterances: viewModel.originalDiarizedUtterances)
    } else if let memoID = appState.currentVoiceMemoID {
        recordingLibrary.cacheVoiceMemoTranscription(
            id: memoID, text: viewModel.transcribedText, segments: viewModel.segments,
            model: UserDefaults.standard.string(forKey: "selectedTranscriptionModel") ?? "",
            diarizedUtterances: viewModel.diarizedUtterances, speakerNames: speakerNames,
            originalSegments: viewModel.originalSegments,
            originalDiarizedUtterances: viewModel.originalDiarizedUtterances)
    }
}
```
(`cacheVoiceMemoTranscription`'s `originalDiarizedUtterances` param is added in Task 3 — implement Tasks 3 + 4 before building.)

- [ ] **Step 2: Replace the speaker-label Button with a Menu**

In `diarizedTranscriptView`, replace the speaker-label `Button { renamingSpeakerID = … } label: { … }` (and its `.buttonStyle/.help`) with a `Menu` exposing rename, merge, and assign. The label text stays identical:
```swift
                            Menu {
                                Button(localized("rename_speaker_title")) {
                                    renamingSpeakerID = utterance.speakerID
                                    renameFieldText = speakerNames[utterance.speakerID] ?? utterance.displayName
                                }
                                let others = SpeakerReconciliation.distinctSpeakers(in: viewModel.diarizedUtterances)
                                    .filter { $0 != utterance.speakerID }
                                if !others.isEmpty {
                                    Menu(localized("merge_speaker_into")) {
                                        ForEach(others, id: \.self) { target in
                                            Button(speakerNames[target] ?? target) {
                                                viewModel.mergeSpeaker(utterance.speakerID, into: target)
                                                persistSpeakerChange()
                                            }
                                        }
                                    }
                                }
                                Menu(localized("assign_turn_to")) {
                                    ForEach(others, id: \.self) { target in
                                        Button(speakerNames[target] ?? target) {
                                            viewModel.reassignUtterance(id: utterance.id, to: target)
                                            persistSpeakerChange()
                                        }
                                    }
                                    Button(localized("new_speaker")) {
                                        viewModel.reassignUtterance(id: utterance.id, to: viewModel.newSpeakerLabel())
                                        persistSpeakerChange()
                                    }
                                }
                            } label: {
                                Text(speakerNames[utterance.speakerID] ?? utterance.displayName)
                                    .font(.system(size: max(11, fontSize - 2), weight: .semibold))
                                    .foregroundColor(.primaryAccent)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(localized("speaker_actions_help"))
```

- [ ] **Step 3: Header "Restore original speakers" button**

In `transcriptionHeader`, near the "Restore all" button, add:
```swift
if viewModel.originalDiarizedUtterances != nil {
    Button(localized("restore_original_speakers")) {
        viewModel.restoreOriginalSpeakers()
        persistSpeakerChange()
    }
    .buttonStyle(.plain)
    .foregroundColor(.primaryAccent)
}
```

- [ ] **Step 4: Load the snapshot on open**

In `loadOrTranscribe()`, in the saved-recording branch add:
```swift
viewModel.originalDiarizedUtterances = saved.originalDiarizedUtterances
```
and in the voice-memo branch:
```swift
viewModel.originalDiarizedUtterances = cached.originalDiarizedUtterances
```

- [ ] **Step 5: Build & smoke-test**

Run the build. Expected: BUILD SUCCEEDED. `Cmd+R`: diarize a file → tap a speaker label → Merge into another / Assign this turn to (existing or New speaker); blocks relabel and adjacent same-speaker coalesce; "Restore original speakers" appears and reverts; reopen → changes persisted.

- [ ] **Step 6: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: speaker-label merge/reassign menu + restore original speakers"
```

---

## Task 5: Localization

**Files:**
- Modify: `Transcribe/Resources/en.lproj/Localizable.strings`, `sv.lproj/Localizable.strings`

- [ ] **Step 1: English**
```
"merge_speaker_into" = "Merge into";
"assign_turn_to" = "Assign this turn to";
"new_speaker" = "New speaker";
"restore_original_speakers" = "Restore original speakers";
"speaker_actions_help" = "Rename, merge, or reassign this speaker";
```

- [ ] **Step 2: Swedish**
```
"merge_speaker_into" = "Slå samman med";
"assign_turn_to" = "Tilldela detta inlägg till";
"new_speaker" = "Ny talare";
"restore_original_speakers" = "Återställ ursprungliga talare";
"speaker_actions_help" = "Byt namn, slå samman eller omfördela denna talare";
```

- [ ] **Step 3: Build & commit**
```bash
git add Transcribe/Resources/en.lproj/Localizable.strings Transcribe/Resources/sv.lproj/Localizable.strings
git commit -m "feat: add speaker reconciliation localization strings (en + sv)"
```

---

## Task 6: Verification + push

- [ ] **Step 1: Full build** — `xcodebuild build ...` → BUILD SUCCEEDED.
- [ ] **Step 2: Full tests** — `xcodebuild test ...` → all pass incl. `SpeakerReconciliationTests`.
- [ ] **Step 3: Manual** (`Cmd+R`): merge an over-split speaker → blocks coalesce; reassign a mis-merged turn to New speaker → it peels out; rename still works; Restore original speakers reverts; reopen confirms persistence; Re-transcribe clears the snapshot.
- [ ] **Step 4: Push** — `git push -u origin feature/speaker-reconciliation`.

---

## Notes for the implementer

- **Cannot build/test on Linux** — gates run on the Mac. Write code; the Mac verifies.
- **Tasks 3 + 4 are interdependent** (`updateOriginalDiarization`, the new cache param) — build them together.
- **`DiarizedUtterance` init** is `init(id:speakerID:displayName:text:startTime:endTime:words:)` with `displayName`/`words` defaulted — `relabel` passes them explicitly.
- **Files under `Transcribe/Models/`** are gitignored source (quirk) — use `git add -f`.
- **Shown speaker name** = `speakerNames[speakerID] ?? displayName`; `relabel` sets `displayName = target`, and any rename override on `target` still applies in the view.
