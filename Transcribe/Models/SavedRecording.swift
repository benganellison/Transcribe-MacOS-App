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
