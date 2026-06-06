import XCTest
@testable import Transcribe

final class TimedTranscriptTests: XCTestCase {

    private func w(_ t: String, _ s: Double, _ e: Double, _ c: Float = 0.9) -> WordTimestamp {
        WordTimestamp(word: t, start: s, end: e, confidence: c)
    }
    private func seg(_ s: Double, _ e: Double, _ words: [WordTimestamp]) -> TranscriptionSegmentData {
        TranscriptionSegmentData(start: s, end: e, text: words.map(\.word).joined(separator: " "), words: words)
    }

    // activeWordIndex
    func testActiveWordWithinSecond() {
        let segs = [seg(0, 2, [w("a", 0, 0.5), w("b", 0.5, 1.0), w("c", 1.0, 2.0)])]
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 0.7)?.wordIndex, 1)
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 0.7)?.segmentIndex, 0)
    }
    func testActiveWordBeforeFirstIsNil() {
        let segs = [seg(1, 2, [w("a", 1, 2)])]
        XCTAssertNil(TimedTranscript.activeWord(in: segs, at: 0.5))
    }
    func testActiveWordAfterLastIsLast() {
        let segs = [seg(0, 2, [w("a", 0, 1), w("b", 1, 2)])]
        let r = TimedTranscript.activeWord(in: segs, at: 5.0)
        XCTAssertEqual(r?.wordIndex, 1)
    }
    func testActiveWordInGapPicksPrevious() {
        let segs = [seg(0, 3, [w("a", 0, 1), w("b", 2, 3)])]   // gap 1..2
        XCTAssertEqual(TimedTranscript.activeWord(in: segs, at: 1.5)?.wordIndex, 0)
    }

    // rebuildText
    func testRebuildTextJoinsSegments() {
        let segs = [seg(0, 1, [w("Hej", 0, 1)]), seg(1, 2, [w("då", 1, 2)])]
        XCTAssertEqual(TimedTranscript.rebuildText(from: segs), "Hej då")
    }

    // sentence reconciliation
    func testReconcileSameWordCountKeepsTiming() {
        let original = seg(0, 2, [w("the", 0, 0.5), w("cat", 0.5, 2.0)])
        let result = TimedTranscript.reconcileSentence(original, newText: "the dog")
        XCTAssertEqual(result.words?.map(\.word), ["the", "dog"])
        XCTAssertEqual(result.words?[0].start, 0)
        XCTAssertEqual(result.words?[1].start, 0.5)
        XCTAssertNotEqual(result.timingApproximate, true)
    }
    func testReconcileDifferentCountDistributesEvenly() {
        let original = seg(0, 3, [w("the", 0, 1.5), w("cat", 1.5, 3.0)])
        let result = TimedTranscript.reconcileSentence(original, newText: "the big black cat")
        XCTAssertEqual(result.words?.count, 4)
        XCTAssertEqual(result.words?.first?.start, 0)
        XCTAssertEqual(result.words?.last?.end, 3.0)
        XCTAssertEqual(result.timingApproximate, true)
        XCTAssertEqual(result.words?[1].start ?? 0, 0.75, accuracy: 0.001)
    }

    // restore
    func testOriginalWordByTime() {
        let original = [seg(0, 2, [w("the", 0, 1), w("cat", 1, 2)])]
        XCTAssertEqual(TimedTranscript.originalWord(in: original, atMidpointOf: w("CAT", 1, 2))?.word, "cat")
    }
    func testOriginalSegmentByOverlap() {
        let original = [seg(0, 2, [w("a", 0, 2)]), seg(2, 4, [w("b", 2, 4)])]
        XCTAssertEqual(TimedTranscript.originalSegment(in: original, overlapping: seg(2, 4, [w("X", 2, 4)]))?.text, "b")
    }
}
