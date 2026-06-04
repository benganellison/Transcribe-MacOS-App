import Foundation
import Testing
@testable import Transcribe

@MainActor
struct RecordingLibraryManagerTests {
    @Test func testSaveRecordingCreatesMetadataFile() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "meeting.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "Team Sync", duration: 42, source: .recording))

            #expect(FileManager.default.fileExists(atPath: saved.audioURL(in: context.libraryURL).path))
            #expect(FileManager.default.fileExists(atPath: saved.metadataURL(in: context.libraryURL).path))
        }
    }

    @Test func testLoadRecordingsFromMetadata() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "load-test.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "Load Test", duration: 10, source: .recording))

            let freshManager = RecordingLibraryManager(libraryURL: context.libraryURL)

            #expect(freshManager.savedRecordings.count == 1)
            #expect(freshManager.savedRecordings.first?.id == saved.id)
            #expect(freshManager.savedRecordings.first?.name == "Load Test")
        }
    }

    @Test func testDeleteRecordingRemovesBothFiles() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "delete-test.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "Delete Test", duration: 12, source: .recording))

            context.manager.delete(recording: saved)

            #expect(!FileManager.default.fileExists(atPath: saved.audioURL(in: context.libraryURL).path))
            #expect(!FileManager.default.fileExists(atPath: saved.metadataURL(in: context.libraryURL).path))
            #expect(context.manager.savedRecordings.isEmpty)
        }
    }

    @Test func testRenameUpdatesFilenameAndMetadata() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "rename-test.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "Old Name", duration: 12, source: .recording))

            let renamed = try #require(context.manager.rename(recording: saved, newName: "New Name"))
            let metadata = try context.loadMetadata(for: renamed)

            #expect(renamed.name == "New Name")
            #expect(renamed.filename != saved.filename)
            #expect(!FileManager.default.fileExists(atPath: saved.audioURL(in: context.libraryURL).path))
            #expect(FileManager.default.fileExists(atPath: renamed.audioURL(in: context.libraryURL).path))
            #expect(metadata.name == "New Name")
            #expect(metadata.filename == renamed.filename)
        }
    }

    @Test func testUpdateTranscription() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "transcription-test.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "Transcript", duration: 7, source: .recording))

            context.manager.updateTranscription(recordingID: saved.id, text: "Hello world", model: "kb_whisper-small-coreml")

            let updated = try #require(context.manager.savedRecordings.first)
            let metadata = try context.loadMetadata(for: updated)

            #expect(updated.transcription == "Hello world")
            #expect(updated.transcriptionModel == "kb_whisper-small-coreml")
            #expect(updated.transcriptionStatus == .completed)
            #expect(updated.transcribedAt != nil)
            #expect(metadata.transcription == "Hello world")
            #expect(metadata.transcriptionModel == "kb_whisper-small-coreml")
        }
    }

    @Test func testFilenameSanitization() throws {
        try withTestContext { context in
            let audioURL = try context.createDummyAudioFile(named: "sanitize-test.m4a")
            let saved = try #require(context.manager.save(audioURL: audioURL, name: "  bad:/\\:*?\"<>| name  ", duration: 3, source: .recording))

            #expect(!saved.filename.contains("/"))
            #expect(!saved.filename.contains("\\"))
            #expect(!saved.filename.contains(":"))
            #expect(!saved.filename.contains("*"))
            #expect(!saved.filename.contains("?"))
            #expect(!saved.filename.contains("\""))
            #expect(!saved.filename.contains("<"))
            #expect(!saved.filename.contains(">"))
            #expect(!saved.filename.contains("|"))
            #expect(saved.filename.hasSuffix(".m4a"))
        }
    }
}

@MainActor
private func withTestContext(_ body: (RecordingLibraryManagerTestContext) throws -> Void) throws {
    let context = try RecordingLibraryManagerTestContext()
    defer { try? context.cleanup() }
    try body(context)
}

@MainActor
private struct RecordingLibraryManagerTestContext {
    let testRoot: URL
    let libraryURL: URL
    let manager: RecordingLibraryManager

    init() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        testRoot = repositoryRoot
            .appendingPathComponent(".test-artifacts", isDirectory: true)
            .appendingPathComponent("RecordingLibraryManagerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        libraryURL = testRoot.appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        manager = RecordingLibraryManager(libraryURL: libraryURL)
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: testRoot.path) {
            try FileManager.default.removeItem(at: testRoot)
        }
    }

    func createDummyAudioFile(named name: String) throws -> URL {
        let sourceDirectory = testRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let audioURL = sourceDirectory.appendingPathComponent(name)
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: audioURL)
        return audioURL
    }

    func loadMetadata(for recording: SavedRecording) throws -> SavedRecording {
        let data = try Data(contentsOf: recording.metadataURL(in: libraryURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SavedRecording.self, from: data)
    }
}
