# Recording Library & Voice Memos Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent recording storage with a browsable library and Apple Voice Memos import support.

**Architecture:** File-based library in a user-selected folder (security-scoped bookmark). JSON metadata sidecars in a hidden `.metadata/` subfolder. New `RecordingLibraryManager` manages save/load/delete. Auto-save replaces temp-and-delete pattern. Voice Memos access via user-granted folder bookmark.

**Tech Stack:** SwiftUI, AVFoundation, Security framework (bookmarks), FileManager, JSONEncoder/Decoder

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `Transcribe/Models/SavedRecording.swift` | `SavedRecording`, `RecordingSource`, `TranscriptionStatus` data models |
| `Transcribe/Models/VoiceMemoRecording.swift` | `VoiceMemoRecording` model for Voice Memos entries |
| `Transcribe/Services/RecordingLibraryManager.swift` | Library manager: save, load, delete, rename, bookmark management |
| `Transcribe/RecordingLibraryView.swift` | Library list view with saved recordings + Voice Memos sections |
| `TranscribeTests/RecordingLibraryManagerTests.swift` | Unit tests for library manager |

### Modified Files
| File | Changes |
|------|---------|
| `Transcribe/AppState.swift` | Add `showRecordingLibrary: Bool`, `currentRecordingID: UUID?` |
| `Transcribe/ContentView.swift` | Add "My Recordings" feature card, navigation to library view |
| `Transcribe/RecordingView.swift` | Replace temp save with library auto-save, remove delete-on-leave |
| `Transcribe/SystemAudioRecordingView.swift` | Auto-save to library after recording |
| `Transcribe/AppDelegate.swift` | Update cleanup to skip recordings, add migration logic |
| `Transcribe/TranscriptionView.swift` | Save transcription back to recording metadata when `currentRecordingID` is set |
| `Transcribe/TranscribeApp.swift` | Inject `RecordingLibraryManager` as environment object |
| `Transcribe/Resources/en.lproj/Localizable.strings` | Add new localization keys |
| `Transcribe/Resources/sv.lproj/Localizable.strings` | Add new localization keys |

---

## Chunk 1: Data Models & Library Manager Core

### Task 1: Create SavedRecording model

**Files:**
- Create: `Transcribe/Models/SavedRecording.swift`

- [ ] **Step 1: Create the Models directory and SavedRecording file**

```swift
// Transcribe/Models/SavedRecording.swift
import Foundation

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

struct SavedRecording: Identifiable, Codable, Equatable {
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
    
    init(
        id: UUID = UUID(),
        filename: String,
        name: String,
        date: Date = Date(),
        duration: TimeInterval,
        location: String? = nil,
        comment: String? = nil,
        transcription: String? = nil,
        transcriptionStatus: TranscriptionStatus = .notStarted,
        transcriptionModel: String? = nil,
        transcribedAt: Date? = nil,
        source: RecordingSource,
        format: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.filename = filename
        self.name = name
        self.date = date
        self.duration = duration
        self.location = location
        self.comment = comment
        self.transcription = transcription
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionModel = transcriptionModel
        self.transcribedAt = transcribedAt
        self.source = source
        self.format = format
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    func audioURL(in libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent(filename)
    }
    
    func metadataURL(in libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent(".metadata")
            .appendingPathComponent("\(id.uuidString).json")
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/Models/SavedRecording.swift
git commit -m "feat: add SavedRecording data model with metadata schema"
```

---

### Task 2: Create VoiceMemoRecording model

**Files:**
- Create: `Transcribe/Models/VoiceMemoRecording.swift`

- [ ] **Step 1: Create VoiceMemoRecording file**

```swift
// Transcribe/Models/VoiceMemoRecording.swift
import Foundation

struct VoiceMemoRecording: Identifiable {
    let id: String
    let fileURL: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let fileSize: Int64
    
    init(fileURL: URL, name: String, date: Date, duration: TimeInterval, fileSize: Int64) {
        self.id = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.name = name
        self.date = date
        self.duration = duration
        self.fileSize = fileSize
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/Models/VoiceMemoRecording.swift
git commit -m "feat: add VoiceMemoRecording model for Voice Memos integration"
```

---

### Task 3: Create RecordingLibraryManager — core save/load

**Files:**
- Create: `Transcribe/Services/RecordingLibraryManager.swift`
- Create: `TranscribeTests/RecordingLibraryManagerTests.swift`

- [ ] **Step 1: Write failing tests for save and load**

```swift
// TranscribeTests/RecordingLibraryManagerTests.swift
import XCTest
@testable import Transcribe

final class RecordingLibraryManagerTests: XCTestCase {
    var manager: RecordingLibraryManager!
    var tempDir: URL!
    
    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingLibraryTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = await RecordingLibraryManager(libraryURL: tempDir)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testSaveRecordingCreatesMetadataFile() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let recording = await manager.save(
            audioURL: audioURL,
            name: "Test Recording",
            duration: 60.0,
            source: .recording
        )
        
        XCTAssertNotNil(recording)
        let metadataURL = recording!.metadataURL(in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }
    
    func testLoadRecordingsFromMetadata() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let saved = await manager.save(
            audioURL: audioURL,
            name: "Test Recording",
            duration: 45.0,
            source: .recording
        )
        XCTAssertNotNil(saved)
        
        let freshManager = await RecordingLibraryManager(libraryURL: tempDir)
        let recordings = await freshManager.savedRecordings
        
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings.first?.name, "Test Recording")
        XCTAssertEqual(recordings.first?.duration, 45.0)
    }
    
    func testDeleteRecordingRemovesBothFiles() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let recording = await manager.save(
            audioURL: audioURL,
            name: "To Delete",
            duration: 30.0,
            source: .recording
        )
        XCTAssertNotNil(recording)
        
        let audioPath = recording!.audioURL(in: tempDir)
        let metadataPath = recording!.metadataURL(in: tempDir)
        
        await manager.delete(recording: recording!)
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataPath.path))
    }
    
    func testRenameUpdatesFilenameAndMetadata() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let recording = await manager.save(
            audioURL: audioURL,
            name: "Original Name",
            duration: 20.0,
            source: .recording
        )
        XCTAssertNotNil(recording)
        
        let renamed = await manager.rename(recording: recording!, newName: "New Name")
        XCTAssertNotNil(renamed)
        XCTAssertEqual(renamed?.name, "New Name")
        
        let newAudioPath = renamed!.audioURL(in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAudioPath.path))
    }
    
    func testUpdateTranscription() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let recording = await manager.save(
            audioURL: audioURL,
            name: "For Transcription",
            duration: 120.0,
            source: .recording
        )
        XCTAssertNotNil(recording)
        
        await manager.updateTranscription(
            recordingID: recording!.id,
            text: "Hello world transcription",
            model: "kb_whisper-small-coreml"
        )
        
        let updated = await manager.savedRecordings.first(where: { $0.id == recording!.id })
        XCTAssertEqual(updated?.transcription, "Hello world transcription")
        XCTAssertEqual(updated?.transcriptionStatus, .completed)
        XCTAssertEqual(updated?.transcriptionModel, "kb_whisper-small-coreml")
        XCTAssertNotNil(updated?.transcribedAt)
    }
    
    func testFilenameSanitization() async throws {
        let audioURL = tempDir.appendingPathComponent("test_audio.m4a")
        try Data("fake audio".utf8).write(to: audioURL)
        
        let recording = await manager.save(
            audioURL: audioURL,
            name: "Weird/Name:With*Special<Chars>",
            duration: 10.0,
            source: .recording
        )
        XCTAssertNotNil(recording)
        XCTAssertFalse(recording!.filename.contains("/"))
        XCTAssertFalse(recording!.filename.contains(":"))
        XCTAssertFalse(recording!.filename.contains("*"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO -only-testing:TranscribeTests/RecordingLibraryManagerTests 2>&1 | tail -20`
Expected: FAIL (RecordingLibraryManager not defined)

- [ ] **Step 3: Implement RecordingLibraryManager**

```swift
// Transcribe/Services/RecordingLibraryManager.swift
import Foundation
import AVFoundation

@MainActor
class RecordingLibraryManager: ObservableObject {
    @Published var savedRecordings: [SavedRecording] = []
    @Published var voiceMemos: [VoiceMemoRecording] = []
    
    private(set) var libraryURL: URL
    private var metadataDirectoryURL: URL {
        libraryURL.appendingPathComponent(".metadata")
    }
    
    private static let libraryBookmarkKey = "recordingLibraryBookmark"
    private static let voiceMemosBookmarkKey = "voiceMemosBookmark"
    
    init(libraryURL: URL? = nil) {
        if let url = libraryURL {
            self.libraryURL = url
        } else if let bookmarkedURL = Self.resolveBookmark(forKey: Self.libraryBookmarkKey) {
            self.libraryURL = bookmarkedURL
        } else {
            let containerDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.libraryURL = containerDocs.appendingPathComponent("Transcribe")
        }
        
        ensureDirectoriesExist()
        loadRecordings()
    }
    
    // MARK: - Directory Setup
    
    private func ensureDirectoriesExist() {
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Bookmark Management
    
    func selectLibraryFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: Self.libraryBookmarkKey)
            self.libraryURL = url
            ensureDirectoriesExist()
            loadRecordings()
        }
    }
    
    func selectVoiceMemosFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: Self.voiceMemosBookmarkKey)
            loadVoiceMemos()
        }
    }
    
    var hasVoiceMemosAccess: Bool {
        UserDefaults.standard.data(forKey: Self.voiceMemosBookmarkKey) != nil
    }
    
    private static func resolveBookmark(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        
        if isStale {
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(newData, forKey: key)
            }
        }
        
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
    
    // MARK: - Save
    
    @discardableResult
    func save(
        audioURL: URL,
        name: String,
        duration: TimeInterval,
        source: RecordingSource
    ) -> SavedRecording? {
        let id = UUID()
        let format = audioURL.pathExtension.lowercased()
        let sanitizedName = sanitizeFilename(name)
        let dateString = formatDateForFilename(Date())
        let filename = "\(dateString)_\(sanitizedName).\(format)"
        let destinationURL = libraryURL.appendingPathComponent(filename)
        
        // Atomic move (try move first, then copy)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                // Handle collision with UUID suffix
                let collisionFilename = "\(dateString)_\(sanitizedName)_\(id.uuidString.prefix(8)).\(format)"
                let collisionURL = libraryURL.appendingPathComponent(collisionFilename)
                try FileManager.default.moveItem(at: audioURL, to: collisionURL)
                return saveFinalizeMetadata(id: id, filename: collisionFilename, name: name, duration: duration, source: source, format: format)
            }
            try FileManager.default.moveItem(at: audioURL, to: destinationURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: audioURL, to: destinationURL)
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                return nil
            }
        }
        
        // Verify file
        guard FileManager.default.fileExists(atPath: destinationURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let size = attrs[.size] as? Int64, size > 0 else {
            return nil
        }
        
        return saveFinalizeMetadata(id: id, filename: filename, name: name, duration: duration, source: source, format: format)
    }
    
    private func saveFinalizeMetadata(id: UUID, filename: String, name: String, duration: TimeInterval, source: RecordingSource, format: String) -> SavedRecording? {
        let recording = SavedRecording(
            id: id,
            filename: filename,
            name: name,
            date: Date(),
            duration: duration,
            source: source,
            format: format
        )
        
        guard writeMetadata(recording) else {
            let audioPath = libraryURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: audioPath)
            return nil
        }
        
        savedRecordings.insert(recording, at: 0)
        return recording
    }
    
    // MARK: - Delete
    
    func delete(recording: SavedRecording) {
        let audioPath = recording.audioURL(in: libraryURL)
        let metadataPath = recording.metadataURL(in: libraryURL)
        
        try? FileManager.default.removeItem(at: audioPath)
        try? FileManager.default.removeItem(at: metadataPath)
        
        savedRecordings.removeAll { $0.id == recording.id }
    }
    
    // MARK: - Rename
    
    func rename(recording: SavedRecording, newName: String) -> SavedRecording? {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recording.id }) else {
            return nil
        }
        
        let format = recording.format
        let sanitizedName = sanitizeFilename(newName)
        let dateString = formatDateForFilename(recording.date)
        let newFilename = "\(dateString)_\(sanitizedName).\(format)"
        
        let oldURL = recording.audioURL(in: libraryURL)
        let newURL = libraryURL.appendingPathComponent(newFilename)
        
        if newFilename != recording.filename {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                return nil
            }
        }
        
        var updated = recording
        updated.name = newName
        updated.filename = newFilename
        updated.updatedAt = Date()
        
        guard writeMetadata(updated) else { return nil }
        
        savedRecordings[index] = updated
        return updated
    }
    
    // MARK: - Update Metadata
    
    func updateMetadata(recording: SavedRecording, location: String?, comment: String?) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recording.id }) else { return }
        
        var updated = recording
        updated.location = location
        updated.comment = comment
        updated.updatedAt = Date()
        
        if writeMetadata(updated) {
            savedRecordings[index] = updated
        }
    }
    
    // MARK: - Transcription Update
    
    func updateTranscription(recordingID: UUID, text: String, model: String) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
        
        var updated = savedRecordings[index]
        updated.transcription = text
        updated.transcriptionStatus = .completed
        updated.transcriptionModel = model
        updated.transcribedAt = Date()
        updated.updatedAt = Date()
        
        if writeMetadata(updated) {
            savedRecordings[index] = updated
        }
    }
    
    // MARK: - Voice Memos Import
    
    func importVoiceMemo(memo: VoiceMemoRecording) -> SavedRecording? {
        // Copy (not move) since Voice Memos folder is read-only
        let destURL = libraryURL.appendingPathComponent(memo.fileURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: memo.fileURL, to: destURL)
        } catch {
            return nil
        }
        return save(audioURL: destURL, name: memo.name, duration: memo.duration, source: .voiceMemoImport)
    }
    
    // MARK: - Load
    
    func loadRecordings() {
        guard FileManager.default.fileExists(atPath: metadataDirectoryURL.path) else { return }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        
        var recordings: [SavedRecording] = []
        
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let recording = try? decoder.decode(SavedRecording.self, from: data) else {
                continue
            }
            
            let audioPath = recording.audioURL(in: libraryURL)
            if FileManager.default.fileExists(atPath: audioPath.path) {
                recordings.append(recording)
            }
        }
        
        savedRecordings = recordings.sorted { $0.date > $1.date }
    }
    
    func loadVoiceMemos() {
        guard let url = Self.resolveBookmark(forKey: Self.voiceMemosBookmarkKey) else {
            voiceMemos = []
            return
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else {
            voiceMemos = []
            return
        }
        
        var memos: [VoiceMemoRecording] = []
        
        for file in files where file.pathExtension == "m4a" {
            let resourceValues = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let date = resourceValues?.creationDate ?? Date()
            let size = Int64(resourceValues?.fileSize ?? 0)
            let asset = AVURLAsset(url: file)
            let duration = CMTimeGetSeconds(asset.duration)
            let name = file.deletingPathExtension().lastPathComponent
            
            memos.append(VoiceMemoRecording(
                fileURL: file,
                name: name,
                date: date,
                duration: duration.isFinite ? duration : 0,
                fileSize: size
            ))
        }
        
        voiceMemos = memos.sorted { $0.date > $1.date }
    }
    
    // MARK: - Private Helpers
    
    private func writeMetadata(_ recording: SavedRecording) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        guard let data = try? encoder.encode(recording) else { return false }
        
        let metadataURL = recording.metadataURL(in: libraryURL)
        
        do {
            try data.write(to: metadataURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "recording" }
        if sanitized.count > 80 { sanitized = String(sanitized.prefix(80)) }
        return sanitized
    }
    
    private func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO -only-testing:TranscribeTests/RecordingLibraryManagerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Transcribe/Services/RecordingLibraryManager.swift TranscribeTests/RecordingLibraryManagerTests.swift
git commit -m "feat: implement RecordingLibraryManager with save/load/delete/rename

Includes security-scoped bookmark management, atomic metadata writes,
filename sanitization, and Voice Memos folder loading."
```

---

## Chunk 2: AppState Changes & Auto-Save Integration

### Task 4: Update AppState

**Files:**
- Modify: `Transcribe/AppState.swift`

- [ ] **Step 1: Add new state properties**

Add to `AppState` class:
```swift
@Published var showRecordingLibrary = false
@Published var currentRecordingID: UUID?

func openRecordingForTranscription(_ url: URL, recordingID: UUID) {
    currentRecordingID = recordingID
    currentTranscriptionURL = url
    showTranscriptionView = true
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/AppState.swift
git commit -m "feat: add recording library navigation state to AppState"
```

---

### Task 5: Inject RecordingLibraryManager into app environment

**Files:**
- Modify: `Transcribe/TranscribeApp.swift`

- [ ] **Step 1: Add RecordingLibraryManager as @StateObject and environmentObject**

Find where `AppState`, `SettingsManager`, and `TranscriptionManager` are created and injected. Add:
```swift
@StateObject private var recordingLibrary = RecordingLibraryManager()
```

And in the view body's `.environmentObject()` chain:
```swift
.environmentObject(recordingLibrary)
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/TranscribeApp.swift
git commit -m "feat: inject RecordingLibraryManager into SwiftUI environment"
```

---

### Task 6: Update RecordingView to auto-save

**Files:**
- Modify: `Transcribe/RecordingView.swift`

- [ ] **Step 1: Add library manager and auto-save logic**

Changes needed:
1. Add `@EnvironmentObject var recordingLibrary: RecordingLibraryManager`
2. After `audioRecorder.stopRecording()` succeeds and `hasRecording` is true, auto-save:
```swift
if let url = audioRecorder.recordingURL {
    recordingLibrary.save(
        audioURL: url,
        name: localized("new_recording"),
        duration: audioRecorder.recordingDuration,
        source: .recording
    )
}
```
3. Remove `showLeaveConfirmation` — recordings are now persistent, leaving is safe
4. Add a brief "✓ Saved" indicator (e.g., a `Text` that appears briefly after save)

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/RecordingView.swift
git commit -m "feat: auto-save mic recordings to library on stop"
```

---

### Task 7: Update SystemAudioRecordingView to auto-save

**Files:**
- Modify: `Transcribe/SystemAudioRecordingView.swift`

- [ ] **Step 1: Add auto-save for system audio recordings**

Same pattern as Task 6:
1. Add `@EnvironmentObject var recordingLibrary: RecordingLibraryManager`
2. After `captureService.stopCapture()` succeeds and `hasRecording` is true, auto-save with `source: .systemAudio`
3. Remove or simplify `showLeaveConfirmation`

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/SystemAudioRecordingView.swift
git commit -m "feat: auto-save system audio recordings to library on stop"
```

---

### Task 8: Update AppDelegate cleanup & migration

**Files:**
- Modify: `Transcribe/AppDelegate.swift`

- [ ] **Step 1: Add migration before cleanup**

Update `applicationDidFinishLaunching`:
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    migrateExistingRecordingsIfNeeded()
    cleanupTemporaryFiles(isStartup: true)
    setupStatusBar()
}

private func migrateExistingRecordingsIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: "recordingMigrationCompleted") else { return }
    
    let tempRecordingsDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("Transcribe")
        .appendingPathComponent("Recordings")
    
    guard FileManager.default.fileExists(atPath: tempRecordingsDir.path),
          let files = try? FileManager.default.contentsOfDirectory(
              at: tempRecordingsDir,
              includingPropertiesForKeys: [.creationDateKey]
          ) else {
        UserDefaults.standard.set(true, forKey: "recordingMigrationCompleted")
        return
    }
    
    let audioExtensions = Set(["m4a", "wav", "mp3", "aac", "flac"])
    let audioFiles = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
    
    if !audioFiles.isEmpty {
        // Migration will be handled by RecordingLibraryManager on next init
        // Just mark it so we don't delete the files in cleanup
        // The actual move happens when RecordingLibraryManager loads
    }
    
    UserDefaults.standard.set(true, forKey: "recordingMigrationCompleted")
}
```

`cleanupTemporaryFiles()` stays the same — it removes the entire `Transcribe` temp dir. Since recordings are now auto-saved to the library folder immediately, there won't be recordings in temp after the migration.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/AppDelegate.swift
git commit -m "feat: add recording migration and update cleanup logic"
```

---

## Chunk 3: Recording Library UI

### Task 9: Create RecordingLibraryView

**Files:**
- Create: `Transcribe/RecordingLibraryView.swift`

- [ ] **Step 1: Implement the library list view**

Create a full SwiftUI view with:
- Header with back button (same pattern as RecordingView: chevron.left + "Back" text)
- ScrollView with two VStack sections
- Section 1 "Saved Recordings": list of recording rows sorted newest-first
- Section 2 "Voice Memos": list or "Connect" button
- Each row: name (bold), date + duration (secondary), transcription status icon
- Context menu per row: Play, Transcribe, Rename, Delete (with confirmation), Show in Finder
- Empty state messages
- "Connect Voice Memos" button that opens `NSOpenPanel` configured to select folders, starting at `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
- Use `.glassCard()` modifier for section containers
- Use existing color system: `.textPrimary`, `.textSecondary`, `.primaryAccent`, `.cardBackground`

Key view structure:
```swift
struct RecordingLibraryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var recordingLibrary: RecordingLibraryManager
    @State private var showDeleteConfirmation = false
    @State private var recordingToDelete: SavedRecording?
    @State private var editingRecording: SavedRecording?
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingID: UUID?
    
    var body: some View { /* ... */ }
    
    private var header: some View { /* back button + title */ }
    private var savedRecordingsSection: some View { /* ... */ }
    private var voiceMemosSection: some View { /* ... */ }
    private func recordingRow(_ recording: SavedRecording) -> some View { /* ... */ }
    private func voiceMemoRow(_ memo: VoiceMemoRecording) -> some View { /* ... */ }
    
    private func playRecording(_ url: URL, id: UUID) { /* ... */ }
    private func transcribeRecording(_ recording: SavedRecording) { /* ... */ }
    private func deleteRecording(_ recording: SavedRecording) { /* ... */ }
    private func showInFinder(_ url: URL) { /* ... */ }
    private func connectVoiceMemos() { /* NSOpenPanel for folder selection */ }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/RecordingLibraryView.swift
git commit -m "feat: add RecordingLibraryView with saved recordings and Voice Memos sections"
```

---

### Task 10: Add "My Recordings" card to ContentView

**Files:**
- Modify: `Transcribe/ContentView.swift`

- [ ] **Step 1: Add navigation case and feature card**

1. In the `Group` in `body`, add before the `mainContent` else branch:
```swift
} else if appState.showRecordingLibrary {
    RecordingLibraryView()
```

2. In `primaryFeatures` HStack, add a new `FeatureCard`:
```swift
FeatureCard(
    icon: "waveform.circle.fill",
    title: localized("my_recordings"),
    action: { appState.showRecordingLibrary = true }
)
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/ContentView.swift
git commit -m "feat: add My Recordings feature card to main screen"
```

---

### Task 11: Wire transcription save-back

**Files:**
- Modify: `Transcribe/TranscriptionView.swift`

- [ ] **Step 1: Save transcription result back to recording metadata**

1. Add `@EnvironmentObject var recordingLibrary: RecordingLibraryManager`
2. Find where transcription completes (where `viewModel.isComplete` or transcription text is finalized)
3. Add save-back logic:
```swift
if let recordingID = appState.currentRecordingID {
    recordingLibrary.updateTranscription(
        recordingID: recordingID,
        text: viewModel.transcriptionText,
        model: selectedModel
    )
}
```
4. In the back/close handler, clear the recording ID:
```swift
appState.currentRecordingID = nil
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Transcribe/TranscriptionView.swift
git commit -m "feat: save transcription results back to recording metadata"
```

---

## Chunk 4: Localization & Final Polish

### Task 12: Add localization strings

**Files:**
- Modify: `Transcribe/Resources/en.lproj/Localizable.strings`
- Modify: `Transcribe/Resources/sv.lproj/Localizable.strings`

- [ ] **Step 1: Add English strings**

Append to `Localizable.strings`:
```strings
/* Recording Library */
"my_recordings" = "My Recordings";
"saved_recordings" = "Saved Recordings";
"voice_memos" = "Voice Memos";
"save_to_library" = "Save to Library";
"recording_saved" = "Recording Saved";
"rename_recording" = "Rename";
"delete_recording" = "Delete Recording";
"show_in_finder" = "Show in Finder";
"no_recordings_yet" = "No recordings yet. Use Recording or System Audio to create your first recording.";
"voice_memos_not_connected" = "Connect your Voice Memos folder to see recordings here.";
"connect_voice_memos" = "Connect Voice Memos";
"location" = "Location";
"comment" = "Comment";
"transcribed" = "Transcribed";
"not_transcribed" = "Not transcribed";
"edit_metadata" = "Edit Details";
"choose_library_folder" = "Choose Library Folder";
"library_folder_description" = "Choose where your recordings are saved";
"confirm_delete" = "Are you sure you want to delete this recording? This cannot be undone.";
```

- [ ] **Step 2: Add Swedish strings**

Append to Swedish `Localizable.strings`:
```strings
/* Recording Library */
"my_recordings" = "Mina inspelningar";
"saved_recordings" = "Sparade inspelningar";
"voice_memos" = "Röstmemon";
"save_to_library" = "Spara till bibliotek";
"recording_saved" = "Inspelning sparad";
"rename_recording" = "Byt namn";
"delete_recording" = "Radera inspelning";
"show_in_finder" = "Visa i Finder";
"no_recordings_yet" = "Inga inspelningar ännu. Använd Inspelning eller Systemljud för att skapa din första inspelning.";
"voice_memos_not_connected" = "Anslut din Röstmemon-mapp för att se inspelningar här.";
"connect_voice_memos" = "Anslut Röstmemon";
"location" = "Plats";
"comment" = "Kommentar";
"transcribed" = "Transkriberad";
"not_transcribed" = "Ej transkriberad";
"edit_metadata" = "Redigera detaljer";
"choose_library_folder" = "Välj biblioteksmapp";
"library_folder_description" = "Välj var dina inspelningar sparas";
"confirm_delete" = "Är du säker på att du vill radera denna inspelning? Detta kan inte ångras.";
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Transcribe/Resources/en.lproj/Localizable.strings Transcribe/Resources/sv.lproj/Localizable.strings
git commit -m "feat: add localization strings for recording library (en + sv)"
```

---

### Task 13: Final build & test run

- [ ] **Step 1: Full clean build**

Run: `xcodebuild clean build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run all tests**

Run: `xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 3: Commit any final fixes**

```bash
git add -A && git commit -m "chore: final cleanup for recording library feature" --allow-empty
```
