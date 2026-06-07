# Instant Draft for Long Recordings — Design

**Date:** 2026-06-07
**Status:** Approved (design); pending implementation plan
**Branch:** `feature/instant-draft` (based on `feature/speaker-reconciliation`, the
tip of the stack — builds on diarization + interactive transcript + reconciliation)

## Goal

For long recordings, show a **fast Parakeet draft transcript immediately**, then
**progressively replace it front-to-back** with streaming KB-Whisper output, while
**diarization runs concurrently** (computed once, applied to draft then final).
The win: start reading a usable transcript in seconds instead of waiting minutes,
with speakers appearing as soon as clustering finishes and the accurate text rolling
in window by window.

## Decisions (from brainstorming)

- **Draft engine:** FluidAudio **Parakeet TDT v3** (fast, 25 European languages incl.
  Swedish; confirm Swedish at implementation).
- **Trigger:** setting **"Fast draft for long recordings"** (default on) + a
  **duration threshold** (default 5 min). Files ≥ threshold get the draft pass;
  shorter ones go straight to Whisper streaming (already fast enough).
- **Replacement:** **progressive, front-to-back** — display = Whisper text for the
  covered prefix `[0, t]` spliced with the draft tail `(t, end]`; `t` advances as
  Whisper completes windows (per-window granularity, approximate seam).
- **Diarization is a concurrent track** — audio-only, computed **once**, merged with
  the draft words first and the Whisper words at the end. Speaker labels are assigned
  **by time**, so they're stable across the draft→accurate seam.
- **Interactivity:** the draft is **read + seek + (diarized labels/highlight when
  ready)**; **editing** activates only when Whisper completes (editing a moving seam
  is unsafe, and edits should target the accurate text).
- **Draft is transient** — only the final Whisper transcript persists.

## Architecture — three concurrent tracks

```
[Long file] ─► AudioPreprocessor (16kHz mono WAV, shared by all)
       ├──────────────► Parakeet v3 (FluidAudio ASR) ─► whole-file DRAFT segments (timed)         [fast]
       ├──────────────► KB-Whisper (streaming) ───────► accurate segments, window by window        [slow]
       └──────────────► Diarizer (FluidAudio) ────────► speaker time-segments (computed ONCE)      [slow]

Display = splice( Whisper[0…t] , draftTail(t…end) )         t = Whisper covered-until time
Speaker labels = merge( currentWords , speakerSegments )    by timestamp; same for draft & final
On Whisper completion → full accurate transcript with word timings → interactive (edit) enabled
```

`diarize once, merge twice`: the expensive clustering runs a single time; the cheap
`DiarizationMerger` runs against the draft words (early) and the Whisper words (final).

## Components (small, isolated)

- **`DraftTranscriptionService.swift`** (`@MainActor`) — wraps FluidAudio
  `AsrManager` (Parakeet `v3` via `AsrModels.downloadAndLoad(version: .v3)`), lazy
  model download mirroring WhisperKit/diarization. `transcribe(fileURL:) async throws
  -> [TranscriptionSegmentData]` (with word/token timings when available). The ONLY
  file importing FluidAudio's ASR types.
- **`DraftSplice.swift`** — pure, unit-tested: `tailDraft(_ draft: [TranscriptionSegmentData], after t: TimeInterval) -> [TranscriptionSegmentData]`
  and the combine helper that yields the displayed segments from
  (whisper-covered, draft-tail). No UI, no audio.
- **`DiarizationService` / `DiarizationMerger`** (existing) — reused. The service's
  `diarize(audio)` (speaker segments) is launched concurrently; the merger runs for
  the draft and again for the final. No diarization re-clustering.
- **`TranscriptionViewModel`** — orchestrates the three tracks; holds
  `draftSegments`, `coveredUntil: TimeInterval`, `isShowingDraft: Bool`, cached
  `speakerSegments`, and re-merges as inputs arrive. Existing Whisper path unchanged
  except it now reports a covered-until time.
- **`WhisperKitService` / `TranscriptionService`** — surface a **covered-until time**
  in streaming updates (derive from completed window count × window duration).
- **Settings** — the "Fast draft for long recordings" toggle + threshold.

## Data flow

1. **Start** (file ≥ threshold && draft enabled): launch Parakeet draft; launch
   diarization concurrently (only if "Identify speakers" is on); launch Whisper.
   (< threshold or draft disabled → current behavior, unchanged.)
2. **Draft ready:** show draft segments, banner "Draft — refining with Whisper…".
   If diarization has finished and the draft has word timings → merge → diarized draft.
3. **Whisper streaming:** `coveredUntil = t` advances; display = Whisper text `[0,t]`
   + `tailDraft(after: t)`. Speaker labels (if available) follow by time.
4. **Whisper complete:** final segments (with word timings) → merge with cached
   `speakerSegments` → diarized final → **interactive features enable** → persist via
   the existing path. Draft discarded.

## Error handling & fallback

- **Parakeet unavailable / draft fails** → skip the draft pass, go straight to Whisper
  streaming (today's behavior). The feature is purely additive.
- **Parakeet lacks usable word timings** → draft renders at segment granularity;
  diarized labels on the draft fall back to segment-level (or wait for Whisper).
- **Diarization disabled or fails** → plain transcript; draft/refine still work.
- **Cancel / Re-transcribe** → all three tracks stop.

## Testing

`DraftSplice` unit tests: boundary at 0 (all draft), mid (split), end (all Whisper);
`tailDraft` filters draft segments strictly after `t`; empty draft; draft entirely
before `t`. Draft service, diarization concurrency, and the live splice = build +
manual smoke on a long Swedish recording.

## Out of scope (YAGNI)

Editing/diarizing-as-correction on the draft (waits for refine), persisting the draft,
word-precise seam alignment, re-clustering, Berget cloud path (offline/local only),
and short-file drafts.
