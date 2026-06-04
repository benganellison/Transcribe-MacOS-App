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
