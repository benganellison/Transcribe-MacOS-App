# Interactive Synced Transcript — Design

**Date:** 2026-06-05
**Status:** Approved (design); pending implementation plan
**Branch:** `feature/interactive-transcript` (based on `feature/diarization`, which
carries diarization + transcription persistence that this builds on)

## Goal

Make the transcript an interactive, audio-synced surface:

1. **Highlight** — words fade grey→white as playback passes them (karaoke), the
   current word accented.
2. **Seek** — tap any word to jump audio to that moment.
3. **Edit** — correct words and sentences inline, with edits persisted and timing
   preserved as well as possible.

All three are powered by one word-aware renderer shared by the plain transcript
and the diarized speaker-blocks view.

## Decisions (from brainstorming)

- **Granularity:** word-level.
- **Word timestamps:** always generated on the local WhisperKit path (no longer
  gated behind "Identify speakers"). Also improves diarization. Recordings
  transcribed before this change need a re-transcribe to gain word sync.
- **Edit model:** edit text, keep timing best-effort (replace = exact;
  sentence rewrite = even-distribute + "approximate" flag).
- **Scope:** applies to both the plain transcript and the diarized view via one
  shared renderer (approach #1: SwiftUI lazy word-flow).

## Architecture

```
segments[words]  ─┐
                  ├─► InteractiveTranscriptView ──► LazyVStack(segments / utterances)
DiarizedUtterance ┘        │                              └─► WordFlowView(words) [FlowLayout]
   (now carries words)     │                                      • color by currentTime
                           │                                      • tap → onSeek(word.start)
   viewModel.currentTime ──┘                                      • editMode → inline TextField
   (10 Hz playback clock)                                         • low-confidence hint
```

During streaming (`isTranscribing`) the existing fast `AutoScrollingTextView`
remains; on completion the interactive renderer takes over.

## Components (small, single-purpose, testable)

- **`FlowLayout.swift`** — a SwiftUI `Layout` (macOS 13+) wrapping word subviews
  like text. Pure layout, no state.
- **`WordFlowView.swift`** — renders one segment's/utterance's words via
  `FlowLayout`; colors each by time; handles tap (seek) and inline edit; shows the
  low-confidence cue. Inputs: `words`, `spokenUntil`, `activeWordID`, `isEditing`,
  `showConfidenceHints`, callbacks.
- **`InteractiveTranscriptView.swift`** — `LazyVStack` of segments (or diarized
  utterances). Owns a `ScrollViewReader` to auto-scroll to the active word when
  "Follow playback" is on. Reused by both views.
- **`TimedTranscript.swift`** — *pure, no UI*: `activeWordIndex(at:)` (binary
  search), edit reconciliation, `rebuildText(from:)`. The unit-tested core.

### Performance

The renderer never re-lays-out the whole transcript per tick. `LazyVStack` keeps
only on-screen segments materialized; each word colors itself from a single
`spokenUntil: TimeInterval` (`word.end <= spokenUntil ? .white : .grey`, current
word accented). A multi-thousand-word meeting evaluates only the ~visible words
each 0.1s tick.

## Data-model changes

- **`WordTimestamp` / `TranscriptionSegmentData`** — fields become `var` (currently
  `let`) so edits mutate in place. Add `var timingApproximate: Bool = false` to a
  segment to mark interpolated word timing after a sentence rewrite. Stay
  `Codable`/`Equatable`.
- **`DiarizedUtterance` gains `words: [WordTimestamp]`** — the merge currently
  joins words into `text` and discards per-word timings; word highlight in the
  diarized view needs them, so `DiarizationMerger` retains each utterance's words.
- **Word timestamps always-on** — drop the `forceWordTimestamps`/`identifySpeakers`
  gating in `WhisperKitService`/`TranscriptionService`; always generate on the
  local path.

## Edit & timing reconciliation

Edit mode is a header toggle. Two gestures:

- **Word edit:** tap a word → inline `TextField`. Commit replaces `word.text`;
  timing untouched → highlight/seek stay exact.
- **Sentence edit:** edit a segment's full text. On commit, re-tokenize into words
  and reconcile against the segment `[start, end]`:
  - *same word count* → map old timings 1:1 (exact);
  - *different count* → distribute `[start, end]` evenly across new words and set
    `timingApproximate = true` (sentence-level highlight stays correct; word-level
    is interpolated within that sentence).

After any edit, `rebuildText(from:)` regenerates `transcribedText`, and we persist
through existing paths: `updateTranscription(…segments…)` for library recordings,
the voice-memo sidecar, and `updateDiarization` for diarized edits.

### Edit recoverability

- The existing **Re-transcribe** button regenerates the original transcript from
  audio — a natural "revert all edits."
- A lightweight **one-step in-session undo** for the most recent edit.
- Editing is therefore never destructive: worst case, Re-transcribe restores ground
  truth.

## Low-confidence hinting (guided editing)

`WordTimestamp.confidence` already exists. In edit mode (and optionally always, via
a toggle), words below a confidence threshold get a subtle cue (dotted underline /
slightly dimmed). This points the user straight at the words most likely to be
wrong, making correction fast. Off by default outside edit mode to keep reading
clean.

## Integration

- `TranscriptionView`: render `InteractiveTranscriptView` for completed plain
  transcripts and inside diarized blocks; keep `AutoScrollingTextView` for
  streaming and as the no-word-timing fallback. Add an **Edit** toggle and a
  **Follow playback** toggle to the transcript header.
- Reuses `viewModel.currentTime`, `viewModel.seek(to:)`, `viewModel.segments`,
  `viewModel.diarizedUtterances`, `viewModel.playbackSpeed` — all already present.
- **Playback speed composes unchanged**: the karaoke clock reads `currentTime`,
  which already advances at the chosen rate.
- **Export**: edits update `transcribedText`/`segments`, so existing txt/SRT/VTT
  export uses corrected text automatically.

## Fallback & error handling

- **No word timings** (cached transcripts from before always-on; Berget cloud
  path) → renderer degrades to **segment-level**: whole segment highlights, tap
  seeks to segment start, sentence editing still works. No crash, no empty UI.
- **Empty word edit** → no-op (deletion out of scope for v1).
- **Edit during playback** → highlight updates pause for the segment being edited;
  resume on commit.

## Testing

`TimedTranscript` unit tests:
- `activeWordIndex(at:)` — before first, after last, gaps between words, exact
  boundary, single word.
- reconciliation — same-count keeps timing; different-count even-distribution sets
  `timingApproximate`; word replace keeps timing.
- `rebuildText(from:)` — round-trip text from segments after edits.

`FlowLayout`, `WordFlowView`, and integration get manual smoke tests (build is
Mac-only). Verify: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`.

## Out of scope (YAGNI for v1)

- Word insertion/deletion as a timing-aware operation (only replace + sentence
  re-tokenize).
- Drag-select across words.
- Re-running forced alignment to re-derive timings after heavy edits.
- True per-word VTT/SRT export (the word timings now enable it; defer to a
  follow-on).
- Interactive sync for the Berget cloud path beyond segment-level fallback.
