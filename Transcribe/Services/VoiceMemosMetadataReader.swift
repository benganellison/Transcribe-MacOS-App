import Foundation
import SQLite3

/// Metadata for a single Voice Memo, read from Apple's `CloudRecordings.db`.
///
/// Apple's Voice Memos app labels recordings by location (e.g. "Chalmers Campus
/// Lindholmen") and stores that label, the real recording date, and the duration
/// in a Core Data SQLite database alongside the `.m4a` files. The audio filenames
/// themselves are opaque timestamps, so this metadata is what users actually use
/// to recognise a recording.
struct VoiceMemoMetadata {
    let title: String?
    let date: Date?
    let duration: TimeInterval?
}

enum VoiceMemosMetadataReader {
    /// The transient type binding used by SQLite to keep `String` arguments alive.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Reads Voice Memo metadata keyed by audio filename (e.g. `20260519 103245-760D9C63.m4a`).
    ///
    /// Returns an empty dictionary if the database is missing, locked, or has an
    /// unexpected schema — callers should fall back to filename-derived metadata.
    static func readMetadata(databaseURL: URL) -> [String: VoiceMemoMetadata] {
        var result: [String: VoiceMemoMetadata] = [:]

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return result
        }
        defer { sqlite3_close(db) }

        let query = "SELECT ZPATH, ZENCRYPTEDTITLE, ZDATE, ZDURATION FROM ZCLOUDRECORDING;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathColumn = sqlite3_column_text(statement, 0) else { continue }
            let filename = (String(cString: pathColumn) as NSString).lastPathComponent
            guard !filename.isEmpty else { continue }

            var title: String?
            if let titleColumn = sqlite3_column_text(statement, 1) {
                let value = String(cString: titleColumn).trimmingCharacters(in: .whitespacesAndNewlines)
                title = value.isEmpty ? nil : value
            }

            // ZDATE is a Core Data timestamp: seconds since 2001-01-01 00:00:00 UTC.
            var date: Date?
            if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                let referenceInterval = sqlite3_column_double(statement, 2)
                if referenceInterval > 0 {
                    date = Date(timeIntervalSinceReferenceDate: referenceInterval)
                }
            }

            var duration: TimeInterval?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                let value = sqlite3_column_double(statement, 3)
                duration = value > 0 ? value : nil
            }

            result[filename] = VoiceMemoMetadata(title: title, date: date, duration: duration)
        }

        return result
    }
}
