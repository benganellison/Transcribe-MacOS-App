# Speaker Reconciliation (merge / reassign) — Design

**Date:** 2026-06-06
**Status:** Approved (design); pending implementation plan
**Branch:** new branch off `feature/interactive-transcript` (builds on diarization +
the interactive transcript's edit/restore patterns)

## Goal

Let the user manually correct diarization mistakes:

- **Merge** two speaker labels into one (the diarizer over-split one person).
- **Reassign** individual turns to a different / new speaker (the diarizer merged
  two people — peel mis-attributed turns out one at a time). This is the "split".
- **Restore original speakers** — revert all manual changes to the diarizer's output.

## Core insight

Both operations reduce to one primitive — **relabel an utterance's `speakerID`** —
followed by **re-grouping adjacent same-speaker utterances** so the display stays
clean. The hard logic is therefore a few pure functions, fully unit-testable.

## Decisions (from brainstorming)

- **Split = manual reassignment**, one turn at a time (no auto re-clustering).
- **Trigger = menus on the existing per-utterance speaker label** (minimal new UI).
- **Revert = snapshot + "Restore original speakers"**, mirroring the transcript
  Restore-all; persisted so it survives reopen.

## Operations

- **Merge `B → A`:** every utterance with `speakerID == B` is relabeled `A`; B's
  entry in the `speakerNames` override map is dropped; adjacent same-speaker
  utterances re-group.
- **Reassign one turn:** a single utterance is relabeled to another existing
  speaker, or to a **New speaker** (`Speaker <maxN+1>`); re-group adjacent.
- **Restore original speakers:** replace `diarizedUtterances` with the snapshot.

## UI

The per-utterance speaker label (today a rename button) becomes a **Menu**:
- *Rename speaker…* (existing behavior)
- *Merge "Speaker X" into ▸* — submenu listing the other current speakers
- *Assign this turn to ▸* — submenu of the other speakers **plus "New speaker"**

A **"Restore original speakers"** button appears in the transcript header when a
manual-change snapshot exists (sibling to the existing "Restore all").

## Components (small, isolated, testable)

- **`Transcribe/Services/SpeakerReconciliation.swift`** — pure, no UI, no audio:
  - `merge(_ utterances: [DiarizedUtterance], from: String, into: String) -> [DiarizedUtterance]`
  - `reassign(_ utterances: [DiarizedUtterance], utteranceID: UUID, to: String) -> [DiarizedUtterance]`
  - `regroupAdjacent(_ utterances: [DiarizedUtterance]) -> [DiarizedUtterance]` — merge
    consecutive same-`speakerID` utterances, concatenating `words` + `text`, taking the
    first `startTime` / last `endTime` (time order preserved).
  - `nextSpeakerLabel(in: [DiarizedUtterance]) -> String` — `Speaker <maxN+1>`.
  - `distinctSpeakers(in: [DiarizedUtterance]) -> [String]` — for the menus, in
    first-appearance order.
- **`TranscriptionViewModel`** (in `TranscriptionView.swift`): `mergeSpeaker(_:into:)`,
  `reassignUtterance(id:to:)`, `restoreOriginalSpeakers()`, plus
  `@Published var originalDiarizedUtterances: [DiarizedUtterance]?` and
  `captureOriginalSpeakersIfNeeded()` (snapshot on first change; cleared in
  `retranscribe()` / when diarization is re-run).
- **`TranscriptionView`**: the speaker-label Menu, the header "Restore original
  speakers" button, and persistence wiring.
- **`RecordingLibraryManager`**: `updateOriginalDiarization(recordingID:utterances:)`
  (mirrors `updateOriginalSegments`); extend the voice-memo cache write.
- **Persistence models**: `SavedRecording.originalDiarizedUtterances: [DiarizedUtterance]?`
  and `VoiceMemoTranscription.originalDiarizedUtterances: [DiarizedUtterance]?` (optional,
  decode-safe).

## Data flow

1. User picks Merge / Assign from a label menu.
2. View calls VM method → `captureOriginalSpeakersIfNeeded()` snapshots the current
   `diarizedUtterances` (only the first time) → applies the pure relabel + regroup →
   updates `@Published diarizedUtterances`.
3. View persists: `updateDiarization(...)` (current) + `updateOriginalDiarization(...)`
   (snapshot) for library recordings, or the voice-memo sidecar for memos.
4. Reopen loads both the current diarization and the snapshot (so Restore still works).

## Edge cases & error handling

- Merge into self, or into/from a non-existent speaker → no-op.
- "New speaker" computes the next free `Speaker N` from existing labels.
- Re-grouping concatenates `words` in time order, so word-level highlight / seek /
  edit keep working on a merged block; `text` is rebuilt from the merged words.
- Renames live in `speakerNames` keyed by `speakerID`; merge drops the source's
  override, target keeps its own.
- Manual speaker changes and the word-level edit/restore feature are independent and
  compose (different fields).

## Testing

`SpeakerReconciliationTests`:
- merge relabels all of B→A and regroups adjacent blocks into one;
- reassign-one splits a run (one utterance moves, neighbors unaffected);
- `nextSpeakerLabel` returns the next free number (e.g. with Speaker 1/Speaker 3 → Speaker 4);
- `regroupAdjacent` concatenates words/text and preserves time order;
- merge into self / unknown speaker is a no-op;
- `distinctSpeakers` returns first-appearance order.

Build/UI verified on the Mac (`xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`).

## Out of scope (YAGNI)

Multi-select batch reassignment, automatic re-clustering split, drag-and-drop
reassignment, and a dedicated speaker-management panel.
