# Recording Library & Voice Memos Integration

**Date**: 2026-06-03  
**Status**: Approved

## Summary

Add persistent recording storage and a recording library to Transcribe. Recordings auto-save to `~/Documents/Transcribe/` instead of being deleted on quit. Integrate with Apple Voice Memos for import/transcription via user-granted folder access. A new "My Recordings" view on the main screen provides unified access to both sources.

## Goals

1. **Persistent recordings** — All recordings (mic and system audio) auto-save and survive app restarts
2. **Recording library** — Browse, play, rename, delete, and transcribe saved recordings from within the app
3. **Voice Memos access** — Show Apple Voice Memos recordings in a separate section for direct transcription or import
4. **Rich metadata** — Each recording stores name, date, duration, location, comment, and transcription text

## Non-Goals

- Full-featured audio editor
- iCloud sync of recordings (users can point storage to an iCloud Drive folder if they wish)
- Importing from arbitrary third-party apps
- Writing back to Apple Voice Memos (Apple's internal DB means loose files don't appear in the app reliably)

## Sandbox & Permissions

The app is sandboxed (`com.apple.security.app-sandbox = true`). This affects storage access:

### Recording Storage
- **Primary location**: App sandbox container `~/Library/Containers/<bundle-id>/Data/Documents/Transcribe/`
- **User-visible option**: On first launch (or via Settings), prompt the user to select a folder via `NSOpenPanel`. Store access as a **security-scoped bookmark** in UserDefaults. Default suggestion: `~/Documents/Transcribe/`
- If the user grants folder access, recordings are saved there (visible in Finder). Otherwise, they go to the sandbox container.

### Voice Memos Access
- Voice Memos files live at `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
- This is **not accessible** from within the sandbox without user action
- **Approach**: In the library view, offer "Connect Voice Memos" which opens an `NSOpenPanel` pre-navigated to the Voice Memos folder. User grants access once; we store a security-scoped bookmark for ongoing read access.
- If the user declines or the folder doesn't exist, the Voice Memos section simply shows an explanation.

### Entitlement Changes
No new entitlements required. We already have:
- `com.apple.security.files.user-selected.read-write` — covers NSOpenPanel-granted access
- Security-scoped bookmarks work within existing sandbox entitlements

## Storage Design

### Directory Structure

```
<library-folder>/    (e.g. ~/Documents/Transcribe/)
├── 2026-06-03_13-45-22_Meeting-notes.m4a
├── 2026-06-03_14-10-00_Interview.m4a
└── .metadata/
    ├── a1b2c3d4-e5f6-7890-abcd-ef1234567890.json
    └── f9e8d7c6-b5a4-3210-fedc-ba9876543210.json
```

- Audio files live at the top level — visible and accessible in Finder
- Metadata lives in `.metadata/` (dot-prefix hides it from casual Finder browsing)
- Audio filename format: `YYYY-MM-DD_HH-mm-ss_<sanitized-name>.<ext>`
- Metadata filename: `<uuid>.json` (stable across renames, avoids collision)

### Metadata Schema

```json
{
  "schemaVersion": 1,
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "filename": "2026-06-03_13-45-22_Meeting-notes.m4a",
  "name": "Meeting notes",
  "date": "2026-06-03T13:45:22Z",
  "duration": 342.5,
  "location": "Stockholm",
  "comment": "Weekly standup",
  "transcription": "Full transcription text if available",
  "transcriptionStatus": "completed",
  "transcriptionModel": "kb_whisper-small-coreml",
  "transcribedAt": "2026-06-03T13:52:00Z",
  "source": "recording",
  "format": "m4a",
  "createdAt": "2026-06-03T13:45:22Z",
  "updatedAt": "2026-06-03T13:52:00Z"
}
```

Fields:
- `schemaVersion` — integer, for future migrations
- `id` — UUID, generated on save, used as metadata filename
- `filename` — audio filename (for cross-reference)
- `name` — user-facing display name (editable)
- `date` — recording timestamp (ISO 8601)
- `duration` — seconds (Double)
- `location` — optional, user-provided
- `comment` — optional, user-provided
- `transcription` — optional, populated after transcription
- `transcriptionStatus` — `"notStarted"` | `"inProgress"` | `"completed"` | `"failed"`
- `transcriptionModel` — model ID used for transcription
- `transcribedAt` — optional, when transcription was performed
- `source` — `"recording"` | `"system_audio"` | `"voice_memo_import"`
- `format` — file extension (e.g. `"m4a"`, `"wav"`)
- `createdAt` / `updatedAt` — metadata lifecycle timestamps

## Auto-Save Behavior

### Current Behavior (being replaced for recordings)
- Recordings saved to temp directory
- `AppDelegate.cleanupTemporaryFiles()` deletes them on launch and quit

### New Behavior — Two-Phase Atomic Save
1. Recording writes to a `.inprogress` temp file (same directory as before)
2. When recording stops, verify file: exists, size > 0, readable duration > 0
3. Atomically move verified file to library folder with final filename
4. Write metadata JSON atomically (`Data.write(to:options:.atomic)`)
5. Only after both succeed is the recording "saved"

- Default name is timestamp-based; user can rename later
- `cleanupTemporaryFiles()` no longer touches the library folder — it only cleans YouTube downloads, audio preprocessing temp files, and stale `.inprogress` files
- System audio recordings follow the same auto-save pattern
- If save fails (disk full, permission error): stop recording, show error alert, preserve any valid partial file in temp

### Migration (Startup Ordering)
On first launch after update:
1. **First**: Check for existing temp recordings and migrate them to the library
2. **Then**: Run `cleanupTemporaryFiles()` for non-recording temp files
3. Store a `recordingMigrationCompleted` flag in UserDefaults to skip on subsequent launches

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
- **Sandbox constraint**: User must grant access via `NSOpenPanel` (one-time). We store a security-scoped bookmark for subsequent launches.
- If access fails or user declines, the Voice Memos section shows an explanation with a "Connect" button
- Parse file attributes for date/duration; Apple's internal metadata DB is not a public API, so we derive names from filenames/filesystem metadata as best-effort

### No Write-Back
- Writing files into Voice Memos' group container does **not** make them appear in the Voice Memos app (Apple tracks recordings in an internal database)
- This feature is explicitly out of scope
- Users who want recordings in Voice Memos can use the "Show in Finder" action and manually add them

## New Components

### RecordingLibraryManager
A new `@Observable` class managing the recording library:
- `savedRecordings: [SavedRecording]` — loaded from `.metadata/` folder
- `voiceMemos: [VoiceMemoRecording]` — loaded from Voice Memos folder (if access granted)
- `libraryURL: URL` — resolved from security-scoped bookmark or sandbox container fallback
- Methods: `save(audioURL:name:source:)`, `delete(recording:)`, `rename(recording:newName:)`, `updateMetadata(recording:)`, `updateTranscription(recordingID:text:model:)`, `importVoiceMemo(memo:)`
- On init: resolve bookmark, scan `.metadata/` folder, load all JSON files
- File system watcher (DispatchSource/FSEvents) to detect external changes

### SavedRecording Model
```swift
struct SavedRecording: Identifiable, Codable {
    static let currentSchemaVersion = 1
    
    let schemaVersion: Int
    let id: UUID
    var filename: String
    var name: String
    var date: Date
    var duration: TimeInterval
    var location: String?
    var comment: String?
    var transcription: String?
    var transcriptionStatus: TranscriptionStatus
    var transcriptionModel: String?
    var transcribedAt: Date?
    var source: RecordingSource
    var format: String
    var createdAt: Date
    var updatedAt: Date
    
    func audioURL(in libraryURL: URL) -> URL { libraryURL.appendingPathComponent(filename) }
    func metadataURL(in libraryURL: URL) -> URL { 
        libraryURL.appendingPathComponent(".metadata/\(id.uuidString).json")
    }
}

enum RecordingSource: String, Codable {
    case recording
    case systemAudio = "system_audio"
    case voiceMemoImport = "voice_memo_import"
}

enum TranscriptionStatus: String, Codable {
    case notStarted
    case inProgress
    case completed
    case failed
}
```

### Transcription Save-Back
When a recording from the library is transcribed:
1. `AppState` carries a `currentRecordingID: UUID?` alongside `currentTranscriptionURL`
2. When transcription completes in `TranscriptionView`, if `currentRecordingID` is set, call `RecordingLibraryManager.updateTranscription(recordingID:text:model:)`
3. This updates the metadata JSON atomically

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

- **Disk full / write failure**: Detect during recording or save. Stop recording, show alert, preserve any valid partial file in temp directory for retry.
- **Voice Memos inaccessible**: Hide section, show "Connect Voice Memos" button with explanation
- **Corrupt metadata JSON**: Log warning, attempt to rebuild from audio file attributes (date, duration from AVAsset). If audio file is also missing, remove the orphan metadata.
- **Missing audio file** (metadata exists but file deleted externally): Show as "unavailable" in list, offer to clean up
- **Security-scoped bookmark stale** (user moved/deleted folder): Show error, prompt to re-select folder
- **Filename collision** (same timestamp + name): Append UUID suffix to disambiguate

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
- Verify metadata JSON round-trip (encode → decode), including schema version handling
- Test filename sanitization edge cases (special characters, very long names, Unicode)
- Test behavior when Voice Memos folder doesn't exist or access is denied
- Test migration from old temp recordings (ordering: migrate before cleanup)
- Test atomic save: verify no partial files on simulated interruption
- Test metadata/audio mismatch recovery (orphan metadata, missing audio)
- Test security-scoped bookmark lifecycle (resolve, access, stale bookmark)
- Test filename collision handling
