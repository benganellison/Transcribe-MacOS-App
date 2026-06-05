import Foundation
import SQLite3
import Testing
@testable import Transcribe

struct VoiceMemosMetadataReaderTests {
    @Test func testReadsTitleDateAndDuration() throws {
        let dbURL = try makeTempDatabase(rows: [
            ("20260519 103245-760D9C63.m4a", "Chalmers Campus Lindholmen", 800872365.220909, 1054.123),
            ("20251218 093409-403AF383.m4a", "Nexer meeting 1", 787739649.308344, 3538.468)
        ])
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let metadata = VoiceMemosMetadataReader.readMetadata(databaseURL: dbURL)

        #expect(metadata.count == 2)

        let first = try #require(metadata["20260519 103245-760D9C63.m4a"])
        #expect(first.title == "Chalmers Campus Lindholmen")
        #expect(first.duration == 1054.123)
        // ZDATE is seconds since 2001-01-01; verify the round-trip.
        #expect(first.date == Date(timeIntervalSinceReferenceDate: 800872365.220909))

        let second = try #require(metadata["20251218 093409-403AF383.m4a"])
        #expect(second.title == "Nexer meeting 1")
    }

    @Test func testMissingDatabaseReturnsEmpty() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).db")
        #expect(VoiceMemosMetadataReader.readMetadata(databaseURL: missing).isEmpty)
    }

    @Test func testBlankTitleIsTreatedAsNil() throws {
        let dbURL = try makeTempDatabase(rows: [
            ("blank.m4a", "   ", 800000000, 12)
        ])
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let metadata = VoiceMemosMetadataReader.readMetadata(databaseURL: dbURL)
        let entry = try #require(metadata["blank.m4a"])
        #expect(entry.title == nil)
    }

    // MARK: - Fixture helpers

    private func makeTempDatabase(rows: [(path: String, title: String, date: Double, duration: Double)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voicememos-\(UUID().uuidString).db")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            ZDATE TIMESTAMP,
            ZDURATION FLOAT,
            ZENCRYPTEDTITLE VARCHAR,
            ZPATH VARCHAR
        );
        """
        #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)

        for (index, row) in rows.enumerated() {
            let insert = """
            INSERT INTO ZCLOUDRECORDING (Z_PK, ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZPATH)
            VALUES (\(index + 1), \(row.date), \(row.duration), '\(row.title)', '\(row.path)');
            """
            #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
        }

        return url
    }
}
