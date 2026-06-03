# Recording Library & Voice Memos Integration

**Date**: 2026-06-03  
**Status**: Approved

## Summary

Add persistent recording storage and a recording library to Transcribe. Recordings auto-save to `~/Documents/Transcribe/` instead of being deleted on quit. Integrate with Apple Voice Memos for read access (and optional write-back). A new "My Recordings" view on the main screen provides unified access to both sources.

## Goals

1. **Persistent recordings** — All recordings (mic and system audio) auto-save and survive app restarts
2. **Recording library** — Browse, play, rename, delete, and transcribe saved recordings from within the app
3. **Voice Memos access** — Show Apple Voice Memos recordings in a separate section for direct transcription or import
4. **Rich metadata** — Each recording stores name, date, duration, location, comment, and transcription text

## Non-Goals

- Full-featured audio editor
- iCloud sync of recordings (the folder is in ~/Documents so users can enable iCloud Drive sync themselves)
- Importing from arbitrary third-party apps

## Storage Design

### Directory Structure

```
~/Documents/Transcribe/
├── 2026-06-03_13-45-22_Meeting-notes.m4a
├── 2026-06-03_14-10-00_Interview.m4a
└── .metadata/
    ├── 2026-06-03_13-45-22_Meeting-notes.json
    └── 2026-06-03_14-10-00_Interview.json
```

- Audio files live at the top level — visible and accessible in Finder
- Metadata lives in `.metadata/` (dot-prefix hides it from casual Finder browsing)
- Filename format: `YYYY-MM-DD_HH-mm-ss_<sanitized-name>.<ext>`
- The `.metadata/` JSON filename matches the audio filename (minus extension) + `.json`

### Metadata Schema

```json
{
  "id": "UUID string",
  "filename": "2026-06-03_13-45-22_Meeting-notes.m4a",
  "name": "Meeting notes",
  "date": "2026-06-03T13:45:22Z",
  "duration": 342.5,
  "location": "Stockholm",
  "comment": "Weekly standup",
  "transcription": "Full transcription text if available",
  "transcribedAt": "2026-06-03T13:52:00Z",
  "source": "recording"
}
```

Fields:
- `id` — UUID, generated on save
- `filename` — audio filename (for cross-reference)
- `name` — user-facing display name (editable)
- `date` — recording timestamp (ISO 8601)
- `duration` — seconds (Double)
- `location` — optional, user-provided
- `comment` — optional, user-provided
- `transcription` — optional, populated after transcription
- `transcribedAt` — optional, when transcription was performed
- `source` — `"recording"` | `"system_audio"` | `"voice_memo_import"`

## Auto-Save Behavior

### Current Behavior (being replaced for recordings)
- Recordings saved to temp directory
- `AppDelegate.cleanupTemporaryFiles()` deletes them on launch and quit

### New Behavior
- When recording stops, audio is immediately saved to `~/Documents/Transcribe/`
- Default name is timestamp-based; user can rename later
- Metadata JSON is created alongside the audio file
- `cleanupTemporaryFiles()` no longer touches `~/Documents/Transcribe/` — it only cleans YouTube downloads and audio preprocessing temp files
- System audio recordings follow the same auto-save pattern

### Migration
- On first launch after update: if temp recordings exist, move them to the new library location
- This is a one-time operation

## UI Design

### Main Screen: New Feature Card

Add a "My Recordings" card to ContentView's main content area, alongside existing cards (Open Files, Recording, System Audio, YouTube). Uses the same card styling (`.glassCard()`).

Icon: `waveform.circle` or `folder`  
Label: localized "my_recordings" / "Mina inspelningar"

Tapping opens `RecordingLibraryView`.

### RecordingLibraryView

A list view with two clearly separated sections:

#### Section 1: "Saved Recordings"
- Source: `~/Documents/Transcribe/`
- Sorted by date (newest first)
- Each row displays:
  - Name (primary text)
  - Date + duration (secondary text)
  - Transcription indicator icon (if transcribed)
- Actions (contextual menu or inline buttons):
  - **Play** — in-app audio player
  - **Transcribe** — opens TranscriptionView with this file
  - **Rename** — edit the display name (updates both filename and metadata)
  - **Edit metadata** — location, comment fields
  - **Delete** — removes audio file + metadata JSON (with confirmation)
  - **Show in Finder** — reveals the file

#### Section 2: "Voice Memos"
- Source: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
- Read-only display of Apple Voice Memos
- Each row displays:
  - Filename or derived name
  - Date + duration
- Actions:
  - **Play** — in-app playback
  - **Transcribe** — transcribe directly (no copy needed)
  - **Save to Library** — copies to `~/Documents/Transcribe/` with metadata

#### Empty States
- "Saved Recordings" empty: "No recordings yet. Use the Recording or System Audio features to create your first recording."
- "Voice Memos" empty or inaccessible: "Voice Memos folder not accessible. Recordings made in Apple Voice Memos will appear here."

### Navigation
- Back button returns to main ContentView
- After transcribing a recording, transcription text is saved back to the metadata JSON
- `AppState` gets a new flag: `showRecordingLibrary: Bool`

### Recording Flow Changes

#### RecordingView (mic recording)
- Remove the "leave confirmation" that warns about losing the recording
- On stop: auto-save to library, show brief "Saved" confirmation
- Add option to navigate to the saved recording in the library

#### SystemAudioRecordingView
- Same auto-save behavior as mic recordings
- Source field in metadata: `"system_audio"`

## Voice Memos Integration

### Reading Voice Memos
- Path: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
- Files are `.m4a` format
- Since this app is **not sandboxed** (it uses ScreenCaptureKit, CoreAudio device access), reading from this path should work without extra entitlements
- If access fails (permissions changed in future macOS), show a user-friendly message
- Parse file attributes for date/duration; Apple's internal metadata DB is not a public API, so we rely on filesystem metadata

### Writing Back to Voice Memos
- Write a copy of a recording to the Voice Memos folder
- This makes it appear in the Voice Memos app on the user's Mac and syncs via iCloud
- Only offer this for recordings that are in a compatible format (`.m4a`)
- If the folder isn't writable, omit this option silently

## New Components

### RecordingLibraryManager
A new `@Observable` class managing the recording library:
- `savedRecordings: [SavedRecording]` — loaded from `~/Documents/Transcribe/.metadata/`
- `voiceMemos: [VoiceMemoRecording]` — loaded from Voice Memos folder
- Methods: `save(audioURL:name:source:)`, `delete(recording:)`, `rename(recording:newName:)`, `updateMetadata(recording:)`, `importVoiceMemo(memo:)`
- File system watcher (DispatchSource/FSEvents) to detect external changes

### SavedRecording Model
```swift
struct SavedRecording: Identifiable, Codable {
    let id: UUID
    var filename: String
    var name: String
    var date: Date
    var duration: TimeInterval
    var location: String?
    var comment: String?
    var transcription: String?
    var transcribedAt: Date?
    var source: RecordingSource
    
    var audioURL: URL { /* ~/Documents/Transcribe/<filename> */ }
    var metadataURL: URL { /* ~/Documents/Transcribe/.metadata/<name>.json */ }
}

enum RecordingSource: String, Codable {
    case recording
    case systemAudio = "system_audio"
    case voiceMemoImport = "voice_memo_import"
}
```

### VoiceMemoRecording Model
```swift
struct VoiceMemoRecording: Identifiable {
    let id: String  // filename as ID
    let fileURL: URL
    let name: String
    let date: Date
    let duration: TimeInterval
}
```

### RecordingLibraryView
New SwiftUI view with the two-section list described above.

## Error Handling

- **Disk full**: Catch write errors, show alert, recording remains in memory until resolved
- **Voice Memos inaccessible**: Hide section or show explanation
- **Corrupt metadata JSON**: Log warning, rebuild from file attributes
- **Missing audio file** (metadata exists but file deleted externally): Show as "unavailable", offer to clean up metadata

## Localization

New keys needed (English + Swedish):
- `my_recordings` / `Mina inspelningar`
- `saved_recordings` / `Sparade inspelningar`
- `voice_memos` / `Röstmemon`
- `save_to_library` / `Spara till bibliotek`
- `recording_saved` / `Inspelning sparad`
- `rename_recording` / `Byt namn`
- `delete_recording` / `Radera inspelning`
- `show_in_finder` / `Visa i Finder`
- `no_recordings_yet` / `Inga inspelningar ännu`
- `location` / `Plats`
- `comment` / `Kommentar`
- Plus any others discovered during implementation

## Testing Considerations

- Unit test `RecordingLibraryManager` save/load/delete/rename operations against a temp directory
- Verify metadata JSON round-trip (encode → decode)
- Test filename sanitization edge cases (special characters, very long names)
- Test behavior when Voice Memos folder doesn't exist
- Test migration from old temp recordings
