import XCTest
@testable import Transcribe

final class SpeakerReconciliationTests: XCTestCase {

    private func u(_ speaker: String, _ text: String, _ start: Double, _ end: Double) -> DiarizedUtterance {
        let words = text.split(separator: " ").enumerated().map { i, w in
            WordTimestamp(word: String(w), start: start + Double(i) * 0.1, end: start + Double(i) * 0.1 + 0.1, confidence: 1.0)
        }
        return DiarizedUtterance(speakerID: speaker, text: text, startTime: start, endTime: end, words: words)
    }

    func testMergeRelabelsAndRegroups() {
        let utts = [u("Speaker 1", "hello", 0, 1), u("Speaker 3", "there", 1, 2)]
        let result = SpeakerReconciliation.merge(utts, from: "Speaker 3", into: "Speaker 1")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, "Speaker 1")
        XCTAssertEqual(result[0].text, "hello there")
        XCTAssertEqual(result[0].startTime, 0)
        XCTAssertEqual(result[0].endTime, 2)
        XCTAssertEqual(result[0].words?.count, 2)
    }

    func testMergeIntoSelfIsNoop() {
        let utts = [u("Speaker 1", "a", 0, 1), u("Speaker 2", "b", 1, 2)]
        XCTAssertEqual(SpeakerReconciliation.merge(utts, from: "Speaker 1", into: "Speaker 1"), utts)
    }

    func testReassignOneSplitsRun() {
        let a = u("Speaker 1", "a", 0, 1)
        let b = u("Speaker 1", "b", 1, 2)
        let c = u("Speaker 1", "c", 2, 3)
        let result = SpeakerReconciliation.reassign([a, b, c], utteranceID: b.id, to: "Speaker 2")
        XCTAssertEqual(result.map(\.speakerID), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(result.count, 3)
    }

    func testNextSpeakerLabelSkipsToMaxPlusOne() {
        let utts = [u("Speaker 1", "a", 0, 1), u("Speaker 3", "b", 1, 2)]
        XCTAssertEqual(SpeakerReconciliation.nextSpeakerLabel(in: utts), "Speaker 4")
    }

    func testRegroupConcatenatesInTimeOrder() {
        let utts = [u("Speaker 1", "one", 0, 1), u("Speaker 1", "two", 1, 2)]
        let result = SpeakerReconciliation.regroupAdjacent(utts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "one two")
        XCTAssertEqual(result[0].words?.map(\.word), ["one", "two"])
        XCTAssertEqual(result[0].endTime, 2)
    }

    func testDistinctSpeakersFirstAppearanceOrder() {
        let utts = [u("Speaker 2", "a", 0, 1), u("Speaker 1", "b", 1, 2), u("Speaker 2", "c", 2, 3)]
        XCTAssertEqual(SpeakerReconciliation.distinctSpeakers(in: utts), ["Speaker 2", "Speaker 1"])
    }

    func testSplitUtteranceBreaksAtWordIndex() {
        let utt = u("Speaker 2", "a b c d", 0, 4)
        let result = SpeakerReconciliation.splitUtterance([utt], utteranceID: utt.id, beforeWordIndex: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "a b")
        XCTAssertEqual(result[1].text, "c d")
        XCTAssertEqual(result[0].speakerID, "Speaker 2")
        XCTAssertEqual(result[1].speakerID, "Speaker 2")
        XCTAssertEqual(result[0].words?.count, 2)
        XCTAssertEqual(result[1].words?.count, 2)
    }

    func testSplitOutOfRangeIsNoop() {
        let utt = u("Speaker 1", "a b", 0, 2)
        XCTAssertEqual(SpeakerReconciliation.splitUtterance([utt], utteranceID: utt.id, beforeWordIndex: 0), [utt])
        XCTAssertEqual(SpeakerReconciliation.splitUtterance([utt], utteranceID: utt.id, beforeWordIndex: 2), [utt])
    }

    func testReassignDoesNotRegroupNeighbors() {
        // Two same-speaker turns; reassigning the first must NOT merge with the second.
        let a = u("Speaker 1", "a", 0, 1)
        let b = u("Speaker 1", "b", 1, 2)
        let result = SpeakerReconciliation.reassign([a, b], utteranceID: a.id, to: "Speaker 1")
        XCTAssertEqual(result.count, 2)
    }
}
