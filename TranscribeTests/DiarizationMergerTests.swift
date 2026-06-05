import XCTest
@testable import Transcribe

final class DiarizationMergerTests: XCTestCase {

    // Minimal word input shape the merger consumes.
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizationMerger.Word {
        DiarizationMerger.Word(text: text, start: start, end: end)
    }

    func testGroupsConsecutiveSameSpeakerWords() async {
        let words = [w("Hej", 0.0, 0.5), w("alla", 0.5, 1.0), w("välkomna", 1.0, 1.8)]
        let speakers = [SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 2.0)]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "Hej alla välkomna")
        XCTAssertEqual(result[0].startTime, 0.0)
        XCTAssertEqual(result[0].endTime, 1.8)
    }

    func testSplitsAtSpeakerChangeMidStream() async {
        // Speaker 1 then Speaker 2 at t=1.0 — boundary falls between words.
        let words = [w("Hej", 0.0, 0.4), w("Bob", 0.4, 0.9), w("Hej", 1.1, 1.5), w("Anna", 1.5, 2.0)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 1.0, end: 2.5),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.map(\.speakerID), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result[0].text, "Hej Bob")
        XCTAssertEqual(result[1].text, "Hej Anna")
    }

    func testWordMidpointDecidesAssignment() async {
        // Word spans 0.8–1.2, midpoint 1.0 lands exactly on the boundary -> earlier block wins.
        let words = [w("gräns", 0.8, 1.2)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 1.0, end: 2.0),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
    }

    func testSingleSpeakerWhenNoSpeakerBlocks() async {
        let words = [w("ensam", 0.0, 0.5)]
        let result = await DiarizationMerger().merge(words: words, speakers: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
    }

    func testEmptyWordsReturnsEmpty() async {
        let result = await DiarizationMerger().merge(
            words: [],
            speakers: [SpeakerSegment(speakerLabel: "Speaker 1", start: 0, end: 1)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testWordInGapAttachesToPreviousSpeaker() async {
        // Second word's midpoint (2.0) is in a gap between blocks -> overlap=0 -> previous speaker.
        let words = [w("ett", 0.2, 0.6), w("två", 1.9, 2.1)]
        let speakers = [
            SpeakerSegment(speakerLabel: "Speaker 1", start: 0.0, end: 1.0),
            SpeakerSegment(speakerLabel: "Speaker 2", start: 3.0, end: 4.0),
        ]
        let result = await DiarizationMerger().merge(words: words, speakers: speakers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "ett två")
    }
}
