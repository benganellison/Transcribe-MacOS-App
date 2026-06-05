import Foundation
import AVFoundation
import SwiftUI

@MainActor
class RecordingLibraryManager: ObservableObject {
    @Published var savedRecordings: [SavedRecording] = []
    @Published var voiceMemos: [VoiceMemoRecording] = []
    private(set) var libraryURL: URL

    private static let recordingLibraryBookmarkKey = "recordingLibraryBookmark"
    private static let voiceMemosBookmarkKey = "voiceMemosBookmarkKey"
    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
    private static let metadataDirectoryName = ".metadata"
    private static let importsDirectoryName = ".imports"

    private let fileManager: FileManager
    private var libraryScopedURL: URL?
    private var voiceMemosScopedURL: URL?

    init(libraryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let libraryURL {
            self.libraryURL = libraryURL
        } else if let bookmarkedURL = Self.resolveBookmarkURL(forKey: Self.recordingLibraryBookmarkKey) {
            self.libraryURL = bookmarkedURL
            if bookmarkedURL.startAccessingSecurityScopedResource() {
                self.libraryScopedURL = bookmarkedURL
            }
        } else {
            self.libraryURL = Self.defaultLibraryURL()
        }

        createLibraryDirectoriesIfNeeded()
        restoreVoiceMemosAccessIfAvailable()
        loadRecordings()
        loadVoiceMemos()
    }


    func selectLibraryFolder(url: URL) {
        storeBookmark(for: url, key: Self.recordingLibraryBookmarkKey)
        replaceScopedAccess(current: &libraryScopedURL, with: url)
        libraryURL = url
        createLibraryDirectoriesIfNeeded()
        loadRecordings()
    }

    func selectVoiceMemosFolder(url: URL) {
        storeBookmark(for: url, key: Self.voiceMemosBookmarkKey)
        replaceScopedAccess(current: &voiceMemosScopedURL, with: url)
        loadVoiceMemos()
    }

    var hasVoiceMemosAccess: Bool {
        UserDefaults.standard.data(forKey: Self.voiceMemosBookmarkKey) != nil
    }

    func save(audioURL: URL, name: String, duration: TimeInterval, source: RecordingSource) -> SavedRecording? {
        createLibraryDirectoriesIfNeeded()

        let now = Date()
        let displayName = normalizedDisplayName(from: name)
        let fileExtension = normalizedFileExtension(for: audioURL)
        let targetURL = uniqueAudioURL(for: displayName, date: now, fileExtension: fileExtension)
        let moved = moveOrCopyAudio(from: audioURL, to: targetURL)

        guard moved, fileSize(at: targetURL) > 0 else {
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            return nil
        }

        let recording = SavedRecording(
            filename: targetURL.lastPathComponent,
            name: displayName,
            date: now,
            duration: duration,
            source: source,
            format: fileExtension,
            createdAt: now,
            updatedAt: now
        )

        guard writeMetadata(recording) else {
            try? fileManager.removeItem(at: targetURL)
            return nil
        }

        savedRecordings.insert(recording, at: 0)
        savedRecordings.sort { $0.date > $1.date }
        return recording
    }

    func delete(recording: SavedRecording) {
        let audioURL = recording.audioURL(in: libraryURL)
        let metadataURL = recording.metadataURL(in: libraryURL)

        if fileManager.fileExists(atPath: audioURL.path) {
            try? fileManager.removeItem(at: audioURL)
        }

        if fileManager.fileExists(atPath: metadataURL.path) {
            try? fileManager.removeItem(at: metadataURL)
        }

        savedRecordings.removeAll { $0.id == recording.id }
    }

    func rename(recording: SavedRecording, newName: String) -> SavedRecording? {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recording.id }) else {
            return nil
        }

        let displayName = normalizedDisplayName(from: newName)
        let fileExtension = normalizedFileExtension(for: recording.audioURL(in: libraryURL))
        let currentAudioURL = recording.audioURL(in: libraryURL)
        let targetURL = uniqueAudioURL(
            for: displayName,
            date: recording.date,
            fileExtension: fileExtension,
            excludingFilename: recording.filename
        )

        var updated = recording
        updated.name = displayName
        updated.filename = targetURL.lastPathComponent
        updated.updatedAt = Date()

        if currentAudioURL != targetURL {
            do {
                try fileManager.moveItem(at: currentAudioURL, to: targetURL)
            } catch {
                return nil
            }
        }

        guard writeMetadata(updated) else {
            if currentAudioURL != targetURL {
                try? fileManager.moveItem(at: targetURL, to: currentAudioURL)
            }
            return nil
        }

        savedRecordings[index] = updated
        savedRecordings.sort { $0.date > $1.date }
        return updated
    }

    func updateMetadata(recording: SavedRecording, location: String?, comment: String?) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recording.id }) else {
            return
        }

        var updated = savedRecordings[index]
        updated.location = normalizedOptionalText(location)
        updated.comment = normalizedOptionalText(comment)
        updated.updatedAt = Date()

        guard writeMetadata(updated) else { return }
        savedRecordings[index] = updated
    }

    func updateTranscription(
        recordingID: UUID,
        text: String,
        segments: [TranscriptionSegmentData]? = nil,
        model: String
    ) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else {
            return
        }

        var updated = savedRecordings[index]
        updated.transcription = text
        updated.transcriptionSegments = segments
        updated.transcriptionStatus = .completed
        updated.transcriptionModel = model
        updated.transcribedAt = Date()
        updated.updatedAt = Date()

        guard writeMetadata(updated) else { return }
        savedRecordings[index] = updated
    }

    func updateDiarization(recordingID: UUID, utterances: [DiarizedUtterance], speakerNames: [String: String]) {
        guard let index = savedRecordings.firstIndex(where: { $0.id == recordingID }) else {
            return
        }

        var updated = savedRecordings[index]
        updated.diarizedUtterances = utterances
        updated.speakerNames = speakerNames
        updated.updatedAt = Date()

        guard writeMetadata(updated) else { return }
        savedRecordings[index] = updated
    }

    /// Looks up a saved recording by ID (e.g. to reload a cached transcription on open).
    func recording(id: UUID) -> SavedRecording? {
        savedRecordings.first(where: { $0.id == id })
    }

    // MARK: - Voice Memo transcription cache

    /// Returns a cached transcription for a voice memo (keyed by its stable file id), if any.
    /// Voice memos aren't library recordings, so their transcriptions live in a sidecar
    /// cache in Application Support rather than in the library metadata.
    func cachedVoiceMemoTranscription(id: String) -> VoiceMemoTranscription? {
        guard let data = try? Data(contentsOf: voiceMemoTranscriptionURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceMemoTranscription.self, from: data)
    }

    /// Persists a voice memo's transcription so reopening it doesn't re-transcribe.
    func cacheVoiceMemoTranscription(id: String, text: String, segments: [TranscriptionSegmentData], model: String) {
        let dir = voiceMemoTranscriptionsDirectory()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let payload = VoiceMemoTranscription(text: text, segments: segments, model: model, date: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: voiceMemoTranscriptionURL(for: id), options: .atomic)
        }
    }

    private func voiceMemoTranscriptionsDirectory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Transcribe", isDirectory: true)
            .appendingPathComponent("VoiceMemoTranscriptions", isDirectory: true)
    }

    private func voiceMemoTranscriptionURL(for id: String) -> URL {
        // `id` is already a filename component; sanitize path separators defensively.
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return voiceMemoTranscriptionsDirectory()
            .appendingPathComponent(safe)
            .appendingPathExtension("json")
    }

    func importVoiceMemo(memo: VoiceMemoRecording) -> SavedRecording? {
        let importsDirectory = importsDirectoryURL()
        try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)

        let stagedURL = importsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(normalizedFileExtension(for: memo.fileURL))

        do {
            try fileManager.copyItem(at: memo.fileURL, to: stagedURL)
        } catch {
            return nil
        }

        defer {
            if fileManager.fileExists(atPath: stagedURL.path) {
                try? fileManager.removeItem(at: stagedURL)
            }
        }

        return save(audioURL: stagedURL, name: memo.name, duration: memo.duration, source: .voiceMemoImport)
    }

    func loadRecordings() {
        createLibraryDirectoriesIfNeeded()

        let metadataDirectory = metadataDirectoryURL()
        let metadataURLs = (try? fileManager.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        savedRecordings = metadataURLs
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let recording = try? decoder.decode(SavedRecording.self, from: data),
                      fileManager.fileExists(atPath: recording.audioURL(in: libraryURL).path) else {
                    return nil
                }
                return recording
            }
            .sorted { $0.date > $1.date }
    }

    func loadVoiceMemos() {
        guard let voiceMemosFolder = resolvedVoiceMemosURL() else {
            voiceMemos = []
            return
        }

        let metadataByFilename = voiceMemoMetadata(in: voiceMemosFolder)

        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: voiceMemosFolder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        voiceMemos = urls
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: resourceKeys), values.isRegularFile != false else {
                    return nil
                }

                let metadata = metadataByFilename[url.lastPathComponent]

                // Prefer the location-based title and recording date from the Voice
                // Memos database; fall back to the filename and file dates otherwise.
                let name = metadata?.title ?? url.deletingPathExtension().lastPathComponent
                let date = metadata?.date ?? values.contentModificationDate ?? values.creationDate ?? .distantPast
                let fileSize = Int64(values.fileSize ?? 0)

                let duration: TimeInterval
                if let dbDuration = metadata?.duration {
                    duration = dbDuration
                } else {
                    let assetDuration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                    duration = assetDuration.isFinite ? assetDuration : 0
                }

                return VoiceMemoRecording(
                    fileURL: url,
                    name: name,
                    date: date,
                    duration: duration,
                    fileSize: fileSize
                )
            }
            .sorted { $0.date > $1.date }
    }

    private func voiceMemoMetadata(in folder: URL) -> [String: VoiceMemoMetadata] {
        let databaseURL = folder.appendingPathComponent("CloudRecordings.db")
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return [:]
        }
        return VoiceMemosMetadataReader.readMetadata(databaseURL: databaseURL)
    }

    private func createLibraryDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDirectoryURL(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: importsDirectoryURL(), withIntermediateDirectories: true)
    }

    private func metadataDirectoryURL() -> URL {
        libraryURL.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
    }

    private func importsDirectoryURL() -> URL {
        libraryURL.appendingPathComponent(Self.importsDirectoryName, isDirectory: true)
    }

    private func normalizedDisplayName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Recording" : trimmed
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedFileExtension(for url: URL) -> String {
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fileExtension.isEmpty ? "m4a" : fileExtension
    }

    private func uniqueAudioURL(for name: String, date: Date, fileExtension: String, excludingFilename: String? = nil) -> URL {
        let timestamp = Self.filenameTimestampFormatter.string(from: date)
        let sanitizedName = sanitizeFilename(name)
        let baseFilename = "\(timestamp)_\(sanitizedName)"

        var candidate = libraryURL
            .appendingPathComponent(baseFilename)
            .appendingPathExtension(fileExtension)

        if !fileExistsForCollision(candidate, excludingFilename: excludingFilename) {
            return candidate
        }

        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        candidate = libraryURL
            .appendingPathComponent("\(baseFilename)_\(suffix)")
            .appendingPathExtension(fileExtension)
        return candidate
    }

    private func fileExistsForCollision(_ url: URL, excludingFilename: String?) -> Bool {
        if let excludingFilename, url.lastPathComponent == excludingFilename {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    private func moveOrCopyAudio(from sourceURL: URL, to destinationURL: URL) -> Bool {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return true
            } catch {
                return false
            }
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !Self.invalidFilenameCharacters.contains($0) }
        var sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)

        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        }

        return sanitized.isEmpty ? "recording" : sanitized
    }

    @discardableResult
    private func writeMetadata(_ recording: SavedRecording) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(recording)
            try data.write(to: recording.metadataURL(in: libraryURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func restoreVoiceMemosAccessIfAvailable() {
        guard let url = Self.resolveBookmarkURL(forKey: Self.voiceMemosBookmarkKey) else {
            return
        }
        if url.startAccessingSecurityScopedResource() {
            voiceMemosScopedURL = url
        }
    }

    private func resolvedVoiceMemosURL() -> URL? {
        if let voiceMemosScopedURL {
            return voiceMemosScopedURL
        }

        guard let url = Self.resolveBookmarkURL(forKey: Self.voiceMemosBookmarkKey) else {
            return nil
        }

        if url.startAccessingSecurityScopedResource() {
            voiceMemosScopedURL = url
        }

        return url
    }

    private func replaceScopedAccess(current: inout URL?, with url: URL) {
        current?.stopAccessingSecurityScopedResource()
        current = nil

        if url.startAccessingSecurityScopedResource() {
            current = url
        }
    }

    private func storeBookmark(for url: URL, key: String) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        UserDefaults.standard.set(bookmark, forKey: key)
    }

    private static func resolveBookmarkURL(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale,
           let refreshed = try? url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            UserDefaults.standard.set(refreshed, forKey: key)
        }

        return url
    }

    private static func defaultLibraryURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documentsURL.appendingPathComponent("Transcribe", isDirectory: true)
    }

    private static let filenameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
